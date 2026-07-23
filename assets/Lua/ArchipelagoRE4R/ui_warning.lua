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
    export("preview_progression_warning", preview_progression_warning)
end

return install
