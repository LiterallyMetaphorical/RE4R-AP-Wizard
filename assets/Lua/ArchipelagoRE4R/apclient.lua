-- apclient.lua -- in-Lua Archipelago client (lua-apclientpp), folded into the ctx
-- mod. Loaded by ArchipelagoRE4R.lua via dofile(...)(ctx) after bridge.lua so it
-- can reach ctx (injection / runtime / per-seed session store).
--
-- Phase 2d: received items -> in-game injection.
--   * on_items_received enqueues each item by its absolute item.index, filtering
--     index <= the persisted watermark (bridge.last_received_index) and dupes.
--   * the poll tick drains the queue, gated on runtime.lua safe-state, in strict
--     contiguous index order, bounded per tick.
--   * own-world physical pickups (item.player == our numeric slot AND
--     item.location > 0) are SKIPPED (BioRand already placed them physically),
--     advancing the watermark without injecting.
--   * everything else resolves item.item (AP id) via ap_item_map.json ->
--     {re4r_item_id, count} and calls the existing verbatim
--     ctx.inject_item_to_inventory; success is decided by ctx.inject_command_
--     succeeded; own-find suppression is recorded with the committed count.
--   * the watermark is persisted immediately after each successful inject (so a
--     Sync/reconnect replay cannot re-inject it) and lazily-flushed after
--     skip-only runs; a failed disk write is retried with back-pressure (delivery
--     pauses until it succeeds). KNOWN LIMITATION (audit F8): the watermark tracks
--     RAM injection, not the game's own save -- an item injected but not yet
--     committed at a typewriter can be lost on a quit-without-save (this matches
--     the Python client); full save-reconciliation is deferred to F8.
--   * poison policy (Cam): unmapped AP id -> skip immediately (loud); a
--     repeatedly-failing inject retries a bounded number of ticks then skips, so
--     one bad item can never permanently freeze all later delivery. (Inventory-
--     full is NOT a failure here: inject_item_to_inventory falls back to Storage.)
--
-- Native-touching bodies (inject_item_to_inventory, get_runtime_state, the inject
-- helpers) are CALLED as existing ctx exports, never reconstructed here.
--
-- Design guards (from the adversarial review):
--   * bounded package.loadlib (never RE2R's infinite `while AP==nil` loop)
--   * every handler body individually pcall-wrapped (a Lua error inside a native
--     apclientpp callback can longjmp across C++ and crash)
--   * the first socket_error is non-fatal (ws/wss autodetect emits a spurious one)

return function(ctx)
    local TAG = "[APClient]"
    local function info(m) log.info(TAG .. " " .. m) end
    local function warn(m) log.warn(TAG .. " " .. m) end
    local function err(m) log.error(TAG .. " " .. m) end

    local function guard(name, fn)
        return function(...)
            local ok, e = pcall(fn, ...)
            if not ok then
                err("handler '" .. name .. "' errored: " .. tostring(e))
            end
        end
    end

    -- 1) Load the DLL (bounded).
    local opener, load_err = package.loadlib("lua-apclientpp.dll", "luaopen_apclientpp")
    if not opener then
        err("package.loadlib failed: " .. tostring(load_err) .. " -- AP client disabled.")
        return
    end
    local ok_open, AP = pcall(opener)
    if not ok_open or type(AP) ~= "table" then
        err("luaopen_apclientpp failed: " .. tostring(AP) .. " -- AP client disabled.")
        return
    end
    info("lua-apclientpp loaded, _VERSION = " .. tostring(AP._VERSION))

    local GAME_NAME = "Resident Evil 4 Remake"
    local ITEMS_HANDLING = 0x7           -- 0b111
    -- [DeathLink] The "DeathLink" tag is carried ALWAYS (not toggled by the option),
    -- because lua-apclientpp exposes no ConnectUpdate to change tags after connect and
    -- slot_data.death_link only arrives post-connect. Behaviour is gated on
    -- st.death_link_enabled instead: an opted-out slot never sends a death and ignores
    -- every incoming one, so carrying the tag is harmless (it only lets the server
    -- deliver death Bounces we then drop).
    local CLIENT_TAGS = { "AP", "DeathLink" }
    local CLIENT_VERSION = { 0, 6, 7 }   -- matches the RE4R apworld protocol
    -- REFramework json.load_file resolves these under reframework/data/.
    local CONNECTION_INFO_FILE = "ArchipelagoRE4R\\ap_connection.json"
    local AP_ITEM_MAP_FILE = "ArchipelagoRE4R\\ap_item_map.json"
    -- [GatedKeys] Written by the launcher at patch time: this room's exact
    -- location-id set (the room's list varies with YAML options since apworld
    -- 0.4.0, so no shipped map can be trusted for scouting).
    local ROOM_LOCATIONS_FILE = "ArchipelagoRE4R\\ap_room_locations.json"
    -- [Port recovery] Seconds of NO contact with the server before the recovery
    -- dialog appears. Measured from client creation or the last time anything
    -- answered, NOT from connect() calls: connect() runs once and lua-apclientpp
    -- retries the socket internally, so counting calls never advances (that bug
    -- is why the dialog never showed on its first live test, 2026-07-29). Long
    -- enough to ride out a sleeping room waking up, short enough that a player
    -- is not left staring at a silent "Connecting...".
    local PORT_UNREACHABLE_SECONDS = 20

    -- Per-tick drain bounds: cap heavy native injects, and cap total items
    -- processed (cheap skips included) so a huge Sync backlog can't stall a frame.
    local MAX_INJECTS_PER_TICK = 3
    local MAX_ITEMS_PER_TICK = 40
    local INVENTORY_STABILITY_SECONDS = 3.0
    -- A repeatedly-failing inject retries this many ticks (while in a safe state)
    -- before being skipped to unblock the queue.
    local MAX_INJECT_RETRIES = 20
    -- [DeathLink] After we send OR apply a death, suppress death traffic for this long
    -- (os.clock seconds): ignore redelivered/echoed incoming deaths and don't re-detect
    -- our own. The inbound kill (game-over screen) never sets IsDead, so there is no
    -- true feedback loop -- this is belt-and-suspenders against bounce bursts.
    local DEATHLINK_AMNESTY_SECONDS = 8.0

    local ap = nil
    local st = {
        server = "",
        slot = "",
        password = "",
        first_socket_error_seen = false,
        numeric_slot = nil,      -- our slot number (get_player_number()), for own-find skip
        seed = "",               -- get_seed(), for the per-seed session file
        item_map_loaded = false, -- ap_item_map.json positively loaded? (gates the drain)
        watermark_dirty = false, -- a watermark persist failed; retry + back-pressure
        -- [DeathLink] set from slot_data.death_link on connect (gates all death traffic)
        death_link_enabled = false,
        dl_last_dead = false,       -- previous IsDead sample, for rising-edge detection
        dl_pending_incoming = nil,  -- {source, cause} queued kill, applied on a safe tick
        dl_amnesty_until = 0,       -- os.clock() until which death traffic is suppressed
    }

    -- AP item id (number) -> { re4r_item_id = <engine id>, count = <delivery count> }
    local ap_item_map = {}
    -- Pending received-items queue + an index set for O(1) enqueue dedup.
    local pending = {}
    local pending_by_index = {}
    -- [F8] Full ledger of every item the server has delivered this connection,
    -- keyed by absolute index -> { item, player, location, flags }. Unlike
    -- `pending` (drained + popped), it is never cleared during play, so a save
    -- rollback can re-queue items already injected. Reset on (re)connect, then
    -- rebuilt by the server's on-connect ReceivedItems replay.
    local received_ledger = {}
    -- index -> consecutive failed-inject tick count (poison retry bookkeeping).
    local inject_failure_counts = {}
    -- [Phase 3] AP location ids already submitted this socket (avoid re-spamming).
    local sent_location_checks = {}
    -- [GatedKeys] The ROOM's actual location id set (missing + checked from the
    -- Connected packet). Since apworld 0.4.0 the location count varies with the
    -- RandomizeGatedKeys option, so the shipped guid/display maps can list
    -- locations this room does not have (vanilla/preserved spots). Every scout
    -- and LocationChecks send is filtered to this set; nil = unavailable ->
    -- fall back to the permissive pre-0.4.0 behavior.
    local room_location_ids = nil
    -- [GatedKeys] lids we already explained in the log (once per session).
    local skipped_non_room_lids = {}

    local function trim(s)
        if type(s) ~= "string" then return "" end
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    -- [Port recovery] The room's expected seed, from the file the launcher wrote
    -- at patch time. Held so a RoomInfo answering with a DIFFERENT seed can be
    -- recognised as "some other multiworld took this port" instead of surfacing
    -- as a bare "Refused: InvalidSlot" (live 2026-07-22, port 65188 -> 46497).
    local function read_expected_seed()
        local ok, payload = pcall(function() return json.load_file(ROOM_LOCATIONS_FILE) end)
        if ok and type(payload) == "table" then
            local seed = trim(payload.seed_name)
            if seed ~= "" then return seed end
        end
        return ""
    end

    -- host:port -> host, port (port nil when the address carries none).
    local function split_server_address(address)
        local text = trim(address)
        local host, port = text:match("^(.*):(%d+)$")
        if host ~= nil then return host, tonumber(port) end
        return text, nil
    end

    local function open_port_recovery(kind, actual_seed, attempts)
        local bridge = ctx.bridge
        if bridge == nil then return end
        -- The player dismissed this exact warning: stay quiet until a connect
        -- succeeds or the address changes (both clear the latch). Without it
        -- the watchdog re-opened the dialog on the very next poll tick, so
        -- Dismiss appeared to do nothing (playtest 2026-08-02). A DIFFERENT
        -- kind still opens: that is new information, not a repeat.
        if st.port_recovery_dismissed_kind == kind then return end
        local host, port = split_server_address(st.server)
        if type(bridge.port_recovery_input) ~= "string" or bridge.port_recovery_input == "" then
            bridge.port_recovery_input = (port ~= nil) and tostring(port) or ""
        end
        bridge.port_recovery_dialog = {
            kind = kind,
            expected_seed = st.expected_seed or "",
            actual_seed = actual_seed or "",
            server = st.server,
            host = host,
            room_url = st.room_url or "",
            attempts = attempts or 0,
        }
    end

    local function close_port_recovery()
        local bridge = ctx.bridge
        if bridge ~= nil then
            bridge.port_recovery_dialog = nil
            bridge.port_recovery_status = ""
        end
    end

    local function read_connection_info()
        local payload = json.load_file(CONNECTION_INFO_FILE)
        if type(payload) ~= "table" then return false end
        local server = trim(payload.server_address)
        local slot = trim(payload.slot_name)
        if server == "" or slot == "" then return false end
        st.server = server
        st.slot = slot
        st.password = trim(payload.password)
        -- The room's web page, written by the launcher at patch time. The mod
        -- cannot fetch it (no HTTP in REFramework's Lua), but the port-recovery
        -- dialog shows it so the player knows exactly where to read the new
        -- port. Absent on installs patched before this field existed.
        st.room_url = trim(payload.room_url)
        return true
    end

    -- Load the AP-id -> engine-id + count map (emitted by data_parser.py). Keyed
    -- by AP id string on disk; we number-key it for lookup against item.item.
    local function load_ap_item_map()
        ap_item_map = {}
        st.item_map_loaded = false
        local payload = json.load_file(AP_ITEM_MAP_FILE)
        if type(payload) ~= "table" or type(payload.items) ~= "table" then
            err("ap_item_map.json missing/invalid (" .. AP_ITEM_MAP_FILE ..
                ") -- received items cannot be resolved; delivery deferred until it loads.")
            return
        end
        local n = 0
        for key, value in pairs(payload.items) do
            local ap_id = tonumber(key)
            local engine_id = type(value) == "table" and tonumber(value.re4r_item_id) or nil
            if ap_id ~= nil and engine_id ~= nil then
                -- floor+clamp to an integer >= 1, matching inject_get_expected_commit_count
                -- and record_local_injection_suppression, so a non-integer count can't
                -- reach the native inject or a %d format.
                local count = math.floor((type(value) == "table" and tonumber(value.count)) or 1)
                ap_item_map[ap_id] = {
                    re4r_item_id = engine_id,
                    count = math.max(1, count),
                    name = (type(value.name) == "string" and value.name ~= "") and value.name or nil,
                    kind = (type(value.kind) == "string" and value.kind ~= "") and value.kind or nil,
                }
                n = n + 1

            end
        end
        st.item_map_loaded = n > 0
        info("loaded ap_item_map.json: " .. n .. " AP-id -> engine-id+count entries")
    end

    -- The exact 5-field compound bridge.lua uses before injecting (is_playable
    -- already implies the others, but we mirror the proven gate verbatim).
    local function safe_to_inject(rs)
        return rs ~= nil
            and rs.is_in_game
            and rs.player_present
            and rs.is_playable
            and not rs.is_loading
            and not rs.is_cutscene
    end

    -- [Phase 4/Overlay] Exact port of client.py _classify_location_scout_flags: AP
    -- ItemFlags -> the three UI buckets. ADVANCEMENT(1) -> PROGRESSION, NEVER_EXCLUDE(2)
    -- -> USEFUL, else FILLER (TRAP=4 falls to FILLER, matching the Python client). Shared
    -- by the scout classification and the received-item toast colour.
    local function classify_flags(raw_flags)
        local flags = math.floor(tonumber(raw_flags) or 0)
        if (flags & 1) ~= 0 then return "PROGRESSION" end
        if (flags & 2) ~= 0 then return "USEFUL" end
        return "FILLER"
    end

    -- [Overlay] Push a toast into the shared check_notifications queue ui_overlay renders
    -- (same schema as detector.lua's toasts; id from next_check_notification_id).
    local function enqueue_toast(title, detail, classification, kind, title_segments)
        local bridge = ctx.bridge
        if bridge == nil or type(bridge.check_notifications) ~= "table" then return end
        local id = tonumber(bridge.next_check_notification_id) or 1
        local now = ctx.now_unix_ms or _G.now_unix_ms
        table.insert(bridge.check_notifications, {
            id = id,
            title = (type(title) == "string") and title:sub(1, 52) or "",
            detail = (type(detail) == "string" and detail ~= "") and detail:sub(1, 74) or nil,
            classification = classification,
            kind = kind, -- event type (received/sent/hint/goal/death) -> glyph in ui_overlay
            title_segments = title_segments, -- per-entity colours; nil = plain title
            native_route = "text", -- native_log.lua composes + pushes onto the game rail
            queued_at_unix_ms = (type(now) == "function") and now() or (os.time() * 1000),
            display_started_at_unix_ms = nil,
        })
        bridge.next_check_notification_id = id + 1
    end

    -- [Overlay] Coalesce a burst of received items (the reconnect catch-up resend,
    -- or a pile of items granted while offline) into ONE rolling "Synced N items"
    -- toast instead of N individual toasts. bump() creates/updates the summary and
    -- keeps it alive; finalize() ends the burst (leaving the toast on screen) so the
    -- next live item toasts normally again.
    local function bump_sync_summary(added, is_restore)
        local bridge = ctx.bridge
        if bridge == nil or type(bridge.check_notifications) ~= "table" then return end
        st.sync_summary_count = (st.sync_summary_count or 0) + (tonumber(added) or 1)
        if is_restore then st.sync_summary_is_restore = true end
        local now = ctx.now_unix_ms or _G.now_unix_ms
        local now_ms = (type(now) == "function") and now() or (os.time() * 1000)
        local n = st.sync_summary_count
        -- [F8] A burst that includes reconciled (re-delivered) items reads as a
        -- restore, so a post-death catch-up doesn't look like a fresh windfall.
        local verb = (st.sync_summary_is_restore == true) and "Restored" or "Synced"
        local label = (n == 1) and (verb .. " 1 item") or (verb .. " " .. n .. " items")
        local existing = nil
        for _, t in ipairs(bridge.check_notifications) do
            if t.id == st.sync_summary_toast_id then existing = t break end
        end
        if existing ~= nil then
            existing.title = label
            existing.display_started_at_unix_ms = nil -- restart lifetime so it stays visible
            existing.queued_at_unix_ms = now_ms
        else
            local id = tonumber(bridge.next_check_notification_id) or 1
            st.sync_summary_toast_id = id
            table.insert(bridge.check_notifications, {
                id = id,
                title = label,
                detail = nil,
                classification = "USEFUL",
                kind = "received", -- "Synced N items" is a batch of received items
                -- The rolling summary mutates its title in place; native rail
                -- entries are fire-once, so this one stays on the imgui overlay
                -- in every mode.
                native_route = "overlay_only",
                queued_at_unix_ms = now_ms,
                display_started_at_unix_ms = nil,
            })
            bridge.next_check_notification_id = id + 1
        end
    end

    local function finalize_sync_summary()
        st.in_sync_burst = false
        -- Burst settled: the title stops mutating, so the summary may now ride
        -- the native rail once (Cam-approved 2026-07-23). native_log re-dispatches
        -- it and, in native mode, takes over from the imgui copy.
        if st.sync_summary_toast_id ~= nil and (st.sync_summary_count or 0) > 0 then
            local bridge = ctx.bridge
            if bridge ~= nil and type(bridge.check_notifications) == "table" then
                for _, t in ipairs(bridge.check_notifications) do
                    if t.id == st.sync_summary_toast_id then
                        t.native_route = "text"
                        t.native_dispatched = false
                        break
                    end
                end
            end
        end
        st.sync_summary_count = 0
        st.sync_summary_toast_id = nil
        st.sync_summary_is_restore = nil
    end

    -- [Overlay] Resolve an AP slot number to a display name via get_player_alias
    -- (pcall-guarded). Falls back to "Player <n>".
    local function ap_player_name(slot)
        if ap == nil or type(slot) ~= "number" then return nil end
        local ok, name = pcall(function() return ap:get_player_alias(slot) end)
        if ok and type(name) == "string" and name ~= "" then return name end
        return "Player " .. tostring(slot)
    end
    ctx.ap_player_name = ap_player_name -- [Overlay] exported for detector's found-for-player toast

    -- [Overlay] Resolve an AP item id to a display name. The name lives in the data package of
    -- the OWNING player's game, so pass that slot. pcall-guarded; nil if unresolved. Exported so
    -- detector's unified pickup toast can name the item that ACTUALLY sits at a location.
    -- GOTCHA (live 2026-07-21, toast read "Collected Unknown"): apclientpp's
    -- get_item_name takes the owning GAME NAME (a string), NOT a slot number. Passing
    -- the slot yields apclientpp's "Unknown" placeholder -- sol2 coerces 5 -> "5",
    -- which matches no game, so the call SUCCEEDS and returns a non-empty string,
    -- defeating the old `name ~= ""` check. Map slot -> game via get_player_game
    -- first, keep the numeric and single-arg forms as fallbacks so this holds whatever
    -- shape the binding actually has, and treat "Unknown" as FAILURE so callers fall
    -- back to the vanilla item name rather than printing "Unknown" at the player.
    local function ap_item_name(item_id, player)
        if ap == nil or type(item_id) ~= "number" then return nil end
        local function usable(name)
            return type(name) == "string" and name ~= "" and name ~= "Unknown"
        end
        local attempts = {}
        if type(player) == "number" then
            local ok_game, game = pcall(function() return ap:get_player_game(player) end)
            if ok_game and type(game) == "string" and game ~= "" then
                attempts[#attempts + 1] = function() return ap:get_item_name(item_id, game) end
            end
            attempts[#attempts + 1] = function() return ap:get_item_name(item_id, player) end
        end
        attempts[#attempts + 1] = function() return ap:get_item_name(item_id) end
        for _, attempt in ipairs(attempts) do
            local ok, name = pcall(attempt)
            if ok and usable(name) then return name end
        end
        return nil
    end
    ctx.ap_item_name = ap_item_name

    -- [Hints] Send raw text/commands to the server (chat + "!" commands). The AP
    -- Actions window builds "!hint <item>" etc. on top of this; responses come
    -- back through the normal PrintJSON pipeline. Returns false when offline.
    local function ap_say(text)
        if ap == nil or type(text) ~= "string" or text == "" then return false end
        local ok = pcall(function() ap:Say(text) end)
        return ok == true
    end
    ctx.ap_say = ap_say

    -- [Hints] Hint economy readout for UI ("96 points - a hint costs 48").
    -- Cost getter name differs across lua-apclientpp builds; probe both.
    local function ap_get_hint_economy()
        if ap == nil then return nil, nil end
        local points, cost = nil, nil
        local ok_points, points_value = pcall(function() return ap:get_hint_points() end)
        if ok_points and type(points_value) == "number" then points = points_value end
        local ok_cost, cost_value = pcall(function() return ap:get_hint_cost_points() end)
        if ok_cost and type(cost_value) == "number" then
            cost = cost_value
        else
            local ok_pct, pct_value = pcall(function() return ap:get_hint_cost_percent() end)
            if ok_pct and type(pct_value) == "number" then
                local total = 0
                for _ in pairs(room_location_ids or {}) do total = total + 1 end
                cost = math.floor((total * pct_value) / 100)
            end
        end
        return points, cost
    end
    ctx.ap_get_hint_economy = ap_get_hint_economy

    -- [Actions] Sorted AP item ids of OUR game (ap_item_map.json keys) for the
    -- hint-an-item picker; names resolve via ap_item_name at draw time.
    local function ap_get_own_item_ids()
        local ids = {}
        for ap_id in pairs(ap_item_map) do
            ids[#ids + 1] = ap_id
        end
        table.sort(ids)
        return ids
    end
    ctx.ap_get_own_item_ids = ap_get_own_item_ids

    -- [Actions] Force-check one of OUR locations (stuck-tester escape hatch,
    -- confirmed in the Actions tab). The server round-trip acknowledges it
    -- through the normal on_location_checked path - no special bookkeeping.
    local function ap_force_check(location_id)
        local id = tonumber(location_id)
        if ap == nil or id == nil then return false end
        local ok = pcall(function() ap:LocationChecks({ math.floor(id) }) end)
        if ok then
            info(string.format("FORCE-CHECK submitted for location %d (debug escape hatch)", math.floor(id)))
        end
        return ok == true
    end
    ctx.ap_force_check = ap_force_check

    -- [Hints] Rebuild bridge.hints_on_my_world from the server's _read_hints
    -- list: keep only UNFOUND hints where WE are the finding player (checks in
    -- our world someone is waiting on), keyed by location_id string. Names are
    -- resolved eagerly (receiving player's datapackage owns the item name).
    local function rebuild_hints_on_my_world(value)
        if ctx.bridge == nil then return end
        local result = {}
        local kept = 0
        if type(value) == "table" then
            for _, hint in ipairs(value) do
                if type(hint) == "table"
                    and tonumber(hint.finding_player) == tonumber(st.numeric_slot)
                    and hint.found ~= true then
                    local location_id = tonumber(hint.location)
                    if location_id ~= nil then
                        local receiving_player = tonumber(hint.receiving_player)
                        local item_id = tonumber(hint.item)
                        result[tostring(math.floor(location_id))] = {
                            location_id = math.floor(location_id),
                            item_id = item_id,
                            item_name = ap_item_name(item_id, receiving_player),
                            receiving_player = receiving_player,
                            receiving_player_name = ap_player_name(receiving_player),
                            item_flags = tonumber(hint.item_flags) or 0,
                        }
                        kept = kept + 1
                    end
                end
            end
        end
        ctx.bridge.hints_on_my_world = result
        info(string.format("Hints on our world: %d unfound (storage sync)", kept))
    end

    -- DataStorage replies. Retrieved answers our initial Get; SetReply arrives on
    -- every later change to a subscribed key (new hint bought, found flipped).
    local function on_retrieved(map)
        if type(map) ~= "table" or st.hints_storage_key == nil then return end
        local value = map[st.hints_storage_key]
        if value ~= nil then rebuild_hints_on_my_world(value) end
    end

    local function on_set_reply(message)
        if type(message) ~= "table" or st.hints_storage_key == nil then return end
        if message.key == st.hints_storage_key then
            rebuild_hints_on_my_world(message.value)
        end
    end

    -- Drain the received-items queue. Called every tick after ap:poll().
    local function drain_received_items()
        local bridge = ctx.bridge
        if bridge == nil then return end
        local save = (type(ctx.save_session_state) == "function") and ctx.save_session_state or function() return true end

        -- persist(): write the watermark to disk; on failure flag dirty so we retry
        -- with back-pressure. Returns whether the write succeeded.
        local function persist()
            if save() then
                st.watermark_dirty = false
                return true
            end
            st.watermark_dirty = true
            err("failed to persist received-item watermark to disk (delivery paused; will retry)")
            return false
        end

        -- Retry a previously-failed persist first, and hold delivery until the disk
        -- watermark catches up to an already-injected item.
        if st.watermark_dirty then
            if not persist() then return end
        end

        -- [F8] Save-reconciliation. A campaign load (die->Continue, manual Load, or
        -- the boot load) restored inventory to a saved version; any items received
        -- and injected AFTER that version was written were dropped by the rollback.
        -- The loadGameSaveData hook recorded which version loaded; here we roll the
        -- delivery watermark back to what that version baked in and re-queue the gap
        -- for the normal drain below to re-inject. An unknown version is NEVER
        -- guessed (no re-delivery), so a load can never double-grant.
        do
            local req = bridge.pending_save_reconcile
            if req ~= nil then
                local lookup = ctx.lookup_save_floor
                local floor = (type(lookup) == "function") and lookup(req.guid, req.save_count) or nil
                if floor ~= nil then
                    local old_wm = math.floor(tonumber(bridge.last_received_index) or -1)
                    if old_wm > floor then
                        local requeued = 0
                        for idx = floor + 1, old_wm do
                            if not pending_by_index[idx] then
                                local led = received_ledger[idx]
                                if led ~= nil then
                                    pending[#pending + 1] = {
                                        index = idx,
                                        item = led.item,
                                        player = led.player,
                                        location = led.location,
                                        flags = led.flags,
                                        reconcile = true, -- [F8] mark as a restore for the toast wording
                                    }
                                    pending_by_index[idx] = true
                                    requeued = requeued + 1
                                end
                            end
                        end
                        bridge.last_received_index = floor
                        bridge.state_dirty = true
                        info(string.format(
                            "F8 reconcile: save '%s' #%s baked watermark %d; live was %d -> rolled back, re-queued %d item(s) for re-delivery",
                            tostring(req.guid), tostring(req.save_count), floor, old_wm, requeued))
                        persist()
                    end
                    bridge.pending_save_reconcile = nil
                elseif bridge.loaded_session_state_path ~= nil then
                    -- Session state is loaded but this exact save version has no
                    -- recorded watermark (a pre-fix save, or one never observed being
                    -- written) -> safe: decline to re-deliver rather than guess.
                    info(string.format(
                        "F8 reconcile: no recorded watermark for save '%s' #%s -> no re-delivery (safe; pre-fix or uncaptured save)",
                        tostring(req.guid), tostring(req.save_count)))
                    bridge.pending_save_reconcile = nil
                end
                -- else: session state not loaded yet (pre-connect) -> keep the request
                -- pending until the per-seed watermark + reconcile map are available.
            end
        end

        if #pending == 0 then return end

        -- Refuse to touch the item stream until the AP-id -> engine map is loaded:
        -- otherwise every item hits the unmapped branch and is lost. Retry the load
        -- (throttled) so a transient file error self-heals; items stay queued.
        if not st.item_map_loaded then
            local now = os.clock()
            if now - (st.item_map_retry_clock or -1e9) >= 5.0 then
                st.item_map_retry_clock = now
                warn("ap_item_map not loaded; deferring item delivery and retrying load")
                load_ap_item_map()
            end
            if not st.item_map_loaded then return end
        end

        -- Need our numeric slot for the own-find skip; lazily (re)resolve rather
        -- than defer forever, and surface a persistent stall.
        if st.numeric_slot == nil and ap ~= nil then
            local ok_num, num = pcall(function() return ap:get_player_number() end)
            st.numeric_slot = (ok_num and type(num) == "number") and num or nil
        end
        if st.numeric_slot == nil then
            local now = os.clock()
            if now - (st.numeric_slot_warn_clock or -1e9) >= 5.0 then
                st.numeric_slot_warn_clock = now
                warn("numeric slot unresolved (get_player_number); deferring item delivery")
            end
            return
        end

        -- Without a seed the watermark keys to a shared/standalone file, colliding
        -- across distinct multiworlds; defer rather than risk that.
        if st.seed == nil or st.seed == "" then
            local now = os.clock()
            if now - (st.seed_warn_clock or -1e9) >= 5.0 then
                st.seed_warn_clock = now
                warn("seed unresolved; deferring item delivery to avoid cross-seed watermark collision")
            end
            return
        end

        local get_runtime_state = ctx.get_runtime_state
        local inject_item_to_inventory = ctx.inject_item_to_inventory
        local inject_command_succeeded = ctx.inject_command_succeeded
        local inject_get_expected_commit_count = ctx.inject_get_expected_commit_count
        local record_local_injection_suppression = ctx.record_local_injection_suppression
        if type(get_runtime_state) ~= "function"
            or type(inject_item_to_inventory) ~= "function"
            or type(inject_command_succeeded) ~= "function" then
            return
        end

        local runtime_state = get_runtime_state()
        local runtime_clock = os.clock()
        if not safe_to_inject(runtime_state) then
            st.item_delivery_resume_not_before = runtime_clock + INVENTORY_STABILITY_SECONDS
            st.item_delivery_stability_logged = false
            return -- busy state: defer the whole drain, do not advance
        end
        -- [Character gate] The Ashley section runs its own inventories and
        -- DISCARDS them when it ends - live 2026-07-30, items put in her main
        -- grid and even in Storage were gone once Leon returned. Delivering
        -- there would report an item received that the player never keeps, so
        -- hold the whole queue until the campaign lead is back. Lossless: the
        -- watermark does not advance, exactly like the busy-state defer above.
        local is_default_character = ctx.inject_is_default_character_active
            or _G.inject_is_default_character_active
        if type(is_default_character) == "function" then
            local ok_character, default_active = pcall(is_default_character)
            if ok_character and not default_active then
                if not st.item_delivery_character_logged then
                    st.item_delivery_character_logged = true
                    info("another character is playing (their inventory is discarded at section end) - holding received items until the campaign lead returns")
                end
                return -- do not advance
            end
            if ok_character and default_active and st.item_delivery_character_logged then
                st.item_delivery_character_logged = false
                info("campaign lead is back - resuming received-item delivery")
            end
        end
        local resume_not_before = tonumber(st.item_delivery_resume_not_before)
        if resume_not_before ~= nil and runtime_clock < resume_not_before then
            if not st.item_delivery_stability_logged then
                info(string.format(
                    "inventory transition ended; deferring received items for %.1fs stability window",
                    INVENTORY_STABILITY_SECONDS
                ))
                st.item_delivery_stability_logged = true
            end
            return
        end
        if resume_not_before ~= nil then
            info("inventory state stable; resuming received-item delivery")
            st.item_delivery_resume_not_before = nil
            st.item_delivery_stability_logged = false
        end

        table.sort(pending, function(a, b) return a.index < b.index end)

        local function pop_head(idx)
            table.remove(pending, 1)
            if idx ~= nil then pending_by_index[idx] = nil end
        end

        -- [Overlay] Enter "sync burst" mode when many genuinely-new (undelivered)
        -- items are queued at once, so they coalesce into one "Synced N items" toast.
        -- Count only idx > watermark to ignore the already-applied reconnect replay.
        local threshold = tonumber(CHECK_SYNC_COALESCE_THRESHOLD) or 4
        if not st.in_sync_burst then
            local new_pending = 0
            for _, e in ipairs(pending) do
                if type(e.index) == "number" and e.index > bridge.last_received_index then
                    new_pending = new_pending + 1
                    if new_pending > threshold then st.in_sync_burst = true break end
                end
            end
        end

        local injected, processed, need_flush = 0, 0, false
        local runtime_domain = "CAMPAIGN"
        if type(ctx.get_runtime_domain) == "function" then
            runtime_domain = ctx.get_runtime_domain()
        end

        while #pending > 0 and injected < MAX_INJECTS_PER_TICK and processed < MAX_ITEMS_PER_TICK do
            local entry = pending[1]
            local idx = entry.index

            if type(idx) ~= "number" then
                warn("dropping queued item with non-integer index")
                pop_head(nil)
                processed = processed + 1
            elseif idx <= bridge.last_received_index then
                pop_head(idx) -- already applied (Sync/reconnect replay); dedupe
                processed = processed + 1
            elseif idx ~= bridge.last_received_index + 1 then
                break -- gap: wait for the missing index (flush any lazy advances)
            else
                local mapping = ap_item_map[entry.item]
                local is_merc_item = (mapping ~= nil and (mapping.kind == "merc_character" or mapping.kind == "merc_stage" or mapping.kind == "merc_filler"))
                    or (type(entry.item) == "number" and entry.item >= 440000001 and entry.item <= 440000099)
                local is_merc_location = (type(entry.location) == "number" and entry.location >= 440001000 and entry.location <= 440001127)

                if is_merc_item then
                    -- Mercenaries unlock item: update ownership immediately, never inject into campaign inventory
                    if type(ctx.handle_merc_item_received) == "function" then
                        ctx.handle_merc_item_received(mapping and mapping.name or "")
                    end
                    bridge.last_received_index = idx
                    need_flush = true
                    pop_head(idx)
                    processed = processed + 1
                    info(string.format("merc item received idx=%d ap=%s [%s]",
                        idx, tostring(entry.item), mapping and mapping.name or "merc_item"))
                elseif runtime_domain == "MERCENARIES" then
                    -- In Mercenaries mode: defer campaign physical items until returned to campaign
                    break
                elseif entry.player == st.numeric_slot
                    and type(entry.location) == "number" and entry.location > 0
                    and not is_merc_location
                    and bridge.non_lead_checked_locations[entry.location] ~= true then
                    -- own-world physical pickup: BioRand already granted it in campaign
                    info(string.format("own-find skip idx=%d ap=%s location=%d",
                        idx, tostring(entry.item), entry.location))
                    bridge.last_received_index = idx
                    need_flush = true -- re-processing a skip is harmless; flush lazily
                    pop_head(idx)
                    processed = processed + 1
                else
                    -- Campaign physical item delivery
                    if mapping == nil or type(mapping.re4r_item_id) ~= "number" or mapping.re4r_item_id <= 0 then
                        -- Map is confirmed loaded (gated above), so this id is genuinely
                        -- unknown -> skip it (loud) so it can't block later items forever.
                        err(string.format(
                            "POISON: AP item id %s (idx %d) not in ap_item_map -> SKIPPING (item lost)",
                            tostring(entry.item), idx))
                        bridge.last_received_index = idx
                        inject_failure_counts[idx] = nil
                        pop_head(idx)
                        processed = processed + 1
                        need_flush = false
                        if not persist() then break end
                    else

                    local status = tostring(inject_item_to_inventory(mapping.re4r_item_id, mapping.count))
                    if inject_command_succeeded(status) then
                        if type(inject_get_expected_commit_count) == "function"
                            and type(record_local_injection_suppression) == "function" then
                            local committed = inject_get_expected_commit_count(mapping.re4r_item_id, mapping.count)
                            record_local_injection_suppression(mapping.re4r_item_id, committed)
                        end
                        bridge.injected_ap_item_indexes[idx] = true
                        -- The non-lead debt for this location is settled.
                        if type(entry.location) == "number"
                            and bridge.non_lead_checked_locations[entry.location] == true then
                            bridge.non_lead_checked_locations[entry.location] = nil
                            info(string.format(
                                "delivered the item a non-lead character picked up at location %d",
                                entry.location))
                        end
                        bridge.last_item_received = string.format("AP #%d -> item %d x%d",
                            idx, mapping.re4r_item_id, mapping.count)
                        bridge.state_dirty = true
                        inject_failure_counts[idx] = nil
                        info(string.format("injected idx=%d ap=%s engine=%d x%d [%s]",
                            idx, tostring(entry.item), mapping.re4r_item_id, mapping.count, status))
                        -- Commit delivery before presentation. A broken toast must never
                        -- make an already-injected AP item eligible for injection again.
                        bridge.last_received_index = idx
                        pop_head(idx)
                        injected = injected + 1
                        processed = processed + 1
                        need_flush = false
                        if not persist() then break end
                        -- [Overlay] Toast the incoming item (invisible before now). Own-
                        -- world grants (player==self) show no "from"; a case-full fallback
                        -- to Storage is surfaced in the detail.
                        do
                            local nm = (type(mapping.name) == "string" and mapping.name ~= "")
                                and mapping.name or ("item " .. mapping.re4r_item_id)
                            local item_label = nm
                                .. ((mapping.count > 1) and (" x" .. mapping.count) or "")
                            local is_self_find = (entry.player == st.numeric_slot)
                            local from = (not is_self_find) and ap_player_name(entry.player) or nil
                            -- [F8] A re-delivery after a save rollback (reconcile) reads as a
                            -- "Restored ..." toast so the player understands the game is giving
                            -- back items received since their last save, not duplicating them.
                            local is_restore = entry.reconcile == true
                            local classification = classify_flags(entry.flags)
                            local item_color = get_check_overlay_classification_color(classification)
                            -- "<sender> sent you <item> - routing to <where>" (Cam's format,
                            -- 2026-07-23). <where> is the REAL landing partition: the case-full
                            -- Storage fallback wins over the item's normal route.
                            local to_storage = string.find(string.lower(status), "storage", 1, true) ~= nil
                            local route_fn = ctx.inject_get_route_destination or _G.inject_get_route_destination
                            local dest = to_storage and "storage (case full)"
                                or ((type(route_fn) == "function") and route_fn(mapping.re4r_item_id))
                                or "inventory"
                            local title, title_segments
                            if is_restore then
                                title = "Restored " .. item_label
                                title_segments = {
                                    { text = "Restored", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                                    { text = truncate_overlay_text(item_label, 32),
                                      color = item_color, entity = "item" },
                                }
                            elseif from ~= nil then
                                title = from .. " sent you " .. item_label
                                title_segments = {
                                    { text = truncate_overlay_text(from, 18),
                                      color = CHECK_OVERLAY_TEXT_COLOR_PLAYER, entity = "player" },
                                    { text = "sent you", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                                    { text = truncate_overlay_text(item_label, 32),
                                      color = item_color, entity = "item" },
                                }
                            else
                                -- Server/self grant (!getitem, collect): no meaningful sender.
                                title = "Received " .. item_label
                                title_segments = {
                                    { text = "Received", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                                    { text = truncate_overlay_text(item_label, 32),
                                      color = item_color, entity = "item" },
                                }
                            end
                            local detail
                            if is_restore then
                                -- The player didn't just find this -- it's being re-granted
                                -- because a reload rolled their inventory back past it. Native
                                -- notices now break to two lines when long (native_log
                                -- composer), so the full explanation fits.
                                detail = "received since your last save, restored on reload"
                            else
                                detail = "routing to " .. dest
                                -- [Celebration] Progression items are what actually move a
                                -- multiworld forward, so a key must never read like ammo.
                                -- Deliberately an elevated TOAST, not a centre-screen banner:
                                -- these can land several at once (and mid-fight), so loud here
                                -- would become noise. The goal is the only banner.
                                if classification == "PROGRESSION" then
                                    detail = detail .. " - a path just opened"
                                end
                            end
                            -- In a reconnect/offline catch-up burst, fold into the
                            -- single rolling summary; otherwise toast this item live.
                            -- Self-finds are the check you just picked up, already toasted by
                            -- detector's "Collected X" - suppress the duplicate, UNLESS it went
                            -- to Storage (a case-full signal the pickup toast can't know about).
                            if st.in_sync_burst then
                                bump_sync_summary(1, is_restore)
                            elseif is_self_find and type(entry.location) == "number"
                                and entry.location > 0 and not to_storage then
                                -- A genuine own-world physical pickup is already toasted by
                                -- detector's unified "Collected X" toast, so suppress the dupe.
                                -- Server/self grants (!getitem, !collect) carry location <= 0
                                -- and have NO pickup toast, so they fall through and toast below
                                -- instead of injecting silently.
                            else
                                enqueue_toast(title, detail, classification, "received", title_segments)
                            end
                        end
                    else
                        local n = (inject_failure_counts[idx] or 0) + 1
                        inject_failure_counts[idx] = n
                        if n >= MAX_INJECT_RETRIES then
                            err(string.format(
                                "POISON: inject failed %dx for idx=%d ap=%s engine=%d -> SKIPPING (item lost). last status: %s",
                                n, idx, tostring(entry.item), mapping.re4r_item_id, status))
                            bridge.last_received_index = idx
                            inject_failure_counts[idx] = nil
                            pop_head(idx)
                            processed = processed + 1
                            need_flush = false
                            if not persist() then break end
                        else
                            warn(string.format("inject failed idx=%d (attempt %d/%d): %s -- retrying next tick",
                                idx, n, MAX_INJECT_RETRIES, status))
                            break -- keep the failing item at the head; do not advance
                        end
                    end
                end
            end
        end

        -- [Overlay] End the sync burst once nothing new remains to deliver (a gap
        -- still counts as new -> stay latched until it fills). Leaves the "Synced N"
        -- toast on screen; the next live item toasts individually again.
        if st.in_sync_burst then
            local more_new = false
            for _, e in ipairs(pending) do
                if type(e.index) == "number" and e.index > bridge.last_received_index then
                    more_new = true break
                end
            end
            if not more_new then finalize_sync_summary() end
        end

        if need_flush then persist() end -- flush lazy own-find skip advances
    end

    -- [Phase 3 Group 1] Submit detected location checks to the AP server. The
    -- detector fills ctx.bridge.pending_checks; each entry now carries a resolved
    -- AP location_id. Send them here on the poll tick, only while fully
    -- slot-connected, tracking which ids we've sent this socket so we don't
    -- re-spam every frame. LocationChecks is idempotent server-side, so a resend
    -- never dupes (verified against the bundled server).
    local function drain_location_checks()
        local bridge = ctx.bridge
        if ap == nil or bridge == nil or type(bridge.pending_checks) ~= "table" then
            return
        end
        -- Fully connected only: a LocationChecks before SLOT_CONNECTED is dropped.
        local ok_state, state = pcall(function() return ap:get_state() end)
        if not ok_state or state ~= AP.State.SLOT_CONNECTED then
            return
        end

        local to_send, keys
        for _, entry in ipairs(bridge.pending_checks) do
            local lid = entry and tonumber(entry.location_id)
            if lid ~= nil then
                lid = math.floor(lid)
                -- [GatedKeys] Vanilla/preserved spots exist in the shipped maps but
                -- not in this room; picking their vanilla item is not an AP check.
                if room_location_ids ~= nil and not room_location_ids[lid] then
                    if not skipped_non_room_lids[lid] then
                        skipped_non_room_lids[lid] = true
                        info(string.format(
                            "location %d is not part of this multiworld (vanilla/preserved spot) -- check not sent",
                            lid))
                    end
                elseif not sent_location_checks[lid] then
                    sent_location_checks[lid] = true
                    to_send = to_send or {}
                    keys = keys or {}
                    to_send[#to_send + 1] = lid
                    keys[#keys + 1] = entry.key
                end
            end
        end

        if to_send ~= nil then
            local ok_send, e = pcall(function() ap:LocationChecks(to_send) end)
            if ok_send then
                -- [Phase 3 Group 2] Optimistically mark the locations checked in the
                -- durable per-seed set (acknowledged_guid_keys -- what the UI reads) and
                -- persist, mirroring the 2c watermark. Idempotent server-side, so a
                -- later resend never dupes.
                local marked = false
                for _, k in ipairs(keys) do
                    if type(k) == "string" and not bridge.acknowledged_guid_keys[k] then
                        bridge.acknowledged_guid_keys[k] = true
                        marked = true
                        -- [Phase 5 Group 3] session Checks-Sent counter for the status window
                        bridge.checks_sent_session = (bridge.checks_sent_session or 0) + 1
                    end
                end
                -- [Non-lead pickups] A location collected while someone other
                -- than the campaign lead is playing granted its item into an
                -- inventory the game DISCARDS at section end (proven live:
                -- Ashley's grid and even Storage are gone when Leon returns).
                -- Remember it, so the own-find skip below does not later
                -- assume the player still has what they picked up.
                local is_default = ctx.inject_is_default_character_active
                    or _G.inject_is_default_character_active
                if type(is_default) == "function" then
                    local ok_char, lead_active = pcall(is_default)
                    if ok_char and lead_active == false then
                        for _, lid in ipairs(to_send) do
                            bridge.non_lead_checked_locations[lid] = true
                        end
                        marked = true
                        info(string.format(
                            "%d location(s) collected by a non-lead character - their items will be delivered when the lead returns",
                            #to_send))
                    end
                end
                bridge.state_dirty = true
                if marked and type(ctx.save_session_state) == "function" then
                    ctx.save_session_state()
                end
                info(string.format("LocationChecks sent: %d location(s)", #to_send))
            else
                -- undo the sent marks so we retry next tick
                for _, lid in ipairs(to_send) do sent_location_checks[lid] = nil end
                err("LocationChecks send failed: " .. tostring(e))
            end
        end
    end

    -- [Phase 3 Group 2] Resend the full persisted checked set on (re)connect. The
    -- durable set is ctx.bridge.acknowledged_guid_keys ("stage|guid" -> true); resolve
    -- each to its AP location_id via the display map and re-submit. Idempotent, so this
    -- recovers a check made while disconnected or a send that didn't land -- our stand-in
    -- for RE2R's game-state re-scan.
    local function resend_checked_locations()
        local bridge = ctx.bridge
        if ap == nil or bridge == nil or type(bridge.acknowledged_guid_keys) ~= "table" then
            return
        end
        local resolve = ctx.get_location_display_entry or _G.get_location_display_entry
        if type(resolve) ~= "function" then return end

        local ids
        for key in pairs(bridge.acknowledged_guid_keys) do
            local bar = type(key) == "string" and string.find(key, "|", 1, true) or nil
            if bar ~= nil then
                local stage = tonumber(string.sub(key, 1, bar - 1))
                local guid = string.sub(key, bar + 1)
                if stage ~= nil then
                    local ok, entry = pcall(resolve, stage, guid)
                    local lid = ok and type(entry) == "table" and tonumber(entry.location_id)
                    if lid ~= nil then
                        lid = math.floor(lid)
                        -- [GatedKeys] Persisted keys from an older world version can
                        -- resolve to locations this room does not have -- skip those.
                        if room_location_ids == nil or room_location_ids[lid] then
                            ids = ids or {}
                            ids[#ids + 1] = lid
                            sent_location_checks[lid] = true -- the drain won't re-send these
                        end
                    end
                end
            end
        end

        if ids ~= nil then
            local ok_send, e = pcall(function() ap:LocationChecks(ids) end)
            if ok_send then
                info(string.format("resent %d persisted check(s) on connect", #ids))
            else
                for _, lid in ipairs(ids) do sent_location_checks[lid] = nil end
                err("check resend on connect failed: " .. tostring(e))
            end
        end
    end

    -- [Phase 4] Report the goal once the victory latch is set. maybe_trigger_victory_
    -- condition (ArchipelagoRE4R.lua, untouched) sets bridge.victory_pending at stage
    -- 59223; here we send StatusUpdate(GOAL) exactly once while connected, then latch
    -- victory_sent + persist (replacing the Python client's goal_achieved + ack_victory).
    local function maybe_send_victory()
        local bridge = ctx.bridge
        if ap == nil or bridge == nil then return end

        local is_merc_only = false
        local slot_data = ctx.slot_data or bridge.slot_data
        if type(slot_data) == "table" and slot_data.game_mode == "mercenaries_only" then
            is_merc_only = true
        end

        if is_merc_only and bridge.victory_sent ~= true and type(bridge.checked_locations) == "table" then
            local all_done = true
            for char_idx = 0, 7 do
                for stage_idx = 0, 3 do
                    local loc_id = 440001000 + char_idx * 16 + stage_idx * 4
                    if bridge.checked_locations[loc_id] ~= true then
                        all_done = false
                        break
                    end
                end
                if not all_done then break end
            end
            if all_done then
                bridge.victory_pending = true
            end
        end

        if bridge.victory_pending ~= true or bridge.victory_sent == true then return end

        -- Fully connected only; otherwise leave the latch to re-fire on reconnect.
        local ok_state, state = pcall(function() return ap:get_state() end)
        if not ok_state or state ~= AP.State.SLOT_CONNECTED then return end

        local ok_send, e = pcall(function() ap:StatusUpdate(AP.ClientStatus.GOAL) end)
        if not ok_send then
            err("StatusUpdate(GOAL) failed: " .. tostring(e))
            return
        end
        -- Latch + persist immediately (the once-guard); mirrors the old ack_victory
        -- transition. The main loop copies bridge.victory_* onto state each tick.
        bridge.victory_sent = true
        bridge.victory_pending = false
        bridge.state_dirty = true
        if type(ctx.save_session_state) == "function" then
            ctx.save_session_state()
        end
        info("StatusUpdate(GOAL) sent -- goal reported to server")
        -- The loudest moment in a run, and it fires exactly ONCE per seed (victory is
        -- latched + persisted above) -- so it gets the centre-screen celebration with no
        -- risk of ever becoming noise. The toast stays as well: it's what the Message Log
        -- captures from, so the goal is still recoverable after the banner fades.
        local is_merc_only = false
        local slot_data = ctx.slot_data or bridge.slot_data
        if type(slot_data) == "table" and slot_data.game_mode == "mercenaries_only" then
            is_merc_only = true
        end

        local trigger_celebration = ctx.trigger_celebration or _G.trigger_celebration
        if is_merc_only then
            if type(trigger_celebration) == "function" then
                trigger_celebration("MERCENARIES COMPLETE", {
                    "Rank A achieved on all 32 loadouts.",
                    "Reported to Archipelago.",
                })
            end
            enqueue_toast("Goal Complete!", "Rank A achieved on all 32 loadouts.", "PROGRESSION", "goal")
        else
            if type(trigger_celebration) == "function" then
                trigger_celebration("GOAL COMPLETE", {
                    "Saddler's dead. Ashley's safe.",
                    "Reported to Archipelago.",
                })
            end
            enqueue_toast("Goal Complete!", "Saddler's dead. Ashley's safe.", "PROGRESSION", "goal")
        end
    end


    -- [Phase 4] Scout every location once on connect so the progression-warning UI gets
    -- seed-aware AP ItemFlags. Mirrors the Python client's _refresh_location_classifications:
    -- one LocationScouts(all ids, create_as_hint=0); the reply lands in on_location_info,
    -- which fills bridge.location_classifications (the table data.lua's warning logic reads).
    local function scout_all_locations()
        local bridge = ctx.bridge
        if ap == nil or bridge == nil then return end
        if room_location_ids == nil then
            -- [GatedKeys] Without the room's real location set, scouting is
            -- skipped: sending ids the room lacks makes the server drop the
            -- socket (the reconnect loop of 2026-07-12). Classifications stay
            -- as they are; progression warnings are limited, gameplay + check
            -- sending are unaffected.
            warn("scout: room location set unavailable -- scouting skipped (progression warnings limited this session)")
            return
        end
        local ids = {}
        -- Scout exactly this room's location set; the shipped map can contain
        -- locations the room does not have (option-dependent).
        for lid in pairs(room_location_ids) do
            ids[#ids + 1] = lid
        end
        -- Rebuild fresh: clear now; on_location_info accumulates the reply (which may
        -- arrive across one or several LocationInfo packets).
        bridge.location_classifications = {}
        bridge.location_scout_player = {} -- [Overlay] per-location owning slot (found-for-player)
        if #ids == 0 then
            warn("scout: no location ids to scout")
            return
        end
        local ok_send, e = pcall(function() ap:LocationScouts(ids, 0) end)
        if ok_send then
            info(string.format("LocationScouts sent: %d location(s)", #ids))
        else
            err("LocationScouts failed: " .. tostring(e))
        end
    end

    -- Handlers.
    -- [Overlay] Publish live connection state for the in-game status line (replaces
    -- the Python-era client_status / ap_connection_status bridge commands). `kind`
    -- drives the overlay colour: "connected" green, "pending" amber, "error" red,
    -- "idle" grey. ap_connection_status stays a coarse connected/disconnected string
    -- so the existing is_ap_connection_active() + check-toast detail keep working.
    local function set_conn_status(kind, label)
        local bridge = ctx.bridge
        if bridge == nil then return end
        bridge.ap_status_kind = kind
        bridge.ap_status_label = label
        bridge.ap_connection_status = (kind == "connected") and "AP connected" or "Disconnected"
    end

    local function on_socket_connected()
        info("socket connected to " .. st.server)
        st.last_contact_clock = os.clock()
        set_conn_status("pending", "Authenticating...")
    end

    local function on_socket_error(msg)
        if not st.first_socket_error_seen then
            st.first_socket_error_seen = true
            info("first socket error (non-fatal, ws/wss autodetect): " .. tostring(msg))
        else
            warn("socket error: " .. tostring(msg))
        end
    end

    local function on_socket_disconnected()
        info("socket disconnected")
        st.slot_connected = false
        set_conn_status("pending", "Reconnecting...")
    end

    local function on_room_info()
        -- Reaching a server proves the address resolves; restamp so a later real
        -- outage starts its countdown fresh.
        st.last_contact_clock = os.clock()
        -- [Port recovery] RoomInfo already carries the seed, so a recycled port
        -- can be caught BEFORE ConnectSlot - joining a stranger's room would
        -- either fail as InvalidSlot or, worse, half-succeed against a room
        -- that happens to share our slot name.
        local ok_seed, room_seed = pcall(function() return ap:get_seed() end)
        room_seed = (ok_seed and type(room_seed) == "string") and room_seed or ""
        if st.expected_seed ~= "" and room_seed ~= "" and room_seed ~= st.expected_seed then
            err(string.format(
                "PORT MISMATCH: %s is serving seed '%s' but this session belongs to seed '%s' - not joining.",
                tostring(st.server), room_seed, tostring(st.expected_seed)))
            set_conn_status("error", "Different multiworld on this port")
            open_port_recovery("seed_mismatch", room_seed, 0)
            return
        end
        info("RoomInfo received -> sending ConnectSlot as '" .. st.slot .. "'")
        ap:ConnectSlot(st.slot, st.password, ITEMS_HANDLING, CLIENT_TAGS, CLIENT_VERSION)
    end

    local function on_slot_connected(slot_data)
        info("SLOT CONNECTED as '" .. st.slot .. "' -- bare-connect SUCCESS")
        set_conn_status("connected", "Connected (" .. st.slot .. ")")
        -- Whatever the recovery dialog was worried about, it is resolved.
        st.last_contact_clock = os.clock()
        st.slot_connected = true
        st.port_recovery_dismissed_kind = nil
        close_port_recovery()
        -- [DeathLink] Read the slot's death_link setting (added to fill_slot_data in the
        -- apworld). Accept boolean true or numeric/string 1. Reset the per-connection
        -- death state so a reconnect can't strand a queued death or a stale edge.
        do
            local dl = (type(slot_data) == "table") and slot_data.death_link or nil
            st.death_link_enabled = (dl == true) or (dl == 1) or (dl == "1")
            st.dl_last_dead = false
            st.dl_pending_incoming = nil
            st.dl_amnesty_until = 0
            info("DeathLink " .. (st.death_link_enabled and "ENABLED" or "disabled") ..
                " (from slot_data)")
        end
        -- [CheckGuidance] Permission ceiling for the world markers
        -- ("off" | "markers" | "markers_rarity"); the marker renderer and the
        -- script-UI options respect it. Older seeds without the key read as
        -- "markers" (neutral markers allowed, rarity colours not).
        do
            local cg = (type(slot_data) == "table") and slot_data.check_guidance or nil
            if cg ~= "off" and cg ~= "markers" and cg ~= "markers_rarity" then
                cg = "markers"
            end
            if ctx.bridge then
                ctx.bridge.check_guidance_ceiling = cg
                if cg ~= "markers_rarity" then
                    ctx.bridge.world_markers_importance_colors = false
                end
            end
            info("CheckGuidance ceiling: " .. cg .. " (from slot_data)")
        end
        -- [Tutorial] The first-run guide, on unless the slot turned it off.
        -- Older seeds without the key keep it on.
        do
            local tut = (type(slot_data) == "table") and slot_data.tutorial or nil
            local enabled = not ((tut == false) or (tut == 0) or (tut == "0"))
            if ctx.bridge then
                ctx.bridge.tutorial_enabled = enabled
            end
            info("Tutorial: " .. (enabled and "enabled" or "disabled") .. " (from slot_data)")
        end
        -- [Random Events] AP-authored event roll: some checks may have moved
        -- (new stage, coordinates and section) and some may not exist at all.
        -- The display layer (markers, checklist, section counts) follows the
        -- roll; detection stays guid-canonical and needs nothing. Rooms
        -- without the block clear any override left by a previous connection.
        do
            local re = (type(slot_data) == "table") and slot_data.random_events or nil
            local set_overrides = ctx.set_random_events_overrides or _G.set_random_events_overrides
            if type(set_overrides) == "function" then
                local ok_overrides, summary = pcall(set_overrides, re)
                if ok_overrides and type(re) == "table"
                    and (re.enabled == true or re.enabled == 1 or re.enabled == "1") then
                    local moved = (type(summary) == "table") and summary.moved or 0
                    local removed = (type(summary) == "table") and summary.removed or 0
                    info("Random Events ACTIVE (from slot_data): " .. tostring(moved)
                        .. " check(s) moved, " .. tostring(removed) .. " removed")
                elseif not ok_overrides then
                    info("Random Events overrides FAILED to apply: " .. tostring(summary))
                end
            end
        end
        -- [Mercenaries] Initialize Mercenaries runtime slot data and virtual gating
        do
            ctx.slot_data = slot_data
            if ctx.bridge then ctx.bridge.slot_data = slot_data end
            local init_merc = ctx.init_merc_ownership or _G.init_merc_ownership
            if type(init_merc) == "function" then
                init_merc(slot_data)
            end
            local install_hooks = ctx.install_merc_virtual_gating_hooks or _G.install_merc_virtual_gating_hooks
            if type(install_hooks) == "function" then
                install_hooks()
            end
            -- Replay received ledger for Mercenaries unlocks
            local handle_item = ctx.handle_merc_item_received or _G.handle_merc_item_received
            if type(handle_item) == "function" and type(received_ledger) == "table" then
                for _, rec in pairs(received_ledger) do
                    if type(rec) == "table" and rec.item ~= nil then
                        local mapping = ap_item_map[rec.item]
                        if mapping and mapping.name then
                            handle_item(mapping.name)
                        end
                    end
                end
            end
        end
        -- Capture our NUMERIC slot + seed and establish the per-seed session

        -- identity so the durable watermark keys to session_<seed>__<slot>.json
        -- and loads on connect. Clear any stale queue from a prior connection.
        local ok_num, num = pcall(function() return ap:get_player_number() end)
        st.numeric_slot = (ok_num and type(num) == "number") and num or nil
        if ctx.bridge then ctx.bridge.ap_numeric_slot = st.numeric_slot end -- [Overlay] found-for-player compare
        local ok_seed, seed = pcall(function() return ap:get_seed() end)
        st.seed = (ok_seed and type(seed) == "string") and seed or ""
        -- [Hints] Prime + subscribe the durable hint list for this slot. This is
        -- the ONLY hint source we trust for state (the on-connect PrintJSON hint
        -- replay stays suppressed as toast spam); Get answers via on_retrieved,
        -- later changes (hint bought, found flipped) push via on_set_reply.
        do
            local ok_team, team = pcall(function() return ap:get_team_number() end)
            st.team_number = (ok_team and type(team) == "number") and team or 0
            if st.numeric_slot ~= nil then
                st.hints_storage_key = string.format("_read_hints_%d_%d", st.team_number, st.numeric_slot)
                if ctx.bridge then ctx.bridge.hints_on_my_world = {} end
                local ok_sub, sub_err = pcall(function()
                    ap:SetNotify({ st.hints_storage_key })
                    ap:Get({ st.hints_storage_key })
                end)
                if not ok_sub then
                    warn("hint storage subscribe failed: " .. tostring(sub_err))
                end
            else
                st.hints_storage_key = nil
            end
        end
        pending = {}
        pending_by_index = {}
        received_ledger = {} -- [F8] fresh identity: rebuilt from the on-connect replay
        inject_failure_counts = {}
        st.item_delivery_resume_not_before = nil
        st.item_delivery_stability_logged = false
        sent_location_checks = {} -- new socket: let the persisted checks resend once
        -- [Overlay] Fresh connection: reset the received-item burst coalescer, and
        -- open a short grace window during which replayed Hint/Goal PrintJSON (the
        -- server resends your hints on connect) is suppressed so old hints don't
        -- re-toast on every auto-reconnect. Outbound item-sends are NOT gated (they
        -- are always live actions the player just took).
        finalize_sync_summary()
        do
            local now = ctx.now_unix_ms or _G.now_unix_ms
            local now_ms = (type(now) == "function") and now() or (os.time() * 1000)
            st.social_live_at_ms = now_ms + 3000
        end
        -- [GatedKeys] Capture this room's real location set BEFORE any resend or
        -- scout below. missing+checked from the Connected packet is exactly the
        -- slot's created location list for its options.
        room_location_ids = nil
        skipped_non_room_lids = {}
        do
            -- File first: the launcher wrote this room's exact id set at patch
            -- time. The AP getters are a live fallback. If BOTH fail, scouting
            -- is skipped entirely -- never fall back to the full shipped map
            -- (scouting ids the room lacks makes the server drop the socket:
            -- live 2026-07-12, a 471-location room vs the 476-id map produced
            -- a connect/disconnect loop every ~1.5s).
            local set, total, source = {}, 0, "launcher file"
            local ok_file, payload = pcall(function() return json.load_file(ROOM_LOCATIONS_FILE) end)
            if ok_file and type(payload) == "table" and type(payload.location_ids) == "table" then
                local file_seed = tostring(payload.seed_name or "")
                local file_slot = tostring(payload.slot_name or "")
                local seed_ok = file_seed == "" or st.seed == "" or file_seed == st.seed
                local slot_ok = file_slot == "" or file_slot == st.slot
                if seed_ok and slot_ok then
                    for _, lid in ipairs(payload.location_ids) do
                        local n = tonumber(lid)
                        if n ~= nil then
                            n = math.floor(n)
                            if not set[n] then
                                set[n] = true
                                total = total + 1
                            end
                        end
                    end
                else
                    warn(string.format(
                        "%s is for seed '%s' slot '%s' but this session is seed '%s' slot '%s' -- ignoring it (re-patch via the launcher)",
                        ROOM_LOCATIONS_FILE, file_seed, file_slot, tostring(st.seed), tostring(st.slot)))
                end
            end
            if total == 0 then
                source = "AP getters"
                for _, getter in ipairs({ "get_missing_locations", "get_checked_locations" }) do
                    local ok_ids, result = pcall(function() return ap[getter](ap) end)
                    if ok_ids and type(result) == "table" then
                        for _, lid in ipairs(result) do
                            local n = tonumber(lid)
                            if n ~= nil then
                                n = math.floor(n)
                                if not set[n] then
                                    set[n] = true
                                    total = total + 1
                                end
                            end
                        end
                    end
                end
            end
            if total > 0 then
                room_location_ids = set
                info(string.format("room location set: %d location(s) via %s", total, source))
            else
                warn("room location set unavailable (no launcher file, AP getters empty) -- location scouting is skipped this session")
            end
        end
        local set_ap_session_identity = ctx.set_ap_session_identity
        if type(set_ap_session_identity) == "function" then
            local stage = ctx.bridge and ctx.bridge.last_state and ctx.bridge.last_state.current_stage
            set_ap_session_identity(st.seed, st.slot, stage)
            info(string.format(
                "session identity set: seed='%s' slot='%s' numeric_slot=%s -> %s (last_received_index=%s)",
                st.seed, st.slot, tostring(st.numeric_slot),
                tostring(ctx.bridge and ctx.bridge.loaded_session_state_path),
                tostring(ctx.bridge and ctx.bridge.last_received_index)))
            if type(ctx.save_session_state) == "function" then
                ctx.save_session_state()
            end
        else
            warn("ctx.set_ap_session_identity unavailable -- session watermark not keyed")
        end
        -- [Phase 3 Group 2] Reconcile: resend the full persisted checked set now that
        -- the per-seed session (incl. acknowledged_guid_keys) has been loaded.
        resend_checked_locations()
        -- [Phase 4] Refresh seed-aware location classifications for the progression UI.
        scout_all_locations()
    end

    local function on_slot_refused(reasons)
        local r = "?"
        if type(reasons) == "table" then r = table.concat(reasons, ", ") end
        err("slot refused: " .. r)
        set_conn_status("error", "Refused: " .. r)
        -- [Port recovery] InvalidSlot means the room we reached has no such slot:
        -- either a recycled port (someone else's room) or a genuine slot typo.
        -- The recovery dialog names both possibilities.
        if string.find(tostring(r), "InvalidSlot", 1, true) ~= nil then
            open_port_recovery("invalid_slot", "", 0)
        end
    end

    local function on_items_received(items)
        if type(items) ~= "table" then return end
        local bridge = ctx.bridge
        local watermark = (bridge and tonumber(bridge.last_received_index)) or -1
        local queued, lo, hi = 0, nil, nil
        for _, item in ipairs(items) do
            local idx = item.index
            if type(idx) == "number" then
                -- [F8] Ledger every delivered item (independent of the watermark) so
                -- a save rollback can re-queue items already popped from `pending`.
                received_ledger[idx] = {
                    item = item.item,
                    player = item.player,
                    location = item.location,
                    flags = item.flags,
                }
                if idx > watermark and not pending_by_index[idx] then
                    pending[#pending + 1] = {
                        index = idx,
                        item = item.item,
                        player = item.player,
                        location = item.location,
                        flags = item.flags,
                    }
                    pending_by_index[idx] = true
                    queued = queued + 1
                    if lo == nil or idx < lo then lo = idx end
                    if hi == nil or idx > hi then hi = idx end
                end
            end
        end
        info(string.format(
            "ReceivedItems: %d in packet, %d newly queued (idx %s..%s), watermark=%s, pending=%d",
            #items, queued, tostring(lo), tostring(hi), tostring(watermark), #pending))
    end

    local function on_location_info(scouts)
        if type(scouts) ~= "table" then return end
        local bridge = ctx.bridge
        if bridge == nil then return end
        if type(bridge.location_classifications) ~= "table" then
            bridge.location_classifications = {}
        end
        if type(bridge.location_scout_player) ~= "table" then
            bridge.location_scout_player = {}
        end
        -- [Overlay] The AP item that actually sits at each location. Without this the check
        -- toast could only name the location, whose name is the item VANILLA had there - so
        -- picking up shotgun shells at the green-herb spot toasted "Green Herb".
        if type(bridge.location_scout_item) ~= "table" then
            bridge.location_scout_item = {}
        end
        local p, u, f = 0, 0, 0
        for _, scout in ipairs(scouts) do
            local lid = type(scout) == "table" and tonumber(scout.location)
            if lid ~= nil then
                local key = tostring(math.floor(lid))
                local cls = classify_flags(scout.flags)
                bridge.location_classifications[key] = cls
                bridge.location_scout_player[key] = tonumber(scout.player)
                bridge.location_scout_item[key] = tonumber(scout.item)
                if cls == "PROGRESSION" then p = p + 1
                elseif cls == "USEFUL" then u = u + 1
                else f = f + 1 end
            end
        end
        local total = 0
        for _ in pairs(bridge.location_classifications) do total = total + 1 end
        info(string.format(
            "LocationInfo: %d scout(s) classified this packet (%d PROG / %d USEFUL / %d FILLER); %d total classified",
            p + u + f, p, u, f, total))
    end

    local function on_location_checked(locations)
        local n = (type(locations) == "table") and #locations or 0
        info("server-confirmed checked locations: " .. n)
    end

    -- [DeathLink] Inbound deaths arrive as a Bounce tagged "DeathLink" with
    -- data = { time, cause, source }. Queue a kill (applied on the next safe tick by
    -- poll_deathlink) when it's a real other-player death we haven't just handled.
    local function on_bounced(bounce)
        -- Receipt log BEFORE any gate: bounces are rare, and this line is the
        -- divider between "server never delivered" and "we dropped it". A live
        -- DS3 death (2026-07-23) produced no RE4R reaction and no log at all,
        -- which was undiagnosable against the silent early-returns below.
        if type(bounce) ~= "table" then
            info("Bounced received: non-table payload type=" .. type(bounce))
            return
        end
        local keys = {}
        for k in pairs(bounce) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local tags_text = "<none>"
        if type(bounce.tags) == "table" then
            local tag_parts = {}
            for _, t in ipairs(bounce.tags) do tag_parts[#tag_parts + 1] = tostring(t) end
            tags_text = table.concat(tag_parts, "+")
        end
        info("Bounced received: keys=" .. table.concat(keys, ",") .. " tags=" .. tags_text)

        if not st.death_link_enabled then
            return
        end
        local is_death = false
        if type(bounce.tags) == "table" then
            for _, t in ipairs(bounce.tags) do
                if t == "DeathLink" then is_death = true break end
            end
        end
        if not is_death then
            info("DeathLink: bounce had no DeathLink tag -- ignored")
            return
        end

        local data = bounce.data
        if type(data) ~= "table" then
            info("DeathLink: bounce data is " .. type(data) .. ", not a table -- ignored")
            return
        end
        local source = data.source

        -- Ignore our own death echoed back to us by the server.
        if type(source) == "string" and source == st.slot then
            return
        end
        -- Amnesty: drop a burst of (re)delivered deaths right after we handled one.
        if os.clock() < (st.dl_amnesty_until or 0) then
            info("DeathLink: incoming death within amnesty window -- ignored")
            return
        end

        st.dl_pending_incoming = {
            source = (type(source) == "string" and source ~= "") and source or nil,
            cause = (type(data.cause) == "string" and data.cause ~= "") and data.cause or nil,
        }
        info("DeathLink: incoming death from " .. tostring(source) .. " queued")
    end

    -- [Overlay] Has the on-connect grace window elapsed? Used to suppress the
    -- server's replayed Hint/Goal PrintJSON right after (re)connect so stale events
    -- don't re-toast on every auto-reconnect.
    local function social_is_live()
        local at = tonumber(st.social_live_at_ms)
        if at == nil then return true end
        local now = ctx.now_unix_ms or _G.now_unix_ms
        local now_ms = (type(now) == "function") and now() or (os.time() * 1000)
        return now_ms >= at
    end

    -- [Overlay] Render a PrintJSON message to plain text. Prefers apclientpp's
    -- render_json (resolves item/player/location ids to names); falls back to
    -- concatenating the raw text parts.
    local function render_print_json(msg)
        if ap ~= nil and type(msg) == "table" and msg.data ~= nil then
            local ok, text = pcall(function()
                local fmt = (AP ~= nil and AP.RenderFormat ~= nil) and AP.RenderFormat.TEXT or nil
                if fmt ~= nil then return ap:render_json(msg.data, fmt) end
                return ap:render_json(msg.data)
            end)
            if ok and type(text) == "string" and text ~= "" then return text end
        end
        if type(msg) == "table" and type(msg.data) == "table" then
            local parts = {}
            for _, node in ipairs(msg.data) do
                if type(node) == "table" and type(node.text) == "string" then
                    parts[#parts + 1] = node.text
                end
            end
            if #parts > 0 then return table.concat(parts) end
        end
        return nil
    end

    -- [Overlay] PrintJSON = the server's multiworld event feed. We surface the
    -- social heartbeat that was previously invisible:
    --   * hints                -> rendered server text (progression-coloured)
    --   * goal completions     -> "<player> has completed their goal"
    -- Item sends are NOT toasted here: your OWN pickups (outbound + self-find) are
    -- covered by detector's unified pickup toast, and inbound gifts from other players
    -- are toasted by items_received. Echoing PrintJSON would double-toast either way.
    local function on_print_json(msg)
        if type(msg) ~= "table" then return end
        local mtype = (type(msg.type) == "string") and msg.type or ""

        if mtype == "ItemSend" then
            local item = (type(msg.item) == "table") and msg.item or nil
            local receiver = tonumber(msg.receiving)
            local finder = item and tonumber(item.player) or nil
            local me = tonumber(st.numeric_slot)
            -- Inbound / self-grant: handled by items_received. Skip.
            if me ~= nil and receiver == me then return end
            -- Only surface sends WE made to someone else (the outbound half).
            if me == nil or finder ~= me then return end

            -- Same get_item_name gotcha as ap_item_name: route through the helper so
            -- the slot -> game mapping (and the "Unknown" rejection) applies here too.
            local item_name
            if item ~= nil then
                item_name = ap_item_name(item.item, receiver)
            end
            local who = ap_player_name(receiver) or ("Player " .. tostring(receiver))
            -- No toast: detector's unified pickup toast already said "Sent <item> to <who>" the
            -- moment you collected it. This server echo would double-toast. Log only.
            info(string.format("PrintJSON ItemSend: sent %s to %s (toast suppressed - covered by pickup)", item_name or "an item", who))
            return
        end

        if mtype == "Hint" then
            if not social_is_live() then return end -- suppress on-connect hint replay
            local text = render_print_json(msg)
            if text ~= nil then
                info("PrintJSON Hint: " .. text)
                -- [Hints] When the hinted location is in OUR world, the detail
                -- line speaks map language: section - container gloss - note.
                local detail = nil
                local net_item = (type(msg.item) == "table") and msg.item or nil
                if net_item ~= nil and tonumber(net_item.player) == tonumber(st.numeric_slot) then
                    local resolver = ctx.get_display_entry_by_location_id or _G.get_display_entry_by_location_id
                    local resolved = (type(resolver) == "function") and resolver(net_item.location) or nil
                    local entry = resolved and resolved.entry or nil
                    if entry ~= nil then
                        local parts = {}
                        local section = tostring(entry.section_name or "")
                        if section ~= "" then table.insert(parts, section) end
                        local gloss_fn = ctx.get_container_gloss or _G.get_container_gloss
                        local gloss = (type(gloss_fn) == "function") and gloss_fn(entry.container) or ""
                        if gloss ~= "" then table.insert(parts, gloss) end
                        local note = tostring(entry.note or "")
                        if note ~= "" then table.insert(parts, note) end
                        if #parts > 0 then detail = "Yours: " .. table.concat(parts, " - ") end
                    end
                end
                enqueue_toast(text, detail, "PROGRESSION", "hint")
            end
            return
        end

        if mtype == "Goal" then
            if not social_is_live() then return end
            -- Our own goal is already toasted locally by maybe_send_victory; skip the
            -- server echo when it names us (best-effort: msg.slot may be absent).
            local me = tonumber(st.numeric_slot)
            if me ~= nil and tonumber(msg.slot) == me then return end
            local text = render_print_json(msg)
            if text ~= nil then
                info("PrintJSON Goal: " .. text)
                enqueue_toast(text, nil, "PROGRESSION", "goal")
            end
            return
        end
        -- Chat / Join / Part / Tutorial / Countdown / ... intentionally ignored.
    end

    -- [DeathLink] Share our death with the multiworld. Live-connection gated;
    -- best-effort (a death while disconnected is simply not propagated).
    local function dl_send_death()
        if ap == nil then return end
        local ok_state, state = pcall(function() return ap:get_state() end)
        if not ok_state or state ~= AP.State.SLOT_CONNECTED then return end
        local src = (st.slot ~= "") and st.slot or "RE4R"
        local data = { time = os.time(), cause = src .. " was killed", source = src }
        local tags = { "DeathLink" }
        -- Broadcast to all DeathLink slots: games/slots are empty arrays. Use
        -- AP.EMPTY_ARRAY, not {} -- a bare {} serializes as an empty JSON *object*, not
        -- [] (per the apclientpp API notes). nil is only a last-ditch fallback.
        local ok = pcall(function() ap:Bounce(data, AP.EMPTY_ARRAY, AP.EMPTY_ARRAY, tags) end)
        if not ok then
            ok = pcall(function() ap:Bounce(data, nil, nil, tags) end)
        end
        if ok then
            info("DeathLink: shared our death with the multiworld")
            enqueue_toast("You died", "Death shared via DeathLink", "PROGRESSION", "death")
            st.dl_amnesty_until = os.clock() + DEATHLINK_AMNESTY_SECONDS
        else
            err("DeathLink: Bounce send failed")
        end
    end

    -- [DeathLink] Apply a queued incoming death by triggering the game's own game-over
    -- -> checkpoint reload (ctx.trigger_game_over). Only called from a safe gameplay
    -- state so the game-over can't fire mid-cutscene/menu/load.
    local function dl_apply_incoming_death()
        local pending = st.dl_pending_incoming
        st.dl_pending_incoming = nil
        if pending == nil then return end
        local trigger = ctx.trigger_game_over
        local killed = (type(trigger) == "function") and trigger() or false
        if killed then
            local who = pending.source or "another player"
            local msg = pending.cause or (who .. " died")
            -- The raw cause string stays in the log; the toast reads as one
            -- sentence: "<player> died - taking you with them" (Cam 2026-07-23).
            info("DeathLink: applied incoming death (" .. msg .. ")")
            enqueue_toast(who .. " died", "taking you with them", "PROGRESSION", "death", {
                { text = truncate_overlay_text(who, 18),
                  color = CHECK_OVERLAY_TEXT_COLOR_PLAYER, entity = "player" },
                { text = "died", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
            })
            st.dl_amnesty_until = os.clock() + DEATHLINK_AMNESTY_SECONDS
            st.dl_last_dead = true -- suppress an outbound echo if IsDead momentarily flips
        else
            err("DeathLink: trigger_game_over failed in a safe state -- death dropped")
        end
    end

    -- [DeathLink] Per-tick pump (called after ap:poll): send our own death on the
    -- rising edge of the player's IsDead flag; apply a queued incoming death once we
    -- reach a safe gameplay state.
    local function poll_deathlink()
        if not st.death_link_enabled then return end

        local get_is_dead = ctx.get_player_is_dead
        if type(get_is_dead) == "function" then
            local dead = get_is_dead()
            if dead ~= nil then
                if dead and not st.dl_last_dead and os.clock() >= (st.dl_amnesty_until or 0) then
                    dl_send_death()
                end
                st.dl_last_dead = dead
            end
        end

        if st.dl_pending_incoming ~= nil then
            local get_runtime_state = ctx.get_runtime_state
            local rs = (type(get_runtime_state) == "function") and get_runtime_state() or nil
            if safe_to_inject(rs) then
                dl_apply_incoming_death()
            end
        end
    end

    -- [DeathLink] Debug-tab helpers: simulate an inbound death through the
    -- REAL queue -> safe-tick -> game-over path, so the apply side is
    -- validatable without a partner game (2026-07-23: the DS3 slot had
    -- DeathLink off, so the cross-game loop had never fired -- and outbound
    -- was proven while inbound sat unexercised). The simulation respects the
    -- slot's death_link gate: it validates production behaviour, never
    -- bypasses it.
    local function ap_debug_deathlink_status()
        if not st.death_link_enabled then
            return "disabled (slot_data.death_link off)"
        end
        local parts = { "enabled" }
        parts[#parts + 1] = (st.dl_pending_incoming ~= nil)
            and "kill queued, waiting for a safe tick" or "no kill queued"
        if os.clock() < (st.dl_amnesty_until or 0) then
            parts[#parts + 1] = string.format(
                "amnesty %.0fs left", (st.dl_amnesty_until or 0) - os.clock())
        end
        return table.concat(parts, "; ")
    end
    ctx.ap_debug_deathlink_status = ap_debug_deathlink_status

    local function ap_debug_simulate_deathlink()
        if not st.death_link_enabled then
            info("DeathLink: simulate ignored -- death_link disabled for this slot")
            return "ignored: death_link disabled for this slot"
        end
        st.dl_pending_incoming = {
            source = "Debug",
            cause = "Simulated inbound death (Debug tab)",
        }
        info("DeathLink: simulated inbound death queued (Debug tab)")
        return "queued; applies on the next safe gameplay tick"
    end
    ctx.ap_debug_simulate_deathlink = ap_debug_simulate_deathlink

    local function connect()
        if not read_connection_info() then
            info("no valid ap_connection.json yet (" .. CONNECTION_INFO_FILE .. "); AP client idle, will retry.")
            set_conn_status("idle", "No session configured")
            return false
        end
        st.expected_seed = read_expected_seed()
        -- [Port recovery] Start the no-contact clock. Handlers restamp it the
        -- moment anything answers; the poll loop opens the recovery dialog if it
        -- stays stale (see poll_port_recovery).
        st.last_contact_clock = os.clock()
        st.slot_connected = false
        info("connecting to " .. st.server .. " as '" .. st.slot .. "'")
        set_conn_status("pending", "Connecting...")
        ap = AP("", GAME_NAME, st.server)   -- uuid unused per lua-apclientpp README
        ap:set_socket_connected_handler(guard("socket_connected", on_socket_connected))
        ap:set_socket_error_handler(guard("socket_error", on_socket_error))
        ap:set_socket_disconnected_handler(guard("socket_disconnected", on_socket_disconnected))
        ap:set_room_info_handler(guard("room_info", on_room_info))
        ap:set_slot_connected_handler(guard("slot_connected", on_slot_connected))
        ap:set_slot_refused_handler(guard("slot_refused", on_slot_refused))
        ap:set_items_received_handler(guard("items_received", on_items_received))
        ap:set_location_info_handler(guard("location_info", on_location_info))
        ap:set_location_checked_handler(guard("location_checked", on_location_checked))
        ap:set_bounced_handler(guard("bounced", on_bounced))
        ap:set_print_json_handler(guard("print_json", on_print_json))
        ap:set_retrieved_handler(guard("retrieved", on_retrieved))
        ap:set_set_reply_handler(guard("set_reply", on_set_reply))
        return true
    end

    -- [Port recovery] Player-facing actions, called by the recovery dialog.
    -- Test = rewrite the port in the game-relative ap_connection.json (the file
    -- the mod actually reads), then drop the client so the retry loop dials the
    -- new address within ~3s. Password and slot are preserved untouched; the
    -- seed check on the next RoomInfo is what proves the new port is right.
    -- Write a new server address into the game-relative connection file and drop
    -- the client so the poll loop dials it (~3s). Slot, password and the room
    -- pointer are preserved: the Server tab edits the address only, and the
    -- recovery dialog edits only the port inside it. Returns ok, message.
    --
    -- NOTE the launcher keeps its own copy of this file under %APPDATA% that Lua
    -- cannot reach, so after an in-game change the launcher still shows the old
    -- address until a re-patch or its own Fix Automatically. The Server tab says
    -- so on screen rather than letting players find out later.
    local function apply_server_address(new_server)
        local payload = {
            server_address = new_server,
            slot_name = st.slot,
            password = st.password or "",
            room_url = st.room_url or "",
        }
        local ok_call, result = pcall(function()
            return json.dump_file(CONNECTION_INFO_FILE, payload, 4)
        end)
        if not (ok_call and result ~= false) then
            err("failed to write " .. CONNECTION_INFO_FILE)
            return false, "Could not save the address. Use the launcher instead."
        end
        info(string.format("connection address set to %s - reconnecting", new_server))
        -- Drop the client; the poll loop re-reads the file and reconnects.
        ap = nil
        st.server = new_server
        -- Restart the no-contact budget, or the watchdog would judge the NEW
        -- address by how long the OLD one had been silent and re-open the
        -- recovery dialog straight away.
        st.last_contact_clock = os.clock()
        st.slot_connected = false
        -- A new address is a fresh conversation: an old dismissal must not
        -- mute warnings about the NEW port.
        st.port_recovery_dismissed_kind = nil
        if ctx.bridge ~= nil then
            ctx.bridge.launcher_server_address = new_server
        end
        set_conn_status("pending", "Reconnecting...")
        return true, string.format("Trying %s...", new_server)
    end

    local function ap_apply_port(port_text)
        local bridge = ctx.bridge
        local port = tonumber(trim(port_text))
        if port == nil or port ~= math.floor(port) or port < 1 or port > 65535 then
            if bridge ~= nil then
                bridge.port_recovery_status = "Enter a port number between 1 and 65535."
            end
            return false
        end
        local host = select(1, split_server_address(st.server))
        if host == "" then
            if bridge ~= nil then
                bridge.port_recovery_status = "No server address on record - use the launcher."
            end
            return false
        end
        local ok_apply, message = apply_server_address(string.format("%s:%d", host, port))
        if bridge ~= nil then
            bridge.port_recovery_status = message
        end
        return ok_apply
    end
    ctx.ap_apply_port = ap_apply_port

    -- [Server tab] Edit the whole address. Takes host:port with or without a
    -- ws:// or wss:// scheme, matching what the launcher's field accepts; a bare
    -- host keeps the port already on record so a slip cannot silently drop it.
    local function ap_apply_server_address(address_text)
        local bridge = ctx.bridge
        local text = trim(address_text)
        if text == "" then
            if bridge ~= nil then bridge.server_tab_status = "Enter an address first." end
            return false
        end
        local host, port = split_server_address(text)
        if host == "" then
            if bridge ~= nil then bridge.server_tab_status = "That address has no host." end
            return false
        end
        if port == nil then
            local _, current_port = split_server_address(st.server)
            port = current_port
            if port == nil then
                if bridge ~= nil then
                    bridge.server_tab_status = "Add a port, for example archipelago.gg:38281."
                end
                return false
            end
        end
        if port ~= math.floor(port) or port < 1 or port > 65535 then
            if bridge ~= nil then
                bridge.server_tab_status = "Port must be between 1 and 65535."
            end
            return false
        end
        local ok_apply, message = apply_server_address(string.format("%s:%d", host, port))
        if bridge ~= nil then bridge.server_tab_status = message end
        return ok_apply
    end
    ctx.ap_apply_server_address = ap_apply_server_address

    -- Reconnect with no edits: the fix for a dropped socket that has not retried
    -- yet, and the way to re-read the file after the launcher rewrites it.
    local function ap_reconnect()
        ap = nil
        st.last_contact_clock = os.clock()
        st.slot_connected = false
        set_conn_status("pending", "Reconnecting...")
        info("reconnect requested from the Server tab")
        if ctx.bridge ~= nil then
            ctx.bridge.server_tab_status = "Reconnecting..."
        end
        return true
    end
    ctx.ap_reconnect = ap_reconnect

    -- Everything the Server tab shows, read on demand so none of it has to be
    -- mirrored onto the bridge every frame.
    local function ap_get_connection_info()
        local seconds_since_contact = nil
        local last_contact = tonumber(st.last_contact_clock)
        if last_contact ~= nil then
            seconds_since_contact = os.clock() - last_contact
        end
        return {
            server = st.server or "",
            slot = st.slot or "",
            seed = st.seed or "",
            expected_seed = st.expected_seed or "",
            room_url = st.room_url or "",
            slot_connected = st.slot_connected == true,
            seconds_since_contact = seconds_since_contact,
        }
    end
    ctx.ap_get_connection_info = ap_get_connection_info

    -- [Port recovery] The watchdog. Runs every poll tick: if we are not slot
    -- connected and nothing has answered for PORT_UNREACHABLE_SECONDS, offer the
    -- dialog. This is the check that actually fires for a dead port, because
    -- lua-apclientpp retries the socket itself and never re-enters connect().
    local function poll_port_recovery()
        if ap == nil or st.slot_connected then return end
        if ctx.bridge ~= nil and ctx.bridge.port_recovery_dialog ~= nil then return end
        -- Dismissed watchdog warnings stay dismissed. open_port_recovery also
        -- checks the latch, but bailing here keeps the warn line below from
        -- firing on every poll tick of a long outage.
        if st.port_recovery_dismissed_kind == "unreachable" then return end
        local ok_state, state = pcall(function() return ap:get_state() end)
        if ok_state and state == AP.State.SLOT_CONNECTED then
            st.slot_connected = true
            st.last_contact_clock = os.clock()
            return
        end
        local since = os.clock() - (tonumber(st.last_contact_clock) or os.clock())
        if since >= PORT_UNREACHABLE_SECONDS then
            warn(string.format(
                "%s has not answered for %ds - offering the port recovery dialog.",
                tostring(st.server), math.floor(since)))
            open_port_recovery("unreachable", "", math.floor(since))
        end
    end

    local function ap_dismiss_port_recovery()
        local dialog = (ctx.bridge ~= nil) and ctx.bridge.port_recovery_dialog or nil
        -- Latch the kind BEFORE closing (close nils the dialog). "unreachable"
        -- is the fallback because it is the only kind the watchdog re-opens on
        -- its own.
        st.port_recovery_dismissed_kind =
            (type(dialog) == "table" and dialog.kind ~= nil) and tostring(dialog.kind) or "unreachable"
        close_port_recovery()
        info(string.format("port recovery: '%s' dialog dismissed by the player",
            tostring(st.port_recovery_dismissed_kind)))
        return true
    end
    ctx.ap_dismiss_port_recovery = ap_dismiss_port_recovery

    load_ap_item_map()
    connect()

    local last_retry_clock = 0
    re.on_pre_application_entry("UpdateBehavior", function()
        local ok, e = pcall(function()
            if ap ~= nil then
                ap:poll()
                drain_received_items()
                drain_location_checks()
                maybe_send_victory()
                poll_deathlink()
                poll_port_recovery()
                return
            end
            local now = os.clock()
            if now - last_retry_clock >= 3.0 then
                last_retry_clock = now
                connect()
            end
        end)
        if not ok then
            err("poll loop error: " .. tostring(e))
        end
    end)

    info("apclient.lua initialized (Phase 2d: received items -> injection).")
end
