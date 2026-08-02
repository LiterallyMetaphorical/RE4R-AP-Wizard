-- [Guidance tab] Everything about FINDING checks: the world markers and how
-- much they tell you.
--
-- These controls used to live in REFramework's own script menu, which a new
-- player has no reason to open - the most useful guidance feature in the mod
-- was hidden behind a menu nobody knew about. Only the two bootstrap toggles
-- (show the window, developer tools) stay there now.
local function install(ctx)
    local bridge = ctx.bridge

    local function export(name, value)
        ctx[name] = value
        _G[name] = value
    end

    local function draw_guidance_content()
        imgui.text("Unchecked spots show a floating [AP] marker with the distance.")
        imgui.text("Markers only ever say WHERE - what to look for, and how much")
        imgui.text("detail, is up to you below.")
        imgui.text("")

        -- The YAML ceiling can disable the whole feature for the slot.
        if bridge.check_guidance_ceiling == "off" then
            imgui.text("World markers are turned off for this multiworld by the")
            imgui.text("host's settings (check_guidance: off). Nothing to configure.")
            return
        end

        local changed_markers, markers_value =
            imgui.checkbox("Show check markers", bridge.world_markers_enabled)
        if changed_markers then
            bridge.world_markers_enabled = markers_value
        end

        if bridge.world_markers_enabled then
            local changed_distance, distance_value =
                imgui.slider_float("How far away markers appear", bridge.world_markers_max_distance, 10.0, 100.0, "%.0fm")
            if changed_distance then
                bridge.world_markers_max_distance = distance_value
            end

            -- Detail ladder, capped by the host's YAML ceiling; identify and
            -- developer tiers are spoilers, so they also need Developer Tools.
            local detail_tier_index = { basic = 1, locate = 2, identify = 3, developer = 4 }
            local detail_names = { "basic", "locate", "identify", "developer" }
            local detail_labels = {
                "Basic - distance, height, area",
                "Locate - + what the item looked like in vanilla",
                "Identify - + the real item and who it belongs to (spoiler)",
                "Developer - + the location code from the spoiler log",
            }
            local ceiling_tier = detail_tier_index[bridge.marker_detail_ceiling or "developer"] or 4
            local max_tier = math.min(ceiling_tier, bridge.developer_tools_enabled and 4 or 2)
            local detail_options = {}
            for i = 1, max_tier do detail_options[i] = detail_labels[i] end
            local cur_name = bridge.world_markers_detail
            if type(cur_name) ~= "string" then
                cur_name = (type(WORLD_MARKER_DETAIL) == "string" and WORLD_MARKER_DETAIL) or "basic"
            end
            local cur_tier = math.min(detail_tier_index[cur_name] or 1, max_tier)
            local changed_detail, new_tier = imgui.combo("How much a marker says", cur_tier, detail_options)
            if changed_detail then
                bridge.world_markers_detail = detail_names[new_tier]
            elseif detail_names[cur_tier] ~= cur_name then
                bridge.world_markers_detail = detail_names[cur_tier]
            end
            if ceiling_tier >= 3 and not bridge.developer_tools_enabled then
                imgui.text("    Identify reveals real placements, so it needs Developer Tools.")
            end

            local changed_hide_oc, hide_oc_value =
                imgui.checkbox("Hide markers from other chapters", bridge.world_markers_hide_offchapter == true)
            if changed_hide_oc then
                bridge.world_markers_hide_offchapter = hide_oc_value
            end
            imgui.text("    Some areas are reused between chapters. Markers for a")
            imgui.text("    different chapter are dimmed and tagged [Ch N]; this hides")
            imgui.text("    them completely.")

            if bridge.check_guidance_ceiling == "markers_rarity" then
                local changed_colors, colors_value = imgui.checkbox(
                    "Colour markers by item importance", bridge.world_markers_importance_colors)
                if changed_colors then
                    bridge.world_markers_importance_colors = colors_value
                end
                imgui.text("    Reveals whether each check holds something important.")
            end
        end

        imgui.text("")
        local changed_hint_markers, hint_markers_value =
            imgui.checkbox("Show [HINT] markers", bridge.world_markers_show_hints)
        if changed_hint_markers then
            bridge.world_markers_show_hints = hint_markers_value
        end
        imgui.text("    Locations you bought a hint for, visible anywhere in the area.")

        imgui.text("")
        if imgui.button("Show the getting-started guide again") then
            local replay = ctx.replay_tutorial or _G.replay_tutorial
            if type(replay) == "function" then
                replay()
            end
        end
        if bridge.tutorial_enabled == false then
            imgui.text("    The host's settings turn the first-run guide off for new seeds.")
        end
    end

    export("draw_guidance_content", draw_guidance_content)
end

return install
