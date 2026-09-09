-- [Trade takeover, experiments] A popout host for the trade probe: Cam
-- asked for the buttons out of the Debug tab's clutter and into their own
-- window, the Boat Spike / Gimmick Nudger pattern (2026-08-31). The probe
-- logic itself (game-thread pump, buttons, logging) lives in merchant.lua
-- and is exported as draw_trade_probe_content; this file only frames it.
-- Delete with the probes once Trade Phase 2 ships.
local function install(ctx)
    local bridge = ctx.bridge

    local function draw_trade_probe()
        if bridge.developer_tools_enabled ~= true
            or bridge.trade_probe_window_enabled ~= true then
            return
        end
        -- begin_window returns whether the window is still OPEN: feed it
        -- back so the title-bar X works (the marker editor's old defect).
        bridge.trade_probe_window_enabled =
            imgui.begin_window("AP Trade Probe", true)
        if bridge.trade_probe_window_enabled ~= true then
            imgui.end_window()
            return
        end
        local content = ctx.draw_trade_probe_content or _G.draw_trade_probe_content
        if type(content) == "function" then
            content()
        else
            imgui.text("merchant module not loaded")
        end
        imgui.end_window()
    end

    ctx.draw_trade_probe = draw_trade_probe
    _G.draw_trade_probe = draw_trade_probe
end

return install
