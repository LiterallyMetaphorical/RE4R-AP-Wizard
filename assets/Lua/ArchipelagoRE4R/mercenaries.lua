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

    local function get_safe_field_int(obj, field_name, fallback)
        if obj == nil then return fallback end
        local ok, val = pcall(function() return obj:get_field(field_name) end)
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

    local function find_first_component(type_name)
        local scene = get_scene_object()
        if scene == nil then return nil end
        local t = cached_typeof(type_name)
        if t == nil then return nil end
        local result = nil
        pcall(function() result = scene:call("findComponents", t) end)
        if result == nil then return nil end

        local ok_el, elements = pcall(function() return result:get_elements() end)
        if ok_el and type(elements) == "table" and #elements > 0 then
            return elements[1]
        end

        local ok_count, count = pcall(function() return result:get_Count() end)
        if not ok_count then
            ok_count, count = pcall(function() return result:get_size() end)
        end
        count = tonumber(count) or 0
        if count > 0 then
            local ok_item, item = pcall(function() return result:get_Item(0) end)
            if not ok_item then
                ok_item, item = pcall(function() return result:get_element(0) end)
            end
            if ok_item and item ~= nil then
                return item
            end
        end
        return nil
    end

    local function get_merc_controller()
        return find_first_component("chainsaw.MercenariesModeController")
    end
    export("get_merc_controller", get_merc_controller)

    local function get_result_gui_behavior()
        return find_first_component("chainsaw.Cp1021GameClearResultGuiBehavior")
    end
    export("get_result_gui_behavior", get_result_gui_behavior)



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
        if find_first_component("chainsaw.Cp1021GameClearResultGuiBehavior") ~= nil
            or find_first_component("chainsaw.Cp1021StageSelectGuiBehavior") ~= nil
            or find_first_component("chainsaw.Cp1021CharacterSelectGuiBehavior") ~= nil
            or find_first_component("chainsaw.Cp1021MainMenuGuiBehavior") ~= nil
            or find_first_component("chainsaw.Cp1021MainMenuBGGuiBehavior") ~= nil then
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

    local function get_mercenaries_checklist()
        local slot_data = ctx.slot_data or bridge.slot_data
        local merc_conf = (type(slot_data) == "table") and slot_data.mercenaries or nil
        local score_checks_mode = (merc_conf and merc_conf.score_checks)
            or (type(slot_data) == "table" and slot_data.mercenaries_score_checks)
            or "standard"

        local active_ranks = { { name = "A", idx = 0 } }
        if score_checks_mode == "standard" or score_checks_mode == "full" then
            table.insert(active_ranks, { name = "S", idx = 1 })
        end
        if score_checks_mode == "full" then
            table.insert(active_ranks, { name = "S+", idx = 2 })
            table.insert(active_ranks, { name = "S++", idx = 3 })
        end

        local checked_set = bridge.checked_locations or {}
        local stages_data = {}
        local grand_found = 0
        local grand_total = 0

        for stage_idx = 0, 3 do
            local stage_name = STAGE_KIND_NAMES[stage_idx]
            local st_found = 0
            local st_total = 0
            local st_chars = {}

            for char_idx = 0, 7 do
                local char_name = ROSTER_INDEX_TO_NAME[char_idx]
                local char_ranks = {}
                local char_st_found = 0

                for _, rank in ipairs(active_ranks) do
                    local loc_id = 440001000 + char_idx * 16 + stage_idx * 4 + rank.idx
                    local is_checked = (checked_set[loc_id] == true)
                    if is_checked then
                        char_st_found = char_st_found + 1
                        st_found = st_found + 1
                        grand_found = grand_found + 1
                    end
                    st_total = st_total + 1
                    grand_total = grand_total + 1
                    table.insert(char_ranks, {
                        name = rank.name,
                        loc_id = loc_id,
                        checked = is_checked,
                    })
                end

                table.insert(st_chars, {
                    char_idx = char_idx,
                    char_name = char_name,
                    unlocked = ownership.characters[char_idx] == true,
                    found = char_st_found,
                    total = #active_ranks,
                    ranks = char_ranks,
                })
            end

            table.insert(stages_data, {
                stage_idx = stage_idx,
                stage_name = stage_name,
                unlocked = ownership.stages[stage_idx] == true,
                found = st_found,
                total = st_total,
                characters = st_chars,
            })
        end

        local is_enabled = (merc_conf ~= nil and merc_conf.enabled == true)
            or (type(slot_data) == "table" and (slot_data.game_mode == "mercenaries_only" or slot_data.game_mode == "campaign_and_mercenaries"))

        return {
            enabled = is_enabled,
            mode = (type(slot_data) == "table") and slot_data.game_mode or "campaign",
            score_checks_mode = score_checks_mode,
            found = grand_found,
            total = grand_total,
            stages = stages_data,
        }
    end
    export("get_mercenaries_checklist", get_mercenaries_checklist)

    local function get_current_merc_play_info()
        local ok, res = pcall(function()
            local controller = get_merc_controller()
            if controller == nil then return nil end

            local raw_stage = get_safe_int(controller, "get_StageKind", -1)
            if raw_stage < 0 then
                raw_stage = get_safe_field_int(controller, "_StageKind", -1)
            end

            local raw_char = get_safe_field_int(controller, "_PlayerCharacterKind", -1)
            local raw_costume = get_safe_field_int(controller, "_PlayerCharacterCostumeId", 0)

            local char_name = "Unknown"
            local char_idx = 0
            local key = string.format("%d:%d", raw_char, raw_costume)
            local entry = CHAR_COSTUME_TO_ROSTER[key]
            if entry ~= nil then
                char_name = entry.name
                char_idx = entry.index
            end

            local stage_name = STAGE_KIND_NAMES[raw_stage] or "Unknown Stage"

            -- Count checks completed for this (char, stage) pair
            local slot_data = ctx.slot_data or bridge.slot_data
            local merc_conf = (type(slot_data) == "table") and slot_data.mercenaries or nil
            local score_checks_mode = (merc_conf and merc_conf.score_checks)
                or (type(slot_data) == "table" and slot_data.mercenaries_score_checks)
                or "standard"

            local active_ranks = { { name = "A", idx = 0 } }
            if score_checks_mode == "standard" or score_checks_mode == "full" then
                table.insert(active_ranks, { name = "S", idx = 1 })
            end
            if score_checks_mode == "full" then
                table.insert(active_ranks, { name = "S+", idx = 2 })
                table.insert(active_ranks, { name = "S++", idx = 3 })
            end

            local checked_set = bridge.checked_locations or {}
            local done_count = 0
            local rank_summary = {}

            for _, rank in ipairs(active_ranks) do
                local loc_id = 440001000 + char_idx * 16 + raw_stage * 4 + rank.idx
                local is_done = (checked_set[loc_id] == true)
                if is_done then
                    done_count = done_count + 1
                    table.insert(rank_summary, "[" .. rank.name .. ": OK]")
                else
                    table.insert(rank_summary, "[" .. rank.name .. "]")
                end
            end

            return {
                stage_name = stage_name,
                char_name = char_name,
                stage_idx = raw_stage,
                char_idx = char_idx,
                done = done_count,
                total = #active_ranks,
                ranks_str = table.concat(rank_summary, " "),
            }
        end)
        if ok then return res end
        return nil
    end

    export("get_current_merc_play_info", get_current_merc_play_info)

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

    local function install_merc_virtual_gating_hooks()
        if hooks_installed then return end

        local function should_enforce_gating()
            local slot_data = ctx.slot_data or bridge.slot_data
            if type(slot_data) == "table" then
                if slot_data.game_mode == "mercenaries_only" or slot_data.game_mode == "campaign_and_mercenaries" then
                    return ownership.initialized == true
                end
                if type(slot_data.mercenaries) == "table" and slot_data.mercenaries.enabled == true then
                    return ownership.initialized == true
                end
            end
            if ownership.initialized then
                return true
            end
            return false
        end

        local function safe_hook(method, pre, post)
            if method == nil then return end
            pcall(function()
                sdk.hook(method, pre, post)
            end)
        end

        -- 0. Hook Cp1021UnlockSettingsUserData.StageSetting.isUnlock (Authoritative Stage Unlock)
        local stage_setting_type = sdk.find_type_definition("chainsaw.Cp1021UnlockSettingsUserData.StageSetting")
        if stage_setting_type ~= nil then
            local is_unlock = stage_setting_type:get_method("isUnlock")
            if is_unlock ~= nil then
                log.info("[Merc AP] Hooking Cp1021UnlockSettingsUserData.StageSetting.isUnlock")
                local last_stage_setting = nil
                safe_hook(is_unlock, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    last_stage_setting = this_ptr
                end, function(retval)
                    local this_ptr = last_stage_setting
                    last_stage_setting = nil
                    if not should_enforce_gating() or this_ptr == nil then return retval end

                    local kind = get_safe_field_int(this_ptr, "KindId", -1)
                    if kind >= 0 and kind <= 3 then
                        local owned = is_stage_owned(kind)
                        log.info(string.format("[Merc AP Gating] StageSetting.isUnlock(stage=%d) -> %s", kind, tostring(owned)))
                        return sdk.to_ptr(owned and 1 or 0)
                    end
                    return retval
                end)
            end
        end

        -- 0. Hook Cp1021UnlockSettingsUserData.CharacterSetting.isUnlock (Authoritative Character Unlock)
        local char_setting_type = sdk.find_type_definition("chainsaw.Cp1021UnlockSettingsUserData.CharacterSetting")
        if char_setting_type ~= nil then
            local is_unlock = char_setting_type:get_method("isUnlock")
            if is_unlock ~= nil then
                log.info("[Merc AP] Hooking Cp1021UnlockSettingsUserData.CharacterSetting.isUnlock")
                local last_char_setting = nil
                safe_hook(is_unlock, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    last_char_setting = this_ptr
                end, function(retval)
                    local this_ptr = last_char_setting
                    last_char_setting = nil
                    if not should_enforce_gating() or this_ptr == nil then return retval end

                    local kind = get_safe_field_int(this_ptr, "KindId", -1)
                    if kind >= 0 and kind <= 7 then
                        local owned = is_character_owned(kind)
                        log.info(string.format("[Merc AP Gating] CharacterSetting.isUnlock(char=%d) -> %s", kind, tostring(owned)))
                        return sdk.to_ptr(owned and 1 or 0)
                    end
                    return retval
                end)
            end
        end

        -- 1. Hook all isUnlock overloads on Cp1021StageSelectGuiBehavior
        local stage_select_type = sdk.find_type_definition("chainsaw.Cp1021StageSelectGuiBehavior")

        if stage_select_type ~= nil then
            for _, method in ipairs(stage_select_type:get_methods() or {}) do
                if method:get_name() == "isUnlock" then
                    local pcount = method:get_num_params()
                    log.info(string.format("[Merc AP] Hooking Cp1021StageSelectGuiBehavior.isUnlock (%d params)", pcount))
                    
                    local last_query = nil
                    safe_hook(method, function(args)
                        local this_ptr = sdk.to_managed_object(args[2])
                        local raw_arg = -1
                        if args[3] ~= nil then
                            local parsed = sdk.to_int64(args[3])
                            if parsed ~= nil then raw_arg = tonumber(parsed) end
                        end
                        last_query = { this = this_ptr, arg = raw_arg }
                    end, function(retval)
                        local query = last_query
                        last_query = nil
                        if not should_enforce_gating() then return retval end

                        if query ~= nil and query.arg >= 0 then
                            local stage_kind = query.arg
                            if query.this ~= nil then
                                local ok_k, k = pcall(function() return query.this:call("getKindId", query.arg) end)
                                if ok_k and type(k) == "number" and k >= 0 and k <= 3 then
                                    stage_kind = k
                                end
                            end

                            if stage_kind >= 0 and stage_kind <= 3 then
                                local owned = is_stage_owned(stage_kind)
                                log.info(string.format("[Merc AP Gating] StageSelect.isUnlock(stage=%d, raw=%d) -> %s", stage_kind, query.arg, tostring(owned)))
                                return sdk.to_ptr(owned and 1 or 0)
                            end
                        end
                        return retval
                    end)
                end
            end
        end

        -- 2. Hook all isUnlock overloads on Cp1021CharacterSelectGuiBehavior
        local char_select_type = sdk.find_type_definition("chainsaw.Cp1021CharacterSelectGuiBehavior")
        if char_select_type ~= nil then
            for _, method in ipairs(char_select_type:get_methods() or {}) do
                if method:get_name() == "isUnlock" then
                    local pcount = method:get_num_params()
                    log.info(string.format("[Merc AP] Hooking Cp1021CharacterSelectGuiBehavior.isUnlock (%d params)", pcount))

                    local last_query = nil
                    safe_hook(method, function(args)
                        local this_ptr = sdk.to_managed_object(args[2])
                        local raw_arg = -1
                        if args[3] ~= nil then
                            local parsed = sdk.to_int64(args[3])
                            if parsed ~= nil then raw_arg = tonumber(parsed) end
                        end
                        last_query = { this = this_ptr, arg = raw_arg }
                    end, function(retval)
                        local query = last_query
                        last_query = nil
                        if not should_enforce_gating() then return retval end

                        if query ~= nil and query.arg >= 0 then
                            local char_kind = query.arg
                            if query.this ~= nil then
                                local ok_k, k = pcall(function() return query.this:call("getCharacterKind", query.arg) end)
                                if ok_k and type(k) == "number" and k >= 0 and k <= 7 then
                                    char_kind = k
                                end
                            end

                            if char_kind >= 0 and char_kind <= 7 then
                                local owned = is_character_owned(char_kind)
                                log.info(string.format("[Merc AP Gating] CharacterSelect.isUnlock(char=%d, raw=%d) -> %s", char_kind, query.arg, tostring(owned)))
                                return sdk.to_ptr(owned and 1 or 0)
                            end
                        end
                        return retval
                    end)
                end
            end
        end

        -- 3. Hook Cp1021CharacterSelectGuiBehavior.updateSelectCharacterList
        if char_select_type ~= nil then
            local update_list = char_select_type:get_method("updateSelectCharacterList")
            if update_list ~= nil then
                log.info("[Merc AP] Hooking Cp1021CharacterSelectGuiBehavior.updateSelectCharacterList")
                safe_hook(update_list, function(args)
                    log.info("[Merc AP Gating] CharacterSelect.updateSelectCharacterList PRE")
                end, function(retval)
                    log.info("[Merc AP Gating] CharacterSelect.updateSelectCharacterList POST")
                    return retval
                end)
            end

            local setup_m = char_select_type:get_method("setup")
            if setup_m ~= nil then
                log.info("[Merc AP] Hooking Cp1021CharacterSelectGuiBehavior.setup")
                safe_hook(setup_m, function(args)
                    log.info("[Merc AP Gating] CharacterSelect.setup PRE")
                end, function(retval)
                    log.info("[Merc AP Gating] CharacterSelect.setup POST")
                    return retval
                end)
            end
        end

        -- 4. Hook Cp1021StageSelectGuiBehavior.setup and updateViewStage
        if stage_select_type ~= nil then
            local setup_m = stage_select_type:get_method("setup")
            if setup_m ~= nil then
                log.info("[Merc AP] Hooking Cp1021StageSelectGuiBehavior.setup")
                safe_hook(setup_m, function(args)
                    log.info("[Merc AP Gating] StageSelect.setup PRE")
                end, function(retval)
                    log.info("[Merc AP Gating] StageSelect.setup POST")
                    return retval
                end)
            end

            local update_view = stage_select_type:get_method("updateViewStage")
            if update_view ~= nil then
                log.info("[Merc AP] Hooking Cp1021StageSelectGuiBehavior.updateViewStage")
                safe_hook(update_view, function(args)
                    log.info("[Merc AP Gating] StageSelect.updateViewStage PRE")
                end, function(retval)
                    log.info("[Merc AP Gating] StageSelect.updateViewStage POST")
                    return retval
                end)
            end
        end

        -- 5. Hook ResultSaveData1021.getHighScore
        local result_save_type = sdk.find_type_definition("chainsaw.ResultSaveData1021")
        if result_save_type ~= nil then
            local get_high_score = result_save_type:get_method("getHighScore")
            if get_high_score ~= nil then
                log.info("[Merc AP] Hooking ResultSaveData1021.getHighScore")
                safe_hook(get_high_score, function(args)
                    local st = sdk.to_int64(args[3])
                    local ch = sdk.to_int64(args[4])
                    log.info(string.format("[Merc AP Gating] ResultSaveData1021.getHighScore(stage=%s, char=%s)", tostring(st), tostring(ch)))
                end, function(retval)
                    return retval
                end)
            end
        end

        -- 6. Hook input check events and stage changes to prevent selection of locked stages
        if stage_select_type ~= nil then
            local set_stage = stage_select_type:get_method("setStage")
            if set_stage ~= nil then
                log.info("[Merc AP] Hooking Cp1021StageSelectGuiBehavior.setStage")
                safe_hook(set_stage, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    if this_ptr ~= nil and should_enforce_gating() then
                        local panel_stage = this_ptr:get_field("_PanelStage")
                        local sl = panel_stage and panel_stage:get_field("_SlStage")
                        local sel_idx = sl and get_safe_int(sl, "get_CursorIndex", -1) or -1
                        if sel_idx >= 0 and sel_idx <= 3 and not is_stage_owned(sel_idx) then
                            log.info(string.format("[Merc AP Gating] Blocking setStage for unowned stage %d", sel_idx))
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                    end
                end, function(retval)
                    return retval
                end)
            end

            local change_step_stage = stage_select_type:get_method("changeStep")
            if change_step_stage ~= nil then
                log.info("[Merc AP] Hooking Cp1021StageSelectGuiBehavior.changeStep")
                safe_hook(change_step_stage, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    local next_step = args[3] ~= nil and sdk.to_int64(args[3]) or -1
                    if this_ptr ~= nil and should_enforce_gating() and next_step ~= 0 and next_step ~= -1 then
                        local panel_stage = this_ptr:get_field("_PanelStage")
                        local sl = panel_stage and panel_stage:get_field("_SlStage")
                        local sel_idx = sl and get_safe_int(sl, "get_CursorIndex", -1) or -1
                        if sel_idx >= 0 and sel_idx <= 3 and not is_stage_owned(sel_idx) then
                            log.info(string.format("[Merc AP Gating] Blocking StageSelect.changeStep to %s for unowned stage %d", tostring(next_step), sel_idx))
                            pcall(function() this_ptr:set_field("_bDecided", false) end)
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                    end
                end, function(retval)
                    return retval
                end)
            end

            local input_check = stage_select_type:get_method("onInputCheckEvent")
            if input_check ~= nil then
                log.info("[Merc AP] Hooking Cp1021StageSelectGuiBehavior.onInputCheckEvent")
                local last_stage_input = nil
                safe_hook(input_check, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    last_stage_input = this_ptr
                end, function(retval)
                    local this_ptr = last_stage_input
                    last_stage_input = nil
                    if not should_enforce_gating() or this_ptr == nil then return retval end

                    local panel_stage = this_ptr:get_field("_PanelStage")
                    local sl = panel_stage and panel_stage:get_field("_SlStage")
                    local sel_idx = sl and get_safe_int(sl, "get_CursorIndex", -1) or -1
                    if sel_idx >= 0 and sel_idx <= 3 then
                        local owned = is_stage_owned(sel_idx)
                        log.info(string.format("[Merc AP Gating] StageSelect.onInputCheckEvent(stage=%d) -> owned=%s", sel_idx, tostring(owned)))
                        if not owned then
                            pcall(function() this_ptr:set_field("_bDecided", false) end)
                            return sdk.to_ptr(0) -- Block confirmation
                        end
                    end
                    return retval
                end)
            end
        end

        local function resolve_selected_character_kind(char_gui)
            if char_gui == nil then return -1 end

            local ok_curr, curr = pcall(function() return char_gui:call("get_CurrCharacter") end)
            if ok_curr and curr ~= nil then
                local ok_kind, kind = pcall(function() return char_gui:call("getCharacterKind", curr) end)
                if ok_kind and type(kind) == "number" and kind >= 0 and kind <= 7 then
                    return kind
                end
            end

            local panel_thumb = char_gui:get_field("_PanelThumbList")
            if panel_thumb ~= nil then
                local ok_idx, idx = pcall(function() return panel_thumb:call("get_SelectedIndex") end)
                if ok_idx and type(idx) == "number" and idx >= 0 and idx <= 7 then
                    return idx
                end

                local sl = panel_thumb:get_field("_SlCharacter")
                if sl ~= nil then
                    local ok_cur, cur = pcall(function() return sl:call("get_CursorIndex") end)
                    if ok_cur and type(cur) == "number" and cur >= 0 and cur <= 7 then
                        return cur
                    end
                end
            end

            return -1
        end

        if char_select_type ~= nil then
            local change_step_char = char_select_type:get_method("changeStep")
            if change_step_char ~= nil then
                log.info("[Merc AP] Hooking Cp1021CharacterSelectGuiBehavior.changeStep")
                safe_hook(change_step_char, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    local next_step = args[3] ~= nil and sdk.to_int64(args[3]) or -1
                    if this_ptr ~= nil and should_enforce_gating() and next_step ~= 0 and next_step ~= -1 then
                        local char_kind = resolve_selected_character_kind(this_ptr)
                        if char_kind >= 0 and char_kind <= 7 and not is_character_owned(char_kind) then
                            log.info(string.format("[Merc AP Gating] Blocking CharacterSelect.changeStep to %s for unowned character %d", tostring(next_step), char_kind))
                            pcall(function() this_ptr:set_field("_bDecided", false) end)
                            pcall(function() this_ptr:set_field("_bOldCharaUnlock", false) end)
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                    end
                end, function(retval)
                    return retval
                end)
            end

            local select_costume = char_select_type:get_method("selectCostume")
            if select_costume ~= nil then
                log.info("[Merc AP] Hooking Cp1021CharacterSelectGuiBehavior.selectCostume")
                safe_hook(select_costume, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    if this_ptr ~= nil and should_enforce_gating() then
                        local char_kind = resolve_selected_character_kind(this_ptr)
                        if char_kind >= 0 and char_kind <= 7 and not is_character_owned(char_kind) then
                            log.info(string.format("[Merc AP Gating] Blocking selectCostume for unowned character %d", char_kind))
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                    end
                end, function(retval)
                    return retval
                end)
            end

            local input_check = char_select_type:get_method("onInputCheckEvent")
            if input_check ~= nil then
                log.info("[Merc AP] Hooking Cp1021CharacterSelectGuiBehavior.onInputCheckEvent")
                local last_char_input = nil
                safe_hook(input_check, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    last_char_input = this_ptr
                end, function(retval)
                    local this_ptr = last_char_input
                    last_char_input = nil
                    if not should_enforce_gating() or this_ptr == nil then return retval end

                    local char_kind = resolve_selected_character_kind(this_ptr)
                    if char_kind >= 0 and char_kind <= 7 then
                        local owned = is_character_owned(char_kind)
                        log.info(string.format("[Merc AP Gating] CharacterSelect.onInputCheckEvent(char=%d) -> owned=%s", char_kind, tostring(owned)))
                        if not owned then
                            pcall(function() this_ptr:set_field("_bDecided", false) end)
                            pcall(function() this_ptr:set_field("_bOldCharaUnlock", false) end)
                            return sdk.to_ptr(0) -- Block confirmation
                        end
                    end
                    return retval
                end)
            end
        end

        -- 7. Hook Cp1021AcController_CharacterSelect & StageSelect
        local ac_char_type = sdk.find_type_definition("chainsaw.gui.mainmenu.Cp1021AcController_CharacterSelect")
        if ac_char_type ~= nil then
            for _, m in ipairs(ac_char_type:get_methods() or {}) do
                local mname = m:get_name()
                log.info(string.format("[Merc AP] Hooking Cp1021AcController_CharacterSelect.%s", mname))
                safe_hook(m, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    log.info(string.format("[Merc AP Gating] AcController_CharacterSelect.%s PRE", mname))
                end, function(retval)
                    return retval
                end)
            end
        end

        local ac_stage_type = sdk.find_type_definition("chainsaw.gui.mainmenu.Cp1021AcController_StageSelect")
        if ac_stage_type ~= nil then
            for _, m in ipairs(ac_stage_type:get_methods() or {}) do
                local mname = m:get_name()
                log.info(string.format("[Merc AP] Hooking Cp1021AcController_StageSelect.%s", mname))
                safe_hook(m, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    log.info(string.format("[Merc AP Gating] AcController_StageSelect.%s PRE", mname))
                end, function(retval)
                    return retval
                end)
            end
        end

        -- 8. Hook MercenariesModeController.startGame & updateGame (AUTHORITATIVE HARD GATE)
        local merc_ctrl_type = sdk.find_type_definition("chainsaw.MercenariesModeController")
        if merc_ctrl_type ~= nil then
            local start_game = merc_ctrl_type:get_method("startGame")
            if start_game ~= nil then
                log.info("[Merc AP] Hooking MercenariesModeController.startGame (Authoritative Hard Security Boundary)")
                safe_hook(start_game, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    if this_ptr ~= nil and should_enforce_gating() then
                        local st = get_safe_field_int(this_ptr, "_StageKind", -1)
                        local ch = get_safe_field_int(this_ptr, "_PlayerCharacterKind", -1)
                        local co = get_safe_field_int(this_ptr, "_PlayerCharacterCostumeId", 0)
                        local key = string.format("%d:%d", ch, co)
                        local entry = CHAR_COSTUME_TO_ROSTER[key]
                        local char_idx = entry and entry.index or ch

                        local st_owned = is_stage_owned(st)
                        local ch_owned = is_character_owned(char_idx)

                        if not (st_owned and ch_owned) then
                            log.error(string.format("[Merc AP Gating] HARD GATE ACTIVATED: Blocking launch! Stage: %d (owned=%s), Character: %s (owned=%s)", st, tostring(st_owned), tostring(char_idx), tostring(ch_owned)))
                            pcall(function() this_ptr:call("requestInGameQuit") end)
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                        log.info(string.format("[Merc AP Gating] HARD GATE PASSED: Stage %d, Character %d (%s) allowed", st, char_idx, tostring(entry and entry.name or "Unknown")))
                    end
                end, function(retval)
                    return retval
                end)
            end

            local update_game = merc_ctrl_type:get_method("updateGame")
            if update_game ~= nil then
                log.info("[Merc AP] Hooking MercenariesModeController.updateGame (Continuous Hard Guard)")
                safe_hook(update_game, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    if this_ptr ~= nil and should_enforce_gating() then
                        local st = get_safe_field_int(this_ptr, "_StageKind", -1)
                        local ch = get_safe_field_int(this_ptr, "_PlayerCharacterKind", -1)
                        local co = get_safe_field_int(this_ptr, "_PlayerCharacterCostumeId", 0)
                        local key = string.format("%d:%d", ch, co)
                        local entry = CHAR_COSTUME_TO_ROSTER[key]
                        local char_idx = entry and entry.index or ch

                        if not (is_stage_owned(st) and is_character_owned(char_idx)) then
                            pcall(function() this_ptr:call("requestInGameQuit") end)
                            return sdk.PreHookResult.SKIP_ORIGINAL
                        end
                    end
                end, function(retval)
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

