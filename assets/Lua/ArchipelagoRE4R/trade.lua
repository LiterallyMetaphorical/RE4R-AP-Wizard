-- trade.lua - the AP-aware Trade tab's runtime half (Trade takeover, Phase 2).
--
-- The buy tab's twin is merchant.lua and this deliberately reads like it,
-- because the two tabs pose the same problem: far more checks than places to
-- show them, so the pak bakes a small window of slots and the runtime rotates
-- checks through it.
--
-- The fork writes the tab at patch time (ApMerchantShopModifier.ApplyTradeTab):
-- every vanilla one-shot row stripped, check slots minted on stand-in ids at
-- reward ids 0-6 with a FIXED spinel price each, then the exchange rows -
-- Velvet Blue, three gems, and vanilla's Gold Token. Everything that has to
-- happen WHEN the player claims one lives here.
--
-- Three things make this different from the buy tab, and each one is a measured
-- fact rather than a preference (MERCHANT_TRADE_DESIGN.md 4.6.5):
--
--   1. THERE IS NO CLAIM EVENT. notifyRecieveItem was the obvious candidate and
--      it was REFUTED live: hooked cleanly, fired zero times across five
--      claims. Claim detection is therefore POLLING getRewardProgress and
--      diffing - the same reconcile-from-truth shape that is already the buy
--      tab's correctness mechanism, so no hook is needed at all.
--
--   2. EVERY ENGINE CALL RUNS ON THE GAME THREAD. Calling into the manager
--      from an imgui draw crashed the game once already. Actions are enqueued
--      and drained one per frame by re.on_frame, never invoked inline.
--
--   3. SLOT IDS ARE A HARD BUDGET OF 0-31. Id 32 registers but its claim does
--      NOT survive a save/reload, and a claim that does not persist re-arms a
--      slot the server has already banked - which would charge the player a
--      second time for a check that can never send again. The fork keeps check
--      slots at the lowest ids for that reason; this half must never invent an
--      id outside the range it was handed.
--
-- Everything is defensive: an old room file with no trade section, a missing
-- method, a manager that is not up yet - each degrades to "log it and leave the
-- tab alone".
return function(ctx)
    local bridge = ctx.bridge

    local trade = {
        -- The rotating display window: slot records from the room file, each
        -- with a FIXED spinel price. A slot is a window, not a home.
        slots = {},
        -- Every trade check in the room, in release order.
        checks = {},
        -- reward id -> the check that slot is CURRENTLY showing. Derived, never
        -- stored, so nothing can drift out of step.
        checks_by_reward_id = {},
        -- location_code -> check record
        checks_by_location = {},
        -- reward id -> last polled progress. The diff against this is what a
        -- claim IS, since no event reports one.
        progress = {},
        -- released checks with no free slot of their tier, surfaced on the HUD
        backlog = 0,
        slot_count = 0,
        check_count = 0,
        claims_this_session = 0,
        polling = false,
        -- Binding is not a one-shot. On a NEW GAME it runs before the
        -- shop's reward table exists, every id answers -1, and nothing
        -- binds - which silently disables the whole tab for the run.
        bound_ok = false,
        bind_attempts = 0,
        -- reward id -> slot record, filled at bind. What lets the icon and
        -- text passes tell "one of ours, currently empty" from "not ours".
        slot_by_reward_id = {},
        -- The fork baked ONE empty-slot text at these GUIDs (derived by the
        -- launcher, carried by the room file). A slot with nothing to show
        -- points at it, so an emptied slot never keeps the name of the check
        -- it just sold. Nil in a room file that predates them.
        empty_name_msg_guid = nil,
        empty_caption_msg_guid = nil,
    }
    ctx.trade = trade

    local function info(text)
        log.info("[RE4R AP][trade] " .. tostring(text))
    end

    local function shop_manager()
        return sdk.get_managed_singleton("chainsaw.InGameShopManager")
    end

    -- getRewardProgress is an ENUM, not a counter: Invalid (-1), None (0),
    -- Recieved (1). None and Recieved are the two states a slot can be in;
    -- Invalid means the tab does not have that id RIGHT NOW (not built yet
    -- on a new game, torn down between saves). Invalid is returned as nil so
    -- nothing downstream can fold it into a baseline: the old
    -- `math.floor(tonumber(value) or 0)` kept the -1, and a table coming back
    -- would then have read "advanced -1 -> 0" - the claim branch, on every
    -- slot holding a check, sending checks nobody bought.
    local function read_progress(mgr, reward_id)
        local value
        local ok = pcall(function()
            value = mgr:call("getRewardProgress", reward_id)
        end)
        if not ok then
            return nil
        end
        local numeric = tonumber(value)
        if numeric == nil or numeric < 0 then
            return nil
        end
        return math.floor(numeric)
    end

    -- ------------------------------------------------------- game-thread pump
    -- Engine calls NEVER run inline from a draw callback or a poll callback.
    -- One action per frame, on the game thread, every outcome logged. See the
    -- header: this is a crash that already happened, not a precaution.
    local pending_actions = {}

    local function enqueue(label, fn)
        pending_actions[#pending_actions + 1] = { label = label, fn = fn }
    end

    -- Icon re-application rides this pump too, declared here and filled in
    -- once the icon code exists further down.
    local per_frame_icons = nil

    re.on_frame(function()
        if per_frame_icons ~= nil then
            per_frame_icons()
        end
        if #pending_actions == 0 then
            return
        end
        local action = table.remove(pending_actions, 1)
        local ok, err = pcall(action.fn)
        if not ok then
            info(string.format("action '%s' errored: %s", action.label, tostring(err)))
        end
    end)

    -- ------------------------------------------------------------- room file
    -- The launcher stamps "trade_shop" into ap_room_locations.json beside the
    -- location ids, the same channel merchant_shop rides. Records carry
    -- everything the runtime needs, so the mod never has to know the tier
    -- table or the stand-in id assignment.
    local function load_trade(payload)
        trade.slots = {}
        trade.checks = {}
        trade.checks_by_reward_id = {}
        trade.checks_by_location = {}
        trade.progress = {}
        trade.slot_by_reward_id = {}
        trade.slot_count = 0
        trade.check_count = 0
        trade.backlog = 0
        trade.empty_name_msg_guid = nil
        trade.empty_caption_msg_guid = nil

        if type(payload) ~= "table" or payload.enabled ~= true then
            return
        end

        if type(payload.empty_name_msg_guid) == "string" and payload.empty_name_msg_guid ~= "" then
            trade.empty_name_msg_guid = payload.empty_name_msg_guid
        end
        if type(payload.empty_caption_msg_guid) == "string" and payload.empty_caption_msg_guid ~= "" then
            trade.empty_caption_msg_guid = payload.empty_caption_msg_guid
        end

        if type(payload.slots) == "table" then
            for _, raw in ipairs(payload.slots) do
                local item_id = math.floor(tonumber(raw and raw.item_id) or 0)
                local price = math.floor(tonumber(raw and raw.price_spinel) or 0)
                if item_id > 0 and price > 0 then
                    trade.slots[#trade.slots + 1] = {
                        item_id = item_id,
                        tier = tostring(raw.tier or "FILLER"),
                        price_spinel = price,
                        -- Assigned on the first reconcile from the tab's own
                        -- reward table, NOT guessed: the fork owns the id
                        -- layout and the runtime reads it back rather than
                        -- assuming it starts at zero.
                        reward_id = nil,
                    }
                end
            end
        end
        trade.slot_count = #trade.slots

        -- The exchange rows. Only their ITEM IDS matter here: the fork baked
        -- their prices, and all this half does is un-claim them so they
        -- restock. Velvet Blue and the Gold Token are deliberately absent -
        -- both are _RecieveType 1, genuinely unlimited, and never need one.
        trade.gem_item_ids = {}
        trade.gem_item_set = {}
        if type(payload.gems) == "table" then
            for _, gem in pairs(payload.gems) do
                local gem_id = math.floor(tonumber(gem and gem.item_id) or 0)
                if gem_id > 0 then
                    trade.gem_item_ids[#trade.gem_item_ids + 1] = gem_id
                    trade.gem_item_set[gem_id] = true
                end
            end
            table.sort(trade.gem_item_ids)
        end

        if type(payload.checks) == "table" then
            for _, raw in ipairs(payload.checks) do
                -- The room file writes location_code (matching the shelf
                -- block); `code` is accepted too so a hand-written probe
                -- payload still loads.
                local code = math.floor(
                    tonumber(raw and (raw.location_code or raw.code)) or 0)
                if code > 0 then
                    local check = {
                        location_code = code,
                        identity = tostring(raw.identity or ("trade:" .. tostring(code))),
                        release_index = math.floor(tonumber(raw.release_index) or 0),
                        chapter = math.floor(tonumber(raw.chapter) or 1),
                        chapter_ordinal = math.floor(tonumber(raw.chapter_ordinal) or 1),
                        price_spinel = math.floor(tonumber(raw.price_spinel) or 1),
                        tier = tostring(raw.tier or "FILLER"),
                        cumulative_spinel = math.floor(tonumber(raw.cumulative_spinel) or 0),
                        display_name = tostring(raw.display_name or "Archipelago Check"),
                        player_name = tostring(raw.player_name or ""),
                        remote = raw.remote == true,
                        item_id_real = math.floor(tonumber(raw.item_id) or 0),
                        item_stack = math.floor(tonumber(raw.item_stack) or 0),
                        -- The fork baked this check's name and caption at
                        -- these GUIDs. Dressing points a slot at them; nothing
                        -- here ever invents a string.
                        name_msg_guid = raw.name_msg_guid and tostring(raw.name_msg_guid) or nil,
                        caption_msg_guid = raw.caption_msg_guid and tostring(raw.caption_msg_guid) or nil,
                        claimed = false,
                    }
                    trade.checks[#trade.checks + 1] = check
                    trade.checks_by_location[code] = check
                end
            end
        end
        table.sort(trade.checks, function(a, b)
            return a.release_index < b.release_index
        end)
        trade.check_count = #trade.checks

        info(string.format(
            "room file: %d check(s) across %d display slot(s)%s",
            trade.check_count, trade.slot_count,
            trade.empty_name_msg_guid and "" or " (no empty-slot text in this room file)"))
    end

    -- ------------------------------------------------------------ reward table
    -- Read the tab's reward ids back out of the live manager and match them to
    -- the room file's slots by ITEM ID. The fork put check slots at ids 0-6,
    -- but reading rather than assuming means a future layout change in the
    -- fork cannot silently desync the two halves.
    local function bind_reward_ids()
        local mgr = shop_manager()
        if mgr == nil then
            return false, "shop manager unavailable"
        end
        -- Binding is POSITIONAL, verified against the live tab. Two failed
        -- attempts got us here and both are worth remembering:
        --
        --   1. Reading `_RewardSettingTable._Settings` - it has no such field.
        --      It is a Dictionary<UInt32, InGameShopRewardSingleSetting>.
        --   2. Reading that dictionary by key. `get_Count` works and returns
        --      12, but `get_Item` does NOT: the key is UInt32 and a Lua number
        --      marshals as Int32, so the overload never matches. The in-game
        --      probe had already proved this ("setting table not enumerable
        --      via get_Item/getItem") before this module tried it again.
        --
        -- So do not enumerate. The FORK owns the id layout and writes check
        -- slots at reward ids 0..N-1 in the order of the manifest's slot list,
        -- then the gems. The room file carries that SAME list, from the same
        -- deterministic TradeShopPlanner call - the two sides were wired to
        -- one planner precisely so they could not disagree.
        --
        -- Positional alone would still be an assumption, so every id is then
        -- CONFIRMED with getRewardProgress, which is proven live and returns
        -- -1 for an id the tab does not have and 0/1 for one it does. An id
        -- that answers -1 is refused rather than bound, so a fork layout
        -- change shows up as a loud unbound slot instead of a silent
        -- mis-mapping.
        local function reward_id_exists(reward_id)
            local value
            local ok = pcall(function()
                value = mgr:call("getRewardProgress", reward_id)
            end)
            if not ok then
                return false
            end
            local numeric = tonumber(value)
            return numeric ~= nil and numeric >= 0
        end

        local bound = 0
        trade.slot_by_reward_id = {}
        for index, slot in ipairs(trade.slots) do
            local reward_id = index - 1
            if reward_id_exists(reward_id) then
                slot.reward_id = reward_id
                trade.slot_by_reward_id[reward_id] = slot
                bound = bound + 1
            else
                slot.reward_id = nil
            end
        end

        -- The gems sit directly above the check slots, same order as the room
        -- file's gem list (the fork writes them straight after).
        trade.gem_reward_ids = {}
        for index = 1, #(trade.gem_item_ids or {}) do
            local reward_id = trade.slot_count + index - 1
            if reward_id_exists(reward_id) then
                trade.gem_reward_ids[#trade.gem_reward_ids + 1] = reward_id
            end
        end

        -- Seed the claim baseline HERE, not on the first poll.
        --
        -- Binding happens on connect, before the player can reach the tab; the
        -- first poll can be seconds later. Seeding in the poll instead leaves a
        -- window where a claim made before that first poll is read as the
        -- baseline and therefore never reported - a silently lost check, the
        -- exact class this project has spent months chasing. An offline harness
        -- run caught it.
        --
        -- Whatever a loaded save already had claimed is still absorbed here, so
        -- the mid-run reconnect case behaves the same as before.
        --
        -- The sweep is logged. It is the answer to "does a pak-baked
        -- _Progress seed the save" if that experiment is ever run, and it
        -- shows which slots a loaded save already had closed.
        local sweep = {}
        local mgr_for_seed = shop_manager()
        if mgr_for_seed ~= nil then
            for _, slot in ipairs(trade.slots) do
                if slot.reward_id ~= nil then
                    local value = read_progress(mgr_for_seed, slot.reward_id)
                    if value ~= nil then
                        trade.progress[slot.reward_id] = value
                    end
                    sweep[#sweep + 1] = string.format("%d=%s", slot.reward_id, tostring(value))
                end
            end
        end

        return bound == trade.slot_count,
            string.format(
                "bound %d/%d check slot(s) at reward ids 0-%d and %d gem slot(s), "
                    .. "each confirmed against the live tab; progress by slot: %s",
                bound, trade.slot_count, math.max(0, trade.slot_count - 1),
                #trade.gem_reward_ids,
                #sweep > 0 and table.concat(sweep, " ") or "none")
    end

    -- ------------------------------------------------------------- rotation
    -- Which check a slot is showing is DERIVED, never stored: ask the server
    -- which checks are already done and the game which chapter has arrived,
    -- then hand each slot the oldest released check it can display. Same
    -- reasoning as the buy tab's assign_rows, and the same payoff: it survives
    -- death, reload and save-hopping for free, because there is no state to get
    -- out of step.
    --
    -- Tier matters here for a reason the buy tab does not share. A trade slot's
    -- spinel price is BAKED into the pak, so a slot may only ever show a check
    -- of its own tier - putting a 6-spinel check on a 1-spinel slot would sell
    -- it for one spinel.
    local function check_is_checked(check)
        local key = "trade:" .. tostring(check.identity)
        local acknowledged = bridge and bridge.acknowledged_guid_keys
        if type(acknowledged) == "table" and acknowledged[key] then
            return true
        end
        -- Queued but not yet acknowledged counts too. A reconfigure (room
        -- file re-read on reconnect) resets every `claimed` flag, and a claim
        -- still waiting for the server would otherwise be re-shown - and
        -- re-buyable - until the ack landed.
        local pending = bridge and bridge.pending_check_keys
        if type(pending) == "table" and pending[key] then
            return true
        end
        return false
    end

    -- Release is decided by the SHOP's own unlock waypoint, not by a chapter
    -- number carried on the bridge.
    --
    -- The first version read `bridge.last_state.current_chapter`, which does
    -- not exist - the bridge's chapter lives under `ui_current_chapter` and is
    -- a display field. So it read nil, the "unknown chapter releases nothing"
    -- rule released nothing, no check was ever assigned to a slot, and a real
    -- claim logged "reward id 1 advanced 0 -> 1 with no check bound". The tab
    -- worked; there was simply nothing on it to send.
    --
    -- merchant.lua already had this right and had had it right for weeks:
    -- ask the manager `isEnableUpdateFlag(chapter - 1)`. That is the shop's
    -- own release waypoint, it is what the buy tab gates on, and it needs no
    -- second source of truth to drift against.
    local function chapter_unlock_flag(chapter)
        local flag = math.floor(tonumber(chapter) or 1) - 1
        if flag < 0 then flag = 0 end
        if flag > 15 then flag = 15 end
        return flag
    end

    local function chapter_is_open(mgr, chapter)
        if mgr == nil then
            return false
        end
        local unlocked = nil
        pcall(function()
            unlocked = mgr:call("isEnableUpdateFlag", chapter_unlock_flag(chapter))
        end)
        return unlocked == true
    end

    -- Highest chapter whose waypoint has fired, or nil before any has. Used
    -- only to notice a chapter BOUNDARY for the gem restock; the release test
    -- above is per-check and does not depend on it.
    local function current_chapter(mgr)
        mgr = mgr or shop_manager()
        if mgr == nil then
            return nil
        end
        local highest = nil
        for chapter = 1, 16 do
            if chapter_is_open(mgr, chapter) then
                highest = chapter
            end
        end
        return highest
    end

    -- Assign checks to slots and report how many released checks had nowhere to
    -- go. Returns the assignment rather than writing it, so a caller can diff.
    local function assign_slots()
        local mgr = shop_manager()
        local by_tier = {}
        local eligible = {}
        for _, check in ipairs(trade.checks) do
            -- Per-check, against the game's own waypoint. Before any waypoint
            -- has fired nothing releases, which is right: showing a chapter-15
            -- check in chapter 1 would let a player buy past the cadence.
            local released = chapter_is_open(mgr, check.chapter)
            if released and not check_is_checked(check) and not check.claimed then
                eligible[check.identity] = true
                local bucket = by_tier[check.tier]
                if bucket == nil then
                    bucket = {}
                    by_tier[check.tier] = bucket
                end
                bucket[#bucket + 1] = check
            end
        end

        -- STABLE: a slot keeps the check it is already showing while that
        -- check is still eligible. Until 2026-09-02 every reconcile re-dealt
        -- the buckets oldest-first, so buying tile 1 shifted every later tile
        -- of that tier left by one and closed the LAST tile - when the tile
        -- the player expects to grey out is the one they just bought. Keeping
        -- assignments put also stops the text and icon dressing from churning
        -- on tiles whose check did not change.
        local assignment = {}
        local held = {}
        local shown = 0
        for _, slot in ipairs(trade.slots) do
            if slot.reward_id ~= nil then
                local showing = trade.checks_by_reward_id[slot.reward_id]
                if showing ~= nil and eligible[showing.identity]
                    and showing.tier == slot.tier and not held[showing.identity] then
                    assignment[slot.reward_id] = showing
                    held[showing.identity] = true
                    shown = shown + 1
                end
            end
        end
        -- Then the empty slots take the oldest released checks of their tier
        -- that nobody is showing.
        local cursor = {}
        for _, slot in ipairs(trade.slots) do
            if slot.reward_id ~= nil and assignment[slot.reward_id] == nil then
                local bucket = by_tier[slot.tier]
                if bucket ~= nil then
                    local index = (cursor[slot.tier] or 0) + 1
                    while bucket[index] ~= nil and held[bucket[index].identity] do
                        index = index + 1
                    end
                    local check = bucket[index]
                    if check ~= nil then
                        assignment[slot.reward_id] = check
                        held[check.identity] = true
                        shown = shown + 1
                    end
                    cursor[slot.tier] = index
                end
            end
        end

        local released_total = 0
        for _, bucket in pairs(by_tier) do
            released_total = released_total + #bucket
        end
        trade.backlog = math.max(0, released_total - shown)
        if bridge ~= nil then
            bridge.trade_backlog = trade.backlog
        end
        return assignment
    end

    -- Re-derive the shelf. Cheap and idempotent, so it is safe to call on
    -- connect, on chapter change, and after every claim.
    --
    -- Forward declarations: the dressing, the state enforcement and the
    -- window report are defined below. Without these the calls would compile
    -- as global lookups and silently do nothing - the same trap merchant.lua
    -- notes.
    local dress_assigned_slots
    local enforce_slot_states
    local report_window

    local function reconcile_slots()
        if trade.slot_count == 0 then
            return
        end
        trade.checks_by_reward_id = assign_slots()
        if type(dress_assigned_slots) == "function" then
            dress_assigned_slots()
        end
        if type(enforce_slot_states) == "function" then
            enforce_slot_states()
        end
        if type(report_window) == "function" then
            report_window()
        end
        -- Parity with the shelf (2026-09-02): the fork now gives trade
        -- stand-ins a shop model entry, so a remote or empty tile shows the
        -- Archipelago logo model and a local tile its real item. The merchant
        -- module owns the placement numbers and the swap hook; it just needs
        -- asking again whenever the window changes. Idempotent per item id.
        local place_models = ctx.merchant_place_ap_models
        if type(place_models) == "function" then
            enqueue("place AP models", function()
                place_models()
            end)
        end
    end

    -- --------------------------------------------------------- claim polling
    -- getRewardProgress(id) reads Recieved (1) on a claimed slot and None (0)
    -- on an open one (measured live). A slot WE left at 0 reading 1 IS the
    -- claim; there is no event to hook. See read_progress for why Invalid is
    -- a third state and never a number here.

    local function queue_check(check)
        if type(bridge.pending_checks) ~= "table" then
            return false
        end
        local key = "trade:" .. tostring(check.identity)
        bridge.pending_check_keys = bridge.pending_check_keys or {}
        if bridge.pending_check_keys[key] then
            return false
        end
        bridge.pending_check_keys[key] = true
        table.insert(bridge.pending_checks, {
            id = bridge.next_pending_check_id or 1,
            guid = nil,
            stage = bridge.last_state and bridge.last_state.current_stage or nil,
            key = key,
            location_id = check.location_code,
            queued_at_unix_ms = (ctx.now_unix_ms and ctx.now_unix_ms()) or 0,
        })
        bridge.next_pending_check_id = (bridge.next_pending_check_id or 1) + 1
        bridge.state_dirty = true
        return true
    end

    -- ------------------------------------------------------ progress writes
    -- setRewardProgress(id, value) is the ONLY write this module makes to the
    -- reward table. 0 (None) OPENS a slot - proven live, MERCHANT_TRADE_DESIGN
    -- 4.6.5 round 4: claim -> reset -> the slot un-claims in the open tab ->
    -- re-claim works. 1 (Recieved) CLOSES it: the game's own "already
    -- received" state for a one-shot row, greyed and unbuyable.
    --
    -- The baseline is updated INSIDE the write, on the same game-thread tick
    -- as the engine call, so the claim poll can never mistake our own write
    -- for a purchase: a claim is only ever a slot WE left at 0 reading 1.
    -- Runs through the pump, never inline from a poll or a draw.
    local pending_writes = {}

    local function write_progress(reward_id, desired, why)
        if pending_writes[reward_id] ~= nil then
            return false
        end
        pending_writes[reward_id] = desired
        enqueue(string.format("set progress %d=%d (%s)", reward_id, desired, why), function()
            pending_writes[reward_id] = nil
            local mgr = shop_manager()
            if mgr == nil then
                return
            end
            mgr:call("setRewardProgress", reward_id, desired)
            trade.progress[reward_id] = desired
        end)
        return true
    end

    -- THE EMPTY-SLOT FIX (2026-09-02, Cam: "Option A").
    --
    -- The pak bakes all seven slots open and priced, because at patch time
    -- nothing knows which slots will hold a check on a given day. So a slot
    -- with nothing assigned used to sit in the tab buyable: spinel spent,
    -- nothing sent, "advanced 0 -> 1 with no check bound" in the log - and
    -- five of the seven tiles at chapter 1 were exactly that.
    --
    -- Every slot is now driven to a DESIRED state from the current window: a
    -- slot showing a check is open (None), a slot showing nothing is closed
    -- (Recieved). Enforced from the baselines, not from fresh reads, so it
    -- cannot race the claim poll; and re-run on every pass, so a reload or a
    -- rewound save that disagrees is corrected within a tick. A claimed slot
    -- is already Recieved, so "rotate" is just this: assign the next check,
    -- and the slot is reopened because it now has one.
    function enforce_slot_states()
        local opened, parked = 0, 0
        for _, slot in ipairs(trade.slots) do
            local reward_id = slot.reward_id
            if reward_id ~= nil then
                local check = trade.checks_by_reward_id[reward_id]
                local desired = (check ~= nil) and 0 or 1
                local baseline = trade.progress[reward_id]
                if baseline ~= nil and baseline ~= desired then
                    if desired == 0 then
                        if write_progress(reward_id, 0, "open for " .. tostring(check.identity)) then
                            opened = opened + 1
                        end
                    elseif write_progress(reward_id, 1, "park, nothing of tier " .. tostring(slot.tier)) then
                        parked = parked + 1
                    end
                end
            end
        end
        if opened > 0 or parked > 0 then
            info(string.format("slot states: %d opened, %d parked", opened, parked))
        end
    end

    -- One line per CHANGE of the window, never per poll: which check each
    -- slot is showing, or "parked". This is the diagnostic that answers "what
    -- should this tab be showing, and why" from the log alone.
    local last_window_report = nil

    function report_window()
        local parts = {}
        for _, slot in ipairs(trade.slots) do
            if slot.reward_id ~= nil then
                local check = trade.checks_by_reward_id[slot.reward_id]
                parts[#parts + 1] = string.format("%d:%s/%d=%s",
                    slot.reward_id, tostring(slot.tier), slot.price_spinel,
                    check and check.identity or "parked")
            end
        end
        local line = string.format("window: %s | backlog %d",
            #parts > 0 and table.concat(parts, " ") or "nothing bound", trade.backlog)
        if line ~= last_window_report then
            last_window_report = line
            info(line)
        end
    end

    -- One poll pass. Reads every bound slot, reports claims, then enforces
    -- the desired states. Safe to call often.
    local invalid_reported = {}

    local function poll_claims()
        if trade.slot_count == 0 then
            return
        end
        local mgr = shop_manager()
        if mgr == nil then
            return
        end

        local claimed_any = false
        for _, slot in ipairs(trade.slots) do
            local reward_id = slot.reward_id
            if reward_id ~= nil then
                local current = read_progress(mgr, reward_id)
                if current == nil then
                    -- Invalid or unreadable: the table is down or rebuilding
                    -- (title screen, a load in progress). A third state, so
                    -- nothing moves - the baseline stays whatever it was and
                    -- a later 0 can never look like a claim.
                    if not invalid_reported[reward_id] then
                        invalid_reported[reward_id] = true
                        info(string.format(
                            "reward id %d answered Invalid; leaving its baseline alone", reward_id))
                    end
                else
                    if invalid_reported[reward_id] then
                        invalid_reported[reward_id] = nil
                        info(string.format(
                            "reward id %d is readable again (%d)", reward_id, current))
                    end
                    local previous = trade.progress[reward_id]
                    if previous == nil then
                        -- Fallback seeding only: bind seeds every bound slot,
                        -- so this is a slot bound late. Seeding rather than
                        -- reporting is still the safe read - a save loaded
                        -- mid-run legitimately starts with closed slots.
                        trade.progress[reward_id] = current
                    elseif current == 1 and previous == 0 then
                        trade.progress[reward_id] = current
                        local check = trade.checks_by_reward_id[reward_id]
                        if check ~= nil and not check.claimed then
                            check.claimed = true
                            trade.claims_this_session = trade.claims_this_session + 1
                            local queued = queue_check(check)
                            info(string.format(
                                "check '%s' claimed: '%s' (%s, %s, %d spinel)%s",
                                check.identity, check.display_name,
                                check.player_name, check.tier, check.price_spinel,
                                queued and "" or " [already queued]"))
                            claimed_any = true
                        else
                            -- The defect itself, if it ever fires again: a
                            -- purchase on a slot with nothing assigned. Parking
                            -- should make it impossible; if it happens, say
                            -- so loudly and leave the slot closed.
                            info(string.format(
                                "reward id %d advanced 0 -> 1 with no check bound "
                                    .. "(spinel spent on an empty slot - report this)",
                                reward_id))
                        end
                    else
                        trade.progress[reward_id] = current
                    end
                end
            end
        end
        if claimed_any then
            -- The claimed slot reads Recieved and shows a check the server
            -- now has. Re-derive the window: if its tier has another check
            -- waiting, the slot is reopened with it; if not, it stays closed.
            reconcile_slots()
        else
            enforce_slot_states()
        end
    end

    -- ------------------------------------------------------- gem restocking
    -- The gems are one-shot rows restocked by the same reset. This replaced the
    -- old plan of nine to eighteen windowed one-shot rows (4.6.5 round 4), so
    -- three slots cover the whole run.
    --
    -- Restock on CHAPTER CHANGE rather than on a timer: it is the waypoint the
    -- design names, it is observable, and it cannot restock twice for the same
    -- chapter the way an interval could.
    local last_restock_chapter = nil

    local function restock_gems(chapter)
        if type(trade.gem_reward_ids) ~= "table" or #trade.gem_reward_ids == 0 then
            return
        end
        for _, reward_id in ipairs(trade.gem_reward_ids) do
            write_progress(reward_id, 0, "gem restock ch" .. tostring(chapter))
        end
        info(string.format("gem slots restocked for chapter %s", tostring(chapter)))
    end

    -- Retry binding until the tab is actually there. Same shape as the bonus
    -- weapon force-unlock's retry-at-playable, and for the same reason: connect
    -- happens long before the shop data is ready, and a single attempt at the
    -- wrong moment costs the entire session rather than a few seconds.
    local REBIND_EVERY_TICKS = 8
    local rebind_countdown = 0

    local function retry_binding_if_needed()
        if trade.slot_count == 0 or trade.bound_ok then
            return
        end
        if rebind_countdown > 0 then
            rebind_countdown = rebind_countdown - 1
            return
        end
        rebind_countdown = REBIND_EVERY_TICKS
        enqueue("rebind reward ids", function()
            if trade.bound_ok then
                return
            end
            trade.bind_attempts = trade.bind_attempts + 1
            local ok, detail = bind_reward_ids()
            if ok then
                trade.bound_ok = true
                info(detail .. string.format(" [after %d attempt(s)]", trade.bind_attempts))
                reconcile_slots()
            elseif trade.bind_attempts == 1 or trade.bind_attempts % 20 == 0 then
                -- Quiet by default: the first few failures are just the shop
                -- not being up yet, which is normal and not worth a wall of
                -- log. Say something every so often so a PERMANENT failure is
                -- still visible.
                info(detail .. " - tab not ready, retrying")
            end
        end)
    end

    local function poll_chapter_waypoint()
        if trade.slot_count == 0 and
            (type(trade.gem_reward_ids) ~= "table" or #trade.gem_reward_ids == 0) then
            return
        end
        retry_binding_if_needed()
        local chapter = current_chapter()
        if chapter == nil then
            return
        end

        -- Recovery: if the window is empty while checks exist and slots are
        -- bound, re-derive now instead of waiting for a chapter boundary.
        -- Configure-time reconcile can run before any waypoint has fired (on
        -- connect, before the save loads), and without this the tab then sat
        -- empty for the whole session - which is exactly how a real claim came
        -- to log "advanced 0 -> 1 with no check bound".
        if trade.check_count > 0 and next(trade.checks_by_reward_id) == nil then
            reconcile_slots()
        end

        if last_restock_chapter == nil then
            -- First sight seeds rather than restocks, for the same reason the
            -- claim poll seeds: a save loaded mid-run must not be treated as a
            -- chapter that just arrived.
            last_restock_chapter = chapter
            reconcile_slots()
            return
        end
        if chapter ~= last_restock_chapter then
            last_restock_chapter = chapter
            restock_gems(chapter)
            -- A new chapter releases new checks, so the window changes too.
            reconcile_slots()
        end
    end

    -- --------------------------------------------------------- slot dressing
    -- A slot shows a stand-in item, so without this it reads as the fork's
    -- baked text no matter which check is on it. The fork baked every check's
    -- real text at the launcher's GUIDs, plus ONE empty-slot text; this points
    -- the slot's item id at the right one, exactly the way the buy tab dresses
    -- a row.
    --
    -- THE OBJECT MATTERS. registerItemMessageOverwriteSetting lives on
    -- chainsaw.ItemMessageManager, reached through ItemManager - which is what
    -- merchant.lua has always asked. The first version of this module asked
    -- chainsaw.MessageManager, which has no such method (il2cpp dump, read
    -- 2026-09-02), so nothing ever landed and every tile kept the pak's
    -- baseline text: the "all seven read [AP] Archipelago Check" in Cam's
    -- screenshot. The method is now verified on the type before it is called,
    -- and every outcome is logged once per change.
    --
    -- Only re-registered when what a slot shows actually CHANGES: the
    -- overwrite is keyed by item id and is global, so re-registering every poll
    -- would be pure churn.
    local dressed = {}          -- item id -> identity, or "empty"
    local dress_reported = {}   -- item id -> last logged outcome

    local OVERWRITE_METHOD = "registerItemMessageOverwriteSetting"

    local function item_message_manager()
        local item_manager = sdk.get_managed_singleton("chainsaw.ItemManager")
        if item_manager == nil then
            return nil, "ItemManager unavailable"
        end
        local manager = nil
        pcall(function() manager = item_manager:call("get_ItemMessageManager") end)
        if manager == nil then
            return nil, "ItemMessageManager unavailable"
        end
        -- Prove the method rather than assume it: a call on a missing method
        -- does not raise in Lua, it just does nothing, which is exactly how
        -- the wrong-object bug stayed invisible.
        local has_method = false
        pcall(function()
            local type_def = manager:get_type_definition()
            has_method = type_def ~= nil and type_def:get_method(OVERWRITE_METHOD) ~= nil
        end)
        if not has_method then
            return nil, OVERWRITE_METHOD .. " missing on the item message manager"
        end
        return manager, nil
    end

    local function dress_slot(slot, check)
        local target, name_guid, caption_guid
        if check ~= nil then
            target = check.identity
            name_guid, caption_guid = check.name_msg_guid, check.caption_msg_guid
        else
            target = "empty"
            name_guid, caption_guid = trade.empty_name_msg_guid, trade.empty_caption_msg_guid
        end
        if name_guid == nil then
            -- Nothing baked for this state (a room file that predates the
            -- empty-slot text): leave the slot as it is.
            return
        end
        if dressed[slot.item_id] == target then
            return
        end
        enqueue("dress slot " .. tostring(slot.item_id) .. " -> " .. target, function()
            local outcome
            local manager, why = item_message_manager()
            if manager == nil then
                outcome = why
            else
                local box = ctx.box_system_guid or _G.box_system_guid
                if type(box) ~= "function" then
                    outcome = "no GUID boxer"
                else
                    local name_id = box(name_guid)
                    local caption_id = caption_guid and box(caption_guid) or nil
                    -- A LOCAL check keeps its real item's caption, as the buy
                    -- tab does: the identity stays native while the name
                    -- carries the [AP] promise.
                    if check ~= nil and not check.remote and check.item_id_real > 0 then
                        local native = nil
                        pcall(function()
                            native = manager:call("getItemCaptionMsgId", check.item_id_real)
                        end)
                        if native ~= nil then
                            caption_id = native
                        end
                    end
                    if name_id == nil then
                        outcome = "name GUID would not parse"
                    else
                        local ok, err = pcall(function()
                            local setting = sdk.create_instance(
                                "chainsaw.ItemMessageIdOverwriteSettingUserdata.Setting")
                            setting._ItemId = slot.item_id
                            setting._NameMsgId = name_id
                            if caption_id ~= nil then
                                setting._CaptionMsgId = caption_id
                            end
                            manager:call(OVERWRITE_METHOD, setting)
                        end)
                        if ok then
                            dressed[slot.item_id] = target
                            outcome = "ok"
                        else
                            outcome = tostring(err)
                        end
                    end
                end
            end
            local line = string.format("dress slot %s (item %d) -> %s: %s",
                tostring(slot.reward_id), slot.item_id, target, tostring(outcome))
            if dress_reported[slot.item_id] ~= line then
                dress_reported[slot.item_id] = line
                info(line)
            end
        end)
    end

    function dress_assigned_slots()
        for _, slot in ipairs(trade.slots) do
            if slot.reward_id ~= nil then
                dress_slot(slot, trade.checks_by_reward_id[slot.reward_id])
            end
        end
    end

    -- ------------------------------------------------------------ slot icons
    -- A trade slot shows a stand-in item, and the stand-ins are cut content
    -- with no icon of their own, so the tab drew blanks and First Aid Sprays.
    --
    -- Two dead ends first, both now measured rather than assumed:
    --   * `shoprewardtextureholderuserdata` is NOT an item-keyed icon map. It
    --     holds one language-keyed texture-holder prefab (ID=12), so there was
    --     never anything for the fork to bake (4.6.12).
    --   * `RewardRootGui` has no onLateUpdate, so the buy tab's hook point does
    --     not exist on this tab.
    --
    -- What the probe found instead is that this tab is the SAME widget. Read
    -- off the dump's own `parent` key, not inferred from the name:
    --
    --   RewardRootGui.RewardScrollGrid.RewardSelectItem
    --     parent -> chainsaw.gui.shop.PurchaseSelectItem
    --
    -- which is the very class merchant.lua already dresses, carrying
    -- `get_ItemId` and `_ItemIconTex`. So the buy tab's proven lever transfers
    -- wholesale: hand GuiPlayObjectExtension.setItemIcon a texture control and
    -- a REAL engine item id, and skip the lookup table entirely.
    local set_item_icon_method = nil
    local set_item_icon_resolved = false

    local function resolve_set_item_icon()
        if set_item_icon_resolved then
            return set_item_icon_method
        end
        set_item_icon_resolved = true
        local ext = sdk.find_type_definition("chainsaw.gui.GuiPlayObjectExtension")
        if ext == nil then
            info("slot icons: GuiPlayObjectExtension not found; slots keep the stand-in icon")
            return nil
        end
        -- Resolve by name, then by arity. REMethodDefinition exposes
        -- get_num_params(), NOT get_params() - guessing that cost merchant.lua
        -- a live round on 2026-08-17 and there is no reason to repeat it.
        pcall(function() set_item_icon_method = ext:get_method("setItemIcon") end)
        if set_item_icon_method == nil then
            pcall(function()
                for _, method in ipairs(ext:get_methods()) do
                    if method:get_name():find("setItemIcon", 1, true) == 1 then
                        local arity = nil
                        pcall(function() arity = method:get_num_params() end)
                        if arity == 2 then
                            set_item_icon_method = method
                            break
                        elseif arity == nil and set_item_icon_method == nil then
                            set_item_icon_method = method
                        end
                    end
                end
            end)
        end
        if set_item_icon_method == nil then
            info("slot icons: no 2-argument setItemIcon; slots keep the stand-in icon")
            return nil
        end
        info("slot icons: using " .. set_item_icon_method:get_name())
        return set_item_icon_method
    end

    local function ap_placeholder_item_id()
        local from_config = ctx.config and ctx.config.PLACEHOLDER_ITEM_ID
        if type(from_config) == "number" and from_config > 0 then
            return math.floor(from_config)
        end
        return 120486400
    end

    -- item id -> the check that slot is showing, plus whether the id is one
    -- of our bound slots at all. Derived on demand so a rotation is reflected
    -- the moment it happens.
    local function check_showing_on(item_id)
        for _, slot in ipairs(trade.slots) do
            if slot.item_id == item_id and slot.reward_id ~= nil then
                return trade.checks_by_reward_id[slot.reward_id], true
            end
        end
        return nil, false
    end

    -- Which check a DRAWN slot is showing.
    --
    -- The reward grid keeps TWO lists side by side -
    --
    --     _AppSelectItems  : List<RewardSelectItem>   the drawn widgets
    --     _CurrRewardItems : List<RewardItem>         the data rows
    --
    -- and identity lives on the DATA row, where `get_RewardId` is exactly the
    -- key the slots are bound by. The widget itself carries no usable ItemId
    -- on this tab (measured: reading it dressed nothing at all).
    --
    -- MEASURED 2026-09-01, the expensive way: pairing widget to row by the
    -- widget's `get_ListIndex` threw ArgumentOutOfRangeException FORTY
    -- THOUSAND times in one session. REFramework logs every internal
    -- exception even when Lua pcalls it, so the log went from 210 KB to
    -- 11.7 MB. ListIndex is not an index into this list, or not only that.
    --
    -- So every list read is bounds-checked now, and the pairing is positional
    -- (ListIndex is not an index into this list; measured 2026-09-01).
    local function row_at(reward_items, index, row_count)
        if reward_items == nil or index == nil then
            return nil
        end
        index = math.floor(index)
        -- The bounds check IS the fix. Calling get_Item out of range is not a
        -- nil, it is a thrown exception, and pcall hides it from Lua while the
        -- engine still pays for it and the log still records it.
        if index < 0 or index >= row_count then
            return nil
        end
        local row = nil
        pcall(function() row = reward_items:call("get_Item", index) end)
        return row
    end

    local function reward_id_of(row)
        if row == nil then
            return nil
        end
        local reward_id = nil
        pcall(function() reward_id = row:call("get_RewardId") end)
        reward_id = tonumber(reward_id)
        if reward_id == nil then
            return nil
        end
        return math.floor(reward_id)
    end

    -- The data row's own item id (RewardItem.get_ItemId). Read only for rows
    -- we do not own, to tell an exchange gem from Velvet Blue or the token.
    local function item_id_of(row)
        if row == nil then
            return nil
        end
        local item_id = nil
        pcall(function() item_id = row:call("get_ItemId") end)
        item_id = tonumber(item_id)
        if item_id == nil or item_id <= 0 then
            return nil
        end
        return math.floor(item_id)
    end

    local function check_for_widget(entry, reward_items, position, row_count)
        -- Positional: widget N shows data row N. The natural pairing for a
        -- grid that is not scrolled, and the one that cannot go out of range.
        local reward_id = reward_id_of(row_at(reward_items, position, row_count))
        if reward_id ~= nil then
            local check = trade.checks_by_reward_id[reward_id]
            if check ~= nil then
                return check, "row"
            end
            -- One of ours with nothing on it: a parked slot.
            if trade.slot_by_reward_id[reward_id] ~= nil then
                return nil, "empty"
            end
            -- A real reward id we do not own: a gem, Velvet Blue, the Gold
            -- Token. Not ours to re-label, but the row's own item id is
            -- handed back so the gem-icon pass below can act on it.
            return nil, "exchange", item_id_of(row_at(reward_items, position, row_count))
        end

        -- Fallback: the buy tab's route, for any path that does set ItemId.
        local entry_item_id = nil
        pcall(function() entry_item_id = entry:call("get_ItemId") end)
        entry_item_id = tonumber(entry_item_id)
        if entry_item_id == nil then
            return nil, "none"
        end
        local check, ours = check_showing_on(math.floor(entry_item_id))
        if check ~= nil then
            return check, "itemid"
        end
        return nil, ours and "empty" or "none"
    end

    -- Dress ONE drawn slot. This is the whole operation; the grid walk below
    -- is just a convenience for driving it in bulk.
    local gem_icon_reported = {}

    local function dress_select_item(entry, reward_items, position, row_count)
        if entry == nil or trade.slot_count == 0 then
            return false
        end
        local setter = resolve_set_item_icon()
        if setter == nil then
            return false
        end
        local check, kind, exchange_item_id = check_for_widget(entry, reward_items, position, row_count)

        -- THE EMERALD DIAGNOSTIC (2026-09-02). Red Beryl and Yellow Diamond
        -- draw their icons on this tab; the Emerald, same recipe and the same
        -- id the apworld mints (120832000), draws blank. The game draws the
        -- exchange rows itself, so this hands a gem row's own item id to the
        -- same setter the check tiles use, once per row, and logs it: if the
        -- Emerald appears, the game's own draw was the problem; if it stays
        -- blank with an "ok" here, the icon resource for that id is missing
        -- from the main-campaign table and the fork has to copy it.
        if check == nil and kind == "exchange" then
            local tex = nil
            pcall(function() tex = entry:get_field("_ItemIconTex") end)
            if exchange_item_id == nil or not (trade.gem_item_set or {})[exchange_item_id] then
                -- Velvet Blue, the Gold Token: not ours to draw. But the
                -- grid recycles its widgets, so if this one wore the logo a
                -- moment ago, give it back to the game (-70 left Velvet Blue
                -- squished exactly this way).
                local release = ctx.merchant_icon_release or _G.merchant_icon_release
                if type(release) == "function" then
                    pcall(release, entry, tex, exchange_item_id)
                end
                return false
            end
            if tex == nil then
                return false
            end
            local ok = pcall(function() setter:call(nil, tex, exchange_item_id) end)
            -- Gems are treasures: square art in a square cell, never drawn
            -- in the shop's wide box by vanilla (Cam, 2026-09-02: they read
            -- stretched at 226x150 next to the round logo). Square box, like
            -- the logo.
            local stamp = ctx.merchant_icon_stamp or _G.merchant_icon_stamp
            if type(stamp) == "function" then
                pcall(stamp, entry, tex, true)
            end
            if not gem_icon_reported[exchange_item_id] then
                gem_icon_reported[exchange_item_id] = true
                info(string.format("gem icon: item %d handed to %s: %s",
                    exchange_item_id, setter:get_name(), ok and "ok" or "threw"))
            end
            return ok
        end
        if check == nil and kind ~= "empty" then
            return false
        end

        -- A LOCAL check wears its real item. A REMOTE one has no RE4R item to
        -- borrow, so it takes the AP placeholder, which already carries the
        -- Archipelago logo art - an Archipelago item rather than a hole. A
        -- PARKED slot wears the placeholder too: it is still an Archipelago
        -- tile, just one with nothing in it yet, and the stand-in's own icon
        -- (blank, or a First Aid Spray) read as an item.
        local icon_item_id
        if check ~= nil and not check.remote and check.item_id_real > 0 then
            icon_item_id = check.item_id_real
        else
            icon_item_id = ap_placeholder_item_id()
        end
        if icon_item_id == nil or icon_item_id <= 0 then
            return false
        end

        local tex = nil
        pcall(function() tex = entry:get_field("_ItemIconTex") end)
        if tex == nil then
            return false
        end
        local ok = pcall(function() setter:call(nil, tex, icon_item_id) end)
        -- The logo is painted round in a cell the shop draws 1.5x wide; the
        -- merchant module squares the box for it and puts it back when the
        -- widget shows anything else (see icon_stamp / icon_release there).
        local stamp = ctx.merchant_icon_stamp or _G.merchant_icon_stamp
        if type(stamp) == "function" then
            -- Square for the logo and for treasure art (a local check
            -- holding a gem), wide for everything else - the merchant
            -- module owns the rule.
            local square = icon_item_id == ap_placeholder_item_id()
            local rule = ctx.merchant_wears_square_art or _G.merchant_wears_square_art
            if not square and type(rule) == "function" then
                local ok_rule, verdict = pcall(rule, icon_item_id)
                square = ok_rule and verdict == true
            end
            pcall(stamp, entry, tex, square)
        end
        return ok
    end

    -- How many widgets the grid is actually drawing.
    --
    -- MEASURED 2026-09-01: reading `_AppSelectItems` and asking the List for
    -- get_Count answered 0, while `_CurrRewardItems` on the same object
    -- answered 11 correctly. So the widget list is not readable the way the
    -- data list is - and `tonumber(count) or 0` quietly turned that failed
    -- read into "nothing to draw", which is the same silent-zero that hid the
    -- reward-dictionary bug.
    --
    -- The grid publishes its own count, `get__AppSelectItemsCount`, so ask
    -- that first and treat a failed read as UNKNOWN rather than as zero.
    local function widget_count(grid, entries)
        local count = nil
        pcall(function() count = grid:call("get__AppSelectItemsCount") end)
        count = tonumber(count)
        if count ~= nil and count > 0 then
            return count, "accessor"
        end
        local listed = nil
        if entries ~= nil then
            pcall(function() listed = entries:call("get_Count") end)
            listed = tonumber(listed)
        end
        if listed ~= nil and listed > 0 then
            return listed, "list"
        end
        -- Both said nothing. Report which kind of nothing it was.
        if count == nil and listed == nil then
            return 0, "unreadable"
        end
        return 0, "empty"
    end

    local function dress_slot_icons(grid)
        if grid == nil or trade.slot_count == 0 then
            return
        end
        local entries = nil
        pcall(function() entries = grid:get_field("_AppSelectItems") end)
        -- The data rows and their count, read once per walk. The count is not
        -- optional bookkeeping: it is what keeps get_Item from throwing, and
        -- an out-of-range get_Item costs an engine exception every frame.
        local reward_items = nil
        pcall(function() reward_items = grid:get_field("_CurrRewardItems") end)
        local row_count = 0
        if reward_items ~= nil then
            local n = nil
            pcall(function() n = reward_items:call("get_Count") end)
            row_count = tonumber(n) or 0
        end
        local count, source = widget_count(grid, entries)
        -- No early return on row_count == 0: the ItemId fallback is the
        -- only route left if the data list ever goes unreadable, and
        -- row_at refuses safely at zero anyway.
        if entries == nil or count == 0 then
            return
        end
        for index = 0, count - 1 do
            pcall(function()
                dress_select_item(entries:call("get_Item", index), reward_items,
                    index, row_count)
            end)
        end
    end

    -- Find the grid, then dress it while the tab is being used.
    --
    -- Two constraints, both learned the hard way today.
    --
    -- PERFORMANCE. The first working version hooked
    -- `PurchaseSelectItem.onLateUpdate`, which is correct and runs PER WIDGET
    -- PER FRAME, each call a trampoline out of the engine into Lua. Dozens of
    -- pooled shop widgets are alive whether or not the shop is on screen, and
    -- the game dropped to ~5 fps. merchant.lua's hook looks like the same
    -- thing and is not: `PurchaseItemListGui.onLateUpdate` is ONE object.
    -- So nothing hot is hooked here. Only the grid's own cold events.
    --
    -- TIMING. The widgets do not exist yet when `updateSlots` fires. The
    -- survey said so in as many words:
    --
    --     survey - 0 drawn widget(s) via empty, 11 data row(s), list=true
    --
    -- The data rows were all there; the widget list was genuinely empty. So a
    -- one-shot dress at populate time can never work, and something has to
    -- look again a moment later.
    --
    -- That retry used to be gated on `bridge.shop_gui_open`, borrowed from
    -- merchant.lua - and that flag is set by `InGameShopGuiState_Enter`, a
    -- BUY-tab state the trade tab does not pass through. It was false the
    -- whole time the tab was open, so the retry never ran once. Borrowing a
    -- neighbour's signal without checking what sets it is the same mistake as
    -- borrowing its API without checking what populates it.
    --
    -- The gate is now the grid's own activity: any of its cold events opens a
    -- bounded window of frames during which the pump re-dresses, and `clear`
    -- shuts it. The window self-limits, so a missed close cannot leak work.
    local ICON_ACTIVE_FRAMES = 1800

    local icon_hook_installed = false
    local reward_grid = nil
    local icon_frames_left = 0

    local function note_grid_activity(args)
        local ok, grid = pcall(function()
            return sdk.to_managed_object(args[2])
        end)
        if not ok or grid == nil then
            return
        end
        if reward_grid == nil then
            info("slot icons: trade grid found")
        end
        reward_grid = grid
        icon_frames_left = ICON_ACTIVE_FRAMES
        pcall(dress_slot_icons, grid)
    end

    local function install_slot_icon_hook()
        if icon_hook_installed then
            return
        end
        local grid_type = sdk.find_type_definition(
            "chainsaw.gui.shop.RewardRootGui.RewardScrollGrid")
        if grid_type == nil then
            info("slot icons: RewardScrollGrid not found; slots keep the stand-in icon")
            return
        end

        -- Measured from the dump, not guessed: this grid has exactly these
        -- update-ish methods and no per-frame one. Each is cold - populate,
        -- cursor move, scroll - and each is a moment the tab redraws.
        local watched = {}
        for _, name in ipairs({ "updateSlots", "select", "updateScrollLoopSetting" }) do
            local method = grid_type:get_method(name)
            if method ~= nil then
                sdk.hook(method, note_grid_activity, nil)
                watched[#watched + 1] = name
            end
        end
        if #watched == 0 then
            info("slot icons: RewardScrollGrid has none of the expected events; "
                .. "slots keep the stand-in icon")
            return
        end
        icon_hook_installed = true

        -- Closing the tab ends the window immediately; the frame budget is
        -- only the backstop for a close we do not see.
        local close_method = grid_type:get_method("clear")
        if close_method ~= nil then
            sdk.hook(close_method, function()
                icon_frames_left = 0
            end, nil)
        end

        info("slot icons: watching RewardScrollGrid." .. table.concat(watched, ", "))
    end

    -- Re-applied while the tab is in use, because the GUI stamps its own icon
    -- back whenever it redraws, and because the widgets arrive after the
    -- populate event. Outside that window this is two comparisons a frame.
    local pump_announced = false

    per_frame_icons = function()
        if reward_grid == nil or icon_frames_left <= 0 or trade.slot_count == 0 then
            return
        end
        icon_frames_left = icon_frames_left - 1
        if not pump_announced then
            pump_announced = true
            -- -63 could not say whether this path ever ran. It had not, once.
            info("slot icons: per-frame dressing is live")
        end
        pcall(dress_slot_icons, reward_grid)
    end

    -- ---------------------------------------------------------------- public
    local function trade_configure(payload)
        load_trade(payload)
        if trade.slot_count > 0 then
            enqueue("bind reward ids", function()
                trade.bind_attempts = trade.bind_attempts + 1
                local ok, detail = bind_reward_ids()
                trade.bound_ok = ok
                info(detail)
                if not ok then
                    -- Not fatal any more: the poll keeps trying. On a new game
                    -- this is simply the shop not being up yet at connect.
                    info("slot binding incomplete - will retry as the shop comes up")
                end
                reconcile_slots()
            end)
            enqueue("install slot icon hook", install_slot_icon_hook)
        end
    end

    local function trade_is_trade_location(location_code)
        local code = tonumber(location_code)
        if code == nil then
            return false
        end
        return trade.checks_by_location[math.floor(code)] ~= nil
    end

    -- [The Checklist] Plain rows for the Insert window, the trade twin of
    -- merchant_checklist_rows: chapter, name, bought, released.
    local checklist_cache = { at = -1, rows = {} }
    local function trade_checklist_rows()
        local now = (os ~= nil and type(os.clock) == "function") and os.clock() or 0
        if now - checklist_cache.at < 0.5 then
            return checklist_cache.rows
        end
        local mgr = shop_manager()
        local open = {}
        for chapter = 1, 16 do
            open[chapter] = chapter_is_open(mgr, chapter)
        end
        local rows = {}
        for _, check in ipairs(trade.checks) do
            rows[#rows + 1] = {
                location_code = check.location_code,
                chapter = check.chapter,
                name = check.display_name,
                player = check.player_name,
                remote = check.remote,
                classification = check.tier,
                price_spinel = check.price_spinel,
                checked = check_is_checked(check),
                released = open[check.chapter] == true,
            }
        end
        checklist_cache.at = now
        checklist_cache.rows = rows
        return rows
    end
    ctx.trade_checklist_rows = trade_checklist_rows

    ctx.trade_configure = trade_configure
    ctx.trade_is_trade_location = trade_is_trade_location
    ctx.trade_poll_claims = poll_claims
    ctx.trade_reconcile_slots = reconcile_slots
    ctx.trade_poll_chapter_waypoint = poll_chapter_waypoint
    -- Exposed by name for the same reason merchant.lua exposes its
    -- purchase path: the hook is only the trigger, so the dressing can be
    -- driven from an offline harness without faking a GUI frame.
    ctx.trade_dress_slot_icons = dress_slot_icons
    ctx.trade_bind_reward_ids = bind_reward_ids
    ctx.trade_enqueue = enqueue
    -- For merchant.lua's model swap hook and AP model placement: which check
    -- a trade stand-in is showing, and whether the id is ours at all.
    ctx.trade_check_showing_on = check_showing_on
    _G.trade_check_showing_on = check_showing_on
    _G.trade_configure = trade_configure
end
