-- Consolidated "Archipelago RE4R" window (window consolidation, 2026-07-17).
-- Every former standalone window is a tab here; the HUD overlays (header,
-- toasts, celebration, world markers) and the progression-warning dialog are
-- separate surfaces and unchanged. The Debug tab only exists while the
-- Developer Tools toggle (script UI) is on.
local function install(ctx)
    local bridge = ctx.bridge

    local function export(name, value)
        ctx[name] = value
        _G[name] = value
    end

    -- REFramework builds without the tab API fall back to collapsing headers.
    local has_tab_api = type(imgui.begin_tab_bar) == "function"
        and type(imgui.begin_tab_item) == "function"

    local function draw_tab(label, content)
        if has_tab_api then
            if imgui.begin_tab_item(label) then
                content()
                imgui.end_tab_item()
            end
        else
            if imgui.collapsing_header(label) then
                content()
            end
        end
    end

    local function resolve(name)
        local fn = ctx[name] or _G[name]
        if type(fn) == "function" then
            return fn
        end
        return function() imgui.text("(" .. name .. " unavailable)") end
    end

    -- ===== Actions tab =====
    -- Structured wrappers for the AP text commands that benefit from game
    -- context (design doc section 8): hint pickers with the point economy
    -- visible, goal-gated release/collect, a free Say box, and the Force
    -- Check escape hatch behind an explicit confirm.

    -- Item names resolve through the datapackage, so cache per connection.
    local hint_items_cache = { slot = nil, ids = {}, names = {} }

    local function get_own_item_list()
        local slot = bridge.ap_numeric_slot
        if hint_items_cache.slot == slot and #hint_items_cache.ids > 0 then
            return hint_items_cache.ids, hint_items_cache.names
        end
        local ids_fn = ctx.ap_get_own_item_ids
        local name_fn = ctx.ap_item_name
        local ids, names = {}, {}
        if type(ids_fn) == "function" and type(name_fn) == "function" then
            for _, ap_id in ipairs(ids_fn()) do
                local item_name = name_fn(ap_id, slot)
                if type(item_name) == "string" and item_name ~= "" then
                    ids[#ids + 1] = ap_id
                    names[#names + 1] = item_name
                end
            end
        end
        if #ids > 0 then
            hint_items_cache.slot = slot
            hint_items_cache.ids = ids
            hint_items_cache.names = names
        end
        return ids, names
    end

    -- Unchecked locations in the current stage, nearest first.
    local function build_nearby_location_rows()
        local rows = {}
        local state = bridge.last_state or {}
        if type(state.current_stage) ~= "number" then
            return rows
        end
        local stage_entry = (type(_G.get_stage_watch_entry) == "function")
            and get_stage_watch_entry(state.current_stage) or nil
        if stage_entry == nil or type(stage_entry.guids) ~= "table" then
            return rows
        end
        local pos = nil
        local pos_fn = ctx.get_player_position or _G.get_player_position
        if type(pos_fn) == "function" then
            local ok_pos, value = pcall(pos_fn)
            if ok_pos then pos = value end
        end
        for guid in pairs(stage_entry.guids) do
            local key = make_stage_guid_key(state.current_stage, guid)
            if key ~= nil
                and not bridge.acknowledged_guid_keys[key]
                and not bridge.pending_check_keys[key] then
                local entry = get_location_display_entry(state.current_stage, guid)
                if entry ~= nil and tonumber(entry.location_id) ~= nil then
                    local distance = nil
                    local ex, ey, ez = tonumber(entry.x), tonumber(entry.y), tonumber(entry.z)
                    if pos ~= nil and ex ~= nil and ey ~= nil and ez ~= nil then
                        local dx, dy, dz = ex - pos.x, ey - pos.y, ez - pos.z
                        distance = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
                    end
                    rows[#rows + 1] = { entry = entry, distance = distance }
                end
            end
        end
        table.sort(rows, function(left, right)
            return (left.distance or 1e9) < (right.distance or 1e9)
        end)
        return rows
    end

    local function draw_actions_content()
        local say = ctx.ap_say
        local economy_fn = ctx.ap_get_hint_economy
        local points, cost = nil, nil
        if type(economy_fn) == "function" then
            points, cost = economy_fn()
        end
        imgui.text(string.format(
            "Hint points: %s | Cost per hint: %s",
            tostring(points or "?"), tostring(cost or "?")))

        -- 1) Where is my item?
        imgui.text("")
        imgui.text("-- Hint: where is my item? --")
        local ids, names = get_own_item_list()
        if #ids == 0 then
            imgui.text("(item list unavailable - connect first)")
        else
            local changed_filter, filter_value = imgui.input_text("Filter Items", bridge.actions_hint_filter or "")
            if changed_filter then bridge.actions_hint_filter = filter_value end
            local filter = string.lower(tostring(bridge.actions_hint_filter or ""))
            local labels, label_names = {}, {}
            for index, item_name in ipairs(names) do
                if filter == "" or string.find(string.lower(item_name), filter, 1, true) then
                    labels[#labels + 1] = item_name
                    label_names[#labels] = names[index]
                end
            end
            if #labels == 0 then
                imgui.text("(no items match the filter)")
            else
                local idx = math.max(1, math.min(#labels, math.floor(tonumber(bridge.actions_hint_selected_index) or 1)))
                local changed_sel, sel = imgui.combo("##hint_item_pick", idx, labels)
                if changed_sel then idx = sel end
                bridge.actions_hint_selected_index = idx
                local affordable = (points == nil or cost == nil) or (points >= cost)
                local button_label = affordable and "Buy Hint for Selected Item" or "Not Enough Hint Points"
                if imgui.button(button_label) and affordable and type(say) == "function" then
                    say("!hint " .. tostring(label_names[idx]))
                end
            end
        end

        -- 2) What is at a nearby location? (+ Force Check on the same pick)
        imgui.text("")
        imgui.text("-- Hint: what sits at a nearby location? --")
        local rows = build_nearby_location_rows()
        if #rows == 0 then
            imgui.text("(no unchecked locations in this stage)")
        else
            local loc_labels, loc_ids, loc_names = {}, {}, {}
            for _, row in ipairs(rows) do
                local entry = row.entry
                local label = string.format(
                    "%s - %s%s",
                    tostring(entry.section_name ~= "" and entry.section_name or "?"),
                    tostring(entry.item_name ~= "" and entry.item_name or entry.toast_title or "?"),
                    row.distance ~= nil and string.format(" (%dm)", math.floor(row.distance + 0.5)) or "")
                loc_labels[#loc_labels + 1] = label
                loc_ids[#loc_labels] = tonumber(entry.location_id)
                loc_names[#loc_labels] = tostring(entry.location_name or "")
            end
            local lidx = math.max(1, math.min(#loc_labels, math.floor(tonumber(bridge.actions_location_selected_index) or 1)))
            local changed_lsel, lsel = imgui.combo("##hint_location_pick", lidx, loc_labels)
            if changed_lsel then lidx = lsel end
            bridge.actions_location_selected_index = lidx
            if imgui.button("Buy Hint for Selected Location") and type(say) == "function" then
                if loc_names[lidx] ~= "" then
                    say("!hint_location " .. loc_names[lidx])
                end
            end

            imgui.text("")
            imgui.text("-- Stuck? Force Check (debug) --")
            imgui.text("Only for a BROKEN/unreachable check - this is basically cheating.")
            imgui.text("If something broke, please report it to Metasr on Discord.")
            local changed_announce, announce = imgui.checkbox(
                "Announce force-check in room chat", bridge.force_check_announce ~= false)
            if changed_announce then bridge.force_check_announce = announce end
            if bridge.actions_confirm == "force" then
                imgui.text("Really force-check: " .. tostring(loc_labels[lidx]))
                if imgui.button("Yes, Force Check It") then
                    local force_fn = ctx.ap_force_check
                    if type(force_fn) == "function" and force_fn(loc_ids[lidx]) then
                        if bridge.force_check_announce ~= false and type(say) == "function" then
                            say(string.format("[debug] force-checked %s (suspected broken check)", loc_names[lidx]))
                        end
                    end
                    bridge.actions_confirm = ""
                end
                imgui.same_line()
                if imgui.button("Cancel##force_check") then bridge.actions_confirm = "" end
            else
                if imgui.button("Force Check Selected Location...") then
                    bridge.actions_confirm = "force"
                end
            end
        end

        -- 3) Post-goal commands.
        imgui.text("")
        imgui.text("-- Post-goal --")
        if bridge.victory_sent == true then
            if bridge.actions_confirm == "release" then
                imgui.text("Send every remaining item in your world to its owners?")
                if imgui.button("Yes, Release") then
                    if type(say) == "function" then say("!release") end
                    bridge.actions_confirm = ""
                end
                imgui.same_line()
                if imgui.button("Cancel##release") then bridge.actions_confirm = "" end
            elseif bridge.actions_confirm == "collect" then
                imgui.text("Pull all of your remaining items home?")
                if imgui.button("Yes, Collect") then
                    if type(say) == "function" then say("!collect") end
                    bridge.actions_confirm = ""
                end
                imgui.same_line()
                if imgui.button("Cancel##collect") then bridge.actions_confirm = "" end
            else
                if imgui.button("Release...") then bridge.actions_confirm = "release" end
                imgui.same_line()
                if imgui.button("Collect...") then bridge.actions_confirm = "collect" end
            end
        else
            imgui.text("Release / Collect unlock after you reach your goal.")
        end

        -- 4) Free chat / command box (escape hatch for everything else).
        imgui.text("")
        imgui.text("-- Chat / commands --")
        local changed_say, say_value = imgui.input_text("##actions_say", bridge.actions_say_text or "")
        if changed_say then bridge.actions_say_text = say_value end
        imgui.same_line()
        if imgui.button("Send") then
            local text = tostring(bridge.actions_say_text or "")
            if text ~= "" and type(say) == "function" and say(text) then
                bridge.actions_say_text = ""
            end
        end
        imgui.text("Responses appear as toasts and in the Message Log tab.")
    end

    local function draw_main_window()
        if not bridge.main_window_enabled or not reframework:is_drawing_ui() then
            return
        end

        imgui.set_next_window_size(Vector2f.new(540, 500), 4)
        bridge.main_window_enabled = imgui.begin_window("Archipelago RE4R", bridge.main_window_enabled, nil)

        local tabs_open = (not has_tab_api) or imgui.begin_tab_bar("##ap_main_tabs")
        if tabs_open then
            draw_tab("Overview", function()
                resolve("draw_connection_content")()
                imgui.text("")
                resolve("draw_status_content")()
            end)
            draw_tab("Actions", draw_actions_content)
            draw_tab("Warp", resolve("draw_warp_content"))
            draw_tab("Message Log", resolve("draw_message_log_content"))
            if bridge.developer_tools_enabled then
                draw_tab("Debug", function()
                    resolve("draw_native_log_content")()
                    imgui.text("")
                    imgui.text("DeathLink")
                    imgui.text("  State: " .. tostring(resolve("ap_debug_deathlink_status")()))
                    if imgui.button("Simulate inbound DeathLink death") then
                        bridge.deathlink_debug_last_result =
                            tostring(resolve("ap_debug_simulate_deathlink")())
                    end
                    if bridge.deathlink_debug_last_result ~= nil then
                        imgui.text("  Last: " .. tostring(bridge.deathlink_debug_last_result))
                    end
                    imgui.text("")
                    imgui.text("Progression Warning")
                    if imgui.button("Preview Progression Warning (real data)") then
                        bridge.progression_warning_debug_last_result =
                            tostring(resolve("preview_progression_warning")())
                    end
                    if bridge.progression_warning_debug_last_result ~= nil then
                        imgui.text("  Last: " .. tostring(bridge.progression_warning_debug_last_result))
                    end
                    imgui.text("")
                    imgui.text("World Markers")
                    if imgui.button("Dump World Markers To Log") then
                        bridge.marker_dump_last_result =
                            tostring(resolve("dump_world_markers_to_log")())
                    end
                    if bridge.marker_dump_last_result ~= nil then
                        imgui.text("  Last: " .. tostring(bridge.marker_dump_last_result))
                    end
                    imgui.text("")
                    resolve("draw_probe_content")()
                    imgui.text("")
                    resolve("draw_injection_content")()
                    imgui.text("")
                    resolve("draw_warp_editor_content")()
                end)
            end
            if has_tab_api then
                imgui.end_tab_bar()
            end
        end

        imgui.end_window()
    end

    export("draw_main_window", draw_main_window)
end

return install
