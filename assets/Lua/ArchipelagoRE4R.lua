local ctx = {}
dofile("reframework\\autorun\\ArchipelagoRE4R\\config.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\state.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\data.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\runtime.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\injection.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\detector.lua")(ctx)

local bridge = ctx.bridge

local function now_unix_ms()
    return os.time() * 1000
end

ctx.now_unix_ms = now_unix_ms
_G.now_unix_ms = now_unix_ms

dofile("reframework\\autorun\\ArchipelagoRE4R\\warp.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\bridge.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\native_log.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\ui_overlay.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\ui_world_markers.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\ui_warning.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\ui_windows.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\ui_checks.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\ui_guidance.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\ui_tutorial.lua")(ctx)
dofile("reframework\\autorun\\ArchipelagoRE4R\\ui_main_window.lua")(ctx)
-- In-Lua Archipelago client (lua-apclientpp). Loaded last so it can reach the
-- full ctx (injection/runtime/session) in later phases. Phase 2a: log-only,
-- behaviour identical to the former standalone reframework/autorun/
-- ArchipelagoRE4R_apclient.lua, which this replaces.
dofile("reframework\\autorun\\ArchipelagoRE4R\\apclient.lua")(ctx)

-- Build identification for support triage: one boot line pairing the Lua
-- build with the launcher's install stamp (version_stamp.json, written at
-- patch time; absent means a pre-stamp or hand-copied install).
do
    local stamp = json.load_file(ctx.config.VERSION_STAMP_FILE)
    local stamp_text = "no launcher stamp"
    if type(stamp) == "table" then
        stamp_text = string.format(
            "launcher %s, payload %s, installed %s",
            tostring(stamp.launcher_version or "?"),
            tostring(stamp.payload_version or "?"),
            tostring(stamp.installed_utc or "?")
        )
    end
    log.info(string.format(
        "[RE4R AP] mod %s (%s)",
        tostring(ctx.config.MOD_VERSION),
        stamp_text
    ))
end

local load_injectable_items = ctx.load_injectable_items
local load_location_display_map = ctx.load_location_display_map
local load_location_guid_map = ctx.load_location_guid_map
local load_stage_chapter_map = ctx.load_stage_chapter_map
local load_warp_points = ctx.load_warp_points
local load_warp_unlocks = ctx.load_warp_unlocks
local process_pending_warp = ctx.process_pending_warp
local refresh_launcher_bridge_files = ctx.refresh_launcher_bridge_files
local save_session_state = ctx.save_session_state
local select_known_injectable_item = ctx.select_known_injectable_item
local select_typewriter_warp_point = ctx.select_typewriter_warp_point
local select_warp_point = ctx.select_warp_point
local sync_typewriter_warp_unlock_for_stage = ctx.sync_typewriter_warp_unlock_for_stage

local clear_pending_pickup_accepts = ctx.clear_pending_pickup_accepts
local install_interact_holder_hit_hook = ctx.install_interact_holder_hit_hook
local install_pickup_accept_hook = ctx.install_pickup_accept_hook
local install_pickup_commit_hook = ctx.install_pickup_commit_hook
local prune_local_injection_suppressions = ctx.prune_local_injection_suppressions
local prune_pending_pickup_accepts = ctx.prune_pending_pickup_accepts
local scan_stage_pickups = ctx.scan_stage_pickups

local dispatch_native_toasts = ctx.dispatch_native_toasts
local draw_celebration_overlay = ctx.draw_celebration_overlay
local draw_check_notification_overlays_polished = ctx.draw_check_notification_overlays_polished
local draw_check_progress_overlay = ctx.draw_check_progress_overlay
local draw_ap_status_menu_overlay = ctx.draw_ap_status_menu_overlay
local draw_world_check_markers = ctx.draw_world_check_markers
local draw_main_window = ctx.draw_main_window
local maybe_show_tutorial = ctx.maybe_show_tutorial
local draw_tutorial_dialog = ctx.draw_tutorial_dialog
local draw_progression_warning_dialog = ctx.draw_progression_warning_dialog
local draw_port_recovery_dialog = ctx.draw_port_recovery_dialog
local capture_message_log_entries = ctx.capture_message_log_entries
local maybe_show_progression_warning = ctx.maybe_show_progression_warning
local sync_warp_inputs_to_current_state = ctx.sync_warp_inputs_to_current_state

local get_runtime_state = ctx.get_runtime_state
local resolve_chapter_for_ui = ctx.resolve_chapter_for_ui
local last_state_process_clock = 0

