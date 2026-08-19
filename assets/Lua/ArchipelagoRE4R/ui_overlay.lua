local function install(ctx)
    ctx.ui_overlay = ctx.ui_overlay or {}

    local bridge = ctx.bridge
    local ui_overlay = ctx.ui_overlay

    local function export(name, value)
        ui_overlay[name] = value
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

    -- Runtime toggle for the developer pickup-probe HUD lines. The Status window
    -- checkbox writes bridge.show_debug_probe_overlay; if it's never been set, fall
    -- back to the config-file default (SHOW_DEBUG_PROBE_OVERLAY).
    local function debug_probe_enabled()
        if bridge ~= nil and bridge.show_debug_probe_overlay ~= nil then
            return bridge.show_debug_probe_overlay == true
        end
        return SHOW_DEBUG_PROBE_OVERLAY == true
    end

    local function build_pickup_probe_item_label(probe)
        if type(probe) ~= "table" then
            return ""
        end

        local stage = tonumber(probe.stage)
        local guid = normalize_guid(probe.guid)
        if stage ~= nil and guid ~= nil then
            local display_entry = get_location_display_entry(stage, guid)
            if type(display_entry) == "table" then
                local item_name = trim_string(display_entry.item_name)
                if item_name ~= "" then
                    return item_name
                end
            end
        end

        local item_id = tonumber(probe.item_id)
        if item_id ~= nil then
            local item_label = ""
            for _, entry in ipairs(injectable_items or {}) do
                if math.floor(tonumber(entry.item_id) or 0) == math.floor(item_id) then
                    item_label = trim_string(entry.label)
                    break
                end
            end
            if item_label == "" then
                item_label = tostring(math.floor(item_id))
            end
            if item_label ~= "" then
                local count = math.max(1, math.floor(tonumber(probe.item_count) or 1))
                if not string.find(string.lower(item_label), " x" .. tostring(count), 1, true) then
                    item_label = string.format("%s x%d", item_label, count)
                end
                return item_label
            end
        end

        return ""
    end

    local function build_pickup_probe_header_text()
        local probe = bridge.pickup_probe
        if type(probe) ~= "table" then
            return nil, nil
        end

        local event_name = trim_string(probe.event_name)
        if event_name == "accept" or event_name == "" then
            return nil, nil
        end

        local item_label = build_pickup_probe_item_label(probe)
        if item_label == "" then
            item_label = "Unknown Item"
        end

        if event_name == "confirmed" and probe.tracked == true and probe.pending ~= true and probe.acknowledged ~= true then
            -- Player-facing pickup line moved to debug-only (Cam 2026-07-13): it
            -- read like dev output ("Pickup Detected ... | FILLER") and duplicated
            -- the check toast. The Status-window "Show pickup probe" toggle (and
            -- the SHOW_DEBUG_PROBE_OVERLAY default) bring it back for debugging.
            if not debug_probe_enabled() then return nil, nil end
            local classification = ""
            local stage = tonumber(probe.stage)
            local guid = normalize_guid(probe.guid)
            if stage ~= nil and guid ~= nil then
                local display_entry = get_location_display_entry(stage, guid)
                if type(display_entry) == "table" then
                    classification = string.upper(trim_string(display_entry.classification))
                end
            end

            local parts = {
                "Pickup Detected - AP Location",
                item_label,
            }
            if classification ~= "" then
                table.insert(parts, classification)
            end
            return table.concat(parts, " | "), get_check_overlay_classification_color(classification)
        end

        if event_name == "confirmed" and probe.tracked == true and probe.pending == true and probe.acknowledged ~= true then
            return "Already Queued | " .. item_label, CHECK_OVERLAY_TEXT_COLOR_FILLER
        end

        if event_name == "confirmed" and probe.tracked == true and probe.acknowledged == true then
            return "Already Checked | " .. item_label, CHECK_OVERLAY_TEXT_COLOR_FILLER
        end

        -- Developer telemetry: a picked-up item the AP dataset doesn't track, or a
        -- path with no accept hook. Hidden from players unless debug_probe_enabled()
        -- (Status-window checkbox / SHOW_DEBUG_PROBE_OVERLAY config default).
        if event_name == "confirmed" and probe.tracked == false then
            if not debug_probe_enabled() then return nil, nil end
            return "Pickup Detected - Not in dataset | " .. item_label, CHECK_OVERLAY_TEXT_COLOR_DETAIL
        end

        if event_name == "commit-only" then
            if not debug_probe_enabled() then return nil, nil end
            return "No accept hook - unknown path | " .. item_label, CHECK_OVERLAY_TEXT_COLOR_DETAIL
        end

        return nil, nil
    end

    local function build_pickup_probe_detail_text()
        local probe = bridge.pickup_probe
        if type(probe) ~= "table" then
            return nil, nil
        end

        local event_name = trim_string(probe.event_name)
        if event_name == "accept" or event_name == "" then
            return nil, nil
        end

        if event_name == "confirmed" and probe.tracked == true and probe.pending ~= true and probe.acknowledged ~= true then
            return nil, nil
        end

        if event_name == "confirmed" and probe.tracked == true and probe.pending == true and probe.acknowledged ~= true then
            local ap_connection_status = trim_string(bridge.ap_connection_status)
            local lower_status = string.lower(ap_connection_status)
            local is_connected = string.find(lower_status, "connected", 1, true) ~= nil
                and string.find(lower_status, "disconnected", 1, true) == nil
            if is_connected then
                return "Queued locally - waiting for AP acknowledgment", CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL
            end
            return "Queued locally - AP server disconnected", CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL
        end

        if event_name == "confirmed" and probe.tracked == true and probe.acknowledged == true then
            return nil, nil
        end

        if event_name == "confirmed" and probe.tracked == false then
            if not debug_probe_enabled() then return nil, nil end
            local guid = normalize_guid(probe.guid)
            local stage_id = math.floor(tonumber(probe.stage) or 0)
            local context_key = trim_string(probe.context_key)
            return string.format(
                "GUID: %s | stage: %s | ctx: %s",
                tostring(guid or ""),
                tostring(stage_id),
                tostring(context_key)
            ), CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL
        end

        if event_name == "commit-only" then
            if not debug_probe_enabled() then return nil, nil end
            local item_id = math.floor(tonumber(probe.item_id) or 0)
            return string.format("item_id: %s", tostring(item_id)), CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL
        end

        return nil, nil
    end

    local function is_ap_connection_active()
        local ap_connection_status = trim_string(bridge.ap_connection_status)
        local lower_status = string.lower(ap_connection_status)
        return string.find(lower_status, "connected", 1, true) ~= nil
            and string.find(lower_status, "disconnected", 1, true) == nil
    end

    local function build_ap_client_overlay_text()
        -- Live in-Lua apclient status (set by apclient.lua set_conn_status). Colour by
        -- kind: connected=green, pending=amber, error=red, idle=grey.
        local kind = trim_string(bridge.ap_status_kind)
        local label = trim_string(bridge.ap_status_label)
        if label == "" then
            return "AP: Starting...", CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL
        end
        local color = CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL
        if kind == "connected" then
            color = CHECK_OVERLAY_TEXT_COLOR_CONNECTED
        elseif kind == "pending" then
            color = CHECK_OVERLAY_TEXT_COLOR_PROGRESS
        elseif kind == "error" then
            color = CHECK_OVERLAY_TEXT_COLOR_ERROR
        end
        return "AP: " .. label, color
    end

    -- display_started_at_unix_ms is the "has this started displaying yet" latch (the
    -- sync-summary coalescer nils it to restart a toast's life). display_started_clock
    -- is a monotonic, sub-second stamp (os.clock()*1000) and is what the lifetime AND
    -- the fade actually measure against: now_unix_ms() is os.time()*1000, i.e. WHOLE
    -- SECONDS, which cannot animate a fade (it made the fade pop). Both are stamped and
    -- cleared together, so the restart path stays correct.
    local function get_active_check_notifications()
        local now_ms = current_unix_ms()
        local now_clock_ms = os.clock() * 1000
        local active = {}
        local kept = {}

        for _, notification in ipairs(bridge.check_notifications) do
            -- [Native rail] Records native_log.lua marked rendered_natively are
            -- shown on the game's own log rail: never draw the imgui toast, and
            -- drop them once the Message Log has captured them (id high-water)
            -- so the durable log still gets every entry. The 30s age fallback
            -- covers a Message Log that never captures. In "overlay" mode the
            -- flag is never set and all of this is inert.
            local is_native = notification.rendered_natively == true
            local record_age_ms = now_ms - (tonumber(notification.queued_at_unix_ms) or now_ms)
            local native_captured = tonumber(notification.id) ~= nil
                and tonumber(notification.id) <= (tonumber(bridge.message_log_last_id) or 0)
            local shown_natively = is_native and (native_captured or record_age_ms > 30000)
            local started_at_unix_ms = tonumber(notification.display_started_at_unix_ms)
            local started_clock_ms = tonumber(notification.display_started_clock)
            local expired = started_at_unix_ms ~= nil
                and started_clock_ms ~= nil
                and (now_clock_ms - started_clock_ms) >= CHECK_NOTIFICATION_DURATION_MS
            if expired or shown_natively then
                -- Drop expired notifications once their on-screen lifetime ends.
            else
                if not is_native and #active < CHECK_NOTIFICATION_MAX_VISIBLE then
                    if started_at_unix_ms == nil then
                        notification.display_started_at_unix_ms = now_ms
                        notification.display_started_clock = now_clock_ms
                    end
                    table.insert(active, notification)
                end
                table.insert(kept, notification)
            end
        end

        bridge.check_notifications = kept
        return active
    end

    local function get_overlay_anchor_x(width)
        local ok, display_size = pcall(function()
            return imgui.get_display_size()
        end)
        if not ok or display_size == nil then
            return CHECK_OVERLAY_MARGIN_X
        end
        return math.max(CHECK_OVERLAY_MARGIN_X, tonumber(display_size.x or 0) - width - CHECK_OVERLAY_MARGIN_X)
    end

    local function set_next_overlay_window_bg_alpha(alpha)
        pcall(function()
            imgui.set_next_window_bg_alpha(alpha)
        end)
    end

    local function push_overlay_text_color(color)
        local rgba = color or CHECK_OVERLAY_TEXT_COLOR_FILLER
        local ok = pcall(function()
            imgui.push_style_color(0, Vector4f.new(rgba[1], rgba[2], rgba[3], rgba[4]))
        end)
        if ok then
            return true
        end

        ok = pcall(function()
            imgui.push_style_color(0, rgba[1], rgba[2], rgba[3], rgba[4])
        end)
        return ok
    end

    local function pop_overlay_text_color(applied)
        if applied then
            pcall(function()
                imgui.pop_style_color(1)
            end)
        end
    end

    -- alpha (0..1, default 1) scales text + shadow opacity so toasts can fade in
    -- and out instead of popping. Colours are {r,g,b,a}; we scale a copy, leaving
    -- fully-opaque callers (the header segments) untouched.
    local function draw_overlay_text(text, color, alpha)
        local rendered_text = tostring(text or "")
        alpha = tonumber(alpha) or 1.0
        local function faded(c)
            c = c or CHECK_OVERLAY_TEXT_COLOR_FILLER
            if alpha >= 0.999 then return c end
            return { c[1], c[2], c[3], (c[4] or 1.0) * alpha }
        end

        local ok_cursor, cursor_pos = pcall(function()
            return imgui.get_cursor_pos()
        end)
        if ok_cursor and cursor_pos ~= nil then
            local ok_shadow_pos = pcall(function()
                imgui.set_cursor_pos(Vector2f.new(cursor_pos.x + 1, cursor_pos.y + 1))
            end)
            if ok_shadow_pos then
                local pushed_shadow = push_overlay_text_color(faded(CHECK_OVERLAY_TEXT_COLOR_SHADOW))
                imgui.text(rendered_text)
                pop_overlay_text_color(pushed_shadow)
                pcall(function()
                    imgui.set_cursor_pos(cursor_pos)
                end)
            end
        end

        local pushed_main = push_overlay_text_color(faded(color))
        imgui.text(rendered_text)
        pop_overlay_text_color(pushed_main)
    end

    local function get_imgui_text_width(text)
        local rendered_text = tostring(text or "")

        local ok_size, text_size = pcall(function()
            return imgui.calc_text_size(rendered_text)
        end)
        if ok_size and text_size ~= nil then
            return tonumber(text_size.x or 0) or 0
        end

        return #rendered_text * 7
    end

    -- [Toast colour-coding] Width of an inline segment row, matching how
    -- draw_overlay_text_segments lays it out: imgui.same_line() inserts ~6px between
    -- items (the same assumption draw_centered_overlay_segments already makes), and
    -- that gap doubles as the word space between segments.
    local function get_overlay_segments_width(segments)
        local total = 0
        for index, segment in ipairs(segments or {}) do
            total = total + get_imgui_text_width(segment.text)
            if index > 1 then
                total = total + 6
            end
        end
        return total
    end

    -- [Toast colour-coding] Draw a row of differently-coloured text segments inline,
    -- each keeping its drop shadow and the toast's fade alpha. Lets a title read as
    -- "Sent <item> to <player>" with the item and the player carrying their own colour.
    local function draw_overlay_text_segments(segments, alpha)
        for index, segment in ipairs(segments or {}) do
            if index > 1 then
                imgui.same_line()
            end
            draw_overlay_text(segment.text, segment.color, alpha)
        end
    end

    local function draw_centered_dialog_text(text, fallback_window_width)
        local rendered_text = tostring(text or "")
        local window_width = math.max(200, tonumber(fallback_window_width) or 720)

        local ok_window_size, window_size = pcall(function()
            return imgui.get_window_size()
        end)
        if ok_window_size and window_size ~= nil then
            window_width = math.max(200, tonumber(window_size.x or 0) or window_width)
        end

        local ok_cursor, cursor_pos = pcall(function()
            return imgui.get_cursor_pos()
        end)
        if ok_cursor and cursor_pos ~= nil then
            local text_width = get_imgui_text_width(rendered_text)
            local centered_x = math.max(18, math.floor((window_width - text_width) * 0.5))
            pcall(function()
                imgui.set_cursor_pos(Vector2f.new(centered_x, cursor_pos.y))
            end)
        end

        imgui.text(rendered_text)
    end

    local function push_overlay_window_transparent_style()
        local applied = 0
        local colors = {
            { 2, { 0.0, 0.0, 0.0, 0.0 } },
            { 5, { 0.0, 0.0, 0.0, 0.0 } },
            { 6, { 0.0, 0.0, 0.0, 0.0 } },
        }

        for _, entry in ipairs(colors) do
            local index = entry[1]
            local rgba = entry[2]
            local ok = pcall(function()
                imgui.push_style_color(index, Vector4f.new(rgba[1], rgba[2], rgba[3], rgba[4]))
            end)
            if not ok then
                ok = pcall(function()
                    imgui.push_style_color(index, rgba[1], rgba[2], rgba[3], rgba[4])
                end)
            end
            if ok then
                applied = applied + 1
            end
        end

        return applied
    end

    local function pop_overlay_window_transparent_style(applied)
        local count = math.max(0, math.floor(tonumber(applied) or 0))
        if count > 0 then
            pcall(function()
                imgui.pop_style_color(count)
            end)
        end
    end

    local function draw_centered_overlay_segments(segments, fallback_window_width)
        local window_width = math.max(200, tonumber(fallback_window_width) or CHECK_OVERLAY_HEADER_WIDTH)

        local ok_window_size, window_size = pcall(function()
            return imgui.get_window_size()
        end)
        if ok_window_size and window_size ~= nil then
            window_width = math.max(200, tonumber(window_size.x or 0) or window_width)
        end

        local total_width = 0
        for index, segment in ipairs(segments or {}) do
            total_width = total_width + get_imgui_text_width(segment.text)
            if index > 1 then
                total_width = total_width + 6
            end
        end

        local ok_cursor, cursor_pos = pcall(function()
            return imgui.get_cursor_pos()
        end)
        if ok_cursor and cursor_pos ~= nil then
            local centered_x = math.max(18, math.floor((window_width - total_width) * 0.5))
            pcall(function()
                imgui.set_cursor_pos(Vector2f.new(centered_x, cursor_pos.y))
            end)
        end

        for index, segment in ipairs(segments or {}) do
            if index > 1 then
                imgui.same_line()
            end
            draw_overlay_text(segment.text, segment.color)
        end
    end

    local function get_check_overlay_header_display_height(stage)
        local line_count = 1
        local ap_client_text = build_ap_client_overlay_text()
        if ap_client_text ~= nil then
            line_count = line_count + 1
        end
        if type(stage) == "number" and get_stage_has_unchecked_progression(stage) then
            line_count = line_count + 1
        end
        local pickup_probe_header_text = build_pickup_probe_header_text()
        local pickup_probe_detail_text = build_pickup_probe_detail_text()
        if pickup_probe_header_text ~= nil then
            line_count = line_count + 1
        end
        if pickup_probe_detail_text ~= nil then
            line_count = line_count + 1
        end
        return CHECK_OVERLAY_HEADER_HEIGHT + ((line_count - 1) * CHECK_OVERLAY_HEADER_MAIN_Y_OFFSET)
    end

    -- Player-position -> section resolution is throttled: native transform reads
    -- and the label scan run at most every 0.25s, not per frame.
    local current_section_cache = {
        checked_at = -math.huge,
        stage = nil,
        section = nil,
    }

    local function get_current_section(stage)
        local now = os.clock()
        if now - current_section_cache.checked_at < 0.25 and current_section_cache.stage == stage then
            return current_section_cache.section
        end

        current_section_cache.checked_at = now
        current_section_cache.stage = stage
        current_section_cache.section = nil

        local chapter_number = resolve_chapter_for_ui(stage)
        local position_getter = ctx.get_player_position or _G.get_player_position
        if type(position_getter) == "function" then
            local ok_position, position = pcall(position_getter)
            if ok_position and position ~= nil then
                current_section_cache.section = get_section_for_position(
                    stage,
                    chapter_number,
                    position.x,
                    position.z
                )
            end
        end

        -- No position (menus, transitions): fall back to the zone name so the
        -- header still shows a place word instead of going blank.
        if current_section_cache.section == nil then
            current_section_cache.section = get_zone_name(stage, chapter_number)
        end
        return current_section_cache.section
    end

    local function draw_check_progress_overlay()
        local get_merc_info = ctx.get_current_merc_play_info or _G.get_current_merc_play_info
        local merc_info = (type(get_merc_info) == "function") and get_merc_info() or nil

        if merc_info ~= nil and merc_info.stage_idx >= 0 then
            local header_text = string.format(
                "The Mercenaries | %s - %s | %d/%d Checked",
                merc_info.stage_name,
                merc_info.char_name,
                merc_info.done,
                merc_info.total
            )
            local ranks_text = merc_info.ranks_str
            local ap_client_text, ap_client_color = build_ap_client_overlay_text()

            local header_line_count = 1 + ((ranks_text ~= nil and ranks_text ~= "") and 1 or 0) + (ap_client_text ~= nil and 1 or 0)
            local header_display_height = (CHECK_OVERLAY_PADDING_Y * 2)
                + (header_line_count * CHECK_OVERLAY_LINE_HEIGHT)
                + ((header_line_count - 1) * CHECK_OVERLAY_ITEM_SPACING_Y)

            local header_window_width = math.max(
                CHECK_OVERLAY_HEADER_MIN_WIDTH,
                get_imgui_text_width(header_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2),
                (ranks_text ~= nil and ranks_text ~= "") and (get_imgui_text_width(ranks_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2)) or 0,
                ap_client_text ~= nil and (get_imgui_text_width(ap_client_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2)) or 0
            )

            imgui.set_next_window_pos(
                Vector2f.new(get_overlay_anchor_x(header_window_width), CHECK_OVERLAY_MARGIN_Y),
                1
            )
            imgui.set_next_window_size(
                Vector2f.new(header_window_width, header_display_height),
                1
            )
            set_next_overlay_window_bg_alpha(0.0)
            local overlay_style_count = push_overlay_window_transparent_style()
            imgui.begin_window("##re4r_check_progress_overlay", true, CHECK_OVERLAY_WINDOW_FLAGS)

            draw_centered_overlay_segments(
                {
                    { text = header_text, color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
                },
                header_window_width
            )

            if ranks_text ~= nil and ranks_text ~= "" then
                draw_centered_overlay_segments(
                    {
                        { text = ranks_text, color = CHECK_OVERLAY_TEXT_COLOR_PROGRESS },
                    },
                    header_window_width
                )
            end

            if ap_client_text ~= nil then
                draw_centered_overlay_segments(
                    {
                        { text = ap_client_text, color = ap_client_color },
                    },
                    header_window_width
                )
            end

            imgui.end_window()
            pop_overlay_window_transparent_style(overlay_style_count)
            return
        end

        local state = bridge.last_state or {}
        if not state.is_playable or type(state.current_stage) ~= "number" then
            return
        end

        local chapter_display = tostring(bridge.ui_current_chapter_display or "(unknown)")


        -- Header: Chapter | <pause-map area name> | <section-scoped checks>.
        -- Stages are internal streaming units and never player-facing (see
        -- PLAYER_GUIDANCE_DESIGN.md); the section is the same place name the
        -- player reads on the in-game map, and the count always describes
        -- exactly the place printed next to it.
        local section_name = get_current_section(state.current_stage)
        local header_text
        if section_name ~= nil and section_name ~= "" then
            local checked_count, total_count = get_section_progress(section_name)
            local progress_text
            if total_count > 0 and checked_count >= total_count then
                progress_text = string.format("All %d Checked", total_count)
            elseif total_count > 0 then
                progress_text = string.format("%d/%d Checked", checked_count, total_count)
            else
                progress_text = "No Checks Here"
            end
            header_text = string.format(
                "Chapter %s | %s | %s",
                chapter_display,
                section_name,
                progress_text
            )
        else
            -- No section resolved (no labels loaded / unknown scene): stage-scoped
            -- counts with honest "nearby" wording, stage id kept out of the UI.
            local checked_count, total_count = get_stage_progress(state.current_stage)
            local progress_text = string.format("%d/%d Checked Nearby", checked_count, total_count)
            if total_count > 0 and checked_count >= total_count then
                progress_text = string.format("All %d Nearby Checked", total_count)
            end
            header_text = string.format(
                "Chapter %s | %s",
                chapter_display,
                progress_text
            )
        end
        local ap_client_text, ap_client_color = build_ap_client_overlay_text()
        local progression_text = nil
        if get_stage_has_unchecked_progression(state.current_stage) then
            progression_text = "Progression Item Nearby"
        end
        local pickup_probe_text, pickup_probe_color = build_pickup_probe_header_text()
        local pickup_probe_detail_text, pickup_probe_detail_color = build_pickup_probe_detail_text()
        local header_display_height = get_check_overlay_header_display_height(state.current_stage)
        local header_window_width = math.max(
            CHECK_OVERLAY_HEADER_MIN_WIDTH,
            get_imgui_text_width(header_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2),
            ap_client_text ~= nil and (get_imgui_text_width(ap_client_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2)) or 0,
            progression_text ~= nil and (get_imgui_text_width(progression_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2)) or 0,
            pickup_probe_text ~= nil and (get_imgui_text_width(pickup_probe_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2)) or 0,
            pickup_probe_detail_text ~= nil
                    and (get_imgui_text_width(pickup_probe_detail_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2))
                    or 0
        )

        imgui.set_next_window_pos(
            Vector2f.new(get_overlay_anchor_x(header_window_width), CHECK_OVERLAY_MARGIN_Y),
            1
        )
        imgui.set_next_window_size(
            Vector2f.new(header_window_width, header_display_height),
            1
        )
        set_next_overlay_window_bg_alpha(0.0)
        local overlay_style_count = push_overlay_window_transparent_style()
        imgui.begin_window("##re4r_check_progress_overlay", true, CHECK_OVERLAY_WINDOW_FLAGS)

        draw_centered_overlay_segments(
            {
                { text = header_text, color = CHECK_OVERLAY_TEXT_COLOR_FILLER },
            },
            header_window_width
        )

        if ap_client_text ~= nil then
            draw_centered_overlay_segments(
                {
                    { text = ap_client_text, color = ap_client_color },
                },
                header_window_width
            )
        end

        if progression_text ~= nil then
            draw_centered_overlay_segments(
                {
                    { text = progression_text, color = CHECK_OVERLAY_TEXT_COLOR_PROGRESS },
                },
                header_window_width
            )
        end

        if pickup_probe_text ~= nil then
            draw_centered_overlay_segments(
                {
                    { text = pickup_probe_text, color = pickup_probe_color },
                },
                header_window_width
            )
        end

        if pickup_probe_detail_text ~= nil then
            draw_centered_overlay_segments(
                {
                    { text = pickup_probe_detail_text, color = pickup_probe_detail_color },
                },
                header_window_width
            )
        end

        imgui.end_window()
        pop_overlay_window_transparent_style(overlay_style_count)
    end

    -- [Menu status] The full header needs a loaded stage (chapter, area, check
    -- counts), so outside gameplay it draws nothing - which left the menus with
    -- no sign of whether Archipelago was even connected. This is the same
    -- AP status line on its own, shown exactly when the header is not: at the
    -- title screen, in menus, during loads (Cam's ask 2026-07-29, alongside the
    -- port recovery dialog - a player staring at a menu is precisely who needs
    -- to know the server is unreachable).
    local function draw_ap_status_menu_overlay()
        local state = bridge.last_state or {}
        if state.is_playable and type(state.current_stage) == "number" then
            return -- the in-game header already carries this line
        end

        local ap_client_text, ap_client_color = build_ap_client_overlay_text()
        if ap_client_text == nil then
            return
        end

        local window_width = math.max(
            CHECK_OVERLAY_HEADER_MIN_WIDTH,
            get_imgui_text_width(ap_client_text) + (CHECK_OVERLAY_HEADER_PADDING_X * 2))
        local window_height = CHECK_OVERLAY_HEADER_HEIGHT

        imgui.set_next_window_pos(
            Vector2f.new(get_overlay_anchor_x(window_width), CHECK_OVERLAY_MARGIN_Y), 1)
        imgui.set_next_window_size(Vector2f.new(window_width, window_height), 1)
        set_next_overlay_window_bg_alpha(0.0)
        local overlay_style_count = push_overlay_window_transparent_style()
        imgui.begin_window("##re4r_ap_status_menu_overlay", true, CHECK_OVERLAY_WINDOW_FLAGS)
        draw_centered_overlay_segments(
            { { text = ap_client_text, color = ap_client_color } },
            window_width)
        imgui.end_window()
        pop_overlay_window_transparent_style(overlay_style_count)
    end

    local function draw_check_notification_overlays_polished()
        local state = bridge.last_state or {}
        if not state.is_playable or type(state.current_stage) ~= "number" then
            return
        end

        local notifications = get_active_check_notifications()
        if #notifications == 0 then
            return
        end

        -- Fade toasts in/out instead of popping (feel polish): alpha ramps 0->1 over
        -- the first FADE_IN_MS and 1->0 over the final FADE_OUT_MS of each toast's life.
        -- Measured against display_started_clock (monotonic, sub-second). The old code
        -- used now_unix_ms(), which is os.time()*1000 -- whole seconds -- so the alpha
        -- only moved once per second and the "fade" visibly stepped/popped.
        local now_clock_ms = os.clock() * 1000
        local FADE_IN_MS = 220
        local FADE_OUT_MS = 650
        local life_ms = tonumber(CHECK_NOTIFICATION_DURATION_MS) or 4500

        local base_y = CHECK_OVERLAY_MARGIN_Y + get_check_overlay_header_display_height(state.current_stage) + CHECK_OVERLAY_GAP_Y

        for index, notification in ipairs(notifications) do
            local toast_alpha = 1.0
            local fade_started = tonumber(notification.display_started_clock)
            if fade_started ~= nil then
                local fade_age = now_clock_ms - fade_started
                if fade_age < FADE_IN_MS then toast_alpha = fade_age / FADE_IN_MS end
                local fade_remaining = life_ms - fade_age
                if fade_remaining < FADE_OUT_MS then
                    toast_alpha = math.min(toast_alpha, math.max(0, fade_remaining) / FADE_OUT_MS)
                end
                toast_alpha = math.max(0, math.min(1, toast_alpha))
            end
            -- Two-axis prefix: event KIND glyph (received/sent/hint/goal/death) +
            -- importance glyph (star/circle/dot), so both what-happened and how-
            -- important read without relying on colour. Shared with the Message Log
            -- via get_check_overlay_combined_prefix. Applied to the display copy only;
            -- notification.title stays raw for the branch below.
            -- Build the title as coloured SEGMENTS: the prefix glyphs first, then either
            -- the notification's own title_segments (item / player each carrying their
            -- own colour) or the plain title. notification.title stays the plain-text
            -- form for the Message Log and the Already-Checked compare below.
            local title_color = get_check_overlay_classification_color(notification.classification)
            local title_segments = {}
            if type(get_check_overlay_combined_prefix) == "function" then
                local prefix = trim_string(
                    get_check_overlay_combined_prefix(notification.kind, notification.classification))
                if prefix ~= "" then
                    title_segments[#title_segments + 1] = { text = prefix, color = title_color }
                end
            end
            if type(notification.title_segments) == "table" and #notification.title_segments > 0 then
                for _, segment in ipairs(notification.title_segments) do
                    title_segments[#title_segments + 1] = {
                        text = tostring(segment.text or ""),
                        color = segment.color or title_color,
                    }
                end
            else
                title_segments[#title_segments + 1] = {
                    text = tostring(notification.title or "Location Checked"),
                    color = title_color,
                }
            end
            local detail_text = nil
            local detail_color = CHECK_OVERLAY_TEXT_COLOR_DETAIL
            local notification_title = trim_string(notification.title)
            if notification_title == "Already Checked" then
                detail_text = "  " .. tostring(notification.detail or "Already sent to AP server")
            elseif is_ap_connection_active() then
                detail_text = nil
            else
                detail_text = "  AP server disconnected - check queued locally"
                detail_color = CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL
            end
            local toast_window_width = math.max(
                CHECK_OVERLAY_TOAST_MIN_WIDTH,
                get_overlay_segments_width(title_segments) + (CHECK_OVERLAY_TOAST_PADDING_X * 2),
                detail_text ~= nil and (get_imgui_text_width(detail_text) + (CHECK_OVERLAY_TOAST_PADDING_X * 2)) or 0
            )
            local offset_y = base_y + ((index - 1) * (CHECK_OVERLAY_TOAST_HEIGHT + CHECK_OVERLAY_GAP_Y))
            imgui.set_next_window_pos(Vector2f.new(get_overlay_anchor_x(toast_window_width), offset_y), 1)
            imgui.set_next_window_size(Vector2f.new(toast_window_width, CHECK_OVERLAY_TOAST_HEIGHT), 1)
            set_next_overlay_window_bg_alpha(0.0)
            local overlay_style_count = push_overlay_window_transparent_style()
            imgui.begin_window(
                string.format("##re4r_check_notification_polished_%d", notification.id),
                true,
                CHECK_OVERLAY_WINDOW_FLAGS
            )
            draw_overlay_text_segments(title_segments, toast_alpha)
            if detail_text ~= nil then
                draw_overlay_text(
                    detail_text,
                    detail_color,
                    toast_alpha
                )
            end
            imgui.end_window()
            pop_overlay_window_transparent_style(overlay_style_count)
        end
    end

    -- [Celebration] A centre-screen banner for the loudest moments. Fires ONLY for the
    -- goal right now -- once per seed -- so it can be as loud as we like without ever
    -- becoming noise. Every tunable lives in config.lua (CELEBRATION_*), which exports
    -- them as globals. ASCII only: the imgui font has no Unicode coverage.

    -- The caller supplies the words; the renderer owns the presentation (banner rules,
    -- colours, size, timing), so copy changes never touch layout.
    local function trigger_celebration(title, details)
        bridge.celebration = {
            title = tostring(title or ""),
            details = (type(details) == "table") and details or {},
            started_clock_ms = os.clock() * 1000,
        }
    end

    local function draw_centered_celebration_line(text, color, alpha)
        local window_width = 600
        local ok_size, window_size = pcall(function() return imgui.get_window_size() end)
        if ok_size and window_size ~= nil then
            window_width = tonumber(window_size.x) or window_width
        end
        local text_width = get_imgui_text_width(text)
        local ok_cursor, cursor_pos = pcall(function() return imgui.get_cursor_pos() end)
        if ok_cursor and cursor_pos ~= nil then
            pcall(function()
                imgui.set_cursor_pos(Vector2f.new(
                    math.max(4, math.floor((window_width - text_width) * 0.5)), cursor_pos.y))
            end)
        end
        draw_overlay_text(text, color, alpha)
    end

    local function draw_celebration_overlay()
        local celebration = bridge.celebration
        if type(celebration) ~= "table" then return end
        local started_clock_ms = tonumber(celebration.started_clock_ms)
        if started_clock_ms == nil then
            bridge.celebration = nil
            return
        end

        local life_ms = tonumber(CELEBRATION_DURATION_MS) or 9000
        local fade_in_ms = tonumber(CELEBRATION_FADE_IN_MS) or 400
        local fade_out_ms = tonumber(CELEBRATION_FADE_OUT_MS) or 1400

        local age_ms = (os.clock() * 1000) - started_clock_ms
        if age_ms >= life_ms then
            bridge.celebration = nil
            return
        end

        local alpha = 1.0
        if age_ms < fade_in_ms then
            alpha = age_ms / fade_in_ms
        end
        local remaining_ms = life_ms - age_ms
        if remaining_ms < fade_out_ms then
            alpha = math.min(alpha, remaining_ms / fade_out_ms)
        end
        -- Slow alpha "breathe" so it lives instead of sitting flat (period 0 disables).
        local pulse_period_ms = tonumber(CELEBRATION_PULSE_PERIOD_MS) or 0
        if pulse_period_ms > 0 then
            alpha = alpha * (0.90 + (0.10 * math.sin((age_ms / pulse_period_ms) * 2 * math.pi)))
        end
        alpha = math.max(0, math.min(1, alpha))

        local display_width, display_height = 1920, 1080
        local ok_display, display_size = pcall(function() return imgui.get_display_size() end)
        if ok_display and display_size ~= nil then
            display_width = tonumber(display_size.x) or display_width
            display_height = tonumber(display_size.y) or display_height
        end

        -- Generous transparent window: oversizing costs nothing and avoids needing
        -- post-font-scale text metrics before begin_window.
        local font_scale = tonumber(CELEBRATION_FONT_SCALE) or 1.6
        local line_height = tonumber(CELEBRATION_LINE_HEIGHT) or 30
        local line_count = 3 + #celebration.details
        local window_width = math.min(
            math.floor(display_width * 0.9),
            math.floor(tonumber(CELEBRATION_WIDTH) or 720)
        )
        local window_height = math.floor((line_count * line_height * font_scale) + 60)
        imgui.set_next_window_pos(
            Vector2f.new(
                math.floor((display_width - window_width) * 0.5),
                math.floor(display_height * 0.30)
            ), 1)
        imgui.set_next_window_size(Vector2f.new(window_width, window_height), 1)
        set_next_overlay_window_bg_alpha(0.0)
        local overlay_style_count = push_overlay_window_transparent_style()
        imgui.begin_window("##re4r_celebration", true, CHECK_OVERLAY_WINDOW_FLAGS)

        -- Bigger text where the build exposes it. imgui's SetWindowFontScale updates the
        -- current font size immediately, so calc_text_size (and therefore our centring)
        -- reflects the scale. If the binding lacks it, this pcall no-ops and everything
        -- still renders correctly, just at normal size.
        local scaled = pcall(function() imgui.set_window_font_scale(font_scale) end)

        local gold = CELEBRATION_TEXT_COLOR or CHECK_OVERLAY_TEXT_COLOR_PROGRESS
        local banner = CELEBRATION_BANNER or "* * * * * * * * * * * * * * * *"
        draw_centered_celebration_line(banner, gold, alpha)
        draw_centered_celebration_line(celebration.title, gold, alpha)
        draw_centered_celebration_line(banner, gold, alpha)
        for _, detail in ipairs(celebration.details) do
            draw_centered_celebration_line(tostring(detail), CHECK_OVERLAY_TEXT_COLOR_FILLER, alpha)
        end

        if scaled then pcall(function() imgui.set_window_font_scale(1.0) end) end
        imgui.end_window()
        pop_overlay_window_transparent_style(overlay_style_count)
    end

    export("get_current_section", get_current_section)
    export("get_overlay_anchor_x", get_overlay_anchor_x)
    export("set_next_overlay_window_bg_alpha", set_next_overlay_window_bg_alpha)
    export("push_overlay_text_color", push_overlay_text_color)
    export("pop_overlay_text_color", pop_overlay_text_color)
    export("draw_overlay_text", draw_overlay_text)
    export("get_imgui_text_width", get_imgui_text_width)
    export("draw_centered_dialog_text", draw_centered_dialog_text)
    export("push_overlay_window_transparent_style", push_overlay_window_transparent_style)
    export("pop_overlay_window_transparent_style", pop_overlay_window_transparent_style)
    export("draw_centered_overlay_segments", draw_centered_overlay_segments)
    export("draw_overlay_text_segments", draw_overlay_text_segments)
    export("get_overlay_segments_width", get_overlay_segments_width)
    export("build_pickup_probe_item_label", build_pickup_probe_item_label)
    export("build_pickup_probe_header_text", build_pickup_probe_header_text)
    export("build_pickup_probe_detail_text", build_pickup_probe_detail_text)
    export("get_active_check_notifications", get_active_check_notifications)
    export("get_check_overlay_header_display_height", get_check_overlay_header_display_height)
    export("draw_check_progress_overlay", draw_check_progress_overlay)
    export("draw_ap_status_menu_overlay", draw_ap_status_menu_overlay)
    export("draw_check_notification_overlays_polished", draw_check_notification_overlays_polished)
    export("trigger_celebration", trigger_celebration)
    export("draw_celebration_overlay", draw_celebration_overlay)
end

return install
