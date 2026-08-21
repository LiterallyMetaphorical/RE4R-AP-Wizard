-- [Tutorial] The welcome window, opened on demand from Guidance ("Show the
-- getting-started guide again"). Styled like the progression-warning dialog
-- (centred, its own window) rather than buried inside a tab.
--
-- First-run teaching belongs to the native in-world book. This window used to
-- arm itself on a seed's first playable Chapter 1 tick, but it can only render
-- inside REFramework's menu, so it ambushed the first Insert of every fresh
-- seed instead of greeting the player (live test 2026-08-16).
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
                "A hint inside your own world lights up that spot; a hint for one",
                "of your items in someone else's world is pinned on screen under",
                "\"Multiworld Hints\", naming the player who has it.",
                "",
                "Something's Wrong has the recovery tools if a check refuses to",
                "send. Waiting on another player is normal in a multiworld: your",
                "next key item may be in someone else's game.",
            },
        },
    }

    local function draw_tutorial_dialog()
        if not bridge.tutorial_dialog_open then
            return
        end
        -- Only draw while REFramework's menu is open (Insert), where there is a
        -- free cursor and imgui receives the clicks. During gameplay the game
        -- captures the mouse for camera-look, so buttons fell through to it -
        -- that was the "mouse falls through" bug. The native in-world book is
        -- the first-run tutorial now; this popup is the reopen-from-Guidance
        -- version, which is always opened from inside the menu anyway.
        local ok_ui, drawing_ui = pcall(function() return reframework:is_drawing_ui() end)
        if not ok_ui or not drawing_ui then
            return
        end
        local state = bridge.last_state or {}
        if not state.is_in_game then
            return
        end

        local page_index = math.max(1, math.min(#PAGES, math.floor(tonumber(bridge.tutorial_page) or 1)))
        local page = PAGES[page_index]

        local dialog_width = 720
        -- Tall enough that the longest page plus the nav buttons and footer
        -- never clip (the old 330 cut the buttons off - the other half of the
        -- report).
        local dialog_height = 460
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

    export("draw_tutorial_dialog", draw_tutorial_dialog)
    export("replay_tutorial", replay_tutorial)
end

return install