local function install_chapter_switch_hook()
    local campaign_type = sdk.find_type_definition("chainsaw.CampaignManager")
    if campaign_type == nil then
        log.info("[RE4R AP] CampaignManager type not found for chapter switch hook")
        bridge.chapter_switch_status = "Chapter switch hook unavailable"
        return
    end

    local load_save_method = campaign_type:get_method("loadGameSaveData")
    if load_save_method == nil then
        log.info("[RE4R AP] CampaignManager.loadGameSaveData not found for chapter switch hook")
        bridge.chapter_switch_status = "Chapter switch hook unavailable"
        return
    end

    sdk.hook(
        load_save_method,
        function(args)
            clear_pending_pickup_accepts("loadGameSaveData")
            -- [F8] Record which campaign save version is being loaded so the AP
            -- client can reconcile received-item delivery against it (restore items
            -- a rollback dropped). Runs on EVERY load (chapter switch or not);
            -- reconciliation is itself a safe no-op when nothing was lost or the
            -- loaded version has no recorded watermark.
            do
                local reader = ctx.read_campaign_save_ids
                if type(reader) == "function" then
                    local ok, guid, count = pcall(function()
                        return reader(sdk.to_managed_object(args[3]))
                    end)
                    if ok and type(guid) == "string" and guid ~= ""
                        and type(count) == "number" then
                        bridge.pending_save_reconcile = { guid = guid, save_count = math.floor(count) }
                    end
                end
            end
            if not bridge.chapter_switch_pending then
                return sdk.PreHookResult.CALL_ORIGINAL
            end

            local armed_label = tostring(bridge.chapter_switch_last_armed_label or "Chapter switch")
            local armed_chapter_id = tonumber(bridge.chapter_switch_pending_chapter_id)
            local armed_special_jump_sequence = tonumber(bridge.chapter_switch_pending_special_jump_sequence)
            bridge.chapter_switch_pending = false
            bridge.chapter_switch_pending_chapter_id = nil
            bridge.chapter_switch_pending_special_jump_sequence = nil
            if armed_chapter_id == nil or armed_special_jump_sequence == nil then
                bridge.chapter_switch_status = "Chapter switch failed"
                return sdk.PreHookResult.CALL_ORIGINAL
            end

            local save_data = sdk.to_managed_object(args[3])
            if save_data == nil then
                bridge.chapter_switch_status = string.format("%s failed: save data missing", armed_label)
                log.error("[RE4R AP] Chapter switch failed: save data missing")
                return sdk.PreHookResult.CALL_ORIGINAL
            end

            local init_settings_type = sdk.find_type_definition("chainsaw.CampaignInitialSetting")
            local init_settings_field = save_data:get_type_definition():get_field("_InitialSettings")
            if init_settings_type == nil or init_settings_field == nil then
                bridge.chapter_switch_status = string.format("%s failed: initial settings missing", armed_label)
                log.error("[RE4R AP] Chapter switch failed: CampaignInitialSetting or _InitialSettings missing")
                return sdk.PreHookResult.CALL_ORIGINAL
            end

            local init_settings = sdk.to_managed_object(init_settings_field:get_data(save_data, false))
            if init_settings == nil then
                bridge.chapter_switch_status = string.format("%s failed: initial settings null", armed_label)
                log.error("[RE4R AP] Chapter switch failed: initial settings null")
                return sdk.PreHookResult.CALL_ORIGINAL
            end

            local ok, err = pcall(function()
                sdk.set_native_field(init_settings, init_settings_type, "_Chapter", armed_chapter_id)
                sdk.set_native_field(
                    init_settings,
                    init_settings_type,
                    "_SpecialJumpSequence",
                    armed_special_jump_sequence
                )
            end)
            if not ok then
                bridge.chapter_switch_status = string.format("%s failed: %s", armed_label, tostring(err))
                log.error("[RE4R AP] Chapter switch failed: " .. tostring(err))
                return sdk.PreHookResult.CALL_ORIGINAL
            end

            bridge.chapter_switch_status = string.format("%s applied on load", armed_label)
            log.info(
                string.format(
                    "[RE4R AP] Chapter switch applied: label=%s chapter=%s special_jump=%s",
                    tostring(armed_label),
                    tostring(armed_chapter_id),
                    tostring(armed_special_jump_sequence)
                )
            )
            return sdk.PreHookResult.CALL_ORIGINAL
        end,
        function(retval)
            return retval
        end
    )
end

