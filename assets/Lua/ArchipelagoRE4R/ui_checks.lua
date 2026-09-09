-- [The Checklist] The window's home tab: where are my remaining checks, and
-- which save point gets me closest to them.
--
-- One section per kind of content the room includes - Main Campaign,
-- Merchant, Mercenaries, Separate Ways (coming soon) - each a collapsing bar
-- with its own count, and side-by-side columns inside so the tab stops being
-- one long list. Typewriter -> region ownership is generated offline
-- (build_typewriter_regions.py) from the authored region order; counts are
-- live from the acknowledged set. Merchant rows come from merchant.lua and
-- trade.lua (the room file plus the local per-seed bought state), the
-- Mercenaries tree from mercenaries.lua.
--
-- Every layout extra (tables, rounding, colours, progress bars) is guarded:
-- a REFramework build without one of them still draws the plain list.
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

    -- ------------------------------------------------------------ imgui bits
    local function has(name)
        return type(imgui[name]) == "function"
    end

    -- ImU32 colours are 0xAABBGGRR.
    local ACCENT = 0xFFFFA050   -- light blue, section titles
    local MUTED = 0xFF9A9A9A    -- grey, not yet / coming soon
    local DONE = 0xFF7FD67F     -- green, bought or found
    local WHITE = 0xFFFFFFFF

    -- ImGuiStyleVar_FrameRounding / ChildRounding / GrabRounding.
    local ROUNDING = { { 12, 6.0 }, { 7, 6.0 }, { 21, 6.0 } }
    -- ImGuiTableFlags_BordersInnerV | ImGuiTableFlags_SizingStretchSame.
    local TABLE_FLAGS = 512 + 32768
    -- ImGuiCond_Once: sections start open, and remember what the player did.

    local function push_rounding()
        local pushed = 0
        if not has("push_style_var") then
            return pushed
        end
        for _, entry in ipairs(ROUNDING) do
            if pcall(imgui.push_style_var, entry[1], entry[2]) then
                pushed = pushed + 1
            end
        end
        return pushed
    end

    local function pop_rounding(pushed)
        if pushed > 0 and has("pop_style_var") then
            pcall(imgui.pop_style_var, pushed)
        end
    end

    local function colored(text, color)
        if has("text_colored") and pcall(imgui.text_colored, text, color) then
            return
        end
        imgui.text(text)
    end

    local function progress(found, total, label)
        if total <= 0 then
            return
        end
        local fraction = math.max(0, math.min(1, found / total))
        if has("progress_bar") and pcall(imgui.progress_bar, fraction, Vector2f.new(-1, 0), label) then
            return
        end
        imgui.text(label)
    end

    -- Side-by-side cells. Returns a handle for next_column/end_columns, or
    -- nil when the build has no tables (everything then flows in one column).
    local function begin_columns(id, count)
        if not has("begin_table") then
            return nil
        end
        local ok, opened = pcall(imgui.begin_table, id, count, TABLE_FLAGS, Vector2f.new(0, 0), 0.0)
        if ok and opened then
            return true
        end
        ok, opened = pcall(imgui.begin_table, id, count, TABLE_FLAGS)
        if ok and opened then
            return true
        end
        return nil
    end

    local function next_column(handle)
        if handle then
            pcall(imgui.table_next_column)
        end
    end

    local function end_columns(handle)
        if handle then
            pcall(imgui.end_table)
        end
    end

    -- Sections start collapsed (Cam, 2026-09-05); imgui remembers what the
    -- player opens for the rest of the session.
    local function section(title, id, count_text)
        local label = title
        if count_text ~= nil and count_text ~= "" then
            label = string.format("%s   %s", title, count_text)
        end
        return imgui.collapsing_header(label .. "##ap_ck_" .. id)
    end

    local function separator()
        if has("separator") then
            pcall(imgui.separator)
        else
            imgui.text("----------------------------------------")
        end
    end

    -- ----------------------------------------------------------- campaign
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

    local function draw_typewriter_row(row)
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
                local done = (region.found or 0) >= (region.total or 0) and (region.total or 0) > 0
                colored(string.format(
                    "    Ch%d  %s  -  %d / %d",
                    region.chapter or 0,
                    tostring(region.section),
                    region.found or 0,
                    region.total or 0
                ), done and DONE or WHITE)
            end
            -- The button is always drawn, greyed until the typewriter is
            -- found in game: a row that simply lacks the button reads as
            -- broken, while a disabled one reads as "not yet".
            local disabled = not unlocked
            if disabled and has("begin_disabled") then
                imgui.begin_disabled(true)
            end
            local pressed = imgui.button("Warp Here##ap_tw_warp_" .. tostring(row.stage))
            if disabled and has("end_disabled") then
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

    local function sum_rows(rows)
        local found, total = 0, 0
        for _, row in ipairs(rows or {}) do
            found = found + (row.found or 0)
            total = total + (row.total or 0)
        end
        return found, total
    end

    local function draw_campaign_section(rows)
        if type(rows) ~= "table" or #rows == 0 then
            imgui.text("(check data not loaded - reconnect, or re-patch from the wizard)")
            return
        end
        local found, total = sum_rows(rows)
        progress(found, total, string.format("%d / %d found", found, total))
        colored("Typewriter warps unlock after you find them in game.", MUTED)
        imgui.text("")

        local columns = begin_columns("##ap_ck_campaign_cols", 2)
        for _, row in ipairs(rows) do
            next_column(columns)
            draw_typewriter_row(row)
        end
        end_columns(columns)
    end

    -- ------------------------------------------------------------ merchant
    -- Rows: { chapter, name, player, remote, checked, released }.
    local function group_by_chapter(rows)
        local groups, by_chapter = {}, {}
        for _, row in ipairs(rows or {}) do
            local chapter = math.floor(tonumber(row.chapter) or 1)
            local group = by_chapter[chapter]
            if group == nil then
                group = { chapter = chapter, rows = {}, checked = 0, released = false }
                by_chapter[chapter] = group
                groups[#groups + 1] = group
            end
            group.rows[#group.rows + 1] = row
            if row.checked then
                group.checked = group.checked + 1
            end
            if row.released then
                group.released = true
            end
        end
        table.sort(groups, function(a, b) return a.chapter < b.chapter end)
        return groups
    end

    local function count_checked(rows)
        local checked = 0
        for _, row in ipairs(rows or {}) do
            if row.checked then
                checked = checked + 1
            end
        end
        return checked, #(rows or {})
    end

    local function draw_check_groups(rows, id_prefix, verb)
        local groups = group_by_chapter(rows)
        if #groups == 0 then
            colored("(none in this room)", MUTED)
            return
        end
        for _, group in ipairs(groups) do
            local state = ""
            if group.checked >= #group.rows then
                state = "  done"
            elseif not group.released then
                state = "  not yet"
            end
            local label = string.format(
                "Chapter %d - %d / %d%s##%s_%d",
                group.chapter, group.checked, #group.rows, state, id_prefix, group.chapter)
            if imgui.tree_node(label) then
                for _, row in ipairs(group.rows) do
                    local mark = row.checked and "[x]" or "[ ]"
                    local who = ""
                    if row.remote and row.player ~= nil and row.player ~= "" then
                        who = string.format("  (%s's)", tostring(row.player))
                    end
                    local color = WHITE
                    if row.checked then
                        color = DONE
                    elseif not row.released then
                        color = MUTED
                    end
                    colored(string.format("    %s %s%s", mark, tostring(row.name), who), color)
                end
                if group.checked < #group.rows and not group.released then
                    colored(string.format("    Released when chapter %d starts.", group.chapter), MUTED)
                end
                imgui.tree_pop()
            end
        end
        if verb ~= nil then
            colored(verb, MUTED)
        end
    end

    local function draw_merchant_section(shop_rows, trade_rows)
        local shop_checked, shop_total = count_checked(shop_rows)
        local trade_checked, trade_total = count_checked(trade_rows)
        progress(shop_checked + trade_checked, shop_total + trade_total,
            string.format("%d / %d bought", shop_checked + trade_checked, shop_total + trade_total))
        imgui.text("")

        local columns = begin_columns("##ap_ck_merchant_cols", 2)
        next_column(columns)
        colored(string.format("Buy tab   %d / %d", shop_checked, shop_total), ACCENT)
        draw_check_groups(shop_rows, "ap_ck_buy", "Checks on the shelf cost pesetas; a gem comes back with each.")
        next_column(columns)
        colored(string.format("Trade tab   %d / %d", trade_checked, trade_total), ACCENT)
        draw_check_groups(trade_rows, "ap_ck_trade", "Trade tiles cost spinel.")
        end_columns(columns)
    end

    -- --------------------------------------------------------- mercenaries
    local function draw_mercenaries_stage(stage)
        local stage_lock = stage.unlocked and "" or "  locked"
        local label = string.format(
            "%s - %d / %d%s##ap_merc_st_%d",
            tostring(stage.stage_name),
            stage.found or 0,
            stage.total or 0,
            stage_lock,
            stage.stage_idx or 0
        )
        if imgui.tree_node(label) then
            for _, char in ipairs(stage.characters or {}) do
                local color = WHITE
                if (char.found or 0) >= (char.total or 0) and (char.total or 0) > 0 then
                    color = DONE
                elseif not char.unlocked then
                    color = MUTED
                end
                colored(string.format(
                    "    %-10s %d/%d%s ",
                    tostring(char.char_name),
                    char.found or 0,
                    char.total or 0,
                    char.unlocked and "" or " (locked)"
                ), color)
                -- Each rank on the same line: "[x] A" in green once its check
                -- went, "[ ] A" dimmed until then (Cam, 2026-09-06: the old
                -- "[A ok]" read as noise). The imgui font is ASCII only, so
                -- the mark is the merchant rows' "[x]", never a glyph.
                if has("same_line") then
                    for _, rank in ipairs(char.ranks or {}) do
                        imgui.same_line()
                        if rank.checked then
                            colored("[x] " .. tostring(rank.name), DONE)
                        else
                            colored("[ ] " .. tostring(rank.name), MUTED)
                        end
                    end
                else
                    local rank_parts = {}
                    for _, rank in ipairs(char.ranks or {}) do
                        rank_parts[#rank_parts + 1] = (rank.checked and "[x] " or "[ ] ") .. tostring(rank.name)
                    end
                    imgui.same_line()
                    colored(table.concat(rank_parts, "  "), color)
                end
            end
            imgui.tree_pop()
        end
    end

    local function draw_mercenaries_section(merc_data)
        progress(merc_data.found or 0, merc_data.total or 0,
            string.format("%d / %d ranks reached", merc_data.found or 0, merc_data.total or 0))
        colored("Characters and stages unlock as their items arrive. Ranks up to A can hold progression.", MUTED)
        imgui.text("")

        local columns = begin_columns("##ap_ck_merc_cols", 2)
        for _, stage in ipairs(merc_data.stages or {}) do
            next_column(columns)
            draw_mercenaries_stage(stage)
        end
        end_columns(columns)
    end

    -- ---------------------------------------------------------------- tab
    local function rows_from(name)
        local fn = ctx[name] or _G[name]
        if type(fn) ~= "function" then
            return {}
        end
        local ok, rows = pcall(fn)
        if ok and type(rows) == "table" then
            return rows
        end
        return {}
    end

    local function draw_checks_content()
        local merc_fn = ctx.get_mercenaries_checklist or _G.get_mercenaries_checklist
        local merc_data = (type(merc_fn) == "function") and merc_fn() or nil
        local merc_enabled = (merc_data ~= nil and merc_data.enabled == true)
        local is_merc_only = merc_enabled and merc_data.mode == "mercenaries_only"

        local campaign_rows = (not is_merc_only) and resolve("get_typewriter_progress")() or {}
        local shop_rows = (not is_merc_only) and rows_from("merchant_checklist_rows") or {}
        local trade_rows = (not is_merc_only) and rows_from("trade_checklist_rows") or {}

        local pushed = push_rounding()

        -- The one line that answers "how far along am I" across everything
        -- the room includes.
        local found, total = sum_rows(campaign_rows)
        local shop_checked, shop_total = count_checked(shop_rows)
        local trade_checked, trade_total = count_checked(trade_rows)
        found = found + shop_checked + trade_checked
        total = total + shop_total + trade_total
        if merc_enabled then
            found = found + (merc_data.found or 0)
            total = total + (merc_data.total or 0)
        end
        colored(string.format("Checks found: %d / %d", found, total), ACCENT)
        progress(found, total, "")
        imgui.text("")

        if not is_merc_only then
            local c_found, c_total = sum_rows(campaign_rows)
            if section("Main Campaign", "campaign", string.format("%d / %d", c_found, c_total)) then
                draw_campaign_section(campaign_rows)
                imgui.text("")
            end
        end

        if not is_merc_only and (shop_total + trade_total) > 0 then
            if section("Merchant", "merchant", string.format("%d / %d", shop_checked + trade_checked, shop_total + trade_total)) then
                draw_merchant_section(shop_rows, trade_rows)
                imgui.text("")
            end
        end

        if merc_enabled then
            if section("Mercenaries", "mercenaries", string.format("%d / %d", merc_data.found or 0, merc_data.total or 0)) then
                draw_mercenaries_section(merc_data)
                if is_merc_only then
                    colored("Goal: Rank A on every character and stage combination.", MUTED)
                end
                imgui.text("")
            end
        end

        colored("Separate Ways - coming soon", MUTED)
        imgui.text("")

        separator()
        if not is_merc_only then
            imgui.text("Last warp: " .. tostring(bridge.last_warp_status or "(idle)"))
        end
        imgui.text("A check not sending, or finished the run? See the")
        imgui.text("Something's Wrong tab.")

        pop_rounding(pushed)
    end

    export("draw_checks_content", draw_checks_content)
end

return install
