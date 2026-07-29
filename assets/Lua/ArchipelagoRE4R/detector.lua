local function install(ctx)
    ctx.detector = ctx.detector or {}
    local bridge = ctx.bridge

    local function export(name, value)
        ctx.detector[name] = value
        ctx[name] = value
        _G[name] = value
    end

    local function current_unix_ms()
        local now_fn = ctx.now_unix_ms or _G.now_unix_ms
        if type(now_fn) == "function" then
            return now_fn()
        end
        return os.time() * 1000
    end

    local recent_pickup_accept_probes = {}
    -- Intercepted placeholder drops waiting to be destroyed OUTSIDE the accept
    -- hook (destroying the GameObject from inside its own method call is not
    -- safe); drained by pump_placeholder_despawns on the frame callback.
    local placeholder_despawn_queue = {}

    local function record_pickup_probe(event_name, stage, context_key, guid, item_id, item_count, tracked, pending, acknowledged)
        local normalized_stage = tonumber(stage)
        if normalized_stage == nil then
            return
        end

        bridge.pickup_probe = {
            event_name = trim_string(event_name),
            stage = math.floor(normalized_stage),
            context_key = trim_string(context_key),
            guid = normalize_guid(guid),
            item_id = tonumber(item_id),
            item_count = math.max(1, math.floor(tonumber(item_count) or 1)),
            tracked = tracked == true,
            pending = pending == true,
            acknowledged = acknowledged == true,
            recorded_at_unix_ms = current_unix_ms(),
        }
    end

    -- Unified pickup toast (Cam 2026-07-13). This is the SINGLE source of truth for a check you
    -- personally collect. It headlines the item that ACTUALLY sits here - never the vanilla name
    -- the location is titled after - so picking up shotgun shells at the green-herb spot says
    -- "Collected Shotgun Shells", not "Green Herb". The matching self-find "Received" toast and the
    -- outbound "Sent" PrintJSON toast are suppressed in apclient.lua to avoid double-toasting.
    local function enqueue_check_notification(guid, stage)
        local display_entry = get_location_display_entry(stage, guid) or {}
        local loc_id = tonumber(display_entry.location_id)
        local key = (loc_id ~= nil) and tostring(math.floor(loc_id)) or nil

        -- The vanilla item this location is named after - shown as the "was ..." origin.
        local vanilla_name = trim_string(display_entry.item_name):gsub("%s+[xX]%d+$", "")

        -- The item that ACTUALLY sits here + who owns it, from the LocationScouts data apclient
        -- stored on the bridge. Resolvers are looked up at call time (apclient loads after us).
        local actual_name, owner
        if key ~= nil then
            if type(bridge.location_scout_player) == "table" then
                owner = tonumber(bridge.location_scout_player[key])
            end
            if type(bridge.location_scout_item) == "table" then
                local item_id = tonumber(bridge.location_scout_item[key])
                local resolve_item = ctx.ap_item_name or _G.ap_item_name
                if item_id ~= nil and type(resolve_item) == "function" then
                    actual_name = trim_string(resolve_item(item_id, owner))
                end
            end
        end

        -- Colour by the ACTUAL item's scout classification, not the vanilla one.
        local classification = trim_string(display_entry.classification)
        if key ~= nil and type(bridge.location_classifications) == "table" then
            local scls = trim_string(bridge.location_classifications[key])
            if scls ~= "" then classification = scls end
        end

        local me = tonumber(bridge.ap_numeric_slot)
        local toast_title, detail_line, toast_kind, toast_title_segments
        -- The own-pickup Option-C line ("Collected X from Y in Z", Cam 2026-07-29)
        -- can run long, so it gets a wider title budget than the 52-char default.
        -- The overlay card width is dynamic and the Message Log wraps, so a longer
        -- title just grows to fit rather than clipping.
        local title_max_chars = 52
        local own_pickup_single_line = false
        -- Native-rail routing (native_log.lua): "suppress" = the game's own
        -- organic pickup toast already shows this item, so in native mode the
        -- imgui duplicate is simply skipped; "text" = push a composed line.
        local toast_native_route = "text"
        if actual_name ~= nil and actual_name ~= "" then
            if owner ~= nil and me ~= nil and owner ~= me then
                -- Another player's item: collecting it SENT it to them (this replaces the old
                -- PrintJSON "Sent" toast, now suppressed).
                local resolve = ctx.ap_player_name or _G.ap_player_name
                local who = (type(resolve) == "function" and resolve(owner)) or ("Player " .. tostring(owner))
                toast_kind = "sent"
                -- Colour-code the entities: the ITEM keeps its classification colour,
                -- the PLAYER gets the dedicated player colour, connectives stay white.
                -- entity tags let the native rail re-colour white (filler) items to
                -- its parchment tint without touching the imgui palette.
                -- (title above stays plain text for the Message Log / compares.)
                if bridge.ap_status_kind == "connected" then
                    toast_title = "You sent " .. actual_name .. " to " .. who
                    toast_title_segments = {
                        { text = "You sent", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                        { text = truncate_overlay_text(actual_name, 32),
                          color = get_check_overlay_classification_color(classification), entity = "item" },
                        { text = "to", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                        { text = truncate_overlay_text(who, 18),
                          color = CHECK_OVERLAY_TEXT_COLOR_PLAYER, entity = "player" },
                    }
                else
                    -- Disconnected: nothing was SENT yet - the check queues until
                    -- reconnect, so "You sent" would be a lie (Cam 2026-07-23).
                    toast_title = "Collected " .. who .. "'s " .. actual_name
                    detail_line = "queued offline"
                    toast_title_segments = {
                        { text = "Collected", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                        { text = truncate_overlay_text(who, 18) .. "'s",
                          color = CHECK_OVERLAY_TEXT_COLOR_PLAYER, entity = "player" },
                        { text = truncate_overlay_text(actual_name, 32),
                          color = get_check_overlay_classification_color(classification), entity = "item" },
                    }
                end
            else
                -- Option C (Cam 2026-07-29): one line -- "Collected <actual> from
                -- <vanilla origin> in <area>". The vanilla name is the location's
                -- find-hint identity; the section is the pause-map area. Both are
                -- secondary context (dim white) and fall away when unavailable.
                -- A trailing " x1" is dropped so singletons read clean; real stack
                -- counts (x5, x10) stay.
                local actual_display = actual_name:gsub("%s+[xX]1$", "")
                local actual_base = actual_name:gsub("%s+[xX]%d+$", "")
                local section_name = trim_string(display_entry.section_name)
                toast_kind = "received"
                toast_native_route = "suppress" -- organic native pickup toast covers it
                own_pickup_single_line = true
                title_max_chars = 78
                toast_title = "Collected " .. actual_display
                toast_title_segments = {
                    { text = "Collected", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                    { text = truncate_overlay_text(actual_display, 30),
                      color = get_check_overlay_classification_color(classification), entity = "item" },
                }
                -- Skip the origin clause when the item you got IS what vanilla had
                -- here ("Collected Green Herb from Green Herb" reads silly).
                if vanilla_name ~= "" and vanilla_name:lower() ~= actual_base:lower() then
                    toast_title = toast_title .. " from " .. vanilla_name
                    toast_title_segments[#toast_title_segments + 1] =
                        { text = "from", color = CHECK_OVERLAY_TEXT_COLOR_FILLER }
                    toast_title_segments[#toast_title_segments + 1] =
                        { text = truncate_overlay_text(vanilla_name, 24), color = CHECK_OVERLAY_TEXT_COLOR_DETAIL }
                end
                if section_name ~= "" then
                    toast_title = toast_title .. " in " .. section_name
                    toast_title_segments[#toast_title_segments + 1] =
                        { text = "in", color = CHECK_OVERLAY_TEXT_COLOR_FILLER }
                    toast_title_segments[#toast_title_segments + 1] =
                        { text = truncate_overlay_text(section_name, 24), color = CHECK_OVERLAY_TEXT_COLOR_DETAIL }
                end
            end
            -- Other-player (sent) toasts still carry the vanilla origin in the
            -- detail line; the own-pickup line already folds it into the title.
            if vanilla_name ~= "" and detail_line == nil and not own_pickup_single_line then
                detail_line = "was " .. vanilla_name
            end
        else
            -- Scout data unavailable (e.g. a gated-keys room whose set we could not scout): fall
            -- back to acknowledging the check by its vanilla name + the remaining count for the
            -- location's pause-map section (stage-scoped "nearby" only when no section resolves).
            local remaining_label
            local section_name = trim_string(display_entry.section_name)
            if section_name ~= "" then
                local section_checked, section_total = get_section_progress(section_name)
                remaining_label = build_nearby_remaining_label(section_total - section_checked, section_name)
            else
                local _, _, remaining_count = get_stage_progress(stage)
                remaining_label = build_nearby_remaining_label(remaining_count)
            end
            toast_kind = "received"
            -- Verb + no duplicated name: the old shape repeated the vanilla name
            -- in title AND detail ("Green Herb x1 - Green Herb - 3 left...").
            local base = trim_string(display_entry.toast_title)
            if base == "" then
                base = vanilla_name
            end
            toast_title = (base ~= "") and ("Checked " .. base) or "Location Checked"
            detail_line = remaining_label
        end

        table.insert(bridge.check_notifications, {
            id = bridge.next_check_notification_id,
            stage = stage,
            guid = normalize_guid(guid),
            title = truncate_overlay_text(toast_title, title_max_chars),
            detail = truncate_overlay_text(detail_line, 74),
            classification = classification,
            kind = toast_kind, -- received (own pickup) or sent (another player's item)
            title_segments = toast_title_segments, -- per-entity colours; nil = plain title
            native_route = toast_native_route,
            queued_at_unix_ms = current_unix_ms(),
            display_started_at_unix_ms = nil,
        })
        bridge.next_check_notification_id = bridge.next_check_notification_id + 1
    end

    local function enqueue_probe_notification(stage, guid, title, detail, classification, title_segments)
        if type(stage) ~= "number" then
            return
        end

        table.insert(bridge.check_notifications, {
            id = bridge.next_check_notification_id,
            stage = stage,
            guid = normalize_guid(guid),
            title = truncate_overlay_text(title, 52),
            detail = truncate_overlay_text(detail, 74),
            classification = trim_string(classification),
            title_segments = title_segments, -- per-entity colours; nil = plain title
            native_route = "text",
            queued_at_unix_ms = current_unix_ms(),
            display_started_at_unix_ms = nil,
        })
        bridge.next_check_notification_id = bridge.next_check_notification_id + 1
    end

    local function enqueue_already_checked_notification(guid, stage)
        local display_entry = get_location_display_entry(stage, guid) or {}
        local item_name = trim_string(display_entry.item_name)
        local classification = trim_string(display_entry.classification)
        -- Short on purpose: the old "- Already sent to AP server" suffix pushed
        -- the native rail's narrow panel into auto-shrink (squished text, Cam
        -- 2026-07-23). "Already Checked" already says it; the item is the news.
        local title = "Already Checked"
        local title_segments = nil
        if item_name ~= "" then
            title = string.format("Already Checked - %s", item_name)
            title_segments = {
                { text = "Already Checked -", color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                { text = truncate_overlay_text(item_name, 32),
                  color = get_check_overlay_classification_color(classification), entity = "item" },
            }
        end

        enqueue_probe_notification(stage, guid, title, nil, classification, title_segments)
    end

    local function copy_guid_sample(values, maximum)
        local result = {}
        local count = 0
        maximum = maximum or 6
        for guid, _ in pairs(values or {}) do
            count = count + 1
            if count > maximum then
                break
            end
            table.insert(result, guid)
        end
        table.sort(result)
        return result
    end

    local function decode_low32_from_hook_arg(raw_arg)
        local ok_int64, int64_value = pcall(function()
            return sdk.to_int64(raw_arg)
        end)
        if not ok_int64 or type(int64_value) ~= "number" then
            return nil
        end

        local low32 = int64_value % 4294967296
        if low32 < 0 then
            low32 = low32 + 4294967296
        end
        return math.floor(low32 + 0.5)
    end

    local function get_context_id_key(raw_context_arg)
        local managed_context = nil
        local ok_context, context = pcall(function()
            return sdk.to_managed_object(raw_context_arg)
        end)
        if ok_context then
            managed_context = context
        end
        if managed_context ~= nil then
            local context_key = trim_string(safe_call(managed_context, "ToString()"))
            if context_key ~= "" then
                return context_key
            end
        end

        local low32 = decode_low32_from_hook_arg(raw_context_arg)
        if type(low32) == "number" then
            return string.format("%08X", low32)
        end

        return nil
    end

    local function find_drop_item_by_context(raw_context_arg)
        if raw_context_arg == nil then
            return nil
        end

        local drop_item_manager = sdk.get_managed_singleton("chainsaw.DropItemManager")
        if drop_item_manager == nil then
            return nil
        end

        local drop_item = safe_call(drop_item_manager, "findDropItem", raw_context_arg)
        if drop_item == nil then
            drop_item = safe_call(drop_item_manager, "findDropItem(chainsaw.ContextID)", raw_context_arg)
        end
        return drop_item
    end

    local function resolve_drop_item_guid_from_context(raw_context_arg)
        local drop_item = find_drop_item_by_context(raw_context_arg)
        if drop_item == nil then
            return nil
        end

        local ok_game_object, game_object = pcall(function()
            return drop_item:get_GameObject()
        end)
        if not ok_game_object or game_object == nil then
            return nil
        end

        return get_game_object_guid(game_object)
    end

    local function clear_pending_pickup_accepts(reason)
        local removed_count = #bridge.pending_pickup_accepts
        bridge.pending_pickup_accepts = {}
        bridge.next_pending_pickup_accept_id = 1
        recent_pickup_accept_probes = {}
        if removed_count > 0 and type(reason) == "string" and reason ~= "" then
            log.info(string.format("[RE4R AP] Cleared %d pending pickup accept(s): %s", removed_count, reason))
        end
    end

    local function prune_pending_pickup_accepts(current_stage)
        local now_ms = current_unix_ms()
        local kept = {}
        for _, entry in ipairs(bridge.pending_pickup_accepts) do
            local age_ms = now_ms - (tonumber(entry.queued_at_unix_ms) or 0)
            local stage_matches = type(current_stage) ~= "number" or entry.stage == current_stage
            -- This list only ever holds TRACKED accepts (enqueue requires the
            -- GUID to be an AP check), so they get the long window that
            -- survives the weapon-acquisition screen.
            if age_ms <= PENDING_TRACKED_ACCEPT_WINDOW_MS and stage_matches then
                table.insert(kept, entry)
            end
        end
        bridge.pending_pickup_accepts = kept
    end

    local function prune_recent_pickup_accept_probes(current_stage)
        local now_ms = current_unix_ms()
        local kept = {}
        for _, entry in ipairs(recent_pickup_accept_probes) do
            local age_ms = now_ms - (tonumber(entry.queued_at_unix_ms) or 0)
            local stage_matches = type(current_stage) ~= "number" or entry.stage == current_stage
            if age_ms <= PENDING_PICKUP_ACCEPT_WINDOW_MS and stage_matches then
                table.insert(kept, entry)
            end
        end
        recent_pickup_accept_probes = kept
    end

    local function enqueue_recent_pickup_accept_probe(stage, context_key, guid, tracked, pending, acknowledged)
        local normalized_guid = normalize_guid(guid)
        local normalized_context_key = trim_string(context_key)
        if normalized_guid == nil or normalized_context_key == "" or type(stage) ~= "number" then
            return false
        end

        prune_recent_pickup_accept_probes(stage)
        local now_ms = current_unix_ms()
        for _, entry in ipairs(recent_pickup_accept_probes) do
            if entry.stage == stage and (entry.context_key == normalized_context_key or entry.guid == normalized_guid) then
                entry.guid = normalized_guid
                entry.context_key = normalized_context_key
                entry.tracked = tracked == true
                entry.pending = pending == true
                entry.acknowledged = acknowledged == true
                entry.queued_at_unix_ms = now_ms
                return true
            end
        end

        table.insert(recent_pickup_accept_probes, {
            stage = stage,
            guid = normalized_guid,
            context_key = normalized_context_key,
            tracked = tracked == true,
            pending = pending == true,
            acknowledged = acknowledged == true,
            queued_at_unix_ms = now_ms,
        })
        return true
    end

    local function pop_recent_pickup_accept_probe(stage)
        if type(stage) ~= "number" then
            return nil
        end

        prune_recent_pickup_accept_probes(stage)
        local newest_index = nil
        local newest_timestamp = nil
        for index, entry in ipairs(recent_pickup_accept_probes) do
            if entry.stage == stage then
                local queued_at = tonumber(entry.queued_at_unix_ms) or 0
                if newest_index == nil or queued_at >= newest_timestamp then
                    newest_index = index
                    newest_timestamp = queued_at
                end
            end
        end

        if newest_index ~= nil then
            local entry = recent_pickup_accept_probes[newest_index]
            table.remove(recent_pickup_accept_probes, newest_index)
            return entry
        end
        return nil
    end

    local function is_guid_pending(stage, guid)
        local key = make_stage_guid_key(stage, guid)
        return key ~= nil and bridge.pending_check_keys[key] == true
    end

    local function enqueue_pending_pickup_accept(raw_context_arg, guid, stage)
        local normalized_guid = normalize_guid(guid)
        local context_key = get_context_id_key(raw_context_arg)
        if normalized_guid == nil or context_key == nil or type(stage) ~= "number" then
            return false
        end
        if not is_stage_guid_tracked(stage, normalized_guid) then
            return false
        end

        local key = make_stage_guid_key(stage, normalized_guid)
        if key == nil or bridge.pending_check_keys[key] or is_guid_acknowledged(stage, normalized_guid) then
            return false
        end

        prune_pending_pickup_accepts(stage)
        local now_ms = current_unix_ms()
        for _, entry in ipairs(bridge.pending_pickup_accepts) do
            if entry.stage == stage and (entry.context_key == context_key or entry.guid == normalized_guid) then
                entry.guid = normalized_guid
                entry.context_key = context_key
                entry.queued_at_unix_ms = now_ms
                return true
            end
        end

        table.insert(bridge.pending_pickup_accepts, {
            id = bridge.next_pending_pickup_accept_id,
            stage = stage,
            guid = normalized_guid,
            context_key = context_key,
            queued_at_unix_ms = now_ms,
        })
        bridge.next_pending_pickup_accept_id = bridge.next_pending_pickup_accept_id + 1
        return true
    end

    local function pop_matching_pending_pickup_accept(stage)
        if type(stage) ~= "number" then
            return nil
        end

        prune_pending_pickup_accepts(stage)
        for index, entry in ipairs(bridge.pending_pickup_accepts) do
            if entry.stage == stage then
                table.remove(bridge.pending_pickup_accepts, index)
                return entry
            end
        end
        return nil
    end

    local function queue_pending_check(guid, stage)
        local normalized_guid = normalize_guid(guid)
        if normalized_guid == nil or type(stage) ~= "number" then
            return
        end

        local key = make_stage_guid_key(stage, normalized_guid)
        if key == nil or bridge.pending_check_keys[key] or is_guid_acknowledged(stage, normalized_guid) then
            return
        end

        -- [Phase 3] Resolve the AP location_id in-process (the display map already
        -- carries it) and attach it so the in-Lua apclient can submit this check via
        -- ap:LocationChecks. The file-bridge fields below stay for now (dormant;
        -- Phase 5 removes them).
        local display_entry = get_location_display_entry(stage, normalized_guid)
        local location_id = display_entry and tonumber(display_entry.location_id)

        bridge.pending_check_keys[key] = true
        table.insert(bridge.pending_checks, {
            id = bridge.next_pending_check_id,
            guid = normalized_guid,
            stage = stage,
            key = key,
            location_id = location_id,
            queued_at_unix_ms = current_unix_ms(),
        })
        bridge.next_pending_check_id = bridge.next_pending_check_id + 1
        bridge.state_dirty = true
        if location_id == nil then
            log.warn(string.format(
                "[RE4R AP] pending check has no AP location_id (stage=%s guid=%s); cannot submit to server",
                tostring(stage), tostring(normalized_guid)))
        end
        enqueue_check_notification(normalized_guid, stage)
    end

    -- Primary pickup detection intentionally pairs a world-side accept signal with an
    -- inventory-side commit signal. The old setItemGetFlag/candidate heuristic flow
    -- produced false positives on ambiguous item types, so it has been removed from
    -- primary detection. Stage scans and holder-hit tracking remain in place as
    -- future fallback building blocks if non-DropItem pickup classes surface later.
    local function read_drop_item_item_id(drop_item)
        local ok, item_data = pcall(function()
            return drop_item:get_field("_ItemData")
        end)
        if not ok or item_data == nil then
            return nil
        end
        local ok_id, item_id = pcall(function()
            return item_data:get_field("ItemID")
        end)
        if not ok_id then
            return nil
        end
        return tonumber(item_id)
    end

    -- The serialized scn shape (_ItemData.ItemID) is not guaranteed to be the
    -- runtime carrier; try the plausible runtime homes in order and take the
    -- first numeric answer.
    local function read_drop_item_item_id_any(drop_item)
        if drop_item == nil then
            return nil
        end

        local direct = read_drop_item_item_id(drop_item)
        if direct ~= nil then
            return direct
        end

        local holder_reads = {
            function() return drop_item:call("get_CurrentItemData") end,
            function() return drop_item:call("get_ItemData") end,
            function() return drop_item:get_field("SaveData") end,
            function() return drop_item:get_field("_SaveData") end,
        }
        for _, read_holder in ipairs(holder_reads) do
            local ok_holder, holder = pcall(read_holder)
            if ok_holder and holder ~= nil then
                for _, field in ipairs({ "ItemID", "_ItemID" }) do
                    local ok_id, item_id = pcall(function()
                        return holder:get_field(field)
                    end)
                    if ok_id then
                        local numeric = tonumber(item_id)
                        if numeric ~= nil then
                            return numeric
                        end
                    end
                end
            end
        end

        local ok_id, item_id = pcall(function()
            return drop_item:call("get_ItemID")
        end)
        if ok_id then
            return tonumber(item_id)
        end
        return nil
    end

    local function queue_placeholder_despawn(drop_item)
        table.insert(placeholder_despawn_queue, drop_item)
    end

    local function pump_placeholder_despawns()
        if #placeholder_despawn_queue == 0 then
            return
        end
        local queue = placeholder_despawn_queue
        placeholder_despawn_queue = {}
        for _, drop_item in ipairs(queue) do
            local ok, err = pcall(function()
                local game_object = drop_item:call("get_GameObject")
                if game_object ~= nil then
                    game_object:call("destroy", game_object)
                end
            end)
            log.info(string.format(
                "[RE4R AP] placeholder despawn %s",
                ok and "ok" or ("FAILED: " .. tostring(err))
            ))
        end
    end

    local function install_pickup_accept_hook()
        local drop_item_type = sdk.find_type_definition("chainsaw.DropItem")
        if drop_item_type == nil then
            log.info("[RE4R AP] DropItem type not found for pickup accept hook")
            return
        end

        local accept_method = drop_item_type:get_method("onAcceptPickup")
        if accept_method == nil then
            log.info("[RE4R AP] DropItem.onAcceptPickup not found for pickup accept hook")
            return
        end

        sdk.hook(
            accept_method,
            function(args)
                local runtime_state = get_runtime_state()
                local stage = get_active_runtime_stage(runtime_state)
                if not runtime_state.is_playable or type(stage) ~= "number" then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end

                local context_arg = args[3]
                local context_key = get_context_id_key(context_arg)
                local guid = resolve_drop_item_guid_from_context(context_arg)
                -- [Stage canonicalization] The drop's DATASET stage wins over the
                -- player's current stage volume: sub-stage boundaries overlap in
                -- the world (live miss 2026-07-23, Abandoned Factory: drops filed
                -- under 44210 grabbed while the runtime reported 44200 ->
                -- "not_in_dataset", checks lost, a placeholder entered the case).
                if guid ~= nil then
                    local dataset_stage = resolve_tracked_stage(guid)
                    if dataset_stage ~= nil then
                        stage = dataset_stage
                    end
                end
                local tracked = guid ~= nil and is_stage_guid_tracked(stage, guid)
                local pending = guid ~= nil and is_guid_pending(stage, guid)
                local acknowledged = guid ~= nil and is_guid_acknowledged(stage, guid)
                if guid ~= nil then
                    enqueue_recent_pickup_accept_probe(stage, context_key, guid, tracked, pending, acknowledged)
                    record_pickup_probe(
                        "accept",
                        stage,
                        context_key,
                        guid,
                        nil,
                        1,
                        tracked,
                        pending,
                        acknowledged
                    )
                end

                -- Placeholder interception: another player's item is physically
                -- the placeholder (SW - Glasses). Send the check here, despawn
                -- the drop next frame, and skip the engine's pickup entirely -
                -- the item never enters the case, so foreign checks leave no
                -- clutter and no pickup UI.
                if PLACEHOLDER_INTERCEPT and tracked and guid ~= nil then
                    -- Resolve the DropItem the SAME way the guid was resolved
                    -- (manager lookup by context). args[2] is NOT reliably the
                    -- DropItem: reading _ItemData off it returned nil in live
                    -- fire (2026-07-22) and the intercept silently never ran.
                    local drop_item = find_drop_item_by_context(context_arg)
                    local item_id = read_drop_item_item_id_any(drop_item)
                    if item_id == nil then
                        local drop_type = "<nil drop_item>"
                        pcall(function()
                            drop_type = drop_item:get_type_definition():get_full_name()
                        end)
                        log.info(string.format(
                            "[RE4R AP] placeholder intercept CANNOT READ ITEM ID stage=%s guid=%s context=%s drop_type=%s - falling back to normal pickup",
                            tostring(stage),
                            tostring(guid),
                            tostring(context_key),
                            tostring(drop_type)
                        ))
                    end
                    if item_id == PLACEHOLDER_ITEM_ID then
                        if acknowledged then
                            enqueue_already_checked_notification(guid, stage)
                        elseif not pending then
                            queue_pending_check(guid, stage)
                        end
                        -- Run the engine's own collected bookkeeping before the
                        -- despawn. SKIP_ORIGINAL means the vanilla accept path
                        -- never records the pickup, so the drop respawned on
                        -- every reload and its map icon never cleared (Cam
                        -- 2026-07-29). onFirstGetAndPickedUp (0 params, found
                        -- via the flag probe) is the drop's own first-get +
                        -- picked-up state write.
                        local ok_got, got_err = pcall(function()
                            drop_item:call("onFirstGetAndPickedUp")
                        end)
                        log.info(string.format(
                            "[RE4R AP] placeholder onFirstGetAndPickedUp %s%s",
                            ok_got and "ok" or "FAILED",
                            ok_got and "" or (": " .. tostring(got_err))
                        ))
                        queue_placeholder_despawn(drop_item)
                        log.info(string.format(
                            "[RE4R AP] placeholder intercept stage=%s guid=%s context=%s (check %s) - drop despawns, inventory untouched",
                            tostring(stage),
                            tostring(guid),
                            tostring(context_key),
                            acknowledged and "already sent" or (pending and "already queued" or "queued")
                        ))
                        return sdk.PreHookResult.SKIP_ORIGINAL
                    end
                end

                if get_stage_watch_entry(stage) == nil then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end

                if guid ~= nil and enqueue_pending_pickup_accept(context_arg, guid, stage) then
                    log.info(
                        string.format(
                            "[RE4R AP] pickup_accept stage=%s guid=%s context=%s",
                            tostring(stage),
                            tostring(guid),
                            tostring(context_key)
                        )
                    )
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                return retval
            end
        )
    end

    local function install_pickup_commit_hook()
        local controllers_type = sdk.find_type_definition("chainsaw.InventoryControllersInfo")
        if controllers_type == nil then
            log.info("[RE4R AP] InventoryControllersInfo type not found for pickup commit hook")
            return
        end

        local pickup_method = controllers_type:get_method("onPickupedItemBase")
        if pickup_method == nil then
            log.info("[RE4R AP] InventoryControllersInfo.onPickupedItemBase not found for pickup commit hook")
            return
        end

        sdk.hook(
            pickup_method,
            function(args)
                local runtime_state = get_runtime_state()
                local stage = get_active_runtime_stage(runtime_state)
                if not runtime_state.is_playable or type(stage) ~= "number" then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end

                local item_id = decode_low32_from_hook_arg(args[4])
                local item_count = decode_low32_from_hook_arg(args[5])
                local context_key = get_context_id_key(args[3])
                if item_count == nil or item_count <= 0 then
                    item_count = 1
                end

                local suppression_helper = ctx.consume_local_injection_suppression or _G.consume_local_injection_suppression
                if type(suppression_helper) == "function" and suppression_helper(item_id, item_count) then
                    log.info(
                        string.format(
                            "[RE4R AP] pickup_commit suppressed local injection stage=%s item_id=%s count=%s",
                            tostring(stage),
                            tostring(item_id),
                            tostring(item_count)
                        )
                    )
                    return sdk.PreHookResult.CALL_ORIGINAL
                end

                local matched_accept = pop_matching_pending_pickup_accept(stage)
                if matched_accept == nil then
                    local recent_accept = pop_recent_pickup_accept_probe(stage)
                    if recent_accept ~= nil then
                        record_pickup_probe(
                            "confirmed",
                            recent_accept.stage,
                            recent_accept.context_key,
                            recent_accept.guid,
                            item_id,
                            item_count,
                            recent_accept.tracked,
                            recent_accept.pending,
                            recent_accept.acknowledged
                        )

                        if recent_accept.tracked == true and recent_accept.pending ~= true and recent_accept.acknowledged ~= true then
                            queue_pending_check(recent_accept.guid, recent_accept.stage)
                            log.info(string.format(
                                "[RE4R AP] pickup_confirmed fresh stage=%s guid=%s item_id=%s count=%s context=%s",
                                tostring(recent_accept.stage),
                                tostring(recent_accept.guid),
                                tostring(item_id),
                                tostring(item_count),
                                tostring(recent_accept.context_key)
                            ))
                            return sdk.PreHookResult.CALL_ORIGINAL
                        end

                        if recent_accept.tracked == true and recent_accept.pending == true and recent_accept.acknowledged ~= true then
                            log.info(string.format(
                                "[RE4R AP] pickup_confirmed already_queued stage=%s guid=%s item_id=%s count=%s context=%s",
                                tostring(recent_accept.stage),
                                tostring(recent_accept.guid),
                                tostring(item_id),
                                tostring(item_count),
                                tostring(recent_accept.context_key)
                            ))
                            return sdk.PreHookResult.CALL_ORIGINAL
                        end

                        if recent_accept.tracked == true and recent_accept.acknowledged == true then
                            enqueue_already_checked_notification(recent_accept.guid, recent_accept.stage)
                            log.info(string.format(
                                "[RE4R AP] pickup_confirmed already_checked stage=%s guid=%s item_id=%s count=%s context=%s",
                                tostring(recent_accept.stage),
                                tostring(recent_accept.guid),
                                tostring(item_id),
                                tostring(item_count),
                                tostring(recent_accept.context_key)
                            ))
                            return sdk.PreHookResult.CALL_ORIGINAL
                        end

                        if recent_accept.tracked ~= true then
                            -- A placeholder only ever physically exists at an AP
                            -- location, so confirming one as untracked means a
                            -- dataset gap or stage-resolution bug - and the item
                            -- just entered the case. Loud breadcrumb, never silent.
                            if tonumber(item_id) == PLACEHOLDER_ITEM_ID then
                                log.error(string.format(
                                    "[RE4R AP] PLACEHOLDER confirmed OUTSIDE dataset (stage=%s guid=%s context=%s) - dataset gap or stage mismatch; placeholder entered the case",
                                    tostring(recent_accept.stage),
                                    tostring(recent_accept.guid),
                                    tostring(recent_accept.context_key)
                                ))
                            end
                            log.info(string.format(
                                "[RE4R AP] pickup_confirmed not_in_dataset stage=%s guid=%s item_id=%s count=%s context=%s",
                                tostring(recent_accept.stage),
                                tostring(recent_accept.guid),
                                tostring(item_id),
                                tostring(item_count),
                                tostring(recent_accept.context_key)
                            ))
                            return sdk.PreHookResult.CALL_ORIGINAL
                        end
                    end

                    record_pickup_probe(
                        "commit-only",
                        stage,
                        context_key,
                        nil,
                        item_id,
                        item_count,
                        false,
                        false,
                        false
                    )
                    log.info(string.format(
                        "[RE4R AP] pickup_commit unmatched stage=%s item_id=%s count=%s",
                        tostring(stage), tostring(item_id), tostring(item_count)
                    ))
                    return sdk.PreHookResult.CALL_ORIGINAL
                end

                pop_recent_pickup_accept_probe(matched_accept.stage)
                record_pickup_probe(
                    "confirmed",
                    matched_accept.stage,
                    matched_accept.context_key,
                    matched_accept.guid,
                    item_id,
                    item_count,
                    true,
                    false,
                    false
                )
                queue_pending_check(matched_accept.guid, matched_accept.stage)
                log.info(
                    string.format(
                        "[RE4R AP] pickup_confirmed stage=%s guid=%s item_id=%s count=%s context=%s",
                        tostring(matched_accept.stage),
                        tostring(matched_accept.guid),
                        tostring(item_id),
                        tostring(item_count),
                        tostring(matched_accept.context_key)
                    )
                )
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                return retval
            end
        )
    end

    local function install_interact_holder_hit_hook()
        local holder_type = sdk.find_type_definition("chainsaw.InteractHolder")
        if holder_type == nil then
            log.info("[RE4R AP] InteractHolder type not found for onHitTarget hook")
            return
        end

        local hit_method = holder_type:get_method("onHitTarget")
        if hit_method == nil then
            log.info("[RE4R AP] InteractHolder.onHitTarget not found for refinement hook")
            return
        end

        sdk.hook(
            hit_method,
            function(args)
                local runtime_state = get_runtime_state()
                if not runtime_state.is_playable or type(runtime_state.current_stage) ~= "number" then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end

                local holder = sdk.to_managed_object(args[2])
                if holder == nil then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end

                local guid = bridge.holder_guid_by_key[tostring(holder)]
                if guid ~= nil then
                    -- Same stage canonicalization as the accept hook: the ack
                    -- key must use the guid's dataset stage, not the volume the
                    -- player stands in.
                    local hit_stage = resolve_tracked_stage(guid) or runtime_state.current_stage
                    if not is_guid_acknowledged(hit_stage, guid) then
                        bridge.recent_holder_hit = {
                            guid = guid,
                            stage = hit_stage,
                            timestamp_unix_ms = current_unix_ms(),
                        }
                    end
                end

                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                return retval
            end
        )
    end

    local function scan_stage_pickups(runtime_state)
        if not runtime_state.is_playable or type(runtime_state.current_stage) ~= "number" then
            bridge.tracked_stage_id = nil
            bridge.tracked_visible_guids = {}
            bridge.tracked_guid_snapshots = {}
            bridge.holder_guid_by_key = {}
            bridge.watched_guid_count = 0
            bridge.visible_guid_count = 0
            bridge.visible_guid_sample = {}
            return
        end

        local stage_id = runtime_state.current_stage
        local stage_entry = get_stage_watch_entry(stage_id) or { guids = {}, item_ids = {} }
        local tracked_guids = stage_entry.guids or {}
        local watched_count = 0
        for guid, _ in pairs(tracked_guids) do
            if not is_guid_acknowledged(stage_id, guid) then
                watched_count = watched_count + 1
            end
        end
        bridge.watched_guid_count = watched_count
        bridge.visible_guid_count = 0
        bridge.visible_guid_sample = {}
        bridge.tracked_stage_id = stage_id
        bridge.tracked_visible_guids = {}
        bridge.tracked_guid_snapshots = {}
        bridge.holder_guid_by_key = {}
    end

    export("clear_pending_pickup_accepts", clear_pending_pickup_accepts)
    export("prune_pending_pickup_accepts", prune_pending_pickup_accepts)
    export("scan_stage_pickups", scan_stage_pickups)
    export("pump_placeholder_despawns", pump_placeholder_despawns)
    export("install_pickup_accept_hook", install_pickup_accept_hook)
    export("install_pickup_commit_hook", install_pickup_commit_hook)
    export("install_interact_holder_hit_hook", install_interact_holder_hit_hook)
end

return install