-- [F8] Record, at each campaign save, the received-item watermark baked into the
-- resulting save version (guid + _SaveCount). The AP client's load-time
-- reconciliation reads these back to restore items a later rollback dropped. The
-- populated GameData is the method's RETURN value (saveGameSaveData builds and
-- returns it), mirroring the probe that mapped this choke point.
local function install_save_watermark_hook()
    local campaign_type = sdk.find_type_definition("chainsaw.CampaignManager")
    if campaign_type == nil then
        log.info("[RE4R AP] CampaignManager type not found -- F8 save-watermark capture disabled")
        return
    end
    local save_method = campaign_type:get_method("saveGameSaveData")
    if save_method == nil then
        log.info("[RE4R AP] CampaignManager.saveGameSaveData not found -- F8 save-watermark capture disabled")
        return
    end
    sdk.hook(
        save_method,
        function(args)
            return sdk.PreHookResult.CALL_ORIGINAL
        end,
        function(retval)
            local ok, err = pcall(function()
                local reader = ctx.read_campaign_save_ids
                local record = ctx.record_save_watermark
                if type(reader) ~= "function" or type(record) ~= "function" then
                    return
                end
                local guid, count = reader(sdk.to_managed_object(retval))
                if type(guid) == "string" and guid ~= "" and type(count) == "number" then
                    local watermark = math.floor(tonumber(bridge.last_received_index) or -1)
                    record(guid, count, watermark)
                    if type(save_session_state) == "function" then
                        save_session_state()
                    end
                    log.info(string.format(
                        "[RE4R AP] F8: recorded save watermark guid=%s save#%d watermark=%d",
                        guid, count, watermark))
                end
            end)
            if not ok then
                log.error("[RE4R AP] F8 save-watermark hook error: " .. tostring(err))
            end
            return retval
        end
    )
end

local function build_state(runtime_state)
    runtime_state = runtime_state or get_runtime_state()

    -- [Phase 5 Group 2] Reduced to the fields read in-process via bridge.last_state
    -- (UI/overlay/detector/apclient). The file-protocol metadata and the serialized
    -- pending_checks/last_command/capabilities went with the Python file bridge.
    return {
        scene_name = runtime_state.scene_name,
        player_present = runtime_state.player_present,
        current_stage = runtime_state.current_stage,
        is_in_game = runtime_state.is_in_game,
        is_title_screen = runtime_state.is_title_screen,
        is_paused = runtime_state.is_paused,
        is_loading = runtime_state.is_loading,
        is_cutscene = runtime_state.is_cutscene,
        is_playable = runtime_state.is_playable,
        watched_guid_count = bridge.watched_guid_count,
        visible_guid_count = bridge.visible_guid_count,
        candidate_check_count = 0,
        ap_connection_status = bridge.ap_connection_status,
        victory_pending = bridge.victory_pending == true,
        victory_sent = bridge.victory_sent == true,
        last_item_received = bridge.last_item_received,
    }
end

local function maybe_trigger_victory_condition(previous_state, state)
    if type(state) ~= "table" or type(state.current_stage) ~= "number" then
        return
    end

    if state.current_stage ~= 59223 then
        return
    end

    if bridge.victory_sent == true or bridge.victory_pending == true then
        return
    end

    -- Level-triggered: latch on any cycle spent at the final stage, with no
    -- freshness or connection gate - the Python client consumes the latch
    -- whenever it (re)connects. Persisted so a script reset or game restart
    -- cannot drop the goal.
    bridge.victory_pending = true
    bridge.state_dirty = true
    save_session_state()
    log.info("[RE4R AP] Victory condition triggered at stage 59223")
end

re.on_script_reset(function()
    ctx.reset_session_state()
end)

load_stage_chapter_map()
load_location_guid_map()
load_location_display_map()
load_map_labels()
load_typewriter_regions()
load_injectable_items()
load_warp_points()
load_warp_unlocks()
if #bridge.warp_points > 0 then
    select_warp_point(1)
end
if #bridge.typewriter_warp_points > 0 then
    select_typewriter_warp_point(bridge.selected_typewriter_warp_index)
end
install_pickup_accept_hook()
install_pickup_commit_hook()
install_chapter_switch_hook()
install_save_watermark_hook()
install_interact_holder_hit_hook()

