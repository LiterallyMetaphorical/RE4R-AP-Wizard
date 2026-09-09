-- [Customize tab, 2026-09-05] Two colours the player owns: the main colour
-- (the active tab, the titles, the check marks; every other shade of the
-- window is derived from it in ui_theme.lua) and the progress bar fill.
-- Cam's calls: the window only (the on-screen header and the markers keep
-- their meaning colours), a row of preset swatches next to each picker, and
-- one setting per player rather than per seed, so the choice lives in
-- ArchipelagoRE4R\ui_prefs.json under reframework/data and follows the
-- player across rooms. Changes apply as they are made and are written a
-- second after the last change.
local function install(ctx)
    local theme = ctx.theme
    if theme == nil then
        return
    end

    local function export(name, value)
        ctx[name] = value
        _G[name] = value
    end

    local PREFS_FILE = "ArchipelagoRE4R\\ui_prefs.json"
    -- fs.glob takes a regex; one backslash in the path is two here, four in
    -- the source.
    local PREFS_GLOB = "ArchipelagoRE4R\\\\ui_prefs\\.json"
    local SAVE_DELAY_SECONDS = 1.0
    -- ImGuiColorEditFlags: NoAlpha (2) and PickerHueBar (1 << 25); both have
    -- held their values since imgui 1.69.
    local EDIT_FLAGS = 2 | (1 << 25)

    local function copy_rgb(rgb)
        return { rgb[1], rgb[2], rgb[3] }
    end

    local MAIN_PRESETS = {
        { name = "Archipelago Blue", rgb = theme.DEFAULT_MAIN_RGB },
        { name = "Gold", rgb = { 0.85, 0.65, 0.13 } },
        { name = "Umbrella Red", rgb = { 0.85, 0.20, 0.18 } },
        { name = "Herb Green", rgb = { 0.35, 0.75, 0.40 } },
        { name = "Violet", rgb = { 0.65, 0.45, 0.95 } },
        { name = "Bone White", rgb = { 0.92, 0.90, 0.85 } },
    }
    local PROGRESS_PRESETS = {
        { name = "Gold", rgb = theme.DEFAULT_PROGRESS_RGB },
        { name = "Archipelago Blue", rgb = theme.DEFAULT_MAIN_RGB },
        { name = "Umbrella Red", rgb = { 0.85, 0.20, 0.18 } },
        { name = "Herb Green", rgb = { 0.35, 0.75, 0.40 } },
        { name = "Violet", rgb = { 0.65, 0.45, 0.95 } },
        { name = "Bone White", rgb = { 0.92, 0.90, 0.85 } },
    }

    local state = {
        main = copy_rgb(theme.DEFAULT_MAIN_RGB),
        progress = copy_rgb(theme.DEFAULT_PROGRESS_RGB),
        dirty_at = nil,
        status = "",
    }

    -- ------------------------------------------------------------ storage
    local function hex_of(rgb)
        local function channel(x)
            x = math.floor((tonumber(x) or 0) * 255 + 0.5)
            if x < 0 then x = 0 elseif x > 255 then x = 255 end
            return x
        end
        return string.format("%02X%02X%02X", channel(rgb[1]), channel(rgb[2]), channel(rgb[3]))
    end

    local function rgb_of_hex(text)
        if type(text) ~= "string" then
            return nil
        end
        local hex = text:match("^#?(%x%x%x%x%x%x)$")
        if hex == nil then
            return nil
        end
        return {
            tonumber(hex:sub(1, 2), 16) / 255,
            tonumber(hex:sub(3, 4), 16) / 255,
            tonumber(hex:sub(5, 6), 16) / 255,
        }
    end

    local function prefs_file_exists()
        if type(fs) ~= "table" or type(fs.glob) ~= "function" then
            -- No way to ask; let load_file answer (it logs a miss, once).
            return true
        end
        local ok, files = pcall(fs.glob, PREFS_GLOB)
        return ok and type(files) == "table" and #files > 0
    end

    local function load_prefs()
        if not prefs_file_exists() then
            return false
        end
        local ok, payload = pcall(json.load_file, PREFS_FILE)
        if not ok or type(payload) ~= "table" then
            return false
        end
        local main = rgb_of_hex(payload.main)
        local progress = rgb_of_hex(payload.progress)
        if main ~= nil then state.main = main end
        if progress ~= nil then state.progress = progress end
        return main ~= nil or progress ~= nil
    end

    local function save_prefs()
        local ok, written = pcall(json.dump_file, PREFS_FILE, {
            main = hex_of(state.main),
            progress = hex_of(state.progress),
        })
        if ok and written ~= false then
            state.status = ""
            return true
        end
        state.status = "Could not save ui_prefs.json; the colours hold until the game closes."
        return false
    end

    -- ------------------------------------------------------------- apply
    local function apply()
        theme.apply_colors(state.main, state.progress)
    end

    local function set_main(rgb)
        state.main = copy_rgb(rgb)
        apply()
        state.dirty_at = os.clock()
    end

    local function set_progress(rgb)
        state.progress = copy_rgb(rgb)
        apply()
        state.dirty_at = os.clock()
    end

    -- Writes a second after the last change, from wherever the frame loop
    -- calls it, so a colour picked right before closing the window still
    -- lands on disk.
    local function flush()
        if state.dirty_at ~= nil and os.clock() - state.dirty_at >= SAVE_DELAY_SECONDS then
            state.dirty_at = nil
            save_prefs()
        end
    end

    -- ----------------------------------------------------------- widgets
    -- The colour editor REFramework exposes: color_edit shows a swatch plus
    -- RGB fields and opens the picker on click; color_picker is the picker
    -- alone. Both take and return an ImU32 in 0xAABBGGRR, like text_colored.
    local function color_editor(label, rgb)
        local value = theme.rgb_to_u32(rgb)
        if type(imgui.color_edit) == "function" then
            local ok, changed, result = pcall(imgui.color_edit, label, value, EDIT_FLAGS)
            if ok then
                if changed and type(result) == "number" and result ~= value then
                    return true, theme.u32_to_rgb(result)
                end
                return false, nil
            end
        end
        if type(imgui.color_picker) == "function" then
            local ok, changed, result = pcall(imgui.color_picker, label, value, EDIT_FLAGS)
            if ok and changed and type(result) == "number" and result ~= value then
                return true, theme.u32_to_rgb(result)
            end
        end
        return false, nil
    end

    local function swatch_row(presets, id, setter)
        for index, preset in ipairs(presets) do
            if index > 1 and type(imgui.same_line) == "function" then
                imgui.same_line()
            end
            if theme.color_button(preset.name .. "##" .. id .. "_" .. tostring(index), preset.rgb) then
                setter(preset.rgb)
            end
        end
    end

    local function draw_customize_content()
        flush()
        theme.heading("Colours")
        theme.note("Changes apply as you make them and are remembered on this PC, for every seed.")
        imgui.text("")

        theme.heading("Main colour")
        theme.note("The active tab, the titles and the check marks. Every other shade of the window follows it.")
        local changed, rgb = color_editor("##ap_main_colour", state.main)
        if changed then
            set_main(rgb)
        end
        swatch_row(MAIN_PRESETS, "ap_main_preset", set_main)
        imgui.text("")

        theme.heading("Progress bar")
        theme.note("The fill of the Checklist's progress bars.")
        local changed_progress, progress_rgb = color_editor("##ap_progress_colour", state.progress)
        if changed_progress then
            set_progress(progress_rgb)
        end
        swatch_row(PROGRESS_PRESETS, "ap_progress_preset", set_progress)
        theme.progress(7, 10, "7 / 10, a sample")
        imgui.text("")

        if imgui.button("Reset both to the defaults##ap_colours_reset") then
            set_main(theme.DEFAULT_MAIN_RGB)
            set_progress(theme.DEFAULT_PROGRESS_RGB)
        end
        if state.status ~= "" then
            theme.note(state.status)
        end
    end

    local loaded = load_prefs()
    apply()
    if loaded then
        log.info(string.format("[RE4R AP] colours loaded from ui_prefs.json: main %s, progress %s",
            hex_of(state.main), hex_of(state.progress)))
    end

    if type(re) == "table" and type(re.on_frame) == "function" then
        re.on_frame(function()
            pcall(flush)
        end)
    end

    export("draw_customize_content", draw_customize_content)
    export("customize_colors", function()
        return copy_rgb(state.main), copy_rgb(state.progress)
    end)
    export("customize_set_main_color", set_main)
    export("customize_set_progress_color", set_progress)
    export("customize_flush_prefs", flush)
end

return install
