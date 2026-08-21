local function install(ctx)
    local bridge = {
        state_dirty = false,
        ap_connection_status = "Disconnected",
        ap_session_seed_name = "",
        ap_session_slot_name = "",
        checks_sent_session = 0,
        last_item_received = "(none)",
        injected_ap_item_indexes = {},
        -- Durable received-item watermark: the highest AP item.index that has been
        -- injected or deliberately skipped. Persisted per-seed (bridge.lua save/
        -- load_session_state) so a Sync/reconnect full replay from index 0 cannot
        -- re-inject. injected_ap_item_indexes above is only a within-boot secondary
        -- guard (wiped on reset/reload); this is the durable source of truth.
        last_received_index = -1,
        -- [F8] Save-reconciliation. Per-campaign-guid record of the received-item
        -- watermark baked into each campaign save version (_SaveCount), persisted
        -- alongside last_received_index (bridge.lua save/load_session_state). On a
        -- campaign load that rolled inventory back to an older save, the AP client
        -- re-delivers items that save did not contain. Shape:
        --   guid -> { save_watermarks = { [saveCountString] = watermark } }
        save_reconcile_map = {},
        -- [F8] Set by the loadGameSaveData hook to { guid, save_count } of the save
        -- being loaded; consumed once by the AP client's drain to reconcile. nil = none.
        pending_save_reconcile = nil,
        -- Consolidated window (ui_main_window.lua): one flag for the whole
        -- tabbed "Archipelago RE4R" window; Developer Tools reveals the Debug
        -- tab (probe, inject, warp editor). The legacy per-window flags below
        -- are retired from the UI but kept as fields for save compatibility.
        main_window_enabled = true,
        developer_tools_enabled = false,
        -- [Actions tab] picker/chat state + the inline confirm slot
        -- ("force" | "release" | "collect" | "").
        actions_hint_filter = "",
        actions_hint_selected_index = 1,
        actions_location_selected_index = 1,
        actions_say_text = "",
        actions_confirm = "",
        force_check_announce = true,
        status_window_enabled = true,
        -- Manual inject window: developer tool, hidden by default (Cam
        -- 2026-07-17). Stuck-player recovery runs on AP-native paths (Force
        -- Check / hints / room-console send); the injection ENGINE stays as
        -- the AP item delivery path. Re-enable via the script UI checkbox.
        inject_window_enabled = false,
        connection_window_enabled = true,
        message_log_window_enabled = false,
        last_state = nil,
        ui_current_chapter = nil,
        ui_current_chapter_display = "(unknown)",
        ui_chapter_source = nil,
        launcher_server_address = "",
        launcher_slot_name = "",
        loaded_session_state_path = nil,
        victory_sent = false,
        victory_pending = false,
        -- [Tutorial] tutorial_enabled comes from slot_data (YAML, default on);
        -- tutorial_shown is per-seed and persists in the session file.
        tutorial_enabled = true,
        tutorial_shown = false,
        tutorial_dialog_open = false,
        tutorial_page = 1,
        -- [Non-lead pickups] Location ids collected while a character other
        -- than the campaign lead was playing. Their inventory is thrown away
        -- when the section ends, so the own-find skip must not assume the
        -- player kept what they physically picked up. Per-seed, persisted.
        non_lead_checked_locations = {},
        pending_checks = {},
        pending_check_keys = {},
        next_pending_check_id = 1,
        pending_pickup_accepts = {},
        next_pending_pickup_accept_id = 1,
        pickup_probe = nil,
        local_injection_suppressions = {},
        check_notifications = {},
        next_check_notification_id = 1,
        -- [Celebration] The single active centre-screen celebration, or nil.
        -- { title = <headline>, details = { <line>, ... }, started_clock_ms = os.clock()*1000 }
        -- Set by ui_overlay.trigger_celebration; the renderer clears it on expiry.
        -- Rare + loud (currently ONLY the goal), so one slot is enough.
        celebration = nil,
        -- Message Log: a durable, in-session copy of every toast (checks, received
        -- items, hints, goals) so an event missed in the ~4.5s HUD window stays
        -- recoverable. Captured passively from check_notifications by an id
        -- high-water mark (ui_windows.capture_message_log_entries);
        -- message_log_last_id is that mark.
        message_log = {},
        message_log_last_id = 0,
        progression_warning_dialog = nil,
        progression_warning_shown_chapters = {},
        progression_warning_visited_stages = {},
        progression_warning_chapter_stage_map = {},
        progression_warning_stage_chapter_membership = {},
        acknowledged_guid_keys = {},
        location_classifications = {},
        -- [Hints] Unfound hints ON OUR LOCATIONS, keyed by location_id string:
        -- { location_id, item_id, item_name, receiving_player,
        --   receiving_player_name, item_flags }. Synced from server data
        -- storage (_read_hints) by apclient.lua; consumed by hint markers,
        -- toasts, and the AP Actions window.
        hints_on_my_world = {},
        last_scan_clock = 0,
        tracked_stage_id = nil,
        tracked_visible_guids = {},
        tracked_guid_snapshots = {},
        holder_guid_by_key = {},
        recent_holder_hit = nil,
        watched_guid_count = 0,
        visible_guid_count = 0,
        visible_guid_sample = {},
        warp_window_enabled = false,
        warp_editor_window_enabled = false,
        -- [Marker position editor] Developer tool: nudge a marker onto the real
        -- item and log a _POSITION_OVERRIDES line. Gated by developer_tools too.
        marker_editor_window_enabled = false,
        -- [D9 spike] Developer tool: probe GmBoat / PierDataSet / ReturnPortInfo
        -- at the lake so the boat-follows-the-player design can be settled.
        -- Temporary; goes away with ui_boat_spike.lua when D9 is built.
        boat_spike_window_enabled = false,
        model_tuner_window_enabled = false,
        -- [World markers] floating "[AP]" tags over unchecked locations in the
        -- current stage (ui_world_markers.lua). Importance colours reveal scouted
        -- classification, so they are opt-in (guidance says where, never what).
        world_markers_enabled = true,
        -- 15m, down from 40m (Cam, 2026-08-13): a shorter leash trades a
        -- screenful of distant tags for markers you meet by exploring, and it
        -- pays for the richer text the tiers now carry. The Guidance slider
        -- still spans 10-100m for anyone who wants the old reach back.
        world_markers_max_distance = 15.0,
        world_markers_show_distance = true,
        world_markers_importance_colors = false,
        -- [D5] True when the launcher's room file says this world was patched
        -- with allow-bonus-items; drives the bonus-weapon force-unlock.
        allow_bonus_items = false,
        -- Marker detail tier (minimal | basic | locate | identify |
        -- developer). Set from slot_data.marker_detail on connect, which is
        -- where the player already chose it, and freely changed in Guidance
        -- with no cap. This literal only matters before the first connect.
        world_markers_detail = "basic",
        -- True once the player picks a tier in Guidance. From then on their
        -- choice persists per seed and the settings file stops overriding it.
        world_markers_detail_chosen = false,
        -- Markers whose chapter differs from the current one are muted + tagged;
        -- this toggle hides those off-chapter markers outright instead.
        world_markers_hide_offchapter = false,
        -- [Hints] "[HINT]" markers over locations with an unfound purchased
        -- hint: whole-stage range, independent of the ambient toggle above
        -- (bought information), still killed by check_guidance "off".
        world_markers_show_hints = true,
        -- YAML permission ceiling from slot_data.check_guidance (apclient.lua):
        -- "off" | "markers" | "markers_rarity". Pre-connect default allows
        -- neutral markers so offline/manual testing behaves like older seeds.
        check_guidance_ceiling = "markers",
        -- [Port recovery] archipelago.gg recycles room ports when a room sleeps,
        -- so a recorded address can start answering a STRANGER's room (live
        -- 2026-07-22: 65188 -> 46497, surfaced only as "Refused: InvalidSlot")
        -- or nothing at all. apclient.lua detects both and parks the details
        -- here; ui_warning.lua draws the recovery dialog. nil = all good.
        -- Shape: { kind = "seed_mismatch" | "unreachable", expected_seed,
        --          actual_seed, server, attempts }
        port_recovery_dialog = nil,
        port_recovery_input = "",
        port_recovery_status = "",
        -- [Server tab] Edit buffer for the address field and the last result
        -- line. The buffer seeds itself from the live address the first time
        -- the tab draws, so it never starts blank.
        server_tab_address_input = "",
        server_tab_status = "",
        inject_selected_category = "All",
        inject_selected_item_index = 1,
        inject_filter_text = "",
        inject_item_id_text = "277078656",
        inject_count = 1,
        inject_count_text = "1",
        inject_status = "(idle)",
        inject_status_detail = "(idle)",
        inject_recent_item_ids = {},
        warp_stage_id = 0,
        warp_x = 0.0,
        warp_y = 0.0,
        warp_z = 0.0,
        last_warp_status = "(idle)",
        warp_points = {},
        warp_point_names = {},
        selected_warp_index = 1,
        typewriter_warp_points = {},
        typewriter_warp_point_names = {},
        typewriter_warp_stage_lookup = {},
        selected_typewriter_warp_index = 1,
        warp_points_status = "(not loaded)",
        unlocked_warp_stage_ids = {},
        loaded_warp_unlocks_path = nil,
        pending_warp = nil,
        chapter_switch_selected_index = 1,
        chapter_switch_pending = false,
        chapter_switch_pending_chapter_id = nil,
        chapter_switch_pending_special_jump_sequence = nil,
        chapter_switch_status = "(idle)",
        chapter_switch_last_armed_label = nil,
        -- [Shop open state] merchant.lua sets this from the shop's own
        -- enter/close states. Read ONLY by apclient's safe_to_inject, to
        -- keep a DeathLink kill and item delivery out of an open shop.
        shop_gui_open = false,
    }

    bridge.progression_warning_final_stage_by_chapter = {
        [1] = 43410,
        [2] = 44110,
        [3] = 45500, -- Cam confirmed best Chapter 3 final-warning stage; require prior visit to 45400 before warning.
        [4] = 45210, -- Best guess: avoid shared church interior stage 45401, which resolves as Chapter 5.
        [5] = 43311,
        [6] = 47410,
        [7] = 50601,
        [8] = 51202, -- Best guess: avoid shared stage 51200, which resolves as Chapter 9 in the stage map.
        [9] = 52202, -- Best guess: armory as the latest chapter-unique stage in current data.
        [10] = 54407, -- Best guess: waterway generator as the final chapter-unique stage before rollover.
        [11] = 55300, -- Best guess: minecart/hive segment before the Chapter 12 transition.
        [12] = 56200, -- Best guess: Salazar boss arena.
        [13] = 62200,
        [14] = 65100,
        [15] = 66105,
        [16] = 69100, -- Best guess: final boss arena rather than the post-fight cleanup stages.
    }

    ctx.bridge = bridge

    ctx.reset_session_state = function()
        bridge.state_dirty = false
        bridge.pending_checks = {}
        bridge.pending_check_keys = {}
        bridge.pending_pickup_accepts = {}
        bridge.next_pending_pickup_accept_id = 1
        bridge.pickup_probe = nil
        bridge.local_injection_suppressions = {}
        bridge.check_notifications = {}
        bridge.next_check_notification_id = 1
        bridge.celebration = nil
        bridge.message_log = {}
        bridge.message_log_last_id = 0
        bridge.progression_warning_dialog = nil
        bridge.progression_warning_shown_chapters = {}
        bridge.progression_warning_visited_stages = {}
        bridge.acknowledged_guid_keys = {}
        bridge.last_scan_clock = 0
        bridge.tracked_stage_id = nil
        bridge.tracked_visible_guids = {}
        bridge.tracked_guid_snapshots = {}
        bridge.holder_guid_by_key = {}
        bridge.recent_holder_hit = nil
        bridge.injected_ap_item_indexes = {}
        bridge.last_received_index = -1
        bridge.save_reconcile_map = {}
        bridge.pending_save_reconcile = nil
        bridge.location_classifications = {}
        bridge.watched_guid_count = 0
        bridge.visible_guid_count = 0
        bridge.visible_guid_sample = {}
        bridge.launcher_server_address = ""
        bridge.launcher_slot_name = ""
        bridge.loaded_session_state_path = nil
        bridge.victory_pending = false
        bridge.victory_sent = false
    end
end

return install
