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
    -- Stage-FAMILY aware, via the same shared collector the world markers
    -- draw from (data.lua collect_open_family_locations). The old exact-stage
    -- lookup meant a marker could be visibly showing a check that this list -
    -- and therefore hint-nearby and Force Check - refused to offer, whenever
    -- the check was filed under a neighbouring sub-stage (Cam 2026-07-29).
    local function build_nearby_location_rows()
        local rows = {}
        local state = bridge.last_state or {}
        if type(state.current_stage) ~= "number" then
            return rows
        end
        local collect = ctx.collect_open_family_locations or _G.collect_open_family_locations
        if type(collect) ~= "function" then
            return rows
        end
        local pos = nil
        local pos_fn = ctx.get_player_position or _G.get_player_position
        if type(pos_fn) == "function" then
            local ok_pos, value = pcall(pos_fn)
            if ok_pos then pos = value end
        end
        for _, open_location in ipairs(collect(state.current_stage)) do
            local entry = open_location.entry
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
        table.sort(rows, function(left, right)
            return (left.distance or 1e9) < (right.distance or 1e9)
        end)
        return rows
    end

    -- ===== Hints tab =====
    -- Hint shopping only. Recovery (Force Check) moved to the Checks tab next
    -- to the location it repairs, post-goal commands went with it, and chat
    -- moved to the Message Log where the conversation already is.
    local function draw_hints_content()
        local say = ctx.ap_say
        local economy_fn = ctx.ap_get_hint_economy
        local points, cost = nil, nil
        if type(economy_fn) == "function" then
            points, cost = economy_fn()
        end
        imgui.text("Hints cost points you earn by finding checks. Buying one")
        imgui.text("tells you where an item is - yours, or what sits nearby.")
        imgui.text("")
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
        end

        -- Hints already bought that point at YOUR locations (rescued from the
        -- deleted Overview tab, where no player ever looked for them).
        resolve("draw_hints_on_my_world")()
    end

    -- ===== Recovery (inside the Checks tab) =====
    -- Force Check plus the post-goal commands. Both are "I am finished with
    -- this location / this run" actions, so they belong beside the check
    -- list rather than beside hint shopping.
    local function draw_recovery_content()
        local say = ctx.ap_say
        imgui.text("A check that will not send is a bug - please report it.")
        imgui.text("Force Check marks it done and releases the item it held.")

        local rows = build_nearby_location_rows()
        if #rows == 0 then
            imgui.text("(no unchecked locations near you)")
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
            local changed_lsel, lsel = imgui.combo("##recovery_location_pick", lidx, loc_labels)
            if changed_lsel then lidx = lsel end
            bridge.actions_location_selected_index = lidx

            local changed_announce, announce = imgui.checkbox(
                "Tell the room I did this", bridge.force_check_announce ~= false)
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

        imgui.text("")
        imgui.text("-- Finished the run? --")
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
    end

    -- ===== Debug tab =====
    -- Audience: a tester who was told "open Debug and do X", and us reading
    -- what comes back. Grouped by purpose, with the thing we actually want
    -- pressed - the diagnostics dump - first. The old flat list opened with
    -- fourteen buttons from a finished toast-rail investigation.
    local function build_diagnostics_text()
        local state = bridge.last_state or {}
        -- Connection facts come from the client, not the bridge: the bridge
        -- has no slot/server/seed fields (first draft read fields that never
        -- existed and printed "?" for all three).
        local info_fn = ctx.ap_get_connection_info or _G.ap_get_connection_info
        local details = (type(info_fn) == "function") and info_fn() or {}
        local function value_or(text, fallback)
            local normalized = tostring(text or "")
            if normalized == "" then
                return fallback
            end
            return normalized
        end

        local seed_line = value_or(details.seed, "(unknown)")
        local expected_seed = tostring(details.expected_seed or "")
        if expected_seed ~= "" and tostring(details.seed or "") ~= "" then
            seed_line = seed_line
                .. (expected_seed == tostring(details.seed) and " (matches this session)" or " (MISMATCH vs " .. expected_seed .. ")")
        elseif expected_seed ~= "" then
            seed_line = expected_seed .. " (on record; room not answering)"
        end

        local lines = {
            "RE4R Archipelago diagnostics",
            string.format("mod build: %s", tostring(MOD_VERSION or "?")),
            string.format("slot: %s", value_or(details.slot, "(not connected)")),
            string.format("server: %s", value_or(details.server, "(none)")),
            string.format("seed: %s", seed_line),
            string.format("room page: %s", value_or(details.room_url, "(not recorded)")),
            string.format("connection: %s", tostring(bridge.ap_status_label or bridge.ap_connection_status or "?")),
            string.format("chapter: %s | stage: %s",
                tostring(bridge.ui_current_chapter_display or "?"),
                tostring(state.current_stage or "?")),
            string.format("checks sent this session: %s", tostring(bridge.checks_sent_session or 0)),
            string.format("acknowledged checks: %s", tostring(count_lookup_entries and count_lookup_entries(bridge.acknowledged_guid_keys) or "?")),
            string.format("received watermark: %s", tostring(bridge.last_received_index or "?")),
            string.format("last item received: %s", tostring(bridge.last_item_received or "(none)")),
            string.format("last warp: %s", tostring(bridge.last_warp_status or "(idle)")),
        }
        return table.concat(lines, "\n")
    end

    local function draw_debug_content()
        -- 1) Diagnostics: what a developer asks for in every bug thread.
        imgui.text("Diagnostics")
        imgui.text(build_diagnostics_text())
        if imgui.button("Copy diagnostics to clipboard") then
            local ok = pcall(function() imgui.set_clipboard(build_diagnostics_text()) end)
            bridge.diagnostics_copy_status = ok and "copied - paste it into your bug report" or "copy failed"
        end
        imgui.same_line()
        if imgui.button("Write diagnostics to log") then
            log.info("[RE4R AP] diagnostics\n" .. build_diagnostics_text())
            bridge.diagnostics_copy_status = "written to re2_framework_log.txt"
        end
        if bridge.diagnostics_copy_status ~= nil then
            imgui.text("  " .. tostring(bridge.diagnostics_copy_status))
        end

        -- 2) Pickup probe: what the detector is seeing right now. The first
        -- question on any "my check did not send" report.
        imgui.text("")
        if imgui.collapsing_header("Pickup Probe##ap_debug_probe") then
            resolve("draw_probe_content")()
        end

        -- 3) Recovery: things a developer will ask a tester to run.
        imgui.text("")
        if imgui.collapsing_header("Item Injection##ap_debug_recovery") then
            imgui.text("Grants items outside the multiworld. Only use this when")
            imgui.text("asked to - it can hand you things the seed never placed.")
            resolve("draw_injection_content")()
        end

        -- 3) Simulations: safe to press, nothing permanent.
        imgui.text("")
        if imgui.collapsing_header("Simulations##ap_debug_sim") then
            if imgui.button("Preview the progression warning") then
                bridge.progression_warning_debug_last_result =
                    tostring(resolve("preview_progression_warning")())
            end
            if bridge.progression_warning_debug_last_result ~= nil then
                imgui.text("  " .. tostring(bridge.progression_warning_debug_last_result))
            end
            if imgui.button("Dump world markers to log") then
                bridge.marker_dump_last_result = tostring(resolve("dump_world_markers_to_log")())
            end
            if bridge.marker_dump_last_result ~= nil then
                imgui.text("  " .. tostring(bridge.marker_dump_last_result))
            end
            imgui.text("")
            imgui.text("DeathLink state: " .. tostring(resolve("ap_debug_deathlink_status")()))
            imgui.text("The button below REALLY kills you - it triggers a game over.")
            if imgui.button("Simulate an inbound DeathLink death") then
                bridge.deathlink_debug_last_result = tostring(resolve("ap_debug_simulate_deathlink")())
            end
            if bridge.deathlink_debug_last_result ~= nil then
                imgui.text("  " .. tostring(bridge.deathlink_debug_last_result))
            end
        end

        -- 4) Authoring tools - irrelevant to testers, collapsed.
        imgui.text("")
        if imgui.collapsing_header("Chapter Switch##ap_debug_chapter") then
            resolve("draw_chapter_switch_content")()
        end

        imgui.text("")
        if imgui.collapsing_header("Developer only##ap_debug_dev") then
            resolve("draw_native_log_content")()
            imgui.text("")
            resolve("draw_warp_editor_content")()
        end
    end

    local function draw_main_window()
        if not bridge.main_window_enabled or not reframework:is_drawing_ui() then
            return
        end

        imgui.set_next_window_size(Vector2f.new(540, 500), 4)
        bridge.main_window_enabled = imgui.begin_window("Archipelago RE4R", bridge.main_window_enabled, nil)

        local tabs_open = (not has_tab_api) or imgui.begin_tab_bar("##ap_main_tabs")
        if tabs_open then
            -- Ordered by how often a player needs them. The Checklist is home:
            -- it answers "where do I go next" and warps you there. The old
            -- Overview tab was developer telemetry and is gone; its one
            -- player-facing part (hints on your world) lives in Hints.
            draw_tab("The Checklist", resolve("draw_checks_content"))
            draw_tab("Guidance", resolve("draw_guidance_content"))
            draw_tab("Hints", draw_hints_content)
            -- Recovery earns a tab of its own: buried at the bottom of the
            -- Checklist, the one tool a stuck player needs was the hardest
            -- thing in the window to find (Cam 2026-07-31).
            draw_tab("Something's Wrong", draw_recovery_content)
            draw_tab("Server", resolve("draw_server_content"))
            draw_tab("Message Log", resolve("draw_message_log_content"))
            if bridge.developer_tools_enabled then
                draw_tab("Debug", draw_debug_content)
            end
            if has_tab_api then
                imgui.end_tab_bar()
            end
        end

        imgui.end_window()
    end

    -- The Checks tab hosts recovery under its "Something's wrong" header.
    export("draw_recovery_content", draw_recovery_content)
    export("draw_main_window", draw_main_window)
end

return install
