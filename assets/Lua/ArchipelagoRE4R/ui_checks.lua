-- [The Checklist] The window's home tab: where are my remaining checks, and
-- which save point gets me closest to them.
--
-- Replaces the old Overview (a status dump of developer telemetry) and
-- absorbs the Warp tab, because "where do I go" and "take me there" are the
-- same question. Typewriter -> region ownership is generated offline
-- (build_typewriter_regions.py) from the authored region order; counts are
-- live from the acknowledged set.
local function install(ctx)
    local bridge = ctx.bridge

    local function export(name, value)
        ctx[name] = value
        _G[name] = value
    end

    local function resolve(name)
        return ctx[name] or _G[name] or function() end
    end

    -- Rows collapse themselves (imgui.tree_node owns that state); we only
    -- track which typewriter was last warped to.
    bridge.checks_selected_stage = bridge.checks_selected_stage or nil

    local function is_unlocked(stage_id)
        local checker = ctx.is_warp_stage_unlocked or _G.is_warp_stage_unlocked
        if type(checker) ~= "function" then
            return true
        end
        local ok, unlocked = pcall(checker, stage_id)
        return ok and unlocked == true
    end

    local function find_warp_point(stage_id)
        for _, warp_point in ipairs(bridge.typewriter_warp_points or {}) do
            if warp_point.stage_id == stage_id then
                return warp_point
            end
        end
        return nil
    end

    local function draw_typewriter_rows()
        local rows = resolve("get_typewriter_progress")()
        if type(rows) ~= "table" or #rows == 0 then
            imgui.text("(check data not loaded - reconnect, or re-patch from the wizard)")
            return
        end

        local grand_found, grand_total = 0, 0
        for _, row in ipairs(rows) do
            grand_found = grand_found + (row.found or 0)
            grand_total = grand_total + (row.total or 0)
        end
        imgui.text(string.format("Checks found: %d / %d", grand_found, grand_total))
        imgui.text("Typewriter warps only unlock after you find them in-game.")
        imgui.text("")

        for _, row in ipairs(rows) do
            local remaining = (row.total or 0) - (row.found or 0)
            local unlocked = is_unlocked(row.stage)
            local label = string.format(
                "%s - %d / %d##ap_tw_%s",
                tostring(row.name),
                row.found or 0,
                row.total or 0,
                tostring(row.stage)
            )

            -- tree_node is available in this REFramework build (checked
            -- against the binary), and keeps the sub-list tight.
            local opened = imgui.tree_node(label)
            if opened then
                for _, region in ipairs(row.regions or {}) do
                    imgui.text(string.format(
                        "    Ch%d  %s  -  %d / %d",
                        region.chapter or 0,
                        tostring(region.section),
                        region.found or 0,
                        region.total or 0
                    ))
                end
                -- The button is always drawn, greyed until the typewriter is
                -- found in game: a row that simply lacks the button reads as
                -- broken, while a disabled one reads as "not yet".
                local disabled = not unlocked
                if disabled and type(imgui.begin_disabled) == "function" then
                    imgui.begin_disabled(true)
                end
                local pressed = imgui.button("Warp Here##ap_tw_warp_" .. tostring(row.stage))
                if disabled and type(imgui.end_disabled) == "function" then
                    imgui.end_disabled()
                end
                if pressed and unlocked then
                    bridge.checks_selected_stage = row.stage
                    local warp_point = find_warp_point(row.stage)
                    local warp_fn = ctx.execute_typewriter_warp or _G.execute_typewriter_warp
                    if warp_point ~= nil and type(warp_fn) == "function" then
                        warp_fn(warp_point)
                    end
                end
                imgui.tree_pop()
            end
        end
    end

    local function draw_checks_content()
        -- No welcome card (that is the tutorial window's job) and no status
        -- strip: chapter, area and connection are already on the HUD header,
        -- and this tab is for the list.
        draw_typewriter_rows()
        imgui.text("")
        imgui.text("Last warp: " .. tostring(bridge.last_warp_status or "(idle)"))
        imgui.text("A check not sending, or finished the run? See the")
        imgui.text("Something's Wrong tab.")
    end

    export("draw_checks_content", draw_checks_content)
end

return install
