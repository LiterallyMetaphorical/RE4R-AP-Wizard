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
    theme.MUTED = 0xFF9A9A9A    -- grey: notes, not yet, coming soon
    theme.DONE = 0xFF7FD67F     -- green: found / bought
    theme.WARN = 0xFF60C0FF     -- amber
    theme.WHITE = 0xFFFFFFFF

    -- [Customize, 2026-09-05] The accent family comes from ONE colour, the
    -- "main colour" the Customize tab lets the player pick. Archipelago blue
    -- is the reference: every shade below is remembered as its offset from
    -- the reference accent in HSV (hue delta, saturation ratio, brightness
    -- ratio), so the reference reproduces this exact palette and any other
    -- main colour gets the same family in its own hue. Greens, ambers and
    -- the marker colours carry meaning and stay fixed.
    theme.DEFAULT_MAIN_RGB = { 0.31, 0.63, 1.0 }
    -- Gold (Cam, 2026-09-05): the fill imgui inherits read as unstyled grey.
    theme.DEFAULT_PROGRESS_RGB = { 0.85, 0.65, 0.13 }

    local REFERENCE_SHADES = {
        window_bg     = { 0.09, 0.10, 0.12 },
        child_bg      = { 0.11, 0.12, 0.15 },
        border        = { 0.24, 0.27, 0.33 },
        frame_bg      = { 0.16, 0.18, 0.22 },
        frame_hover   = { 0.21, 0.25, 0.31 },
        frame_active  = { 0.25, 0.33, 0.45 },
        title_bg      = { 0.10, 0.11, 0.14 },
        title_active  = { 0.13, 0.16, 0.22 },
        button        = { 0.18, 0.21, 0.26 },
        button_hover  = { 0.24, 0.31, 0.42 },
        header        = { 0.16, 0.19, 0.24 },
        header_hover  = { 0.22, 0.28, 0.37 },
        header_active = { 0.27, 0.36, 0.50 },
        separator     = { 0.25, 0.36, 0.52 },
        accent_hover  = { 0.42, 0.70, 1.0 },
    }

    local function clamp01(x)
        if x < 0 then return 0 end
        if x > 1 then return 1 end
        return x
    end

    local function rgb_to_hsv(rgb)
        local r, g, b = rgb[1], rgb[2], rgb[3]
        local max = math.max(r, g, b)
        local min = math.min(r, g, b)
        local delta = max - min
        local h = 0
        if delta > 1e-6 then
            if max == r then
                h = 60 * (((g - b) / delta) % 6)
            elseif max == g then
                h = 60 * (((b - r) / delta) + 2)
            else
                h = 60 * (((r - g) / delta) + 4)
            end
        end
        local s = (max > 1e-6) and (delta / max) or 0
        return h, s, max
    end

    local function hsv_to_rgb(h, s, v)
        h = h % 360
        local c = v * s
        local x = c * (1 - math.abs(((h / 60) % 2) - 1))
        local m = v - c
        local r, g, b
        if h < 60 then r, g, b = c, x, 0
        elseif h < 120 then r, g, b = x, c, 0
        elseif h < 180 then r, g, b = 0, c, x
        elseif h < 240 then r, g, b = 0, x, c
        elseif h < 300 then r, g, b = x, 0, c
        else r, g, b = c, 0, x end
        return { clamp01(r + m), clamp01(g + m), clamp01(b + m) }
    end

    local REF_H, REF_S, REF_V = rgb_to_hsv(theme.DEFAULT_MAIN_RGB)
    local SHADE_OFFSETS = {}
    for key, rgb in pairs(REFERENCE_SHADES) do
        local h, s, v = rgb_to_hsv(rgb)
        local dh = h - REF_H
        if dh > 180 then dh = dh - 360 elseif dh < -180 then dh = dh + 360 end
        SHADE_OFFSETS[key] = {
            dh = dh,
            sr = (REF_S > 1e-6) and (s / REF_S) or 0,
            vr = (REF_V > 1e-6) and (v / REF_V) or 0,
        }
    end

    local function luminance(rgb)
        return 0.2126 * rgb[1] + 0.7152 * rgb[2] + 0.0722 * rgb[3]
    end

    -- The whole family for a main colour. Pure: the Customize tab previews
    -- with it and the harness checks it.
    function theme.palette_from(main_rgb)
        local h, s, v = rgb_to_hsv(main_rgb)
        -- Brightness follows the pick, dampened: a dark main colour darkens
        -- the frames but never to black.
        local v_scale = math.sqrt(math.max(v, 0.0))
        local shades = {}
        for key, offset in pairs(SHADE_OFFSETS) do
            shades[key] = hsv_to_rgb(
                h + offset.dh,
                clamp01(s * offset.sr),
                math.max(0.02, clamp01(offset.vr * v_scale)))
        end
        shades.accent = { main_rgb[1], main_rgb[2], main_rgb[3] }
        -- Titles are text on the dark frames: keep them readable whatever the
        -- pick (lift a dark one, keep a neon one from vibrating).
        shades.accent_text = hsv_to_rgb(h, math.min(s, 0.85), math.max(v, 0.75))
        -- The active tab's label: dark on a light accent, light on a dark one.
        if luminance(main_rgb) > 0.45 then
            shades.accent_label = { 0.05, 0.06, 0.08 }
        else
            shades.accent_label = { 0.95, 0.96, 0.98 }
        end
        return shades
    end

    local function rgba(rgb, alpha)
        return { rgb[1], rgb[2], rgb[3], alpha or 1.0 }
    end

    function theme.rgb_to_u32(rgb)
        local r = math.floor(clamp01(rgb[1]) * 255 + 0.5)
        local g = math.floor(clamp01(rgb[2]) * 255 + 0.5)
        local b = math.floor(clamp01(rgb[3]) * 255 + 0.5)
        return 0xFF000000 | (b << 16) | (g << 8) | r
    end

    function theme.u32_to_rgb(value)
        value = math.floor(tonumber(value) or 0)
        return { (value & 0xFF) / 255, ((value >> 8) & 0xFF) / 255, ((value >> 16) & 0xFF) / 255 }
    end

    function theme.luminance(rgb)
        return luminance(rgb)
    end

    -- Dear ImGui 1.92.0 in REFramework 1.5.9.1 (version string read out of the
    -- DLL, no docking): ImGuiCol_PlotHistogram, the progress bar fill, is
    -- index 43. 42 is pushed too so a build one entry short (without the
    -- InputTextCursor slot) still paints the bar; whichever neighbour that
    -- hits is a plot colour this window never draws.
    local PROGRESS_COLOR_INDICES = { 43, 42 }

    local ACCENT_RGBA, ACCENT_HOVER_RGBA, ACCENT_TEXT_RGBA
    local WINDOW_COLORS = {}

    -- Rebuild every pushed colour from the two picks. Called at install with
    -- the defaults and by the Customize tab on every change.
    function theme.apply_colors(main_rgb, progress_rgb)
        main_rgb = main_rgb or theme.DEFAULT_MAIN_RGB
        progress_rgb = progress_rgb or theme.DEFAULT_PROGRESS_RGB
        local p = theme.palette_from(main_rgb)
        theme.MAIN_RGB = { main_rgb[1], main_rgb[2], main_rgb[3] }
        theme.PROGRESS_RGB = { progress_rgb[1], progress_rgb[2], progress_rgb[3] }
        theme.ACCENT = theme.rgb_to_u32(p.accent_text)
        ACCENT_RGBA = rgba(p.accent)
        ACCENT_HOVER_RGBA = rgba(p.accent_hover)
        ACCENT_TEXT_RGBA = rgba(p.accent_label)
        -- ImGuiCol_* index, RGBA. Indices below 33 are the stable ones.
        WINDOW_COLORS = {
            { 2, rgba(p.window_bg, 0.97) },     -- WindowBg
            { 3, rgba(p.child_bg) },            -- ChildBg
            { 5, rgba(p.border) },              -- Border
            { 7, rgba(p.frame_bg) },            -- FrameBg
            { 8, rgba(p.frame_hover) },         -- FrameBgHovered
            { 9, rgba(p.frame_active) },        -- FrameBgActive
            { 10, rgba(p.title_bg) },           -- TitleBg
            { 11, rgba(p.title_active) },       -- TitleBgActive
            { 18, ACCENT_RGBA },                -- CheckMark
            { 19, ACCENT_RGBA },                -- SliderGrab
            { 20, ACCENT_HOVER_RGBA },          -- SliderGrabActive
            { 21, rgba(p.button) },             -- Button
            { 22, rgba(p.button_hover) },       -- ButtonHovered
            { 23, ACCENT_RGBA },                -- ButtonActive
            { 24, rgba(p.header) },             -- Header (section bars)
            { 25, rgba(p.header_hover) },       -- HeaderHovered
            { 26, rgba(p.header_active) },      -- HeaderActive
            { 27, rgba(p.separator) },          -- Separator
        }
        for _, index in ipairs(PROGRESS_COLOR_INDICES) do
            WINDOW_COLORS[#WINDOW_COLORS + 1] = { index, rgba(progress_rgb) }
        end
    end
    theme.apply_colors(theme.DEFAULT_MAIN_RGB, theme.DEFAULT_PROGRESS_RGB)

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

    -- A button painted in a colour, with a label that stays readable on it:
    -- the Customize tab's preset swatches.
    function theme.color_button(label, rgb)
        local pushed = push_color(21, rgba(rgb))
        pushed = pushed + push_color(22, rgba(rgb))
        pushed = pushed + push_color(23, rgba(rgb))
        local text = (luminance(rgb) > 0.45) and { 0.05, 0.06, 0.08, 1.0 } or { 0.95, 0.96, 0.98, 1.0 }
        pushed = pushed + push_color(0, text)
        local clicked = imgui.button(label)
        pop_colors(pushed)
        return clicked == true
    end
end

return install
