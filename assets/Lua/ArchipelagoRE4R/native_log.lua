-- native_log.lua - route AP toasts onto the game's own bottom-right activity
-- log rail (the native "Chicken Egg" pickup toast) instead of the imgui
-- overlay. The imgui toast rail stays fully intact as the fallback surface:
-- NATIVE_TOAST_MODE (config.lua / Debug tab) selects "native", "overlay"
-- (legacy behaviour, byte-identical), or "both" (A/B compare).
--
-- API facts mined from il2cpp_dump.json (game root, 2026-07-23):
--   chainsaw.ActivityLogManager : AppSingleton
--     :requestLog(chainsaw.gui.LogRequestBase req, System.Boolean isSync)
--   chainsaw.gui.NoticeLogRequest
--     .ctor(System.Int32 value, System.String log, chainsaw.gui.LogOwnerType owner)
--     field Log : System.String  -- ARBITRARY TEXT on the native rail
--   chainsaw.gui.ItemGetLogRequest
--     .ctor(System.Int32 value, chainsaw.ItemID itemId, LogOwnerType owner,
--           chainsaw.StatusEffectID effectID)  -- icon + localized item name
--   chainsaw.gui.ItemRecieveLogRequest (sic)
--     .ctor(System.Int32 value, chainsaw.ItemID itemId, LogOwnerType owner)
--   LogRequestBase fields: Value:int, LogOwnerType, LogCauseType, LogAct,
--     <IsWideLog>k__BackingField:bool
--   LogOwnerType: Player=0 Partner=1 (System expected 2) Other=3 - resolved at
--     runtime, never hardcoded.
-- Inline colour tags are an engine msg feature already proven in-game by
-- BioRand file text: <COL FILE>x</COL> (preset) and <COLOR RRGGBB>x</COLOR>
-- (hex). Whether the RAIL's text control parses them is exactly what the
-- Debug-tab test buttons verify.
local function install(ctx)
    local bridge = ctx.bridge
    local config = ctx.config

    local function export(name, value)
        ctx[name] = value
        _G[name] = value
    end

    -- Runtime mode lives on the bridge so the Debug tab can flip it live.
    -- Falls back to the config default on load / script reset.
    if type(bridge.native_toast_mode) ~= "string" then
        bridge.native_toast_mode = tostring(config.NATIVE_TOAST_MODE or "overlay")
    end
    bridge.native_log_status = bridge.native_log_status or "no push yet"

    local function set_status(text)
        bridge.native_log_status = tostring(text)
        log.info("[RE4R AP][native_log] " .. tostring(text))
    end

    -- ---------------------------------------------------------------- enums
    local enum_cache = {}
    local function enum_value(type_name, field_name, fallback)
        local key = type_name .. "." .. field_name
        local cached = enum_cache[key]
        if cached ~= nil then
            return cached
        end
        local ok, value = pcall(function()
            local td = sdk.find_type_definition(type_name)
            if td == nil then
                return nil
            end
            local field = td:get_field(field_name)
            if field == nil then
                return nil
            end
            return field:get_data(nil)
        end)
        local resolved = (ok and type(value) == "number") and value or fallback
        enum_cache[key] = resolved
        return resolved
    end

    local function owner_system()
        -- LogOwnerType.System expected = 2; Other (3) is the safe fallback.
        return enum_value("chainsaw.gui.LogOwnerType", "System",
            enum_value("chainsaw.gui.LogOwnerType", "Other", 3))
    end

    local function effect_id_none()
        return enum_value("chainsaw.StatusEffectID", "Invalid",
            enum_value("chainsaw.StatusEffectID", "None", 0))
    end

    -- ------------------------------------------------------------- plumbing
    local function get_manager()
        local ok, mgr = pcall(function()
            return sdk.get_managed_singleton("chainsaw.ActivityLogManager")
        end)
        if ok then
            return mgr
        end
        return nil
    end

    local function create_request(type_name)
        local ok, req = pcall(function()
            local instance = sdk.create_instance(type_name)
            if instance == nil then
                instance = sdk.create_instance(type_name, true)
            end
            if instance == nil then
                return nil
            end
            return instance:add_ref()
        end)
        if ok then
            return req
        end
        return nil
    end

    local function call_ctor(req, signature, ...)
        local args = { ... }
        local ok = pcall(function()
            req:call(signature, table.unpack(args))
        end)
        return ok
    end

    local function set_wide(req)
        local ok = pcall(function()
            req:call("set_IsWideLog(System.Boolean)", true)
        end)
        if not ok then
            pcall(function()
                req:set_field("<IsWideLog>k__BackingField", true)
            end)
        end
    end

    local function submit(req, label)
        local mgr = get_manager()
        if mgr == nil then
            set_status("FAIL " .. label .. ": ActivityLogManager singleton not found")
            return false
        end
        local ok, err = pcall(function()
            mgr:call("requestLog(chainsaw.gui.LogRequestBase, System.Boolean)", req, false)
        end)
        if not ok then
            -- Overload-string mismatch fallback: let REFramework resolve it.
            ok, err = pcall(function()
                mgr:call("requestLog", req, false)
            end)
        end
        if ok then
            set_status("ok " .. label)
            return true
        end
        set_status("FAIL " .. label .. ": " .. tostring(err))
        return false
    end

    -- ------------------------------------------------- panel-state discovery
    -- Organic item toasts draw a backing banner; our free-text notices come
    -- out plainer. Which visual variant a rail entry uses is decided by the
    -- request's getTextPanelState() return - a runtime-only string. The hooks
    -- below (a) log + auto-capture every distinct value per request type onto
    -- the bridge, and (b) when bridge.native_notice_panel_override is a
    -- non-empty string, make NoticeLogRequest report THAT state instead, so
    -- our lines adopt the item-style banner.
    local managed_string_cache = {}
    local function managed_string_ptr(text)
        local cached = managed_string_cache[text]
        if cached == nil then
            local ok, ms = pcall(function()
                local s = sdk.create_managed_string(text)
                if s == nil then
                    return nil
                end
                return s:add_ref()
            end)
            if not ok or ms == nil then
                return nil
            end
            managed_string_cache[text] = ms
            cached = ms
        end
        local ok_ptr, ptr = pcall(function()
            return sdk.to_ptr(cached)
        end)
        if ok_ptr then
            return ptr
        end
        return nil
    end

    local function read_managed_string(retval)
        local ok, text = pcall(function()
            local managed = sdk.to_managed_object(retval)
            if managed == nil then
                return nil
            end
            return managed:call("ToString()")
        end)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
        return nil
    end

    local panel_hooks_installed = false
    local function install_panel_state_hooks()
        if panel_hooks_installed then
            return true
        end
        local installed_any = false
        -- Capture-only probes: what do the organic request types report?
        local capture_specs = {
            { type_name = "chainsaw.gui.ItemGetLogRequest", capture_key = "native_log_itemget_panel_state" },
            { type_name = "chainsaw.gui.ItemRecieveLogRequest", capture_key = "native_log_recieve_panel_state" },
        }
        for _, spec in ipairs(capture_specs) do
            local ok = pcall(function()
                local td = sdk.find_type_definition(spec.type_name)
                local method = td and td:get_method("getTextPanelState")
                if method == nil then
                    error("getTextPanelState missing on " .. spec.type_name)
                end
                sdk.hook(method, function(args)
                    return sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval)
                    local text = read_managed_string(retval)
                    if text ~= nil and bridge[spec.capture_key] ~= text then
                        bridge[spec.capture_key] = text
                        log.info(string.format(
                            "[RE4R AP][native_log] %s panel state = '%s'",
                            spec.type_name, text
                        ))
                    end
                    return retval
                end)
            end)
            installed_any = installed_any or ok
        end
        -- Notice hook: capture AND (when the override is set) replace.
        local ok_notice = pcall(function()
            local td = sdk.find_type_definition("chainsaw.gui.NoticeLogRequest")
            local method = td and td:get_method("getTextPanelState")
            if method == nil then
                error("getTextPanelState missing on NoticeLogRequest")
            end
            sdk.hook(method, function(args)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval)
                local text = read_managed_string(retval)
                if text ~= nil and bridge.native_log_notice_panel_state ~= text then
                    bridge.native_log_notice_panel_state = text
                    log.info(string.format(
                        "[RE4R AP][native_log] NoticeLogRequest panel state = '%s'",
                        text
                    ))
                end
                local desired = bridge.native_notice_panel_override
                if type(desired) == "string" and desired ~= "" and desired ~= text then
                    local replacement = managed_string_ptr(desired)
                    if replacement ~= nil then
                        return replacement
                    end
                end
                return retval
            end)
        end)
        installed_any = installed_any or ok_notice
        panel_hooks_installed = installed_any
        set_status(installed_any and "panel-state hooks installed" or "FAIL: panel-state hooks not installed")
        return installed_any
    end

    -- Boot-persisted override (config) installs the hooks immediately; the
    -- empty default costs nothing until the Debug tab installs them.
    if type(config.NATIVE_TOAST_PANEL_STATE) == "string" and config.NATIVE_TOAST_PANEL_STATE ~= "" then
        bridge.native_notice_panel_override = config.NATIVE_TOAST_PANEL_STATE
        install_panel_state_hooks()
    end

    -- ------------------------------------------------------------ rate gate
    -- The rail shows a handful of entries; a burst would scroll everything
    -- away. Excess pushes queue here and drain one per frame. (Reconnect
    -- catch-up bursts never reach this - they stay coalesced on the imgui
    -- summary toast via native_route = "overlay_only".)
    local push_window_start = 0.0
    local push_window_count = 0
    local deferred = {}
    local PUSHES_PER_SECOND = 3
    local DEFERRED_CAP = 12

    local function rate_gate_allows()
        local now = os.clock()
        if (now - push_window_start) >= 1.0 then
            push_window_start = now
            push_window_count = 0
        end
        if push_window_count >= PUSHES_PER_SECOND then
            return false
        end
        push_window_count = push_window_count + 1
        return true
    end

    -- -------------------------------------------------------------- pushers
    local function push_text_now(text, opts)
        opts = opts or {}
        local req = create_request("chainsaw.gui.NoticeLogRequest")
        if req == nil then
            set_status("FAIL notice: create_instance returned nil")
            return false
        end
        local value = tonumber(opts.value) or 1
        local owner = tonumber(opts.owner) or owner_system()
        local constructed = call_ctor(
            req,
            ".ctor(System.Int32, System.String, chainsaw.gui.LogOwnerType)",
            value, tostring(text), owner
        )
        if not constructed then
            -- Fallback: default ctor + direct field writes.
            local ok_fields = call_ctor(req, ".ctor()")
            if ok_fields then
                pcall(function()
                    req:set_field("Log", tostring(text))
                    req:set_field("Value", value)
                    req:set_field("LogOwnerType", owner)
                end)
            else
                set_status("FAIL notice: no usable ctor")
                return false
            end
        end
        if opts.wide then
            set_wide(req)
        end
        return submit(req, "notice(" .. tostring(text):sub(1, 40) .. ")")
    end

    local function push_text(text, opts)
        if type(text) ~= "string" or text == "" then
            return false
        end
        if not rate_gate_allows() then
            if #deferred < DEFERRED_CAP then
                deferred[#deferred + 1] = { text = text, opts = opts }
            end
            return true -- queued counts as handled; drain happens in the tick
        end
        return push_text_now(text, opts)
    end

    local function push_item_get(item_id, count, opts)
        opts = opts or {}
        local id = tonumber(item_id)
        if id == nil then
            return false
        end
        local req = create_request("chainsaw.gui.ItemGetLogRequest")
        if req == nil then
            set_status("FAIL itemget: create_instance returned nil")
            return false
        end
        local constructed = call_ctor(
            req,
            ".ctor(System.Int32, chainsaw.ItemID, chainsaw.gui.LogOwnerType, chainsaw.StatusEffectID)",
            tonumber(count) or 1, id, tonumber(opts.owner) or owner_system(), effect_id_none()
        )
        if not constructed then
            set_status("FAIL itemget: ctor rejected")
            return false
        end
        return submit(req, "itemget(" .. id .. ")")
    end

    local function push_item_recieve(item_id, count, opts)
        opts = opts or {}
        local id = tonumber(item_id)
        if id == nil then
            return false
        end
        local req = create_request("chainsaw.gui.ItemRecieveLogRequest")
        if req == nil then
            set_status("FAIL itemrecieve: create_instance returned nil")
            return false
        end
        local constructed = call_ctor(
            req,
            ".ctor(System.Int32, chainsaw.ItemID, chainsaw.gui.LogOwnerType)",
            tonumber(count) or 1, id, tonumber(opts.owner) or owner_system()
        )
        if not constructed then
            set_status("FAIL itemrecieve: ctor rejected")
            return false
        end
        return submit(req, "itemrecieve(" .. id .. ")")
    end

    -- ------------------------------------------------------------- composer
    local function color_to_hex(color)
        if type(color) ~= "table" then
            return nil
        end
        local r = math.floor((tonumber(color[1]) or 1) * 255 + 0.5)
        local g = math.floor((tonumber(color[2]) or 1) * 255 + 0.5)
        local b = math.floor((tonumber(color[3]) or 1) * 255 + 0.5)
        if r >= 250 and g >= 250 and b >= 250 then
            return nil -- white = default text colour, no tag needed
        end
        return string.format("%02X%02X%02X", r, g, b)
    end

    local function wrap_color(text, color)
        local hex = color_to_hex(color)
        if hex == nil then
            return text
        end
        return "<COLOR " .. hex .. ">" .. text .. "</COLOR>"
    end

    local function classification_color(classification)
        local cls = tostring(classification or ""):upper()
        if cls == "PROGRESSION" then
            return config.CHECK_OVERLAY_TEXT_COLOR_PROGRESS
        end
        if cls == "USEFUL" then
            return config.CHECK_OVERLAY_TEXT_COLOR_USEFUL
        end
        return nil
    end

    -- Glyph prefix for NATIVE lines only (the rail draws the real game font -
    -- Unicode verified live; the imgui overlay/Message Log keep their ASCII
    -- prefixes). Same two-axis rules as data.lua's imgui prefix: meta events
    -- show the kind glyph alone, item events kind + rarity, kindless probes
    -- rarity only. The rarity glyph carries the classification colour.
    local NATIVE_KIND_GLYPHS = {
        received = config.NATIVE_GLYPH_KIND_RECEIVED,
        sent = config.NATIVE_GLYPH_KIND_SENT,
        hint = config.NATIVE_GLYPH_KIND_HINT,
        goal = config.NATIVE_GLYPH_KIND_GOAL,
        death = config.NATIVE_GLYPH_KIND_DEATH,
    }
    local NATIVE_RARITY_GLYPHS = {
        PROGRESSION = config.NATIVE_GLYPH_RARITY_PROGRESSION,
        USEFUL = config.NATIVE_GLYPH_RARITY_USEFUL,
        FILLER = config.NATIVE_GLYPH_RARITY_FILLER,
    }

    local function native_glyph_prefix(kind, classification)
        if config.NATIVE_GLYPHS_ENABLED == false then
            return ""
        end
        local normalized_kind = tostring(kind or ""):lower()
        local kind_glyph = NATIVE_KIND_GLYPHS[normalized_kind] or ""
        local is_meta = normalized_kind == "hint"
            or normalized_kind == "goal"
            or normalized_kind == "death"
        local prefix = (kind_glyph ~= "") and (kind_glyph .. " ") or ""
        if not is_meta then
            local cls = tostring(classification or ""):upper()
            local rarity_glyph = NATIVE_RARITY_GLYPHS[cls] or ""
            if rarity_glyph ~= "" then
                prefix = prefix .. wrap_color(rarity_glyph, classification_color(cls)) .. " "
            end
        end
        return prefix
    end

    -- Character count as seen on screen: colour tags collapse to nothing and
    -- multi-byte UTF-8 glyphs count once (#line counts bytes, which both the
    -- tags and the glyphs inflate).
    local function visible_length(line)
        local stripped = line
            :gsub("<COLOR %x+>", ""):gsub("</COLOR>", "")
            :gsub("<COL [^>]+>", ""):gsub("</COL>", "")
        local count = 0
        for _ in stripped:gmatch("[^\128-\191]") do
            count = count + 1
        end
        return count
    end

    -- Build the native one-liner from a check_notifications record. Segments
    -- keep their per-entity colours as inline tags; segmentless titles get the
    -- classification colour for the whole line. The "was <vanilla>" origin
    -- detail stays Message-Log-only by design; every other detail is appended.
    local function compose_from_record(rec)
        local pieces = {}
        if type(rec.title_segments) == "table" and #rec.title_segments > 0 then
            for _, segment in ipairs(rec.title_segments) do
                local text = tostring(segment.text or "")
                if text ~= "" then
                    local wrapped = wrap_color(text, segment.color)
                    -- Filler items are white on the imgui overlay (deliberate), but
                    -- on the native rail white is the connective colour - tint the
                    -- ITEM entity parchment so the name still reads as a thing.
                    if wrapped == text and segment.entity == "item"
                        and type(config.NATIVE_ITEM_FALLBACK_HEX) == "string"
                        and config.NATIVE_ITEM_FALLBACK_HEX ~= "" then
                        wrapped = "<COLOR " .. config.NATIVE_ITEM_FALLBACK_HEX .. ">"
                            .. text .. "</COLOR>"
                    end
                    pieces[#pieces + 1] = wrapped
                end
            end
        else
            local title = tostring(rec.title or "")
            if title ~= "" then
                local color = classification_color(rec.classification)
                pieces[#pieces + 1] = color and wrap_color(title, color) or title
            end
        end
        local line = table.concat(pieces, " ")
        local detail = tostring(rec.detail or "")
        if detail ~= "" and detail:sub(1, 4) ~= "was " then
            line = (line ~= "") and (line .. " - " .. detail) or detail
        end
        if line == "" then
            return ""
        end
        return native_glyph_prefix(rec.kind, rec.classification) .. line
    end

    local function is_ap_connected()
        return bridge.ap_status_kind == "connected"
    end

    -- ------------------------------------------------------------ dispatcher
    -- Runs every frame from the entry's re.on_frame, AFTER
    -- capture_message_log_entries so the durable log always sees a record
    -- before the overlay's pruner may drop it (ui_overlay only drops records
    -- that are BOTH rendered_natively AND already captured).
    --
    -- Routes (producer-set rec.native_route, default "text"):
    --   "text"         - compose + push onto the native rail
    --   "suppress"     - the game's own organic pickup toast already shows
    --                    this (local in-world pickup): push nothing, just stop
    --                    the imgui duplicate. Offline, push a queued-notice
    --                    line instead so the reassurance is not lost.
    --   "overlay_only" - never native (the mutating "Synced N items" summary)
    local DISPATCH_MAX_AGE_MS = 10000

    local function dispatch_native_toasts()
        local mode = bridge.native_toast_mode
        if mode ~= "native" and mode ~= "both" then
            return
        end

        -- Drain one deferred rate-gated push per frame.
        if #deferred > 0 and rate_gate_allows() then
            local item = table.remove(deferred, 1)
            push_text_now(item.text, item.opts)
        end

        if type(bridge.check_notifications) ~= "table" then
            return
        end
        local now = ctx.now_unix_ms and ctx.now_unix_ms() or (os.time() * 1000)
        for _, rec in ipairs(bridge.check_notifications) do
            if not rec.native_dispatched then
                rec.native_dispatched = true
                local age = now - (tonumber(rec.queued_at_unix_ms) or now)
                local route = rec.native_route or "text"
                if age > DISPATCH_MAX_AGE_MS or route == "overlay_only" then
                    -- stale (mode was flipped after it queued) or opted out
                elseif route == "suppress" then
                    if mode == "native" then
                        if is_ap_connected() then
                            rec.rendered_natively = true
                        else
                            -- Offline: the organic toast can't say "queued";
                            -- surface that on the rail in place of the imgui line.
                            if push_text(compose_from_record(rec) .. " - queued offline", {}) then
                                rec.rendered_natively = true
                            end
                        end
                    end
                    -- "both": leave the imgui toast alongside the organic one
                    -- (that IS the legacy double-toast, kept for comparison).
                else -- "text"
                    local line = compose_from_record(rec)
                    if line ~= "" then
                        -- Wide at >40 visible chars: the narrow panel auto-shrinks
                        -- longer lines into squished text (live find, Cam 2026-07-23).
                        local pushed = push_text(line, { wide = visible_length(line) > 40 })
                        if pushed and mode == "native" then
                            rec.rendered_natively = true
                        end
                    end
                end
            end
        end
    end

    -- -------------------------------------------------------------- debug UI
    -- Spike surface (Debug tab): every unknown the dump could not answer gets
    -- a button. Results land in bridge.native_log_status + the REFramework log.
    local function draw_native_log_content()
        imgui.text("Native Toast Rail (spike)")
        local mode_labels = { "native", "overlay", "both" }
        local mode_index = 1
        for i, m in ipairs(mode_labels) do
            if bridge.native_toast_mode == m then
                mode_index = i
            end
        end
        local changed_mode, new_mode_index = imgui.combo("Toast mode", mode_index, mode_labels)
        if changed_mode then
            bridge.native_toast_mode = mode_labels[new_mode_index] or "overlay"
        end
        imgui.text("Last result: " .. tostring(bridge.native_log_status))

        if imgui.button("Probe manager + enums") then
            local mgr = get_manager()
            set_status(string.format(
                "manager=%s ownerSystem=%s ownerPlayer=%s effectNone=%s",
                mgr ~= nil and "FOUND" or "MISSING",
                tostring(owner_system()),
                tostring(enum_value("chainsaw.gui.LogOwnerType", "Player", -1)),
                tostring(effect_id_none())
            ))
        end
        if imgui.button("Notice: plain") then
            push_text_now("AP native rail test - plain text", {})
        end
        if imgui.button("Notice: hex colour tags") then
            push_text_now("Sent <COLOR E0B24A>Red9</COLOR> to <COLOR 73C7F5>Alice</COLOR>", {})
        end
        if imgui.button("Notice: preset tag (COL FILE)") then
            push_text_now("Preset tag <COL FILE>gold words</COL> test", {})
        end
        if imgui.button("Notice: wide + long") then
            push_text_now(
                "Wide log test - a much longer Archipelago line to see how the rail wraps or clips it",
                { wide = true }
            )
        end
        if imgui.button("Notice: unicode") then
            push_text_now("Unicode test: \u{00C5}lice \u{2605} \u{2192} works?", {})
        end
        if imgui.button("Notice: owner=Player") then
            push_text_now("Owner Player test", { owner = enum_value("chainsaw.gui.LogOwnerType", "Player", 0) })
        end
        if imgui.button("Notice: glyph sampler") then
            push_text_now("Glyphs: ← → ★ ◆ • ☠ † × ✝ ✟ ✓ ✗ ⚑ ◈ ↔ ▲", {})
        end
        if imgui.button("Notice: glyph prefix demo") then
            push_text_now(
                native_glyph_prefix("sent", "PROGRESSION")
                    .. "Sent <COLOR E0B24A>Red9</COLOR> to <COLOR 73C7F5>Alice</COLOR>",
                {}
            )
        end

        imgui.text(string.format(
            "Panel states - itemget: %s | notice: %s | recieve: %s",
            tostring(bridge.native_log_itemget_panel_state or "?"),
            tostring(bridge.native_log_notice_panel_state or "?"),
            tostring(bridge.native_log_recieve_panel_state or "?")
        ))
        if imgui.button("Install panel-state hooks") then
            install_panel_state_hooks()
        end
        local override_active = type(bridge.native_notice_panel_override) == "string"
            and bridge.native_notice_panel_override ~= ""
        local changed_style, style_value =
            imgui.checkbox("Style notices like item toasts (capture itemget state first)", override_active)
        if changed_style then
            if style_value then
                local captured = bridge.native_log_itemget_panel_state
                if type(captured) == "string" and captured ~= "" then
                    bridge.native_notice_panel_override = captured
                    install_panel_state_hooks()
                    set_status("notice style override = '" .. captured .. "'")
                else
                    set_status("no itemget state captured - install hooks, then pick up any item")
                end
            else
                bridge.native_notice_panel_override = ""
                set_status("notice style override off")
            end
        end

        if imgui.button("ItemGet: placeholder x1") then
            push_item_get(config.PLACEHOLDER_ITEM_ID, 1)
        end
        if imgui.button("ItemGet: placeholder x3 (Value=count?)") then
            push_item_get(config.PLACEHOLDER_ITEM_ID, 3)
        end
        if imgui.button("ItemRecieve: placeholder") then
            push_item_recieve(config.PLACEHOLDER_ITEM_ID, 1)
        end
    end

    export("push_native_text", push_text)
    export("push_native_item_get", push_item_get)
    export("push_native_item_recieve", push_item_recieve)
    export("dispatch_native_toasts", dispatch_native_toasts)
    export("draw_native_log_content", draw_native_log_content)
end

return install
