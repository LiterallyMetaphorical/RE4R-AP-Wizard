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
                -- With SUPPRESS_ORGANIC_AP_ITEM_TOAST the game's own item toast
                -- is skipped for this pickup, so OUR line is the one the player
                -- sees ("text"). Without it we stay out of the way and let the
                -- organic toast speak ("suppress"), which leaves our enriched
                -- line to the Message Log only.
                toast_native_route = SUPPRESS_ORGANIC_AP_ITEM_TOAST and "text" or "suppress"
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

    local function get_drop_item_context(drop_item)
        local context_object = safe_call(drop_item, "get_DropItemContext")
        if context_object == nil then
            local ok_field, field_value = pcall(function()
                return drop_item:get_field("<DropItemContext>k__BackingField")
            end)
            if ok_field then
                context_object = field_value
            end
        end
        return context_object
    end

    -- [Per-save consumption gate] reads DropItemContext._SaveCur.Count for the
    -- drop whose GameObject carries target_guid. That count lives in the SAVE
    -- (setCountZero probe v5: consumption writes _SaveCur.Count = 0 and nothing
    -- else), so it discriminates "THIS save consumed this drop" from the
    -- per-seed acknowledged set, which is durable across saves and says only
    -- that the seed checked the location at some point. Returns count, or nil
    -- plus a reason when the answer is unknowable right now (manager missing,
    -- drop not dispatched, context unreachable). Callers must fail CLOSED on
    -- nil - never mutate world state on an unknown.
    local function resolve_drop_save_count_by_guid(target_guid)
        local normalized_target = normalize_guid(tostring(target_guid))
        if normalized_target == nil then
            return nil, "bad_guid"
        end

        local drop_item_manager = sdk.get_managed_singleton("chainsaw.DropItemManager")
        if drop_item_manager == nil then
            return nil, "no_manager"
        end

        local drop_list = safe_call(drop_item_manager, "collectAllItem")
        if drop_list == nil then
            drop_list = safe_call(drop_item_manager, "collectAllItem()")
        end
        if drop_list == nil then
            return nil, "no_enumerator"
        end

        local list_count = safe_call(drop_list, "get_Count")
        if type(list_count) ~= "number" then
            list_count = safe_call(drop_list, "get_size")
        end
        if type(list_count) ~= "number" then
            return nil, "list_unreadable"
        end

        for index = 0, list_count - 1 do
            local drop_item = safe_call(drop_list, "get_Item", index)
            if drop_item == nil then
                drop_item = safe_call(drop_list, "get_element", index)
            end
            if drop_item ~= nil then
                local ok_game_object, game_object = pcall(function()
                    return drop_item:get_GameObject()
                end)
                if ok_game_object and game_object ~= nil then
                    local guid = normalize_guid(tostring(get_game_object_guid(game_object)))
                    if guid == normalized_target then
                        local context_object = get_drop_item_context(drop_item)
                        if context_object == nil then
                            return nil, "no_context"
                        end

                        local save_cur = safe_call(context_object, "get_SaveCur")
                        if save_cur == nil then
                            local ok_field, field_value = pcall(function()
                                return context_object:get_field("_SaveCur")
                            end)
                            if ok_field then
                                save_cur = field_value
                            end
                        end
                        if save_cur == nil then
                            return nil, "no_savecur"
                        end

                        local item_count = safe_call(save_cur, "get_Count")
                        if type(item_count) ~= "number" then
                            local ok_field, field_value = pcall(function()
                                return save_cur:get_field("Count")
                            end)
                            if ok_field and type(field_value) == "number" then
                                item_count = field_value
                            end
                        end
                        if type(item_count) ~= "number" then
                            return nil, "no_count"
                        end

                        return item_count, nil
                    end
                end
            end
        end

        return nil, "not_found"
    end

    -- Per-save memo state for the pickup-event-flag machinery (declared here
    -- so the load-clear below can reset them; populated further down).
    local fired_event_flag_keys = {}
    local retro_heal_skip_logged = {}

    local function clear_event_flag_memos()
        fired_event_flag_keys = {}
        retro_heal_skip_logged = {}
    end

    local function clear_pending_pickup_accepts(reason)
        local removed_count = #bridge.pending_pickup_accepts
        bridge.pending_pickup_accepts = {}
        bridge.next_pending_pickup_accept_id = 1
        recent_pickup_accept_probes = {}
        -- Event-flag dedupe is per-SAVE state: a load can swap to a save whose
        -- flags and drop-consumption differ, so both memo tables reset here
        -- (fire_pickup_event_flags re-checks the live flag before setting, so
        -- a reset is idempotent, never a double-set).
        clear_event_flag_memos()
        if removed_count > 0 and type(reason) == "string" and reason ~= "" then
            log.info(string.format("[RE4R AP] Cleared %d pending pickup accept(s): %s", removed_count, reason))
        end
    end

    -- AGE-ONLY pruning. These prunes used to ALSO drop any entry whose stage
    -- differed from the caller's current runtime stage - but accepts are filed
    -- under the guid's DATASET stage (canonicalization), and runtime volumes
    -- overlap and flap. Standing in a neighbouring sub-stage volume silently
    -- destroyed the pending accept within one scan tick, so the commit never
    -- matched and the check was LOST (Cam's Ch8 Mines Ruby, 2026-07-29
    -- 19:46: accept logged, then nothing - the marker staying up was the
    -- visible symptom). Reload safety is unaffected: clear_pending("load")
    -- still wipes on loading screens, and age windows bound everything else.
    local function prune_pending_pickup_accepts(_)
        local now_ms = current_unix_ms()
        local kept = {}
        for _, entry in ipairs(bridge.pending_pickup_accepts) do
            local age_ms = now_ms - (tonumber(entry.queued_at_unix_ms) or 0)
            -- This list only ever holds TRACKED accepts (enqueue requires the
            -- GUID to be an AP check), so they get the long window that
            -- survives the weapon-acquisition screen.
            if age_ms <= PENDING_TRACKED_ACCEPT_WINDOW_MS then
                table.insert(kept, entry)
            end
        end
        bridge.pending_pickup_accepts = kept
    end

    local function prune_recent_pickup_accept_probes(_)
        local now_ms = current_unix_ms()
        local kept = {}
        for _, entry in ipairs(recent_pickup_accept_probes) do
            local age_ms = now_ms - (tonumber(entry.queued_at_unix_ms) or 0)
            if age_ms <= PENDING_PICKUP_ACCEPT_WINDOW_MS then
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

    -- Context-key match first (the drop's exact identity, stage-independent),
    -- newest same-stage entry as the fallback for contextless callers.
    local function pop_recent_pickup_accept_probe(stage, context_key)
        prune_recent_pickup_accept_probes()
        local normalized_context = trim_string(context_key)
        if normalized_context ~= "" then
            for index, entry in ipairs(recent_pickup_accept_probes) do
                if entry.context_key == normalized_context then
                    table.remove(recent_pickup_accept_probes, index)
                    return entry
                end
            end
        end
        if type(stage) ~= "number" then
            return nil
        end

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

    -- runtime_stage is the volume the player was standing in, which can differ
    -- from the canonicalized dataset stage. Both are recorded so the commit hook
    -- can find this entry under whichever one it reports.
    local function enqueue_pending_pickup_accept(raw_context_arg, guid, stage, runtime_stage)
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
                entry.runtime_stage = runtime_stage
                entry.queued_at_unix_ms = now_ms
                return true
            end
        end

        table.insert(bridge.pending_pickup_accepts, {
            id = bridge.next_pending_pickup_accept_id,
            stage = stage,
            runtime_stage = runtime_stage,
            guid = normalized_guid,
            context_key = context_key,
            queued_at_unix_ms = now_ms,
        })
        bridge.next_pending_pickup_accept_id = bridge.next_pending_pickup_accept_id + 1
        return true
    end

    -- [Pickup event flags] re-fire the vanilla SetFlagSettings scenario flags
    -- for this drop (table: data.get_pickup_event_flags). The AP item swap
    -- changes the looted item's kind, so the game's own pickup trigger never
    -- runs the GO's SetFlagSettings; without these flags the scripted events
    -- they drive (Salazar knights ambush, ch2 chapter advance, island keycard
    -- doors) stay dead. Fired on every commit confirm path incl.
    -- already_checked (reload-and-regrab heals itself) AND in the placeholder
    -- intercept - foreign-item locations SKIP_ORIGINAL at accept and never
    -- commit, so the intercept is their only pickup moment. Validated live
    -- 2026-07-30: setting 319b884a armed the Mausoleum knights + crawl-under
    -- escape.
    -- (fired_event_flag_keys is declared above the load-clear, which resets it
    -- per save.)
    local function fire_pickup_event_flags(guid, reason)
        local entry = get_pickup_event_flags(guid)
        if entry == nil then
            return
        end
        for _, flag_guid in ipairs(entry.flags) do
            local fire_key = string.format("%s|%s", tostring(guid), tostring(flag_guid))
            if not fired_event_flag_keys[fire_key] then
                local current = check_scenario_flag(flag_guid)
                if current == true then
                    fired_event_flag_keys[fire_key] = true
                elseif set_scenario_flag(flag_guid) then
                    fired_event_flag_keys[fire_key] = true
                    log.info(string.format(
                        "[RE4R AP] pickup event flag set flag=%s guid=%s reason=%s",
                        tostring(flag_guid),
                        tostring(guid),
                        tostring(reason)
                    ))
                else
                    log.error(string.format(
                        "[RE4R AP] pickup event flag FAILED flag=%s guid=%s reason=%s",
                        tostring(flag_guid),
                        tostring(guid),
                        tostring(reason)
                    ))
                end
            end
        end
    end

    -- Context-key match FIRST: both hooks see the same drop context (proven
    -- live - accept and confirm logged identical keys), so this pairing is
    -- exact and immune to runtime-vs-dataset stage divergence. Stage match
    -- stays only as the fallback for a contextless commit.
    local function pop_matching_pending_pickup_accept(stage, context_key)
        prune_pending_pickup_accepts()
        local normalized_context = trim_string(context_key)
        if normalized_context ~= "" then
            for index, entry in ipairs(bridge.pending_pickup_accepts) do
                if entry.context_key == normalized_context then
                    table.remove(bridge.pending_pickup_accepts, index)
                    return entry
                end
            end
        end
        if type(stage) ~= "number" then
            return nil
        end
        -- Match the canonicalized stage OR the runtime volume the accept was
        -- taken in. The commit hook has no guid to canonicalize with, so it can
        -- only report the raw volume; comparing that against the canonicalized
        -- stage alone silently loses every check in a room whose sub-areas
        -- overlap.
        for index, entry in ipairs(bridge.pending_pickup_accepts) do
            if entry.stage == stage or entry.runtime_stage == stage then
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
                -- Keep the volume we were STANDING in as well. The commit hook
                -- reports that raw runtime stage, not this canonicalized one, so
                -- the pending accept has to be findable under both or the commit
                -- cannot match it (live miss 2026-08-02, Abandoned Factory:
                -- accept filed under 44210, commit arrived as 44200 -> "commit
                -- unmatched", check lost).
                local runtime_stage = stage
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
                        -- Foreign-item locations NEVER reach the commit hook:
                        -- this intercept returns SKIP_ORIGINAL and despawns the
                        -- drop, so the commit-path event-flag firing cannot run
                        -- for them. This IS the pickup moment for a placeholder
                        -- drop, so the vanilla pickup event flags fire here.
                        -- Live gap 2026-07-30 01:15: the Salazar regrab logged
                        -- only setCountZero - no commit, no flags, knights
                        -- stayed dormant.
                        fire_pickup_event_flags(guid, "placeholder_intercept")
                        -- Run the engine's own collected bookkeeping before the
                        -- despawn. SKIP_ORIGINAL means the vanilla accept path
                        -- never records the pickup, so the drop respawned on
                        -- every reload and its map icon never cleared (Cam
                        -- 2026-07-29). Two writes, both mined via the flag probe:
                        -- onFirstGetAndPickedUp = the drop's first-get record.
                        local ok_got, got_err = pcall(function()
                            drop_item:call("onFirstGetAndPickedUp")
                        end)
                        log.info(string.format(
                            "[RE4R AP] placeholder onFirstGetAndPickedUp %s%s",
                            ok_got and "ok" or "FAILED",
                            ok_got and "" or (": " .. tostring(got_err))
                        ))
                        -- setCountZero = the PERSISTENT consumption. Probe v5
                        -- proved every vanilla pickup flips the context's
                        -- _SaveCur.Count to 0 and changes nothing else (8/8);
                        -- this is the context's own method for that write and
                        -- it fires the _OnSetCountZero deletion delegates.
                        -- onFirstGetAndPickedUp alone was NOT enough (already-
                        -- sent placeholders respawned at 50401/50501 live).
                        local ok_zero, zero_err = pcall(function()
                            local context_object = drop_item:call("get_DropItemContext")
                            if context_object == nil then
                                context_object = drop_item:get_field("<DropItemContext>k__BackingField")
                            end
                            if context_object == nil then
                                error("DropItemContext unreachable")
                            end
                            context_object:call("setCountZero")
                        end)
                        log.info(string.format(
                            "[RE4R AP] placeholder setCountZero %s%s",
                            ok_zero and "ok" or "FAILED",
                            ok_zero and "" or (": " .. tostring(zero_err))
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

                if guid ~= nil and enqueue_pending_pickup_accept(context_arg, guid, stage, runtime_stage) then
                    -- [Own-pickup toast] Arm HERE, not at commit: the game pushes
                    -- its own item toast around the moment the item lands, which
                    -- can beat the commit hook, and accept always precedes both.
                    -- The `tracked` test is what limits this to AP locations;
                    -- foreign placements never reach it (they returned
                    -- SKIP_ORIGINAL above and show no organic toast anyway).
                    if SUPPRESS_ORGANIC_AP_ITEM_TOAST and tracked then
                        bridge.suppress_organic_item_toast_until_ms =
                            current_unix_ms() + (tonumber(ORGANIC_TOAST_SUPPRESS_WINDOW_MS) or 15000)
                    end
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
                    -- LOUD skip: this used to return silently, which made a
                    -- commit that fired mid-transition (stage nil / not
                    -- playable) indistinguishable from one that never fired -
                    -- exactly the ambiguity that hid the Mines lost-check.
                    log.info(string.format(
                        "[RE4R AP] pickup_commit skipped (playable=%s stage=%s) item_id=%s",
                        tostring(runtime_state.is_playable),
                        tostring(stage),
                        tostring(decode_low32_from_hook_arg(args[4]))
                    ))
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

                local matched_accept = pop_matching_pending_pickup_accept(stage, context_key)
                if matched_accept == nil then
                    local recent_accept = pop_recent_pickup_accept_probe(stage, context_key)
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
                            fire_pickup_event_flags(recent_accept.guid, "fresh")
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
                            fire_pickup_event_flags(recent_accept.guid, "already_queued")
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
                            fire_pickup_event_flags(recent_accept.guid, "already_checked")
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

                pop_recent_pickup_accept_probe(matched_accept.stage, matched_accept.context_key)
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
                fire_pickup_event_flags(matched_accept.guid, "commit")
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

    -- [Pickup event flags retro-heal] curated: only entries whose retro_heal
    -- is true in pickup_event_flags.json (Salazar 319b884a for now). Covers
    -- saves where the location was collected BEFORE this fix existed, so no
    -- pickup commit will ever re-fire it. THREE gates, all required:
    --   1. stage family - a stale flag can only apply where it matters, never
    --      remotely (a blanket retro-set could edge-trigger dormant events
    --      like the ch2 chapter advance out of order);
    --   2. per-seed acknowledged set - the seed checked the location at all;
    --   3. per-SAVE consumption - DropItemContext._SaveCur.Count == 0 for the
    --      drop in THIS save. Gate 2 alone corrupted a rewound save live
    --      (2026-07-30 00:48: an older Ashley-section save in the same family
    --      got 319b884a set, post-pickup world state walled off the route to
    --      the un-collected Insignia). The count lives in the save, so it is
    --      the discriminator gate 2 cannot be. Unknown count (drop not
    --      dispatched, context unreachable) fails CLOSED: never mutate world
    --      state on an unknown. Throttled to one scan per 5s; fired keys
    --      dedupe so steady state does zero native calls.
    -- [Drop audit] passive never-tracked telemetry. Every ~10s in-game, walk
    -- the DropItemManager's live set and record each AP-pool guid ever seen
    -- (union across sessions AND seeds - aliveness is a property of the game,
    -- not the seed). Offline diff vs the dataset then convicts dead content
    -- by the sibling rule (stage produced seen guids, this guid never, in any
    -- run). Born from the loc56 cut-content hunt: 2 confirmed dead herbs took
    -- a manual probe + screenshots; this collects the same evidence for free
    -- during every playtest.
    -- [v2] Each tracked drop also records its LIVE world position. The 08-02
    -- ghost reports were all for spots the audit proves alive, which leaves
    -- marker-offset (the marker's dataset coordinates vs where the drop
    -- really sits) and stale markers as the open explanations. Diffing pos
    -- against re4r_ap_static.json's x/y/z offline measures the first one
    -- directly. Caveat for readers: tracked does not mean visible - inert
    -- possession twins report positions too.
    local drop_audit = { seen = nil, pos = nil, dirty = false }
    local drop_audit_last_scan = 0.0
    local drop_audit_last_write = 0.0

    local function ensure_drop_audit_loaded()
        if drop_audit.seen ~= nil then
            return
        end
        drop_audit.seen = {}
        drop_audit.pos = {}
        local payload = json.load_file(DROP_AUDIT_FILE)
        if type(payload) == "table" and type(payload.seen) == "table" then
            for guid, stamp in pairs(payload.seen) do
                drop_audit.seen[guid] = stamp
            end
        end
        -- v1 files simply have no pos table; they upgrade in place on the
        -- next write.
        if type(payload) == "table" and type(payload.pos) == "table" then
            for guid, position in pairs(payload.pos) do
                if type(position) == "table"
                    and type(position.x) == "number"
                    and type(position.y) == "number"
                    and type(position.z) == "number" then
                    drop_audit.pos[guid] = { x = position.x, y = position.y, z = position.z }
                end
            end
        end
    end

    local function read_drop_world_position(game_object)
        local ok, position = pcall(function()
            local transform = game_object:get_Transform()
            if transform == nil then
                return nil
            end
            local vec = transform:get_Position()
            if vec == nil then
                return nil
            end
            return { x = tonumber(vec.x), y = tonumber(vec.y), z = tonumber(vec.z) }
        end)
        if not ok or type(position) ~= "table"
            or type(position.x) ~= "number"
            or type(position.y) ~= "number"
            or type(position.z) ~= "number" then
            return nil
        end
        local function round_cm(value)
            return math.floor(value * 100 + 0.5) / 100
        end
        return { x = round_cm(position.x), y = round_cm(position.y), z = round_cm(position.z) }
    end

    local function drop_audit_scan()
        ensure_drop_audit_loaded()
        local manager = sdk.get_managed_singleton("chainsaw.DropItemManager")
        if manager == nil then
            return
        end
        local drop_list = safe_call(manager, "collectAllItem")
        if drop_list == nil then
            drop_list = safe_call(manager, "collectAllItem()")
        end
        if drop_list == nil then
            return
        end
        local count = safe_call(drop_list, "get_Count")
        if type(count) ~= "number" then
            count = safe_call(drop_list, "get_size")
        end
        if type(count) ~= "number" then
            return
        end
        for index = 0, count - 1 do
            local drop_item = safe_call(drop_list, "get_Item", index)
            if drop_item == nil then
                drop_item = safe_call(drop_list, "get_element", index)
            end
            if drop_item ~= nil then
                local ok_go, game_object = pcall(function()
                    return drop_item:get_GameObject()
                end)
                if ok_go and game_object ~= nil then
                    local guid = normalize_guid(tostring(get_game_object_guid(game_object)))
                    if guid ~= nil and resolve_tracked_stage(guid) ~= nil then
                        if drop_audit.seen[guid] == nil then
                            drop_audit.seen[guid] = os.time()
                            drop_audit.dirty = true
                        end
                        -- Last-known live position wins: a cage item that gets
                        -- shot down should report where it landed, not where
                        -- it hung. The 0.5m epsilon keeps physics jitter from
                        -- dirtying the file forever.
                        local position = read_drop_world_position(game_object)
                        if position ~= nil then
                            local previous = drop_audit.pos[guid]
                            if previous == nil
                                or math.abs(previous.x - position.x) > 0.5
                                or math.abs(previous.y - position.y) > 0.5
                                or math.abs(previous.z - position.z) > 0.5 then
                                drop_audit.pos[guid] = position
                                drop_audit.dirty = true
                            end
                        end
                    end
                end
            end
        end
    end

    re.on_frame(function()
        local now = os.clock()
        if now - drop_audit_last_scan >= 10.0 then
            drop_audit_last_scan = now
            if tonumber(get_active_runtime_stage()) ~= nil then
                pcall(drop_audit_scan)
            end
        end
        if drop_audit.dirty and now - drop_audit_last_write >= 30.0 then
            drop_audit_last_write = now
            drop_audit.dirty = false
            pcall(function()
                json.dump_file(DROP_AUDIT_FILE, { version = 2, seen = drop_audit.seen, pos = drop_audit.pos })
            end)
        end
    end)

    local retro_heal_last_clock = 0.0

    re.on_frame(function()
        -- Default off until the per-save gate is re-verified live on a
        -- rewound save. See config.PICKUP_EVENT_FLAG_RETRO_HEAL.
        if not PICKUP_EVENT_FLAG_RETRO_HEAL then
            return
        end
        local now = os.clock()
        if now - retro_heal_last_clock < 5.0 then
            return
        end
        retro_heal_last_clock = now

        local ok, err = pcall(function()
            local current_stage = tonumber(get_active_runtime_stage())
            if current_stage == nil then
                return
            end
            local family = get_stage_family_stages(current_stage)
            if type(family) ~= "table" then
                return
            end
            local family_set = {}
            for _, family_stage in ipairs(family) do
                family_set[tonumber(family_stage) or -1] = true
            end
            for guid, entry in pairs(get_pickup_event_flag_entries()) do
                if entry.retro_heal
                    and entry.stage ~= nil
                    and family_set[entry.stage]
                    and is_guid_acknowledged(entry.stage, guid) then
                    local save_count, unknown_reason = resolve_drop_save_count_by_guid(guid)
                    if save_count == 0 then
                        fire_pickup_event_flags(guid, "retro_heal")
                    else
                        -- Fail closed. Log the refusal once per guid per
                        -- session so the verification run shows exactly what
                        -- the per-save gate saw.
                        if not retro_heal_skip_logged[guid] then
                            retro_heal_skip_logged[guid] = true
                            log.info(string.format(
                                "[RE4R AP] retro-heal refused guid=%s save_count=%s reason=%s",
                                tostring(guid),
                                tostring(save_count),
                                tostring(unknown_reason)
                            ))
                        end
                    end
                end
            end
        end)
        if not ok then
            log.info(string.format(
                "[RE4R AP] pickup event flag retro-heal error: %s",
                tostring(err)
            ))
        end
    end)

    export("clear_pending_pickup_accepts", clear_pending_pickup_accepts)
    export("prune_pending_pickup_accepts", prune_pending_pickup_accepts)
    export("scan_stage_pickups", scan_stage_pickups)
    export("pump_placeholder_despawns", pump_placeholder_despawns)
    export("install_pickup_accept_hook", install_pickup_accept_hook)
    export("install_pickup_commit_hook", install_pickup_commit_hook)
    export("install_interact_holder_hit_hook", install_interact_holder_hit_hook)
end

return install
