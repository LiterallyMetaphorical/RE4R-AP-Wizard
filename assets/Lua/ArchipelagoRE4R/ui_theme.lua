-- [Theme] One look for the Archipelago window, shared by every tab: rounded
-- frames, a dark palette with a blue accent, a button tab strip (this
-- REFramework build exposes no tab-bar API to Lua, so the window used to
-- fall back to a column of stacked headers), side-by-side columns, section
-- bars with counts, progress bars.
--
-- Every imgui extra is guarded (type check + pcall). A build without one of
-- them keeps working and just looks plainer. Style indices are the stable
-- Dear ImGui ones (ImGuiStyleVar_* and ImGuiCol_* below 33 have not moved
-- across the versions REFramework has shipped).
local function install(ctx)
    local theme = {}
    ctx.theme = theme

    local function has(name)
        return type(imgui[name]) == "function"
    end

    -- ImU32 colours are 0xAABBGGRR.
    theme.ACCENT = 0xFFFFA050   -- light blue: titles, the active tab
    theme.MUTED = 0xFF9A9A9A    -- grey: notes, not yet, coming soon
    theme.DONE = 0xFF7FD67F     -- green: found / bought
    theme.WARN = 0xFF60C0FF     -- amber
    theme.WHITE = 0xFFFFFFFF

    local ACCENT_RGBA = { 0.31, 0.63, 1.0, 1.0 }
    local ACCENT_HOVER_RGBA = { 0.42, 0.70, 1.0, 1.0 }
    local ACCENT_TEXT_RGBA = { 0.05, 0.06, 0.08, 1.0 }

    -- ImGuiCol_* index, RGBA.
    local WINDOW_COLORS = {
        { 2, { 0.09, 0.10, 0.12, 0.97 } },   -- WindowBg
        { 3, { 0.11, 0.12, 0.15, 1.0 } },    -- ChildBg
        { 5, { 0.24, 0.27, 0.33, 1.0 } },    -- Border
        { 7, { 0.16, 0.18, 0.22, 1.0 } },    -- FrameBg
        { 8, { 0.21, 0.25, 0.31, 1.0 } },    -- FrameBgHovered
        { 9, { 0.25, 0.33, 0.45, 1.0 } },    -- FrameBgActive
        { 10, { 0.10, 0.11, 0.14, 1.0 } },   -- TitleBg
        { 11, { 0.13, 0.16, 0.22, 1.0 } },   -- TitleBgActive
        { 18, ACCENT_RGBA },                 -- CheckMark
        { 19, ACCENT_RGBA },                 -- SliderGrab
        { 20, ACCENT_HOVER_RGBA },           -- SliderGrabActive
        { 21, { 0.18, 0.21, 0.26, 1.0 } },   -- Button
        { 22, { 0.24, 0.31, 0.42, 1.0 } },   -- ButtonHovered
        { 23, ACCENT_RGBA },                 -- ButtonActive
        { 24, { 0.16, 0.19, 0.24, 1.0 } },   -- Header (section bars)
        { 25, { 0.22, 0.28, 0.37, 1.0 } },   -- HeaderHovered
        { 26, { 0.27, 0.36, 0.50, 1.0 } },   -- HeaderActive
        { 27, { 0.25, 0.36, 0.52, 1.0 } },   -- Separator
    }

    -- ImGuiStyleVar_* index, value (number or {x, y}).
    local WINDOW_VARS = {
        { 3, 8.0 },              -- WindowRounding
        { 7, 6.0 },              -- ChildRounding
        { 9, 6.0 },              -- PopupRounding
        { 12, 6.0 },             -- FrameRounding
        { 19, 6.0 },             -- ScrollbarRounding
        { 21, 6.0 },             -- GrabRounding
        { 2, { 12.0, 10.0 } },   -- WindowPadding
        { 11, { 8.0, 4.0 } },    -- FramePadding
        { 14, { 8.0, 6.0 } },    -- ItemSpacing
        { 17, { 6.0, 4.0 } },    -- CellPadding
    }

    -- ImGuiTableFlags_BordersInnerV | ImGuiTableFlags_SizingStretchSame.
    local TABLE_FLAGS = 512 + 32768
    -- ImGuiCond_Once: a section starts the way we say, then remembers.
    local COND_ONCE = 2

    -- ------------------------------------------------------------ pushes
    local function push_color(index, rgba)
        if not has("push_style_color") then
            return 0
        end
        if pcall(imgui.push_style_color, index, Vector4f.new(rgba[1], rgba[2], rgba[3], rgba[4])) then
            return 1
        end
        if pcall(imgui.push_style_color, index, rgba[1], rgba[2], rgba[3], rgba[4]) then
            return 1
        end
        return 0
    end

    local function pop_colors(count)
        if count > 0 and has("pop_style_color") then
            pcall(imgui.pop_style_color, count)
        end
    end

    local function push_var(index, value)
        if not has("push_style_var") then
            return 0
        end
        if type(value) == "table" then
            if pcall(imgui.push_style_var, index, Vector2f.new(value[1], value[2])) then
                return 1
            end
            return 0
        end
        if pcall(imgui.push_style_var, index, value) then
            return 1
        end
        return 0
    end

    local function pop_vars(count)
        if count > 0 and has("pop_style_var") then
            pcall(imgui.pop_style_var, count)
        end
    end

    -- The whole look, pushed before begin_window and popped after end_window.
    function theme.push_window_style()
        local handle = { vars = 0, colors = 0 }
        for _, entry in ipairs(WINDOW_VARS) do
            handle.vars = handle.vars + push_var(entry[1], entry[2])
        end
        for _, entry in ipairs(WINDOW_COLORS) do
            handle.colors = handle.colors + push_color(entry[1], entry[2])
        end
        return handle
    end

    function theme.pop_window_style(handle)
        if type(handle) ~= "table" then
            return
        end
        pop_colors(handle.colors or 0)
        pop_vars(handle.vars or 0)
    end

    -- --------------------------------------------------------------- text
    function theme.colored(text, color)
        if has("text_colored") and pcall(imgui.text_colored, text, color) then
            return
        end
        imgui.text(text)
    end

    function theme.heading(text)
        theme.colored(text, theme.ACCENT)
    end

    function theme.note(text)
        theme.colored(text, theme.MUTED)
    end

    function theme.separator()
        if has("separator") and pcall(imgui.separator) then
            return
        end
        imgui.text("----------------------------------------")
    end

    function theme.progress(found, total, label)
        if total <= 0 then
            return
        end
        local fraction = math.max(0, math.min(1, found / total))
        if has("progress_bar") and pcall(imgui.progress_bar, fraction, Vector2f.new(-1, 0), label or "") then
            return
        end
        if label ~= nil and label ~= "" then
            imgui.text(label)
        end
    end

    -- ----------------------------------------------------------- layout
    -- A collapsing bar with an optional count on the right of the title.
    function theme.section(title, id, count_text, default_open)
        if has("set_next_item_open") then
            pcall(imgui.set_next_item_open, default_open ~= false, COND_ONCE)
        end
        local label = title
        if count_text ~= nil and count_text ~= "" then
            label = string.format("%s   %s", title, count_text)
        end
        return imgui.collapsing_header(label .. "##ap_sec_" .. tostring(id))
    end

    -- Side-by-side cells. Returns a handle for next_column/end_columns, or
    -- nil when the build has no tables (content then flows in one column).
    function theme.begin_columns(id, count)
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

    function theme.next_column(handle)
        if handle then
            pcall(imgui.table_next_column)
        end
    end

    function theme.end_columns(handle)
        if handle then
            pcall(imgui.end_table)
        end
    end

    -- A bordered, scrolling panel filling the rest of the window: the tab body.
    function theme.begin_panel()
        if not has("begin_child_window") or not has("end_child_window") then
            return { open = false }
        end
        local ok = pcall(imgui.begin_child_window, Vector2f.new(0, 0), true, 0)
        return { open = ok }
    end

    function theme.end_panel(handle)
        if type(handle) == "table" and handle.open then
            pcall(imgui.end_child_window)
        end
    end

    -- A row of buttons standing in for tabs; the active one wears the accent.
    -- Returns the (possibly new) active index.
    function theme.tab_strip(id, labels, active)
        for index, label in ipairs(labels) do
            if index > 1 and has("same_line") then
                imgui.same_line()
            end
            local pushed = 0
            if index == active then
                pushed = pushed + push_color(21, ACCENT_RGBA)
                pushed = pushed + push_color(22, ACCENT_HOVER_RGBA)
                pushed = pushed + push_color(23, ACCENT_RGBA)
                pushed = pushed + push_color(0, ACCENT_TEXT_RGBA)
            end
            if imgui.button(tostring(label) .. tostring(id) .. "_" .. tostring(index)) then
                active = index
            end
            pop_colors(pushed)
        end
        return active
    end
end

return install
