-- ======================================================================
-- Archipelago Resident Evil 4 Remake - Mercenaries Runtime Module
-- ======================================================================

local function install(ctx)
    ctx.mercenaries = ctx.mercenaries or {}
    local bridge = ctx.bridge

    local function export(name, value)
        ctx.mercenaries[name] = value
        ctx[name] = value
        _G[name] = value
    end

    -- Canonical mappings
    local STAGE_KIND_NAMES = {
        [0] = "Village",
        [1] = "Castle",
        [2] = "Island",
        [3] = "Docks",
    }

    local STAGE_NAME_TO_KIND = {
        ["Village"] = 0,
        ["Castle"] = 1,
        ["Island"] = 2,
        ["Docks"] = 3,
    }

    -- PlayerCharacterWithCostumeKind index (0..7) and (chara, costume) mapping
    local CHAR_COSTUME_TO_ROSTER = {
        ["0:0"] = { index = 0, name = "Leon", item_name = "Mercenaries Character: Leon" },
        ["0:1"] = { index = 1, name = "Leon (Pinstripe)", item_name = "Mercenaries Character: Leon (Pinstripe)" },
        ["1:0"] = { index = 2, name = "Luis", item_name = "Mercenaries Character: Luis" },
        ["2:0"] = { index = 3, name = "Krauser", item_name = "Mercenaries Character: Krauser" },
        ["3:0"] = { index = 4, name = "HUNK", item_name = "Mercenaries Character: HUNK" },
        ["4:0"] = { index = 5, name = "Ada", item_name = "Mercenaries Character: Ada" },
        ["4:1"] = { index = 6, name = "Ada (Dress)", item_name = "Mercenaries Character: Ada (Dress)" },
        ["5:0"] = { index = 7, name = "Wesker", item_name = "Mercenaries Character: Wesker" },
    }

    local ROSTER_INDEX_TO_NAME = {
        [0] = "Leon",
        [1] = "Leon (Pinstripe)",
        [2] = "Luis",
        [3] = "Krauser",
        [4] = "HUNK",
        [5] = "Ada",
        [6] = "Ada (Dress)",
        [7] = "Wesker",
    }

    local SCORE_RANK_NAMES = {
        [0] = "C",
        [1] = "B",
        [2] = "A",
        [3] = "S",
        [4] = "S+",  -- Engine SS
        [5] = "S++", -- Engine SSS
    }

    local END_GAME_TYPE_NAMES = {
        [-1] = "Invalid",
        [0] = "TimeOut",
        [1] = "Dead",
        [2] = "Exterminated",
    }

    -- Lifecycle state machine
    local STATE_IDLE = "IDLE"
    local STATE_RUN_PRESENT = "RUN_PRESENT"
    local STATE_RESULT_PIPELINE = "RESULT_PIPELINE"
    local STATE_RESULT_READY = "RESULT_READY"
    local STATE_RESULT_CONSUMED = "RESULT_CONSUMED"

    local merc_state = {
        lifecycle = STATE_IDLE,
        controller_generation = 0,
        last_is_result = false,
        pipeline_entered_at = 0,
        result_consumed_gen = -1,
        active_controller = nil,
    }

    -- AP Ownership State
    local ownership = {
        characters = {}, -- [0..7] = true
        stages = {},     -- [0..3] = true
        initialized = false,
    }

    local function get_safe_int(obj, method_name, fallback)
        if obj == nil then return fallback end
        local ok, val = pcall(function() return obj:call(method_name) end)
        if ok and type(val) == "number" then return val end
        return fallback
    end

    local function decode_anti_cheat_int(obj)
        if obj == nil then return 0 end
        local ok, val = pcall(function() return obj:call("get_Value()") end)
        if ok and type(val) == "number" then return val end
        local ok_field, raw_val = pcall(function() return obj:get_field("_Value") end)
        if ok_field and type(raw_val) == "number" then return raw_val end
        return 0
    end

    local function get_merc_manager()
        local type_def = sdk.find_type_definition("chainsaw.MercenariesManager")
        if type_def ~= nil then
            local get_instance = type_def:get_method("get_Instance")
            if get_instance ~= nil and type(get_instance.call) == "function" then
                local ok, inst = pcall(function() return get_instance:call(nil) end)
                if ok and inst ~= nil then return inst end
            end
        end
        local ok_m, mgr = pcall(function() return sdk.get_managed_singleton("chainsaw.MercenariesManager") end)
        if ok_m and mgr ~= nil then return mgr end
        return nil
    end


    local type_cache = {}
    local function cached_typeof(type_name)
        if not type_cache[type_name] then
            type_cache[type_name] = sdk.typeof(type_name)
        end
        return type_cache[type_name]
    end

    local function get_scene_object()
        local scene_mgr = sdk.get_native_singleton("via.SceneManager")
        local scene_mgr_type = sdk.find_type_definition("via.SceneManager")
        if scene_mgr == nil or scene_mgr_type == nil then return nil end
        return sdk.call_native_func(scene_mgr, scene_mgr_type, "get_CurrentScene")
    end

    local function get_merc_controller()
        local scene = get_scene_object()
        if scene == nil then return nil end
        local typeof_ctrl = cached_typeof("chainsaw.MercenariesModeController")
        if typeof_ctrl == nil then return nil end
        local game_obj = scene:call("findGameObject(System.Type)", typeof_ctrl)
        if game_obj == nil then return nil end
        return game_obj:call("getComponent(System.Type)", typeof_ctrl)
    end

    local function get_result_gui_behavior()
        local scene = get_scene_object()
        if scene == nil then return nil end
        local typeof_gui = cached_typeof("chainsaw.Cp1021GameClearResultGuiBehavior")
        if typeof_gui == nil then return nil end
        local game_obj = scene:call("findGameObject(System.Type)", typeof_gui)
        if game_obj == nil then return nil end
        return game_obj:call("getComponent(System.Type)", typeof_gui)
    end


    -- Authoritative Runtime Domain Detection
    local function get_runtime_domain()
        local merc_mgr = get_merc_manager()
        if merc_mgr ~= nil then
            local is_active = get_safe_int(merc_mgr, "get_Routine", -1) >= 0
            local is_res = get_safe_int(merc_mgr, "get_IsResult", 0) == 1
            if is_active or is_res then
                return "MERCENARIES"
            end
        end

        local ctrl = get_merc_controller()
        if ctrl ~= nil then
            return "MERCENARIES"
        end

        -- Check GUI behaviors
        local res_gui = get_result_gui_behavior()
        if res_gui ~= nil then
            return "MERCENARIES"
        end

        local runtime_state = type(ctx.get_runtime_state) == "function" and ctx.get_runtime_state() or nil
        if runtime_state ~= nil and runtime_state.is_in_game and not runtime_state.is_title_screen then
            return "CAMPAIGN"
        end

        return "MENU_OR_OTHER"
    end
    export("get_runtime_domain", get_runtime_domain)

    -- Ownership management
    local function init_merc_ownership(slot_data)
        ownership.characters = {}
        ownership.stages = {}
        ownership.initialized = true

        if type(slot_data) ~= "table" then return end
        local merc_data = slot_data.mercenaries
        if type(merc_data) ~= "table" or merc_data.enabled ~= true then return end

        local start_char = merc_data.starting_character
        if type(start_char) == "string" then
            for key, roster in pairs(CHAR_COSTUME_TO_ROSTER) do
                if roster.item_name == start_char or roster.name == start_char then
                    ownership.characters[roster.index] = true
                    log.info(string.format("[Merc AP] granted starting character: %s (index %d)", roster.name, roster.index))
                    break
                end
            end
        end

        local start_stage = merc_data.starting_stage
        if type(start_stage) == "string" then
            for stage_name, stage_kind in pairs(STAGE_NAME_TO_KIND) do
                if start_stage == ("Mercenaries Stage: " .. stage_name) or start_stage == stage_name then
                    ownership.stages[stage_kind] = true
                    log.info(string.format("[Merc AP] granted starting stage: %s (kind %d)", stage_name, stage_kind))
                    break
                end
            end
        end
    end
    export("init_merc_ownership", init_merc_ownership)

    local function handle_merc_item_received(item_name)
        if type(item_name) ~= "string" then return false end

        -- Check character items
        for key, roster in pairs(CHAR_COSTUME_TO_ROSTER) do
            if roster.item_name == item_name or roster.name == item_name then
                ownership.characters[roster.index] = true
                log.info(string.format("[Merc AP] received character unlock: %s", roster.name))
                return true
            end
        end

        -- Check stage items
        for stage_name, stage_kind in pairs(STAGE_NAME_TO_KIND) do
            local expected_item = "Mercenaries Stage: " .. stage_name
            if expected_item == item_name or stage_name == item_name then
                ownership.stages[stage_kind] = true
                log.info(string.format("[Merc AP] received stage unlock: %s", stage_name))
                return true
            end
        end

        return false
    end
    export("handle_merc_item_received", handle_merc_item_received)

    local function is_character_owned(chara_costume_index)
        return ownership.characters[chara_costume_index] == true
    end

    local function is_stage_owned(stage_kind)
        return ownership.stages[stage_kind] == true
    end

    -- Result location emission
    local function get_merc_location_id(char_name, stage_name, rank_name, slot_data)
        -- 1. Try slot_data lookup
        if type(slot_data) == "table" and type(slot_data.mercenaries) == "table" then
            local locs = slot_data.mercenaries.locations
            if type(locs) == "table" and type(locs[char_name]) == "table" and type(locs[char_name][stage_name]) == "table" then
                local id = tonumber(locs[char_name][stage_name][rank_name])
                if id ~= nil then return id end
            end
        end

        -- 2. Deterministic formula fallback
        local char_idx = nil
        for idx, name in pairs(ROSTER_INDEX_TO_NAME) do
            if name == char_name then char_idx = idx break end
        end
        local stage_idx = STAGE_NAME_TO_KIND[stage_name]
        local rank_idx = (rank_name == "A" and 0) or (rank_name == "S" and 1) or (rank_name == "S+" and 2) or (rank_name == "S++" and 3) or nil

        if char_idx ~= nil and stage_idx ~= nil and rank_idx ~= nil then
            return 440001000 + char_idx * 16 + stage_idx * 4 + rank_idx
        end
        return nil
    end

    local function evaluate_result_locations(payload, slot_data)
        local char_name = payload.char_name
        local stage_name = payload.stage_name
        local rank_num = payload.rank -- 0=C, 1=B, 2=A, 3=S, 4=SS[S+], 5=SSS[S++]
        local score_checks_mode = "standard"

        if type(slot_data) == "table" and type(slot_data.mercenaries) == "table" then
            score_checks_mode = slot_data.mercenaries.score_checks or "standard"
        end

        local ranks_to_check = {}
        if rank_num >= 2 then -- Rank A
            ranks_to_check[#ranks_to_check + 1] = "A"
        end
        if rank_num >= 3 and (score_checks_mode == "standard" or score_checks_mode == "full") then -- Rank S
            ranks_to_check[#ranks_to_check + 1] = "S"
        end
        if rank_num >= 4 and score_checks_mode == "full" then -- Rank S+
            ranks_to_check[#ranks_to_check + 1] = "S+"
        end
        if rank_num >= 5 and score_checks_mode == "full" then -- Rank S++
            ranks_to_check[#ranks_to_check + 1] = "S++"
        end

        local queued_names = {}
        bridge.pending_checks = bridge.pending_checks or {}
        local checked_set = bridge.checked_locations or {}

        for _, r_name in ipairs(ranks_to_check) do
            local loc_id = get_merc_location_id(char_name, stage_name, r_name, slot_data)
            if loc_id ~= nil and checked_set[loc_id] ~= true then
                local already_pending = false
                for _, p in ipairs(bridge.pending_checks) do
                    if p == loc_id or (type(p) == "table" and p.location_id == loc_id) then
                        already_pending = true
                        break
                    end
                end
                if not already_pending then
                    bridge.pending_checks[#bridge.pending_checks + 1] = loc_id
                    queued_names[#queued_names + 1] = "Rank " .. r_name
                end
            end
        end

        if #queued_names > 0 then
            log.info(string.format(
                "[Merc AP] queued checks: %s (total pending: %d)",
                table.concat(queued_names, ", "),
                #bridge.pending_checks
            ))
        else
            log.info("[Merc AP] no new score checks queued (already checked or rank below threshold)")
        end
    end

    -- Continuous Result Polling & Readiness
    local function poll_result_pipeline()
        local res_gui = get_result_gui_behavior()
        if res_gui == nil then return end

        local open_param = res_gui:get_field("_OpenParam")
        if open_param == nil then return end

        local stage_val = get_safe_int(open_param, "get_Stage", -1)
        if stage_val == -1 then
            local ok_f, val_f = pcall(function() return open_param:get_field("Stage") end)
            if ok_f and type(val_f) == "number" then stage_val = val_f end
        end

        local chara_val = get_safe_int(open_param, "get_PlChara", -1)
        if chara_val == -1 then
            local ok_f, val_f = pcall(function() return open_param:get_field("PlChara") end)
            if ok_f and type(val_f) == "number" then chara_val = val_f end
        end

        -- Check if payload is populated
        if stage_val == -1 or chara_val == -1 then
            return -- still default unpopulated
        end

        local costume_val = get_safe_int(open_param, "get_PlCostumeId", 0)
        local rank_val = get_safe_int(open_param, "get_Rank", 0)
        local total_score_obj = nil
        pcall(function() total_score_obj = open_param:get_field("TotalScore") end)
        local total_score = decode_anti_cheat_int(total_score_obj)

        local char_key = string.format("%d:%d", chara_val, costume_val)
        local roster_info = CHAR_COSTUME_TO_ROSTER[char_key]
        local char_name = roster_info and roster_info.name or string.format("Unknown(%s)", char_key)
        local stage_name = STAGE_KIND_NAMES[stage_val] or string.format("UnknownStage(%d)", stage_val)
        local rank_name = SCORE_RANK_NAMES[rank_val] or string.format("Rank(%d)", rank_val)

        -- Transition state to RESULT_READY
        merc_state.lifecycle = STATE_RESULT_READY
        log.info(string.format(
            "[Merc AP] result ready: %s / %s / %s / %d",
            char_name, stage_name, rank_name, total_score
        ))

        local payload = {
            char_name = char_name,
            stage_name = stage_name,
            stage_kind = stage_val,
            chara_kind = chara_val,
            costume_id = costume_val,
            rank = rank_val,
            rank_name = rank_name,
            total_score = total_score,
            generation = merc_state.controller_generation,
        }

        -- Consume exactly once for this generation
        if merc_state.result_consumed_gen ~= merc_state.controller_generation then
            merc_state.result_consumed_gen = merc_state.controller_generation
            merc_state.lifecycle = STATE_RESULT_CONSUMED
            evaluate_result_locations(payload, ctx.slot_data or bridge.slot_data)
        end
    end

    -- Frame update tick
    local function update_mercenaries_state()
        local merc_mgr = get_merc_manager()
        local controller = get_merc_controller()

        -- 1. Controller lifetime tracking
        if controller ~= nil then
            if merc_state.active_controller ~= controller then
                merc_state.active_controller = controller
                merc_state.controller_generation = merc_state.controller_generation + 1
                merc_state.lifecycle = STATE_RUN_PRESENT
                merc_state.last_is_result = false
            end
        else
            if merc_state.active_controller ~= nil then
                merc_state.active_controller = nil
                merc_state.lifecycle = STATE_IDLE
                merc_state.last_is_result = false
            end
        end

        -- 2. Observe MercenariesManager.get_IsResult() boundary
        if merc_mgr ~= nil then
            local is_result = get_safe_int(merc_mgr, "get_IsResult", 0) == 1
            if is_result and not merc_state.last_is_result then
                merc_state.last_is_result = true
                merc_state.lifecycle = STATE_RESULT_PIPELINE
                merc_state.pipeline_entered_at = os.clock()
                log.info(string.format(
                    "[Merc AP] result pipeline entered (generation %d)",
                    merc_state.controller_generation
                ))
            elseif not is_result then
                merc_state.last_is_result = false
            end
        end

        -- 3. Poll payload if inside result pipeline
        if merc_state.lifecycle == STATE_RESULT_PIPELINE then
            poll_result_pipeline()
        end
    end
    export("update_mercenaries_state", update_mercenaries_state)

    -- Virtual Selection Gating (Hooks)
    local hooks_installed = false
    local pending_stage_query = nil
    local pending_char_query = nil

    local function install_merc_virtual_gating_hooks()
        if hooks_installed then return end

        local stage_select_type = sdk.find_type_definition("chainsaw.Cp1021StageSelectGuiBehavior")
        if stage_select_type ~= nil then
            local is_unlock_method = stage_select_type:get_method("isUnlock")
            if is_unlock_method ~= nil then
                sdk.hook(is_unlock_method, function(args)
                    local this_ptr = sdk.to_managed_object(args[1])
                    local kind_id = -1
                    if args[2] ~= nil then
                        local raw_arg = sdk.to_int64(args[2])
                        if raw_arg ~= nil and raw_arg >= 0 and raw_arg <= 10 then
                            kind_id = tonumber(raw_arg)
                        end
                    end
                    if (kind_id < 0 or kind_id > 3) and this_ptr ~= nil then
                        kind_id = get_safe_int(this_ptr, "getKindId", -1)
                    end
                    pending_stage_query = kind_id
                end, function(retval)
                    local kind_id = pending_stage_query
                    pending_stage_query = nil
                    if not ownership.initialized then return retval end
                    local slot_data = ctx.slot_data or bridge.slot_data
                    if type(slot_data) ~= "table" or type(slot_data.mercenaries) ~= "table" or slot_data.mercenaries.enabled ~= true then
                        return retval -- vanilla untouched
                    end

                    if kind_id ~= nil and kind_id >= 0 and kind_id <= 3 then
                        local owned = is_stage_owned(kind_id)
                        return sdk.to_ptr(owned and 1 or 0)
                    end
                    return retval
                end)
            end
        end

        local char_select_type = sdk.find_type_definition("chainsaw.Cp1021CharacterSelectGuiBehavior")
        if char_select_type ~= nil then
            local is_unlock_method = char_select_type:get_method("isUnlock")
            if is_unlock_method ~= nil then
                sdk.hook(is_unlock_method, function(args)
                    local this_ptr = sdk.to_managed_object(args[1])
                    local char_kind = -1
                    if args[2] ~= nil then
                        local raw_arg = sdk.to_int64(args[2])
                        if raw_arg ~= nil and raw_arg >= 0 and raw_arg <= 20 then
                            char_kind = tonumber(raw_arg)
                        end
                    end
                    if (char_kind < 0 or char_kind > 7) and this_ptr ~= nil then
                        char_kind = get_safe_int(this_ptr, "getCharacterKind", -1)
                    end
                    pending_char_query = char_kind
                end, function(retval)
                    local char_kind = pending_char_query
                    pending_char_query = nil
                    if not ownership.initialized then return retval end
                    local slot_data = ctx.slot_data or bridge.slot_data
                    if type(slot_data) ~= "table" or type(slot_data.mercenaries) ~= "table" or slot_data.mercenaries.enabled ~= true then
                        return retval -- vanilla untouched
                    end

                    if char_kind ~= nil and char_kind >= 0 and char_kind <= 7 then
                        local owned = is_character_owned(char_kind)
                        return sdk.to_ptr(owned and 1 or 0)
                    end
                    return retval
                end)
            end
        end

        hooks_installed = true
        log.info("[Merc AP] virtual unlock gating hooks initialized")
    end
    export("install_merc_virtual_gating_hooks", install_merc_virtual_gating_hooks)

    -- Install hooks immediately on boot
    install_merc_virtual_gating_hooks()

    export("merc_state", merc_state)
    export("merc_ownership", ownership)
end

return install

