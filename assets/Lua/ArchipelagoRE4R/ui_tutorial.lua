-- [Tutorial] A one-time welcome window, shown the first time a seed reaches
-- Chapter 1. Styled like the progression-warning dialog (centred, its own
-- window) rather than buried inside a tab, because a first-time player has no
-- reason to open the window at all - the thing that explains the mod cannot
-- itself require knowing about the mod.
--
-- Suppressed by the `tutorial` YAML option (default on), so a veteran can turn
-- it off for every future seed, and dismissed per-seed once shown.
local function install(ctx)
    local bridge = ctx.bridge

    local function export(name, value)
        ctx[name] = value
        _G[name] = value
    end

    local function resolve(name)
        return ctx[name] or _G[name]
    end

    -- Pages keep each screen short; a wall of text gets dismissed unread.
    local PAGES = {
        {
            title = "Welcome to Resident Evil 4 in Archipelago",
            lines = {
                "Your item pickups are now checks. Collecting one sends an item",
                "to another player in the multiworld, and their finds send items",
                "to you - weapons, herbs, key items, anything.",
                "",
                "Items belonging to other players appear in the world as the",
                "Archipelago logo. Grab them like any other pickup: they go to",
                "their owner, not into your inventory.",
            },
        },
        {
            title = "Finding your checks",
            lines = {
                "Unchecked spots show a floating [AP] Marker with the distance,",
                "the chapter it belongs to, and how far above or below you it is.",
                "",
                "The Guidance tab turns Markers on or off, sets how far away they",
                "appear, and can make them more detailed - up to naming the item",
                "you would be finding.",
                "",
                "The on-screen header always shows your area and how many checks",
                "you have found there.",
            },
        },
        {
            title = "When you get stuck",
            lines = {
                "Press Insert at any time to open or close the Archipelago",
                "window (this is REFramework's menu key).",
                "",
                "The Checklist tab lists every save point with how many checks",
                "are still waiting near it - and warps you there once you have",
                "visited it.",
                "",
                "The Hints tab spends hint points to reveal where an item is.",
                "Something's Wrong has the recovery tools if a check refuses to",
                "send. Waiting on another player is normal in a multiworld: your",
                "next key item may be in someone else's game.",
            },
        },
    }

    local function tutorial_allowed()
        -- Host/YAML opt-out wins; absent means enabled (older rooms).
        return bridge.tutorial_enabled ~= false
    end

    -- Arm on the first playable Chapter 1 tick of a seed. state.lua owns the
    -- per-seed flag so it persists with the session file.
    local function maybe_show_tutorial()
        if not tutorial_allowed() or bridge.tutorial_shown == true or bridge.tutorial_dialog_open then
            return
        end
        local state = bridge.last_state or {}
        if not state.is_in_game or not state.is_playable then
            return
        end
        local chapter = tonumber(bridge.ui_current_chapter)
        if chapter ~= nil and chapter > 1 then
            -- Joined mid-run (or a returning player): never interrupt.
            bridge.tutorial_shown = true
            return
        end
        if chapter ~= 1 then
            return
        end
        bridge.tutorial_dialog_open = true
        bridge.tutorial_page = 1
    end

    local function draw_tutorial_dialog()
        if not bridge.tutorial_dialog_open then
            return
        end
        local state = bridge.last_state or {}
        if not state.is_in_game then
            return
        end

        local page_index = math.max(1, math.min(#PAGES, math.floor(tonumber(bridge.tutorial_page) or 1)))
        local page = PAGES[page_index]

        local dialog_width = 720
        local dialog_height = 330
        local pos_x, pos_y = 80, 80
        local ok_display, display_size = pcall(function()
            return imgui.get_display_size()
        end)
        if ok_display and display_size ~= nil then
            pos_x = math.max(40, ((tonumber(display_size.x or 0) - dialog_width) * 0.5))
            pos_y = math.max(40, ((tonumber(display_size.y or 0) - dialog_height) * 0.35))
        end

        imgui.set_next_window_pos(Vector2f.new(pos_x, pos_y), 1)
        imgui.set_next_window_size(Vector2f.new(dialog_width, dialog_height), 1)

        local visible = imgui.begin_window("Archipelago - Getting Started", true, nil)
        if not visible then
            bridge.tutorial_dialog_open = false
            bridge.tutorial_shown = true
            imgui.end_window()
            return
        end

        local centered = resolve("draw_centered_dialog_text")
        local function line(text)
            if type(centered) == "function" then
                centered(text, dialog_width)
            else
                imgui.text(text)
            end
        end

        line(page.title)
        line("------------------------------------------------------------")
        for _, text in ipairs(page.lines) do
            line(text)
        end

        imgui.text("")
        imgui.text(string.format("  Page %d of %d", page_index, #PAGES))
        if page_index > 1 then
            if imgui.button("Back##ap_tut_back") then
                bridge.tutorial_page = page_index - 1
            end
            imgui.same_line()
        end
        if page_index < #PAGES then
            if imgui.button("Next##ap_tut_next") then
                bridge.tutorial_page = page_index + 1
            end
            imgui.same_line()
            if imgui.button("Skip##ap_tut_skip") then
                bridge.tutorial_dialog_open = false
                bridge.tutorial_shown = true
            end
        else
            if imgui.button("Start playing##ap_tut_done") then
                bridge.tutorial_dialog_open = false
                bridge.tutorial_shown = true
            end
        end

        imgui.text("")
        imgui.text("  Reopen this any time from the Guidance tab.")
        imgui.end_window()
    end

    -- Manual replay, offered in Guidance.
    local function replay_tutorial()
        bridge.tutorial_page = 1
        bridge.tutorial_dialog_open = true
        return "tutorial reopened"
    end

    export("maybe_show_tutorial", maybe_show_tutorial)
    export("draw_tutorial_dialog", draw_tutorial_dialog)
    export("replay_tutorial", replay_tutorial)
end

return install
