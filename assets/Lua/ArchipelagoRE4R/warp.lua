local function install(ctx)
    ctx.warp = ctx.warp or {}

    local bridge = ctx.bridge
    local warp = ctx.warp

    local function export(name, value)
        warp[name] = value
        ctx[name] = value
        _G[name] = value
    end

    local function get_prefecture_and_location_ids(stage_id)
        if type(stage_id) ~= "number" then
            return nil, nil
        end

        local pref_id = math.floor(stage_id / 1000)
        local loc_id = pref_id * 1000
        return pref_id, loc_id
    end

    local function is_typewriter_warp_name(name)
        local normalized_name = trim_string(name)
        if normalized_name == "" then
            return false
        end
        return string.find(normalized_name, "Typewriter", 1, true) ~= nil
            or string.find(normalized_name, "Save Point", 1, true) ~= nil
    end

    local function is_warp_stage_unlocked(stage_id)
        local normalized_stage_id = normalize_stage_id(stage_id)
        return normalized_stage_id ~= nil and bridge.unlocked_warp_stage_ids[normalized_stage_id] == true
    end

    local function rebuild_typewriter_warp_points()
        local previous_selection = bridge.typewriter_warp_points[bridge.selected_typewriter_warp_index]
        local previous_stage_id = previous_selection ~= nil and previous_selection.stage_id or nil

        bridge.typewriter_warp_points = {}
        bridge.typewriter_warp_point_names = {}
        bridge.typewriter_warp_stage_lookup = {}
        bridge.selected_typewriter_warp_index = 1

        for _, warp_point in ipairs(bridge.warp_points) do
            if is_typewriter_warp_name(warp_point.name) then
                bridge.typewriter_warp_stage_lookup[warp_point.stage_id] = true
                table.insert(bridge.typewriter_warp_points, warp_point)

                local display_name = warp_point.name
                -- Lead with the pause-map section (the player vocabulary the
                -- rest of the UI speaks) when it resolves and the CSV name
                -- doesn't already carry it. Resolves via the same Voronoi
                -- lookup the display map uses; nil-safe on early boot (maps
                -- not loaded yet) - later rebuilds self-heal the labels.
                local section_fn = ctx.get_section_for_position or _G.get_section_for_position
                if type(section_fn) == "function" then
                    local ok_section, section = pcall(
                        section_fn, warp_point.stage_id, nil, warp_point.x, warp_point.z)
                    if ok_section and type(section) == "string" and section ~= ""
                        and not string.find(display_name, section, 1, true) then
                        display_name = section .. " | " .. display_name
                    end
                end
                if not is_warp_stage_unlocked(warp_point.stage_id) then
                    display_name = display_name .. " [Locked]"
                end
                table.insert(bridge.typewriter_warp_point_names, display_name)
            end
        end

        if previous_stage_id ~= nil then
            for index, warp_point in ipairs(bridge.typewriter_warp_points) do
                if warp_point.stage_id == previous_stage_id then
                    bridge.selected_typewriter_warp_index = index
                    return
                end
            end
        end

        for index, warp_point in ipairs(bridge.typewriter_warp_points) do
            if is_warp_stage_unlocked(warp_point.stage_id) then
                bridge.selected_typewriter_warp_index = index
                return
            end
        end
    end

    local function get_warp_unlocks_file_path()
        local seed_name = trim_string(bridge.ap_session_seed_name)
        local slot_name = trim_string(bridge.ap_session_slot_name)
        if seed_name == "" or slot_name == "" then
            return WARP_UNLOCKS_DIR .. "\\standalone.json"
        end

        return string.format(
            "%s\\%s__%s.json",
            WARP_UNLOCKS_DIR,
            sanitize_session_component(seed_name),
            sanitize_session_component(slot_name)
        )
    end

    local function load_warp_unlocks()
        local unlocks_path = get_warp_unlocks_file_path()
        bridge.loaded_warp_unlocks_path = unlocks_path
        bridge.unlocked_warp_stage_ids = {}

        local payload = json.load_file(unlocks_path)
        if type(payload) == "table" then
            for _, raw_stage_id in ipairs(payload) do
                local stage_id = normalize_stage_id(raw_stage_id)
                if stage_id ~= nil then
                    bridge.unlocked_warp_stage_ids[stage_id] = true
                end
            end
        end

        rebuild_typewriter_warp_points()
    end

    local function save_warp_unlocks()
        local unlocks_path = get_warp_unlocks_file_path()
        bridge.loaded_warp_unlocks_path = unlocks_path

        local unlocked_stage_ids = {}
        for stage_id, is_unlocked in pairs(bridge.unlocked_warp_stage_ids) do
            if is_unlocked == true then
                table.insert(unlocked_stage_ids, stage_id)
            end
        end
        table.sort(unlocked_stage_ids)

        local ok = json.dump_file(unlocks_path, unlocked_stage_ids, 4)
        if not ok then
            log.error("[ArchipelagoRE4R] Failed to write warp unlocks to " .. tostring(unlocks_path))
        end
        return ok
    end

    local function sync_typewriter_warp_unlock_for_stage(stage_id)
        local normalized_stage_id = normalize_stage_id(stage_id)
        if normalized_stage_id == nil or bridge.typewriter_warp_stage_lookup[normalized_stage_id] ~= true then
            return false
        end
        if bridge.unlocked_warp_stage_ids[normalized_stage_id] == true then
            return false
        end

        bridge.unlocked_warp_stage_ids[normalized_stage_id] = true
        save_warp_unlocks()
        rebuild_typewriter_warp_points()
        return true
    end

    local function load_warp_points()
        bridge.warp_points = {}
        bridge.warp_point_names = {}
        bridge.selected_warp_index = 1
        bridge.typewriter_warp_points = {}
        bridge.typewriter_warp_point_names = {}
        bridge.typewriter_warp_stage_lookup = {}
        bridge.selected_typewriter_warp_index = 1

        local file = io.open(WARP_POINTS_FILE, "r")
        if file == nil then
            bridge.warp_points_status = "warp.csv not found"
            rebuild_typewriter_warp_points()
            return false
        end

        for line in file:lines() do
            local trimmed = trim_string(line)
            if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
                local stage_text, x_text, y_text, z_text, name_text = trimmed:match("^([^,]+),([^,]+),([^,]+),([^,]+),(.+)$")
                if stage_text ~= nil then
                    local stage_id = tonumber(trim_string(stage_text))
                    local x = tonumber(trim_string(x_text))
                    local y = tonumber(trim_string(y_text))
                    local z = tonumber(trim_string(z_text))
                    local name = trim_string(name_text)
                    if type(stage_id) == "number" and type(x) == "number" and type(y) == "number" and type(z) == "number" then
                        if name == "" then
                            name = string.format("Stage %d", stage_id)
                        end

                        table.insert(bridge.warp_points, {
                            stage_id = math.floor(stage_id + 0.5),
                            x = x,
                            y = y,
                            z = z,
                            name = name,
                        })
                        table.insert(bridge.warp_point_names, name)
                    end
                end
            end
        end

        file:close()

        if #bridge.warp_points > 0 then
            bridge.warp_points_status = string.format("Loaded %d warp points", #bridge.warp_points)
        else
            bridge.warp_points_status = "No warp points loaded"
        end
        rebuild_typewriter_warp_points()
        return true
    end

    local function select_warp_point(index)
        local warp_point = bridge.warp_points[index]
        if warp_point == nil then
            return false
        end

        bridge.selected_warp_index = index
        bridge.warp_stage_id = warp_point.stage_id
        bridge.warp_x = warp_point.x
        bridge.warp_y = warp_point.y
        bridge.warp_z = warp_point.z
        return true
    end

    local function select_typewriter_warp_point(index)
        local warp_point = bridge.typewriter_warp_points[index]
        if warp_point == nil then
            return false
        end

        bridge.selected_typewriter_warp_index = index
        bridge.warp_stage_id = warp_point.stage_id
        bridge.warp_x = warp_point.x
        bridge.warp_y = warp_point.y
        bridge.warp_z = warp_point.z
        return true
    end

    local function save_current_warp_point()
        local state = bridge.last_state or {}
        local stage_id = state.current_stage
        local pos = get_player_position()
        if type(stage_id) ~= "number" or pos == nil then
            bridge.last_warp_status = "Save point failed"
            return false
        end

        local file = io.open(WARP_POINTS_FILE, "a")
        if file == nil then
            bridge.last_warp_status = "Save point failed"
            return false
        end

        local name = string.format("DEBUG - rename me (%d)", stage_id)
        file:write(string.format("%d,%.3f,%.3f,%.3f,%s\n", stage_id, pos.x, pos.y, pos.z, name))
        file:close()

        load_warp_points()
        bridge.last_warp_status = string.format("Saved debug point for stage %d", stage_id)
        return true
    end

    -- warp technique created by JumperDenfer (https://www.nexusmods.com/residentevil42023/mods/5923)
    local function preloadZone(stage_id)
        local pref_id, loc_id = get_prefecture_and_location_ids(stage_id)
        if type(pref_id) ~= "number" or type(loc_id) ~= "number" then
            log.error("[RE4R AP] preloadZone failed: invalid stage_id")
            return false
        end

        local pref_manager = sdk.get_managed_singleton("chainsaw.PrefectureSceneManager")
        local loc_manager = sdk.get_managed_singleton("chainsaw.LocationSceneManager")
        local env_manager = sdk.get_managed_singleton("chainsaw.EnvSceneManager")
        if pref_manager == nil or loc_manager == nil or env_manager == nil then
            log.error("[RE4R AP] preloadZone failed: scene manager missing")
            return false
        end

        local ok, err = pcall(function()
            pref_manager:call(
                "requestToChangeStatus(chainsaw.PrefectureID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)",
                pref_id,
                sdk.create_int32(3),
                1
            )
            loc_manager:call(
                "requestToChangeStatus(chainsaw.LocID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)",
                loc_id,
                sdk.create_int32(3),
                1
            )
            env_manager:call(
                "requestToChangeStatus(chainsaw.StageID, System.Nullable`1<chainsaw.EnvSceneStatus>, chainsaw.EnvSceneStatusRequestPriority)",
                stage_id,
                sdk.create_int32(3),
                1
            )
        end)
        if not ok then
            log.error("[RE4R AP] preloadZone failed: " .. tostring(err))
            return false
        end

        return true
    end

    -- warp technique created by JumperDenfer (https://www.nexusmods.com/residentevil42023/mods/5923)
    local function executeWarpNow(stage_id, x, y, z)
        local pref_id, loc_id = get_prefecture_and_location_ids(stage_id)
        if type(pref_id) ~= "number" or type(loc_id) ~= "number" then
            log.error("[RE4R AP] executeWarpNow failed: invalid stage_id")
            return false
        end

        local character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
        if character_manager == nil then
            log.error("[RE4R AP] executeWarpNow failed: CharacterManager missing")
            return false
        end

        local ok_context, player_context = pcall(function()
            return character_manager:call("getPlayerContextRef")
        end)
        if not ok_context or player_context == nil then
            log.error("[RE4R AP] executeWarpNow failed: player context missing")
            return false
        end

        local pos = sdk.create_instance("via.vec3")
        local vec3_type = sdk.find_type_definition("via.vec3")
        local quat = sdk.create_instance("via.Quaternion")
        local quat_type = sdk.find_type_definition("via.Quaternion")
        local stage_identifier = sdk.create_instance("chainsaw.StageIdentifier")
        if pos == nil or vec3_type == nil or quat == nil or quat_type == nil or stage_identifier == nil then
            log.error("[RE4R AP] executeWarpNow failed: value type construction failed")
            return false
        end

        sdk.set_native_field(pos, vec3_type, "x", tonumber(x) or 0.0)
        sdk.set_native_field(pos, vec3_type, "y", tonumber(y) or 0.0)
        sdk.set_native_field(pos, vec3_type, "z", tonumber(z) or 0.0)
        sdk.set_native_field(quat, quat_type, "x", 0.0)
        sdk.set_native_field(quat, quat_type, "y", 0.0)
        sdk.set_native_field(quat, quat_type, "z", 0.0)
        sdk.set_native_field(quat, quat_type, "w", 1.0)

        local ok_warp, err = pcall(function()
            stage_identifier:call("setup(chainsaw.LocID, chainsaw.StageID, chainsaw.AreaID)", loc_id, stage_id, 0)
            character_manager:call(
                "requestWarp(chainsaw.ContextID, System.Nullable`1<via.vec3>, System.Nullable`1<via.Quaternion>, chainsaw.StageIdentifier)",
                player_context:get_field("_ID"),
                pos,
                quat,
                stage_identifier
            )
        end)
        if not ok_warp then
            bridge.last_warp_status = "Failed"
            log.error("[RE4R AP] executeWarpNow failed: " .. tostring(err))
            return false
        end

        bridge.last_warp_status = string.format("Warp requested to %s", tostring(stage_id))
        log.info(
            string.format(
                "[RE4R AP] warpToLocation requested stage=%s pos=(%.3f, %.3f, %.3f)",
                tostring(stage_id),
                tonumber(x) or 0.0,
                tonumber(y) or 0.0,
                tonumber(z) or 0.0
            )
        )
        return true
    end

    -- warp technique created by JumperDenfer (https://www.nexusmods.com/residentevil42023/mods/5923)
    local function warpToLocation(stage_id, x, y, z)
        local normalized_stage_id = math.floor((tonumber(stage_id) or 0) + 0.5)
        local normalized_x = tonumber(x)
        local normalized_y = tonumber(y)
        local normalized_z = tonumber(z)
        if normalized_stage_id <= 0 or normalized_x == nil or normalized_y == nil or normalized_z == nil then
            log.error("[RE4R AP] warpToLocation failed: invalid parameters")
            bridge.last_warp_status = "Invalid warp parameters"
            return false
        end

        if not preloadZone(normalized_stage_id) then
            return false
        end

        bridge.pending_warp = {
            stage_id = normalized_stage_id,
            x = normalized_x,
            y = normalized_y,
            z = normalized_z,
            queued_at_clock = os.clock(),
            last_preload_clock = os.clock(),
        }
        bridge.last_warp_status = string.format("Warp requested to %s", tostring(normalized_stage_id))
        log.info(
            string.format(
                "[RE4R AP] warpToLocation queued stage=%s pos=(%.3f, %.3f, %.3f)",
                tostring(normalized_stage_id),
                normalized_x,
                normalized_y,
                normalized_z
            )
        )
        return true
    end

    local function process_pending_warp(runtime_state)
        local pending = bridge.pending_warp
        if pending == nil then
            return
        end

        local now_clock = os.clock()
        if now_clock - (pending.last_preload_clock or 0) >= 0.10 then
            preloadZone(pending.stage_id)
            pending.last_preload_clock = now_clock
        end

        if now_clock - (pending.queued_at_clock or now_clock) < SAFE_WARP_PRELOAD_DELAY_SECONDS then
            return
        end

        if runtime_state ~= nil and runtime_state.is_loading then
            return
        end

        local ok = executeWarpNow(pending.stage_id, pending.x, pending.y, pending.z)
        if not ok then
            bridge.last_warp_status = "Warp failed"
            -- The click already succeeded seconds ago from the player's view;
            -- a deferred failure MUST surface as a toast or it looks like the
            -- warp just never happened (executeWarpNow logged the reason).
            local push = ctx.push_info_toast or _G.push_info_toast
            if type(push) == "function" then
                push("Warp failed", "see re2_framework_log.txt for the reason")
            end
        end
        bridge.pending_warp = nil
    end

    export("get_prefecture_and_location_ids", get_prefecture_and_location_ids)
    export("is_warp_stage_unlocked", is_warp_stage_unlocked)
    export("load_warp_unlocks", load_warp_unlocks)
    export("save_warp_unlocks", save_warp_unlocks)
    export("sync_typewriter_warp_unlock_for_stage", sync_typewriter_warp_unlock_for_stage)
    export("load_warp_points", load_warp_points)
    export("select_warp_point", select_warp_point)
    export("select_typewriter_warp_point", select_typewriter_warp_point)
    export("save_current_warp_point", save_current_warp_point)
    export("preloadZone", preloadZone)
    export("warpToLocation", warpToLocation)
    export("process_pending_warp", process_pending_warp)
end

return install
