local function install(ctx)
    ctx.ui_warning = ctx.ui_warning or {}

    local bridge = ctx.bridge
    local ui_warning = ctx.ui_warning

    local function export(name, value)
        ui_warning[name] = value
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

    local function get_progression_warning_triggered_chapter(stage_id)
        local normalized_stage_id = math.floor(tonumber(stage_id) or 0)
        if normalized_stage_id <= 0 then
            return nil
        end

        for chapter, final_stage_id in pairs(bridge.progression_warning_final_stage_by_chapter or {}) do
            if tonumber(final_stage_id) == normalized_stage_id then
                return tonumber(chapter)
            end
        end

        return nil
    end

    local function should_open_progression_warning_for_stage(chapter, stage_id)
        local normalized_chapter = math.floor(tonumber(chapter) or 0)
        local normalized_stage_id = math.floor(tonumber(stage_id) or 0)
        if normalized_chapter <= 0 or normalized_stage_id <= 0 then
            return false
        end

        if normalized_chapter == 3 and normalized_stage_id == 45500 then
            return bridge.progression_warning_visited_stages["45400"] == true
        end

        return true
    end

    local function maybe_show_progression_warning(previous_state, current_state)
        if type(current_state) ~= "table" or not current_state.is_playable or type(current_state.current_stage) ~= "number" then
            return
        end

        local entered_stage = false
        if type(previous_state) ~= "table" then
            entered_stage = true
        elseif not previous_state.is_playable then
            entered_stage = true
        elseif type(previous_state.current_stage) ~= "number" then
            entered_stage = true
        elseif previous_state.current_stage ~= current_state.current_stage then
            entered_stage = true
        end

        if not entered_stage then
            return
        end

        bridge.progression_warning_visited_stages[tostring(current_state.current_stage)] = true

        local triggered_chapter = get_progression_warning_triggered_chapter(current_state.current_stage)
        if triggered_chapter == nil or bridge.progression_warning_shown_chapters[triggered_chapter] == true then
            return
        end
        if not should_open_progression_warning_for_stage(triggered_chapter, current_state.current_stage) then
            return
        end

        local entries = get_unchecked_progression_locations_for_chapter(triggered_chapter)
        if #entries == 0 then
            -- Loud skip: the playtest question "did it evaluate and find the
            -- chapter clean, or never run?" must be answerable from the log.
            log.info(string.format(
                "[RE4R AP] progression_warning chapter=%s clean at stage=%s - no unchecked progression, dialog skipped",
                tostring(triggered_chapter),
                tostring(current_state.current_stage)
            ))
            return
        end

        bridge.progression_warning_shown_chapters[triggered_chapter] = true
        bridge.progression_warning_dialog = {
            chapter = triggered_chapter,
            final_stage = current_state.current_stage,
            entries = entries,
            created_at_unix_ms = current_unix_ms(),
        }

        log.info(
            string.format(
                "[RE4R AP] progression_warning_opened chapter=%s stage=%s count=%s",
                tostring(triggered_chapter),
                tostring(current_state.current_stage),
                tostring(#entries)
            )
        )
    end

    local function draw_progression_warning_dialog()
        local dialog = bridge.progression_warning_dialog
        if type(dialog) ~= "table" or type(dialog.entries) ~= "table" or #dialog.entries == 0 then
            return
        end

        local state = bridge.last_state or {}
        if not state.is_in_game then
            return
        end

        local dialog_width = 720
        local dialog_height = math.max(240, math.min(460, 190 + (#dialog.entries * 22)))
        local pos_x = 80
        local pos_y = 80

        local ok_display, display_size = pcall(function()
            return imgui.get_display_size()
        end)
        if ok_display and display_size ~= nil then
            pos_x = math.max(40, ((tonumber(display_size.x or 0) - dialog_width) * 0.5))
            pos_y = math.max(40, ((tonumber(display_size.y or 0) - dialog_height) * 0.35))
        end

        imgui.set_next_window_pos(Vector2f.new(pos_x, pos_y), 1)
        imgui.set_next_window_size(Vector2f.new(dialog_width, dialog_height), 1)

        local dialog_visible = imgui.begin_window("Archipelago Progression Warning", true, nil)
        if not dialog_visible then
            bridge.progression_warning_dialog = nil
            imgui.end_window()
            return
        end

        draw_centered_dialog_text(
            string.format(
                "Chapter %s warning: unchecked progression locations remain.",
                tostring(dialog.chapter or "(unknown)")
            ),
            dialog_width
        )
        draw_centered_dialog_text("Continuing may permanently lock out progression items in this chapter.", dialog_width)
        draw_centered_dialog_text("If you want to recover them, go back now before pushing onward.", dialog_width)
        draw_centered_dialog_text("------------------------------------------------------------", dialog_width)
        draw_centered_dialog_text("Unchecked progression locations:", dialog_width)

        for _, entry in ipairs(dialog.entries) do
            draw_centered_dialog_text(
                string.format(
                    "- %s | %s",
                    tostring(entry.item_name or "Unknown item"),
                    tostring(entry.place or entry.stage_name or "")
                ),
                dialog_width
            )
        end

        draw_centered_dialog_text("------------------------------------------------------------", dialog_width)

        draw_centered_dialog_text("Run back or warp to a previous typewriter before proceeding.", dialog_width)

        local proceed_button_label = "Proceed Anyway"
        local go_back_button_label = "Go Back (Use Warp Menu)"
        local button_spacing = 12
        local estimated_row_width = get_imgui_text_width(proceed_button_label)
            + get_imgui_text_width(go_back_button_label)
            + 64
            + button_spacing
        local button_row_window_width = dialog_width
        local ok_button_window_size, button_window_size = pcall(function()
            return imgui.get_window_size()
        end)
        if ok_button_window_size and button_window_size ~= nil then
            button_row_window_width = math.max(200, tonumber(button_window_size.x or 0) or dialog_width)
        end
        local ok_button_cursor, button_cursor_pos = pcall(function()
            return imgui.get_cursor_pos()
        end)
        if ok_button_cursor and button_cursor_pos ~= nil then
            local centered_x = math.max(18, math.floor((button_row_window_width - estimated_row_width) * 0.5))
            pcall(function()
                imgui.set_cursor_pos(Vector2f.new(centered_x, button_cursor_pos.y))
            end)
        end

        if imgui.button(proceed_button_label) then
            log.info(
                string.format(
                    "[RE4R AP] progression_warning_confirmed chapter=%s stage=%s",
                    tostring(dialog.chapter),
                    tostring(dialog.final_stage)
                )
            )
            bridge.progression_warning_dialog = nil
            imgui.end_window()
            return
        end

        imgui.same_line()
        if imgui.button(go_back_button_label) then
            log.info(
                string.format(
                    "[RE4R AP] progression_warning_dismissed chapter=%s stage=%s",
                    tostring(dialog.chapter),
                    tostring(dialog.final_stage)
                )
            )
            bridge.progression_warning_dialog = nil
            imgui.end_window()
            return
        end

        draw_centered_dialog_text("Tip: this does not warp automatically.", dialog_width)
        imgui.end_window()
    end

    -- [Port recovery] archipelago.gg gives a sleeping room's port away, so a
    -- player's recorded address can end up answering a stranger's room or
    -- nothing at all. apclient.lua detects that (RoomInfo seed mismatch,
    -- InvalidSlot, or sustained silence) and parks the details in
    -- bridge.port_recovery_dialog; this dialog is the in-game fix so the player
    -- does not have to alt-tab to the launcher to keep playing.
    --
    -- Deliberately NOT gated on being in-game: the connection matters at the
    -- main menu too, which is exactly where a player sits while wondering why
    -- nothing is connecting.
    local function draw_port_recovery_dialog()
        local dialog = bridge.port_recovery_dialog
        if type(dialog) ~= "table" then
            return
        end

        local dialog_width = 720
        -- Sized to the content (the first cut left half the window empty, which
        -- is most of why it read as unfinished - Cam 2026-07-29). Grows only for
        -- the lines that are conditional.
        local dialog_height = 250
        local room_url = trim_string(dialog.room_url)
        if room_url ~= "" then dialog_height = dialog_height + 22 end
        local ok_ui, drawing_ui = pcall(function() return reframework:is_drawing_ui() end)
        local mouse_captured = ok_ui and not drawing_ui
        if mouse_captured then dialog_height = dialog_height + 22 end
        if trim_string(bridge.port_recovery_status) ~= "" then dialog_height = dialog_height + 22 end

        local pos_x, pos_y = 80, 80
        local ok_display, display_size = pcall(function()
            return imgui.get_display_size()
        end)
        if ok_display and display_size ~= nil then
            pos_x = math.max(40, ((tonumber(display_size.x or 0) - dialog_width) * 0.5))
            pos_y = math.max(40, ((tonumber(display_size.y or 0) - dialog_height) * 0.30))
        end
        imgui.set_next_window_pos(Vector2f.new(pos_x, pos_y), 1)
        imgui.set_next_window_size(Vector2f.new(dialog_width, dialog_height), 1)

        local visible = imgui.begin_window("Archipelago Server Port Mismatch Detected", true, nil)
        if not visible then
            -- The titlebar X is a dismissal too. Just dropping the frame left
            -- the dialog state in place, so the window was back on the next
            -- frame - the same does-nothing bug as the Dismiss button.
            local dismiss = ctx.ap_dismiss_port_recovery or _G.ap_dismiss_port_recovery
            if type(dismiss) == "function" then
                dismiss()
            else
                bridge.port_recovery_dialog = nil
            end
            imgui.end_window()
            return
        end

        -- One centered, coloured line. draw_centered_overlay_segments carries the
        -- drop shadow the plain helper lacks, so text stays legible over the
        -- game's own art, and colour gives the dialog a hierarchy instead of a
        -- wall of identical white text.
        local function line(text, color)
            draw_centered_overlay_segments(
                { { text = tostring(text), color = color or CHECK_OVERLAY_TEXT_COLOR_FILLER } },
                dialog_width)
        end
        local function gap()
            if not pcall(function() imgui.spacing() end) then
                line(" ")
            end
        end
        local function rule()
            if not pcall(function() imgui.separator() end) then
                line("------------------------------------------------------------",
                    CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL)
            end
        end

        gap()
        local kind = tostring(dialog.kind or "")
        if kind == "seed_mismatch" then
            line("This port is serving a DIFFERENT multiworld.", CHECK_OVERLAY_TEXT_COLOR_ERROR)
            line("Your checks would go to the wrong room, so nothing was sent.",
                CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL)
        elseif kind == "invalid_slot" then
            line("The server refused your slot name.", CHECK_OVERLAY_TEXT_COLOR_ERROR)
            line("Usually the room's port changed and another room answered.",
                CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL)
        else
            line("The Archipelago server is not answering.", CHECK_OVERLAY_TEXT_COLOR_PROGRESS)
            line("Rooms sleep when idle, and their port often changes on waking.",
                CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL)
        end

        gap()
        line("Please enter the new port number found on your room page")
        -- The room page itself, when the launcher recorded one: it is the exact
        -- place the current port is written, so it replaces the old made-up
        -- "Example: host:[port]" line (Cam 2026-07-29). Older installs patched
        -- before the launcher carried this field simply show nothing here.
        -- Coloured like a link, though imgui cannot make it clickable.
        if room_url ~= "" then
            line(room_url, CHECK_OVERLAY_TEXT_COLOR_PLAYER)
        end
        line(string.format("Recorded address: %s", tostring(dialog.server or "?")),
            CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL)
        gap()

        -- Everything else in this dialog is centered text, so centre the widgets
        -- too - imgui places controls (and their labels) hard left by default,
        -- which read as a broken layout next to the centered copy (Cam
        -- 2026-07-29). Move the cursor to the row's centre before drawing.
        local function begin_centered_row(row_width)
            local window_width = dialog_width
            local ok_size, size = pcall(function() return imgui.get_window_size() end)
            if ok_size and size ~= nil then
                window_width = math.max(200, tonumber(size.x or 0) or dialog_width)
            end
            local ok_cursor, cursor = pcall(function() return imgui.get_cursor_pos() end)
            if ok_cursor and cursor ~= nil then
                pcall(function()
                    imgui.set_cursor_pos(Vector2f.new(
                        math.max(18, math.floor((window_width - row_width) * 0.5)), cursor.y))
                end)
            end
        end

        line("New port:")

        local field_width = 160
        -- The outcome rides on the button instead of a trailing line (Cam's
        -- layout): the promise belongs where the action is.
        local test_label = "Test Port (window will close if the new port succeeds)"
        local test_width = get_imgui_text_width(test_label) + 28
        begin_centered_row(field_width + 10 + test_width)
        pcall(function() imgui.push_item_width(field_width) end)
        -- "##" id = no imgui label (the centered caption above replaces it).
        local changed_port, port_value = imgui.input_text("##ap_new_port", bridge.port_recovery_input or "")
        pcall(function() imgui.pop_item_width() end)
        if changed_port then
            bridge.port_recovery_input = port_value
        end

        imgui.same_line()
        if imgui.button(test_label) then
            local apply = ctx.ap_apply_port or _G.ap_apply_port
            if type(apply) == "function" then
                apply(bridge.port_recovery_input)
            else
                bridge.port_recovery_status = "Port change unavailable - use the launcher."
            end
        end

        local status = trim_string(bridge.port_recovery_status)
        if status ~= "" then
            -- Amber while a port is being tried, red when the input was rejected.
            local status_color = CHECK_OVERLAY_TEXT_COLOR_PROGRESS
            if string.find(status, "Enter a port", 1, true)
                or string.find(status, "Could not", 1, true)
                or string.find(status, "unavailable", 1, true)
                or string.find(status, "No server", 1, true) then
                status_color = CHECK_OVERLAY_TEXT_COLOR_ERROR
            end
            line(status, status_color)
        end

        -- The game keeps the mouse while its own menus are up, so imgui gets no
        -- clicks until REFramework's overlay is open. Say so, and only while it
        -- is true - the line disappears the moment Insert is pressed.
        if mouse_captured then
            line("Press Insert to free your mouse, then type the port above.",
                CHECK_OVERLAY_TEXT_COLOR_PROGRESS)
        end

        gap()
        rule()
        gap()
        line('Alternatively, boot the RE4R AP Launcher and select "Fix Automatically".',
            CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL)

        local dismiss_label = "Dismiss this message"
        begin_centered_row(get_imgui_text_width(dismiss_label) + 28)
        if imgui.button(dismiss_label) then
            local dismiss = ctx.ap_dismiss_port_recovery or _G.ap_dismiss_port_recovery
            if type(dismiss) == "function" then
                dismiss()
            else
                bridge.port_recovery_dialog = nil
            end
            imgui.end_window()
            return
        end

        imgui.end_window()
    end

    -- Debug-tab preview: run the REAL query and open the dialog for the first
    -- chapter (ascending) that still has unchecked progression locations, so
    -- the UI can be eyeballed with genuine data. Replaces the fake-entry debug
    -- scaffold, which made the dialog lie when a chapter was genuinely clean
    -- (live 2026-07-23: "Debug progression warning test" at a clean chapter 1
    -- boundary). Leaves the once-per-chapter latch untouched, so the organic
    -- warning still fires at the chapter boundary.
    local function preview_progression_warning()
        for chapter = 1, 16 do
            local entries = get_unchecked_progression_locations_for_chapter(chapter)
            if #entries > 0 then
                bridge.progression_warning_dialog = {
                    chapter = chapter,
                    final_stage = nil,
                    entries = entries,
                    created_at_unix_ms = current_unix_ms(),
                }
                return string.format(
                    "chapter %d: %d unchecked progression location(s)",
                    chapter,
                    #entries
                )
            end
        end
        return "all chapters clean - no unchecked progression locations"
    end

    export("get_progression_warning_triggered_chapter", get_progression_warning_triggered_chapter)
    export("maybe_show_progression_warning", maybe_show_progression_warning)
    export("draw_progression_warning_dialog", draw_progression_warning_dialog)
    export("draw_port_recovery_dialog", draw_port_recovery_dialog)
    export("preview_progression_warning", preview_progression_warning)
end

return install
