local function install(ctx)
    ctx.ui_windows = ctx.ui_windows or {}

    local bridge = ctx.bridge
    local ui_windows = ctx.ui_windows

    local function export(name, value)
        ui_windows[name] = value
        ctx[name] = value
        _G[name] = value
    end

    local chapter_switch_entries = {
        { label = "Chapter 1", chapter_id = 21100, special_jump_sequence = 6 },
        { label = "Chapter 2", chapter_id = 21200, special_jump_sequence = 7 },
        { label = "Chapter 3", chapter_id = 21300, special_jump_sequence = 8 },
        { label = "Chapter 4", chapter_id = 22100, special_jump_sequence = 9 },
        { label = "Chapter 5", chapter_id = 22200, special_jump_sequence = 10 },
        { label = "Chapter 6", chapter_id = 22300, special_jump_sequence = 11 },
        { label = "Chapter 7", chapter_id = 23100, special_jump_sequence = 12 },
        { label = "Chapter 8", chapter_id = 23200, special_jump_sequence = 13 },
        { label = "Chapter 9", chapter_id = 23300, special_jump_sequence = 14 },
        { label = "Chapter 10", chapter_id = 24100, special_jump_sequence = 15 },
        { label = "Chapter 11", chapter_id = 24200, special_jump_sequence = 16 },
        { label = "Chapter 12", chapter_id = 24300, special_jump_sequence = 17 },
        { label = "Chapter 13", chapter_id = 25100, special_jump_sequence = 18 },
        { label = "Chapter 14", chapter_id = 25200, special_jump_sequence = 19 },
        { label = "Chapter 15", chapter_id = 25300, special_jump_sequence = 20 },
        { label = "Chapter 16", chapter_id = 25400, special_jump_sequence = 21 },
    }

    local chapter_switch_labels = {}
    for _, entry in ipairs(chapter_switch_entries) do
        table.insert(chapter_switch_labels, entry.label)
    end

    local function format_optional(value)
        if value == nil then
            return "(unknown)"
        end
        return tostring(value)
    end

    local function format_bool(value)
        if value then
            return "true"
        end
        return "false"
    end

    local function get_selected_chapter_switch_entry()
        local normalized_index = math.max(1, math.min(#chapter_switch_entries, math.floor(tonumber(bridge.chapter_switch_selected_index) or 1)))
        bridge.chapter_switch_selected_index = normalized_index
        return chapter_switch_entries[normalized_index]
    end

    local function arm_chapter_switch()
        local entry = get_selected_chapter_switch_entry()
        if entry == nil then
            bridge.chapter_switch_status = "Chapter switch unavailable"
            return false
        end

        bridge.chapter_switch_pending = true
        bridge.chapter_switch_pending_chapter_id = entry.chapter_id
        bridge.chapter_switch_pending_special_jump_sequence = entry.special_jump_sequence
        bridge.chapter_switch_last_armed_label = entry.label
        bridge.chapter_switch_status = string.format("%s armed for next load", entry.label)
        log.info(
            string.format(
                "[RE4R AP] Chapter switch armed: label=%s chapter=%s special_jump=%s",
                tostring(entry.label),
                tostring(entry.chapter_id),
                tostring(entry.special_jump_sequence)
            )
        )
        return true
    end

    -- Player-facing session status (Overview tab of the consolidated window).
    local function draw_status_content()
        local state = bridge.last_state or {}
        imgui.text("Playable: " .. format_bool(state.is_playable == true))
        imgui.text("AP Connection: " .. tostring(bridge.ap_status_label or bridge.ap_connection_status or "Disconnected"))
        local section_resolver = ctx.get_current_section or _G.get_current_section
        local current_section = nil
        if type(section_resolver) == "function" and type(state.current_stage) == "number" then
            local ok_section, resolved_section = pcall(section_resolver, state.current_stage)
            if ok_section and type(resolved_section) == "string" and resolved_section ~= "" then
                current_section = resolved_section
            end
        end
        imgui.text(
            string.format(
                "Chapter: %s | Area: %s | Stage: %s",
                tostring(bridge.ui_current_chapter_display or "(unknown)"),
                tostring(current_section or "(unknown)"),
                format_optional(state.current_stage)
            )
        )
        imgui.text(
            string.format(
                "Candidate Checks: %s | Checks Sent: %s",
                tostring(state.candidate_check_count or 0),
                tostring(bridge.checks_sent_session or 0)
            )
        )
        imgui.text("Last Item Received: " .. tostring(bridge.last_item_received or "(none)"))

        -- [Hints] Unfound hints on OUR locations (durable, storage-synced by
        -- apclient). Place = section (container gloss) - authored note.
        local hints = bridge.hints_on_my_world
        if type(hints) == "table" and next(hints) ~= nil then
            local rows = {}
            for _, hint in pairs(hints) do
                table.insert(rows, hint)
            end
            table.sort(rows, function(left, right)
                return tostring(left.item_name or "") < tostring(right.item_name or "")
            end)

            imgui.text("")
            imgui.text(string.format("-- Hints On Your World (%d unfound) --", #rows))
            local resolver = ctx.get_display_entry_by_location_id or _G.get_display_entry_by_location_id
            local gloss_fn = ctx.get_container_gloss or _G.get_container_gloss
            for _, hint in ipairs(rows) do
                local place = "(unknown place)"
                local resolved = (type(resolver) == "function") and resolver(hint.location_id) or nil
                local entry = resolved and resolved.entry or nil
                if entry ~= nil then
                    place = tostring(entry.section_name or "")
                    local gloss = (type(gloss_fn) == "function") and gloss_fn(entry.container) or ""
                    if gloss ~= "" then place = string.format("%s (%s)", place, gloss) end
                    local note = tostring(entry.note or "")
                    if note ~= "" then place = place .. " - " .. note end
                end
                imgui.text(string.format(
                    "%s for %s - %s",
                    tostring(hint.item_name or "Unknown item"),
                    tostring(hint.receiving_player_name or "?"),
                    place
                ))
            end
        end

    end

    -- Developer telemetry (Debug tab): GUID counters + pickup probe. The
    -- checkbox mirrors the probe into the HUD overlay.
    local function draw_probe_content()
        local state = bridge.last_state or {}
        imgui.text(
            string.format(
                "Watched GUIDs: %s | Visible GUIDs: %s",
                tostring(state.watched_guid_count or 0),
                tostring(state.visible_guid_count or 0)
            )
        )
        imgui.text("-- Pickup Probe (debug) --")
        local probe = bridge.pickup_probe
        if type(probe) == "table" then
            local label_fn = _G.build_pickup_probe_item_label
            local item_label = (type(label_fn) == "function") and label_fn(probe) or "(item)"
            imgui.text("Last Pickup: " .. tostring(item_label))
            imgui.text(string.format(
                "Tracked: %s | Event: %s",
                format_bool(probe.tracked == true),
                tostring(trim_string(probe.event_name) ~= "" and probe.event_name or "-")
            ))
            imgui.text("GUID: " .. tostring(normalize_guid(probe.guid) or "-"))
            imgui.text(string.format(
                "Stage: %s | Ctx: %s",
                format_optional(probe.stage),
                tostring(trim_string(probe.context_key) ~= "" and probe.context_key or "-")
            ))
        else
            imgui.text("Last Pickup: (none yet)")
        end

        if bridge.show_debug_probe_overlay == nil then
            bridge.show_debug_probe_overlay = (SHOW_DEBUG_PROBE_OVERLAY == true)
        end
        local changed, new_value = imgui.checkbox(
            "Show pickup probe in game HUD", bridge.show_debug_probe_overlay == true)
        if changed then
            bridge.show_debug_probe_overlay = new_value
        end
    end

    -- Connection summary (Overview tab).
    local function draw_connection_content()
        imgui.text("Server: " .. format_optional(bridge.launcher_server_address ~= "" and bridge.launcher_server_address or nil))
        imgui.text("Slot: " .. format_optional(bridge.launcher_slot_name ~= "" and bridge.launcher_slot_name or nil))
        imgui.text("AP Connection: " .. tostring(bridge.ap_status_label or bridge.ap_connection_status or "Disconnected"))
        imgui.text("AP Client: in-game Lua (lua-apclientpp)")
    end

    -- Manual engine-item injection (Debug tab; developer tool).
    local function draw_injection_content()
        imgui.text(string.format("RE4R Item Injection Debug | Catalog: %d items", #injectable_items))

        if type(bridge.inject_recent_item_ids) == "table" and #bridge.inject_recent_item_ids > 0 then
            imgui.text("Recent:")
            imgui.same_line()
            local first_recent = true
            for _, recent_item_id in ipairs(bridge.inject_recent_item_ids) do
                local recent_label, recent_index = get_injectable_label_for_item_id(recent_item_id)
                recent_label = string.format("%s [%d]", recent_label, recent_item_id)

                if not first_recent then
                    imgui.same_line()
                end
                first_recent = false

                if imgui.button(recent_label) then
                    bridge.inject_item_id_text = tostring(recent_item_id)
                    if recent_index ~= nil then
                        bridge.inject_selected_item_index = recent_index
                        local recent_entry = injectable_items[recent_index]
                        if recent_entry ~= nil then
                            bridge.inject_selected_category = get_injectable_display_category(recent_entry.kind, recent_entry.label)
                        end
                    end
                    bridge.inject_status = "Raw Item ID populated from Recent"
                end
            end
        else
            imgui.text("Recent: (none)")
        end

        local current_category_index = 1
        for index, category_name in ipairs(injectable_category_names) do
            if category_name == tostring(bridge.inject_selected_category or "All") then
                current_category_index = index
                break
            end
        end

        local changed_category, selected_category_index = imgui.combo(
            "Item Type",
            current_category_index,
            injectable_category_names
        )
        if changed_category then
            bridge.inject_selected_category = injectable_category_names[selected_category_index] or "All"
        end

        local filtered_item_names, filtered_item_indices = build_filtered_injectable_view(bridge.inject_selected_category)
        local selection_visible_in_filter = false
        local filtered_selected_index = 1
        for filtered_index, full_index in ipairs(filtered_item_indices) do
            if full_index == bridge.inject_selected_item_index then
                filtered_selected_index = filtered_index
                selection_visible_in_filter = true
                break
            end
        end

        if changed_category and #filtered_item_indices > 0 and not selection_visible_in_filter then
            select_known_injectable_item(filtered_item_indices[1])
            filtered_selected_index = 1
            selection_visible_in_filter = true
        end

        local active_item_id = math.floor(tonumber(trim_string(bridge.inject_item_id_text)) or 0)
        local active_item_kind = inject_get_item_kind(active_item_id)
        local active_route_label = inject_get_route_label(active_item_kind, active_item_id)
        local active_item_label, matched_active_index = get_injectable_label_for_item_id(active_item_id)

        if #filtered_item_indices > 0 then
            local changed_inject_item, inject_item_index = imgui.combo(
                "Injectable Item",
                filtered_selected_index,
                filtered_item_names
            )
            if changed_inject_item then
                select_known_injectable_item(filtered_item_indices[inject_item_index] or filtered_item_indices[1])
            end
        end

        imgui.text(
            string.format(
                "Route: -> %s",
                active_route_label
            )
        )

        local changed_item_id_text, item_id_text = imgui.input_text("Raw Item ID", tostring(bridge.inject_item_id_text or ""), 0)
        if changed_item_id_text then
            bridge.inject_item_id_text = item_id_text
            local matched_index = find_known_injectable_item_index(tonumber(item_id_text))
            if matched_index ~= nil then
                bridge.inject_selected_item_index = matched_index
                local matched_entry = injectable_items[matched_index]
                if matched_entry ~= nil then
                    bridge.inject_selected_category = get_injectable_display_category(matched_entry.kind, matched_entry.label)
                end
            end
        end

        if type(bridge.inject_count_text) ~= "string" or bridge.inject_count_text == "" then
            bridge.inject_count_text = tostring(bridge.inject_count or 1)
        end

        local changed_count, inject_count_text = imgui.input_text("Count", tostring(bridge.inject_count_text or "1"), 0)
        if changed_count then
            bridge.inject_count_text = inject_count_text
            local parsed_count = tonumber(inject_count_text)
            if parsed_count ~= nil then
                bridge.inject_count = math.max(1, math.floor(parsed_count))
            end
        end

        if imgui.button("Inject Item") then
            local requested_item_id = math.floor(tonumber(trim_string(bridge.inject_item_id_text)) or 0)
            local requested_count = math.max(
                1,
                math.floor(tonumber(trim_string(bridge.inject_count_text or "")) or tonumber(bridge.inject_count) or 1)
            )
            bridge.inject_count = requested_count
            bridge.inject_count_text = tostring(requested_count)

            local requested_item_kind = inject_get_item_kind(requested_item_id)
            local requested_route_label = inject_get_route_label(requested_item_kind, requested_item_id)
            local requested_item_label = active_item_label
            if requested_item_id ~= active_item_id then
                requested_item_label = get_injectable_label_for_item_id(requested_item_id)
            end

            local inject_result = inject_item_to_inventory(requested_item_id, requested_count)
            bridge.inject_status_detail = tostring(inject_result or "(idle)")
            bridge.inject_status = bridge.inject_status_detail
            if inject_status_succeeded(bridge.inject_status_detail) then
                inject_record_recent_item(requested_item_id)
                bridge.inject_status = string.format("%s -> %s", requested_item_label, requested_route_label)
            end
        end

        imgui.text("Status: " .. tostring(bridge.inject_status or "(idle)"))
    end

    local function sync_warp_inputs_to_current_state()
        local state = bridge.last_state or {}
        if type(state.current_stage) == "number" then
            bridge.warp_stage_id = state.current_stage
        end

        local pos = get_player_position()
        if pos ~= nil then
            bridge.warp_x = tonumber(pos.x) or bridge.warp_x
            bridge.warp_y = tonumber(pos.y) or bridge.warp_y
            bridge.warp_z = tonumber(pos.z) or bridge.warp_z
        end
    end

    -- Every Warp click verdict rides the normal toast pipeline (HUD/native
    -- rail + Message Log), because the old feedback - a one-line "Last Warp:"
    -- status update - read as "the button did nothing" (Cam 2026-07-29).
    -- Shared pusher lives in data.lua (warp.lua's deferred failure uses it too).
    local function push_warp_feedback_toast(title, detail)
        local push = ctx.push_info_toast or _G.push_info_toast
        if type(push) == "function" then
            push(title, detail)
        end
    end

    -- Typewriter warp + chapter switch (Warp tab). Warp system originally
    -- created by JumperDenfer.
    local function draw_warp_content()
        if #bridge.typewriter_warp_points > 0 then
            local changed_warp_index, warp_index = imgui.combo(
                "##warp_point_selector",
                bridge.selected_typewriter_warp_index,
                bridge.typewriter_warp_point_names
            )
            if changed_warp_index then
                select_typewriter_warp_point(warp_index)
            end
        else
            imgui.text("No typewriter warp points loaded")
        end

        -- Unique imgui ID on its OWN row - load-bearing, not style. The
        -- original bare "Warp" button on the combo's same_line NEVER received
        -- clicks (hover reached it, clicks vanished; proven via staged
        -- instrumentation 2026-07-29). Do not rename back or re-inline.
        local warp_clicked = imgui.button("Warp Now##ap_warp_exec")
        if warp_clicked and bridge.pending_warp ~= nil then
            -- Debounce the sub-tick window between click and execute so a
            -- double-click cannot queue the warp twice.
            push_warp_feedback_toast("Warp already in progress", nil)
            warp_clicked = false
        end
        if warp_clicked then
            local selected_warp_point = bridge.typewriter_warp_points[bridge.selected_typewriter_warp_index]
            -- Log EVERY click verdict: a warp report with zero [RE4R AP] warp
            -- lines means the click died in a silent branch here - that
            -- ambiguity is exactly what made "warp does nothing" undiagnosable
            -- from the 2026-07-29 log.
            if selected_warp_point == nil then
                bridge.last_warp_status = "No typewriter warp selected"
                log.info(string.format(
                    "[RE4R AP] warp click: no selection (index=%s of %d points)",
                    tostring(bridge.selected_typewriter_warp_index),
                    #bridge.typewriter_warp_points))
                push_warp_feedback_toast("Warp: nothing selected", "pick a typewriter first")
            elseif not is_warp_stage_unlocked(selected_warp_point.stage_id) then
                bridge.last_warp_status = selected_warp_point.name .. " is locked until visited"
                log.info(string.format(
                    "[RE4R AP] warp click: %s (stage %s) is LOCKED - stand at that typewriter once this seed to unlock it",
                    tostring(selected_warp_point.name),
                    tostring(selected_warp_point.stage_id)))
                push_warp_feedback_toast(
                    "Warp locked: " .. tostring(selected_warp_point.name),
                    "visit that typewriter once this seed to unlock it")
            else
                log.info(string.format(
                    "[RE4R AP] warp click: %s (stage %s) unlocked - executing",
                    tostring(selected_warp_point.name),
                    tostring(selected_warp_point.stage_id)))
                local ok = warpToLocation(
                    selected_warp_point.stage_id,
                    selected_warp_point.x,
                    selected_warp_point.y,
                    selected_warp_point.z
                )
                if ok then
                    push_warp_feedback_toast(
                        "Warping to " .. tostring(selected_warp_point.name),
                        "you may need to warp a few times over")
                else
                    bridge.last_warp_status = "Warp failed"
                    push_warp_feedback_toast(
                        "Warp failed: " .. tostring(selected_warp_point.name),
                        "see re2_framework_log.txt for the reason")
                end
            end
        end

        imgui.text("Last Warp: " .. tostring(bridge.last_warp_status or "(idle)"))

        imgui.text("Chapter Switch")

        local changed_chapter_index, chapter_index = imgui.combo(
            "##chapter_switch_selector",
            bridge.chapter_switch_selected_index,
            chapter_switch_labels
        )
        if changed_chapter_index then
            bridge.chapter_switch_selected_index = chapter_index
        end
        imgui.same_line()
        if imgui.button("Arm Chapter Switch") then
            arm_chapter_switch()
        end

        local pending_label = "none"
        if bridge.chapter_switch_pending and type(bridge.chapter_switch_last_armed_label) == "string" then
            pending_label = bridge.chapter_switch_last_armed_label
        end

        imgui.text(
            string.format(
                "Pending: %s | Status: %s",
                pending_label,
                tostring(bridge.chapter_switch_status or "(idle)")
            )
        )
    end

    -- Warp point authoring (Debug tab; developer tool).
    local function draw_warp_editor_content()
        imgui.text("Warp CSV: " .. tostring(bridge.warp_points_status or "(unknown)"))

        if imgui.button("Reload Warp CSV") then
            load_warp_points()
            if #bridge.warp_points > 0 then
                select_warp_point(1)
            end
            if #bridge.typewriter_warp_points > 0 then
                select_typewriter_warp_point(bridge.selected_typewriter_warp_index)
            end
        end

        if imgui.button("Fill Current Stage") then
            local state = bridge.last_state or {}
            if type(state.current_stage) == "number" then
                bridge.warp_stage_id = state.current_stage
            end
        end
        imgui.same_line()
        if imgui.button("Fill Player Position") then
            local pos = get_player_position()
            if pos ~= nil then
                bridge.warp_x = tonumber(pos.x) or bridge.warp_x
                bridge.warp_y = tonumber(pos.y) or bridge.warp_y
                bridge.warp_z = tonumber(pos.z) or bridge.warp_z
            end
        end

        imgui.push_id("warp_stage_id")
        local changed_stage, stage_value = imgui.drag_float("Stage ID", tonumber(bridge.warp_stage_id) or 0.0, 1.0, 0, 999999, "%.0f")
        imgui.pop_id()
        if changed_stage then
            bridge.warp_stage_id = math.floor((tonumber(stage_value) or 0) + 0.5)
        end

        imgui.push_id("warp_x")
        local changed_x, value_x = imgui.drag_float("X", tonumber(bridge.warp_x) or 0.0, 0.01, -9999, 9999, "%.3f")
        imgui.pop_id()
        if changed_x then
            bridge.warp_x = tonumber(value_x) or bridge.warp_x
        end

        imgui.same_line()
        imgui.push_id("warp_y")
        local changed_y, value_y = imgui.drag_float("Y", tonumber(bridge.warp_y) or 0.0, 0.01, -9999, 9999, "%.3f")
        imgui.pop_id()
        if changed_y then
            bridge.warp_y = tonumber(value_y) or bridge.warp_y
        end

        imgui.same_line()
        imgui.push_id("warp_z")
        local changed_z, value_z = imgui.drag_float("Z", tonumber(bridge.warp_z) or 0.0, 0.01, -9999, 9999, "%.3f")
        imgui.pop_id()
        if changed_z then
            bridge.warp_z = tonumber(value_z) or bridge.warp_z
        end

        if imgui.button("Save Current Point") then
            save_current_warp_point()
        end
    end

    -- ===================================================================
    -- Message Log
    -- A scrollable, in-session history of AP event toasts. Each toast lives
    -- ~4.5s on the HUD then ui_overlay prunes it; this window keeps a durable
    -- copy so a missed toast is recoverable. It is a PASSIVE CONSUMER of the
    -- shared bridge.check_notifications stream: every toast (detector pickups,
    -- apclient received/hint/goal/synced) already lands there with a unique,
    -- ascending id, so we record each event exactly once by an id high-water
    -- mark -- no producer (apclient.lua / detector.lua) is touched.
    -- ===================================================================
    local MESSAGE_LOG_MAX_ENTRIES = 200

    local function message_log_now_ms()
        local now_fn = ctx.now_unix_ms or _G.now_unix_ms
        if type(now_fn) == "function" then
            return now_fn()
        end
        return os.time() * 1000
    end

    -- Copy any not-yet-seen toast out of the ephemeral check_notifications queue
    -- into the durable bridge.message_log ring buffer. Safe to call every frame:
    -- it only appends entries whose id exceeds the high-water mark, so a toast is
    -- captured on the first frame it exists (well before its ~4.5s prune), once.
    local function capture_message_log_entries()
        if type(bridge.check_notifications) ~= "table" then
            return
        end
        if type(bridge.message_log) ~= "table" then
            bridge.message_log = {}
        end
        local log_entries = bridge.message_log
        local high = tonumber(bridge.message_log_last_id) or 0
        local max_id = high
        for _, notification in ipairs(bridge.check_notifications) do
            local id = tonumber(notification.id)
            if id ~= nil and id > high then
                -- Snapshot the fields: the live notification is mutated in place by
                -- the sync-summary coalescer and pruned on expiry, so we copy, not ref.
                log_entries[#log_entries + 1] = {
                    id = id,
                    title = (type(notification.title) == "string") and notification.title or "",
                    detail = (type(notification.detail) == "string" and notification.detail ~= "")
                        and notification.detail
                        or nil,
                    classification = notification.classification,
                    kind = notification.kind,
                    at_unix_ms = tonumber(notification.queued_at_unix_ms) or message_log_now_ms(),
                }
                if id > max_id then
                    max_id = id
                end
            end
        end
        bridge.message_log_last_id = max_id
        -- Bound the buffer: drop the oldest entries beyond the cap.
        local overflow = #log_entries - MESSAGE_LOG_MAX_ENTRIES
        while overflow > 0 do
            table.remove(log_entries, 1)
            overflow = overflow - 1
        end
    end

    local function format_message_log_age(at_unix_ms)
        local at = tonumber(at_unix_ms)
        if at == nil then
            return ""
        end
        local delta_ms = message_log_now_ms() - at
        if delta_ms < 0 then
            delta_ms = 0
        end
        local secs = math.floor(delta_ms / 1000)
        if secs < 5 then
            return "just now"
        end
        if secs < 60 then
            return string.format("%ds ago", secs)
        end
        local mins = math.floor(secs / 60)
        if mins < 60 then
            return string.format("%dm ago", mins)
        end
        return string.format("%dh ago", math.floor(mins / 60))
    end

    -- Durable AP event history (Message Log tab).
    local function draw_message_log_content()
        local log_entries = bridge.message_log or {}
        local count = #log_entries

        imgui.text(string.format("AP Events this session: %d", count))
        imgui.same_line()
        if imgui.button("Clear") then
            -- Keep message_log_last_id so cleared entries are not re-captured.
            bridge.message_log = {}
        end
        imgui.text("")

        if count == 0 then
            imgui.text("No events yet.")
            imgui.text("Checks, received items, hints and goals appear here as they happen.")
        else
            -- Newest first: the reason to open this window is "what did I just miss?".
            for index = count, 1, -1 do
                local entry = log_entries[index]
                if type(entry) == "table" then
                    local prefix = ""
                    if type(get_check_overlay_combined_prefix) == "function" then
                        prefix = get_check_overlay_combined_prefix(entry.kind, entry.classification)
                    end
                    local title_color = CHECK_OVERLAY_TEXT_COLOR_FILLER
                    if type(get_check_overlay_classification_color) == "function" then
                        title_color = get_check_overlay_classification_color(entry.classification)
                    end

                    local applied_title = push_overlay_text_color(title_color)
                    imgui.text(prefix .. tostring(entry.title or ""))
                    pop_overlay_text_color(applied_title)

                    local sub = format_message_log_age(entry.at_unix_ms)
                    if type(entry.detail) == "string" and entry.detail ~= "" then
                        sub = sub .. "  -  " .. entry.detail
                    end
                    local applied_sub = push_overlay_text_color(CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL)
                    imgui.text("    " .. sub)
                    pop_overlay_text_color(applied_sub)
                end
            end
        end
    end

    export("arm_chapter_switch", arm_chapter_switch)
    export("draw_connection_content", draw_connection_content)
    export("draw_status_content", draw_status_content)
    export("draw_probe_content", draw_probe_content)
    export("draw_injection_content", draw_injection_content)
    export("sync_warp_inputs_to_current_state", sync_warp_inputs_to_current_state)
    export("draw_warp_content", draw_warp_content)
    export("draw_warp_editor_content", draw_warp_editor_content)
    export("capture_message_log_entries", capture_message_log_entries)
    export("draw_message_log_content", draw_message_log_content)
end

return install