re.on_pre_application_entry("UpdateBehavior", function()
    local ok, err = pcall(function()
        local now_clock = os.clock()
        local runtime_state = nil

        if now_clock - bridge.last_scan_clock >= SCAN_INTERVAL_SECONDS then
            bridge.last_scan_clock = now_clock
            runtime_state = get_runtime_state()
            process_pending_warp(runtime_state)
            scan_stage_pickups(runtime_state)
            prune_local_injection_suppressions()
            if runtime_state.is_loading then
                clear_pending_pickup_accepts("load")
            else
                prune_pending_pickup_accepts(runtime_state.current_stage)
            end
        end

        if now_clock - last_state_process_clock < WRITE_INTERVAL_SECONDS then
            return
        end

        last_state_process_clock = now_clock
        if runtime_state == nil then
            runtime_state = get_runtime_state()
            process_pending_warp(runtime_state)
        end
        if runtime_state ~= nil and runtime_state.is_in_game and type(runtime_state.current_stage) == "number" then
            sync_typewriter_warp_unlock_for_stage(runtime_state.current_stage)
        end
        if type(refresh_launcher_bridge_files) == "function" then
            refresh_launcher_bridge_files()
        end
        local state = build_state(runtime_state)
        -- Prefer the game's authoritative current chapter (CampaignManager); fall
        -- back to the stage-derived map only when it is unavailable (menus/boot).
        local auth_chapter = nil
        local auth_getter = ctx.get_authoritative_chapter or _G.get_authoritative_chapter
        if type(auth_getter) == "function" then
            local ok_auth, value = pcall(auth_getter)
            if ok_auth then auth_chapter = value end
        end
        if type(auth_chapter) == "number" then
            bridge.ui_current_chapter = auth_chapter
            bridge.ui_current_chapter_display = tostring(auth_chapter)
            bridge.ui_chapter_source = "campaign_manager"
        else
            bridge.ui_current_chapter, bridge.ui_current_chapter_display, bridge.ui_chapter_source = resolve_chapter_for_ui(
                state.current_stage
            )
        end
        local previous_state = bridge.last_state
        maybe_show_progression_warning(previous_state, state)
        maybe_trigger_victory_condition(previous_state, state)
        state.victory_pending = bridge.victory_pending == true
        state.victory_sent = bridge.victory_sent == true
        bridge.last_state = state
        -- [Phase 5 Group 1] Outbound bridge_state.json write removed. build_state's
        -- result is published to bridge.last_state above and read in-process by the
        -- UI/overlay/detector/apclient; no file is written for the (deleted) Python client.
    end)

    if not ok then
        log.error("[ArchipelagoRE4R] Bridge update failed: " .. tostring(err))
    end
end)

if #injectable_items > 0 then
    local initial_inject_index = find_known_injectable_item_index(tonumber(bridge.inject_item_id_text))
        or math.min(math.max(bridge.inject_selected_item_index, 1), #injectable_items)
    select_known_injectable_item(initial_inject_index)
end

re.on_frame(function()
    -- Destroy intercepted placeholder drops outside their own accept hook.
    pump_placeholder_despawns()
    -- Capture toasts into the durable Message Log before the overlay prunes them.
    capture_message_log_entries()
    -- Then mirror fresh toasts onto the game's native activity-log rail (mode-
    -- gated inside; ui_overlay skips records it marks rendered_natively).
    dispatch_native_toasts()
    -- World-space check markers first; the HUD windows layer over them.
    draw_world_check_markers()
    draw_check_progress_overlay()
    -- Outside gameplay the header draws nothing, so the AP connection
    -- status gets its own line at the menus and during loads.
    draw_ap_status_menu_overlay()
    draw_check_notification_overlays_polished()
    -- After the toast rail so the goal banner layers over it.
    draw_celebration_overlay()
    draw_progression_warning_dialog()
    -- Connection recovery sits above everything else: it is only ever
    -- visible when the session cannot reach its own multiworld.
    draw_port_recovery_dialog()
    -- First-seed welcome: armed on the first playable Chapter 1 tick.
    maybe_show_tutorial()
    draw_tutorial_dialog()
    draw_main_window()
end)

re.on_draw_ui(function()
    -- One window, one toggle (consolidation 2026-07-17). Developer Tools
    -- reveals the Debug tab (probe / inject / warp editor).
    local changed_main, main_value = imgui.checkbox("Show Archipelago RE4R Window", bridge.main_window_enabled)
    if changed_main then
        bridge.main_window_enabled = main_value
    end

    local changed_dev, dev_value = imgui.checkbox("Developer Tools (Debug tab)", bridge.developer_tools_enabled)
    if changed_dev then
        bridge.developer_tools_enabled = dev_value
        if dev_value and type(sync_warp_inputs_to_current_state) == "function" then
            sync_warp_inputs_to_current_state()
        end
    end

    imgui.text("Marker settings live in the window's Guidance tab (press Insert).")
end)
