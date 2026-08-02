local function install(ctx)
    ctx.bridge_io = ctx.bridge_io or {}

    local bridge = ctx.bridge

    local function export(name, value)
        ctx.bridge_io[name] = value
        ctx[name] = value
        _G[name] = value
    end

    local function build_session_state_file_path(bridge_dir)
        local seed_name = trim_string(bridge.ap_session_seed_name)
        local slot_name = trim_string(bridge.ap_session_slot_name)
        if seed_name == "" or slot_name == "" then
            return bridge_dir .. "\\session_standalone.json"
        end

        return string.format(
            "%s\\session_%s__%s.json",
            bridge_dir,
            sanitize_session_component(seed_name),
            sanitize_session_component(slot_name)
        )
    end

    local function get_session_state_file_path()
        return build_session_state_file_path(BRIDGE_DIR)
    end

    -- The pre-2026-07-23 store location: "\RE4R-AP\bridge" = game drive root
    -- (APPDATA resolves empty under REFramework). Read-only migration source.
    local function get_legacy_session_state_file_path()
        return build_session_state_file_path(LEGACY_BRIDGE_DIR)
    end

    local function save_session_state()
        local session_state_path = get_session_state_file_path()
        bridge.loaded_session_state_path = session_state_path
        local ok = json.dump_file(session_state_path, {
            victory_sent = bridge.victory_sent == true,
            victory_pending = bridge.victory_pending == true,
            last_received_index = math.floor(tonumber(bridge.last_received_index) or -1),
            -- Per-seed so a returning player is never re-taught, but a brand
            -- new seed greets a brand new player.
            tutorial_shown = bridge.tutorial_shown == true,
            -- [Phase 3] durable per-seed checked set ("stage|guid" -> true).
            acknowledged_guid_keys = bridge.acknowledged_guid_keys,
            -- [F8] per-guid, per-save-version received-item watermarks.
            save_reconcile = bridge.save_reconcile_map or {},
        }, 4)
        if not ok then
            log.error("[ArchipelagoRE4R] Failed to write session state to " .. tostring(session_state_path))
        end
        return ok
    end

    local function load_session_state()
        local session_state_path = get_session_state_file_path()
        bridge.loaded_session_state_path = session_state_path
        bridge.victory_sent = false
        bridge.victory_pending = false
        bridge.last_received_index = -1
        bridge.tutorial_shown = false
        bridge.acknowledged_guid_keys = {}
        bridge.save_reconcile_map = {}

        local payload = json.load_file(session_state_path)
        local migrated_from = nil
        if type(payload) ~= "table" then
            -- One-time forward migration from the legacy drive-root store.
            -- The legacy file is left in place (never deleted): losing the
            -- watermark would re-inject received items as duplicates.
            local legacy_path = get_legacy_session_state_file_path()
            local legacy_payload = json.load_file(legacy_path)
            if type(legacy_payload) == "table" then
                payload = legacy_payload
                migrated_from = legacy_path
            end
        end
        if type(payload) == "table" then
            bridge.victory_sent = payload.victory_sent == true
            bridge.victory_pending = payload.victory_pending == true
            bridge.last_received_index = math.floor(tonumber(payload.last_received_index) or -1)
            bridge.tutorial_shown = payload.tutorial_shown == true
            if type(payload.acknowledged_guid_keys) == "table" then
                for k, v in pairs(payload.acknowledged_guid_keys) do
                    if type(k) == "string" and v == true then
                        bridge.acknowledged_guid_keys[k] = true
                    end
                end
            end
            -- [F8] per-guid save-version watermarks (received-item reconciliation).
            if type(payload.save_reconcile) == "table" then
                for guid, rec in pairs(payload.save_reconcile) do
                    if type(guid) == "string" and type(rec) == "table"
                        and type(rec.save_watermarks) == "table" then
                        local sw = {}
                        for count_key, wm in pairs(rec.save_watermarks) do
                            local wmn = tonumber(wm)
                            if wmn ~= nil then sw[tostring(count_key)] = math.floor(wmn) end
                        end
                        bridge.save_reconcile_map[guid] = { save_watermarks = sw }
                    end
                end
            end
        end
        if migrated_from ~= nil then
            local saved = save_session_state()
            log.info(string.format(
                "[RE4R AP] session state migrated from legacy %s to %s (write %s)",
                tostring(migrated_from),
                tostring(session_state_path),
                saved and "ok" or "FAILED - still running on legacy data"
            ))
        end
    end

    local function refresh_launcher_connection_info()
        bridge.launcher_server_address = ""
        bridge.launcher_slot_name = ""

        local payload = json.load_file(CONNECTION_INFO_FILE)
        if type(payload) ~= "table" then
            return
        end

        local server_address = trim_string(payload.server_address)
        local slot_name = trim_string(payload.slot_name)
        if server_address ~= "" then
            bridge.launcher_server_address = server_address
        end
        if slot_name ~= "" then
            bridge.launcher_slot_name = slot_name
        end
    end

    local function refresh_launcher_bridge_files()
        refresh_launcher_connection_info()
    end

    local function set_ap_session_identity(seed_name, slot_name, current_stage)
        local normalized_seed_name = trim_string(seed_name)
        local normalized_slot_name = trim_string(slot_name)
        local changed = normalized_seed_name ~= bridge.ap_session_seed_name
            or normalized_slot_name ~= bridge.ap_session_slot_name
            or bridge.loaded_warp_unlocks_path == nil
            or bridge.loaded_session_state_path == nil

        bridge.ap_session_seed_name = normalized_seed_name
        bridge.ap_session_slot_name = normalized_slot_name

        if normalized_seed_name == "" or normalized_slot_name == "" then
            bridge.location_classifications = {}
            bridge.progression_warning_dialog = nil
        end

        if changed then
            bridge.progression_warning_dialog = nil
            bridge.progression_warning_shown_chapters = {}
            bridge.progression_warning_visited_stages = {}
            bridge.victory_pending = false
            load_session_state()
            local load_warp_unlocks = ctx.load_warp_unlocks
            if type(load_warp_unlocks) == "function" then
                load_warp_unlocks()
            end
            local sync_typewriter_warp_unlock_for_stage = ctx.sync_typewriter_warp_unlock_for_stage
            if type(sync_typewriter_warp_unlock_for_stage) == "function" then
                sync_typewriter_warp_unlock_for_stage(current_stage)
            end
        end
    end

    -- [F8] Read the campaign save identity off a chainsaw.CampaignManager.GameData
    -- managed object: its stable per-playthrough guid string + monotonic _SaveCount.
    -- Every native read is pcall-guarded and the guid is only returned when its
    -- canonical ToString() succeeds, so the key format can never drift between the
    -- save and load sides; returns (nil, nil) on any failure -> caller declines to
    -- reconcile rather than acting on bad data.
    local function read_campaign_save_ids(save_data)
        if save_data == nil then return nil, nil end
        local guid = nil
        pcall(function()
            local g = save_data:get_field("_CurrentCampaignUniqueGuid")
            if g ~= nil then
                local s = g:call("ToString()")
                if type(s) == "string" and s ~= "" then guid = s end
            end
        end)
        local count = nil
        pcall(function()
            local c = save_data:get_field("_SaveCount")
            if type(c) == "number" then count = math.floor(c) end
        end)
        return guid, count
    end

    -- [F8] Record that campaign save version <save_count> for <guid> baked in
    -- received items up to <watermark>. Bounded to the most recent counts so a long
    -- playthrough cannot grow the session file without limit. Caller persists.
    local SAVE_WATERMARK_KEEP = 64
    local function record_save_watermark(guid, save_count, watermark)
        if type(guid) ~= "string" or guid == "" then return end
        local count = tonumber(save_count)
        if count == nil then return end
        local wm = math.floor(tonumber(watermark) or -1)
        bridge.save_reconcile_map = bridge.save_reconcile_map or {}
        local rec = bridge.save_reconcile_map[guid]
        if type(rec) ~= "table" or type(rec.save_watermarks) ~= "table" then
            rec = { save_watermarks = {} }
            bridge.save_reconcile_map[guid] = rec
        end
        rec.save_watermarks[tostring(math.floor(count))] = wm
        -- Prune to the most recent SAVE_WATERMARK_KEEP counts (numeric order).
        local counts = {}
        for k in pairs(rec.save_watermarks) do
            local n = tonumber(k)
            if n ~= nil then counts[#counts + 1] = n end
        end
        if #counts > SAVE_WATERMARK_KEEP then
            table.sort(counts)
            for i = 1, #counts - SAVE_WATERMARK_KEEP do
                rec.save_watermarks[tostring(counts[i])] = nil
            end
        end
    end

    -- [F8] The received-item watermark baked into save version <save_count> of
    -- <guid>, or nil if we have no record of that exact version. The caller then
    -- declines to reconcile -- it never guesses, so a load can never double-grant
    -- an item the save already contains.
    local function lookup_save_floor(guid, save_count)
        if type(guid) ~= "string" then return nil end
        local map = bridge.save_reconcile_map
        if type(map) ~= "table" then return nil end
        local rec = map[guid]
        if type(rec) ~= "table" or type(rec.save_watermarks) ~= "table" then return nil end
        local count = tonumber(save_count)
        if count == nil then return nil end
        local wm = rec.save_watermarks[tostring(math.floor(count))]
        return (type(wm) == "number") and wm or nil
    end

    export("save_session_state", save_session_state)
    export("set_ap_session_identity", set_ap_session_identity)
    export("refresh_launcher_bridge_files", refresh_launcher_bridge_files)
    export("read_campaign_save_ids", read_campaign_save_ids)
    export("record_save_watermark", record_save_watermark)
    export("lookup_save_floor", lookup_save_floor)
end

return install
