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

    local STAGE_KIND_NAMES = {
        [0] = "Village",
        [1] = "Castle",
        [2] = "Island",
        [3] = "Docks",
    }

    local STAGE_NAME_TO_KIND = {
        Village = 0,
        Castle = 1,
        Island = 2,
        Docks = 3,
    }

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
        [4] = "S+",
        [5] = "S++",
    }

    local STATE_IDLE = "IDLE"
    local STATE_RUN_PRESENT = "RUN_PRESENT"
    local STATE_RESULT_PIPELINE = "RESULT_PIPELINE"
    local STATE_RESULT_READY = "RESULT_READY"
    local STATE_RESULT_CONSUMED = "RESULT_CONSUMED"

    local merc_state = {
        lifecycle = STATE_IDLE,
        last_is_result = false,
        result_epoch = 0,
        consumed_result_epoch = -1,
        ready_result_epoch = -1,
        result_payload = nil,
    }

    local ownership = {
        characters = {},
        stages = {},
        enabled = false,
        ready = false,
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

    local function get_safe_field_bool(obj, field_name, fallback)
        if obj == nil then return fallback end
        local ok, val = pcall(function() return obj:get_field(field_name) end)
        if ok and type(val) == "boolean" then return val end
        if ok and type(val) == "number" then return val ~= 0 end
        return fallback
    end

    local function get_safe_bool(obj, method_name, fallback)
        if obj == nil then return fallback end
        local ok, val = pcall(function() return obj:call(method_name) end)
        if ok and type(val) == "boolean" then return val end
        if ok and type(val) == "number" then return val ~= 0 end
        return fallback
    end

    local function get_obj_address_str(obj)
        if obj == nil then return "nil" end
        local addr = nil
        pcall(function() addr = obj:get_address() end)
        if addr ~= nil then return string.format("0x%X", addr) end
        return tostring(obj)
    end

    local function same_object(left, right)
        if left == nil or right == nil then return false end
        if left == right then return true end
        local left_id = get_obj_address_str(left)
        local right_id = get_obj_address_str(right)
        return left_id ~= "nil" and left_id == right_id
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
        local ok, mgr = pcall(function()
            return sdk.get_managed_singleton("chainsaw.MercenariesManager")
        end)
        if ok and mgr ~= nil then return mgr end
        return nil
    end

    local type_cache = {}
    local function cached_typeof(type_name)
        if type_cache[type_name] == nil then type_cache[type_name] = sdk.typeof(type_name) end
        return type_cache[type_name]
    end

    local function get_scene_object()
        local scene_mgr = sdk.get_native_singleton("via.SceneManager")
        local scene_mgr_type = sdk.find_type_definition("via.SceneManager")
        if scene_mgr == nil or scene_mgr_type == nil then return nil end
        return sdk.call_native_func(scene_mgr, scene_mgr_type, "get_CurrentScene")
    end

    local function get_all_components(type_name)
        local scene = get_scene_object()
        if scene == nil then return {} end
        local type_obj = cached_typeof(type_name)
        if type_obj == nil then return {} end
        local result = nil
        pcall(function() result = scene:call("findComponents", type_obj) end)
        if result == nil then return {} end

        local list = {}
        local ok_elements, elements = pcall(function() return result:get_elements() end)
        if ok_elements and type(elements) == "table" then
            for _, element in ipairs(elements) do
                if element ~= nil then list[#list + 1] = element end
            end
            if #list > 0 then return list end
        end

        local ok_count, count = pcall(function() return result:get_Count() end)
        if not ok_count then ok_count, count = pcall(function() return result:get_size() end) end
        count = tonumber(count) or 0
        for index = 0, count - 1 do
            local ok_item, item = pcall(function() return result:get_Item(index) end)
            if not ok_item or item == nil then
                ok_item, item = pcall(function() return result:get_element(index) end)
            end
            if ok_item and item ~= nil then list[#list + 1] = item end
        end
        return list
    end

    local function find_first_component(type_name)
        local components = get_all_components(type_name)
        return #components > 0 and components[1] or nil
    end

    local function get_merc_controller()
        return find_first_component("chainsaw.MercenariesModeController")
    end
    export("get_merc_controller", get_merc_controller)

    local function get_result_gui_behavior()
        return find_first_component("chainsaw.Cp1021GameClearResultGuiBehavior")
    end
    export("get_result_gui_behavior", get_result_gui_behavior)

    local function get_runtime_domain()
        local merc_mgr = get_merc_manager()
        if merc_mgr ~= nil then
            local is_active = get_safe_int(merc_mgr, "get_Routine", -1) >= 0
            local is_result = get_safe_bool(merc_mgr, "get_IsResult", merc_state.last_is_result)
            if is_active or is_result then return "MERCENARIES" end
        end

        if get_merc_controller() ~= nil then return "MERCENARIES" end
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

    local function init_merc_ownership(slot_data)
        ownership.characters = {}
        ownership.stages = {}
        ownership.enabled = false
        ownership.ready = false
        if type(slot_data) ~= "table" then return end

        local merc_data = slot_data.mercenaries
        local mode_enabled = slot_data.game_mode == "mercenaries_only"
            or slot_data.game_mode == "campaign_and_mercenaries"
        local merc_enabled = mode_enabled or (type(merc_data) == "table" and merc_data.enabled == true)
        if not merc_enabled then return end
        ownership.enabled = true

        local starting_character = type(merc_data) == "table" and merc_data.starting_character or nil
        if type(starting_character) == "string" then
            for _, roster in pairs(CHAR_COSTUME_TO_ROSTER) do
                if roster.item_name == starting_character or roster.name == starting_character then
                    ownership.characters[roster.index] = true
                    log.info(string.format("[Merc AP Gating] granted starting character: %s (index %d)", roster.name, roster.index))
                    break
                end
            end
        end

        local starting_stage = type(merc_data) == "table" and merc_data.starting_stage or nil
        if type(starting_stage) == "string" then
            for stage_name, stage_kind in pairs(STAGE_NAME_TO_KIND) do
                if starting_stage == "Mercenaries Stage: " .. stage_name or starting_stage == stage_name then
                    ownership.stages[stage_kind] = true
                    log.info(string.format("[Merc AP Gating] granted starting stage: %s (kind %d)", stage_name, stage_kind))
                    break
                end
            end
        end

        ownership.ready = true
        log.info("[Merc AP Gating] ownership ready: starting inventory established")
    end
    export("init_merc_ownership", init_merc_ownership)

    local function refresh_open_merc_menus()
        local stage_gui = find_first_component("chainsaw.Cp1021StageSelectGuiBehavior")
        if stage_gui ~= nil then pcall(function() stage_gui:call("updateViewStage") end) end
        local char_gui = find_first_component("chainsaw.Cp1021CharacterSelectGuiBehavior")
        if char_gui ~= nil then pcall(function() char_gui:call("updateSelectCharacterList") end) end
    end
    export("refresh_open_merc_menus", refresh_open_merc_menus)

    local function handle_merc_item_received(item_name)
        if type(item_name) ~= "string" then return false end
        local changed = false
        for _, roster in pairs(CHAR_COSTUME_TO_ROSTER) do
            if roster.item_name == item_name or roster.name == item_name then
                if not ownership.characters[roster.index] then
                    ownership.characters[roster.index] = true
                    changed = true
                    log.info(string.format("[Merc AP Gating] received character unlock: %s (index %d)", roster.name, roster.index))
                end
                break
            end
        end
        for stage_name, stage_kind in pairs(STAGE_NAME_TO_KIND) do
            if item_name == "Mercenaries Stage: " .. stage_name or item_name == stage_name then
                if not ownership.stages[stage_kind] then
                    ownership.stages[stage_kind] = true
                    changed = true
                    log.info(string.format("[Merc AP Gating] received stage unlock: %s (kind %d)", stage_name, stage_kind))
                end
                break
            end
        end
        if changed then refresh_open_merc_menus() end
        return changed
    end
    export("handle_merc_item_received", handle_merc_item_received)

    local function reconcile_merc_ownership(items)
        if type(items) ~= "table" then return false end
        local changed = false
        for _, item in pairs(items) do
            local name = type(item) == "string" and item or (type(item) == "table" and item.name or nil)
            if type(name) == "string" and handle_merc_item_received(name) then changed = true end
        end
        return changed
    end
    export("reconcile_merc_ownership", reconcile_merc_ownership)

    local function is_character_owned(index)
        return ownership.characters[index] == true
    end

    local function is_stage_owned(index)
        return ownership.stages[index] == true
    end

    local function get_score_checks_mode(slot_data)
        local merc_data = type(slot_data) == "table" and slot_data.mercenaries or nil
        return (type(merc_data) == "table" and merc_data.score_checks)
            or (type(slot_data) == "table" and slot_data.mercenaries_score_checks)
            or "standard"
    end

    local function get_active_rank_names(score_checks_mode)
        local ranks = { "A" }
        if score_checks_mode == "standard" or score_checks_mode == "full" then ranks[#ranks + 1] = "S" end
        if score_checks_mode == "full" then
            ranks[#ranks + 1] = "S+"
            ranks[#ranks + 1] = "S++"
        end
        return ranks
    end

    local function get_merc_location_id(char_name, stage_name, rank_name, slot_data)
        local merc_data = type(slot_data) == "table" and slot_data.mercenaries or nil
        local locations = type(merc_data) == "table" and merc_data.locations or nil
        if type(locations) ~= "table" then
            return nil, "slot location map unavailable"
        end

        local by_character = locations[char_name]
        local by_stage = type(by_character) == "table" and by_character[stage_name] or nil
        local mapped = type(by_stage) == "table" and by_stage[rank_name] or nil
        if type(mapped) ~= "number" or mapped ~= math.floor(mapped) or mapped <= 0 then
            return nil, "slot location mapping missing or invalid"
        end
        return mapped
    end

    local function location_in_set(location_set, location_id)
        if type(location_set) ~= "table" then return true end
        if location_set[location_id] == true or location_set[tostring(location_id)] == true then return true end
        for _, value in pairs(location_set) do
            if tonumber(value) == location_id then return true end
        end
        return false
    end

    local function get_room_location_set()
        local candidates = {
            bridge.room_location_ids,
            bridge.room_location_set,
            bridge.room_locations,
            ctx.room_location_ids,
            ctx.room_location_set,
            ctx.room_locations,
        }
        for _, candidate in ipairs(candidates) do
            if type(candidate) == "table" then return candidate end
        end
        return nil
    end

    local function get_location_checked(set, location_id)
        return set[location_id] == true or set[tostring(location_id)] == true
    end

    local function get_mercenaries_checklist()
        local slot_data = ctx.slot_data or bridge.slot_data
        local merc_data = type(slot_data) == "table" and slot_data.mercenaries or nil
        local score_checks_mode = get_score_checks_mode(slot_data)
        local rank_names = get_active_rank_names(score_checks_mode)
        local checked_set = bridge.checked_locations or {}
        local stages = {}
        local grand_found, grand_total = 0, 0

        for stage_index = 0, 3 do
            local stage_name = STAGE_KIND_NAMES[stage_index]
            local stage_found, stage_total = 0, 0
            local characters = {}
            for char_index = 0, 7 do
                local char_name = ROSTER_INDEX_TO_NAME[char_index]
                local ranks = {}
                local char_found = 0
                for _, rank_name in ipairs(rank_names) do
                    local location_id = get_merc_location_id(char_name, stage_name, rank_name, slot_data)
                    local checked = location_id ~= nil and get_location_checked(checked_set, location_id)
                    if checked then
                        char_found = char_found + 1
                        stage_found = stage_found + 1
                        grand_found = grand_found + 1
                    end
                    stage_total = stage_total + 1
                    grand_total = grand_total + 1
                    ranks[#ranks + 1] = { name = rank_name, loc_id = location_id, checked = checked }
                end
                characters[#characters + 1] = {
                    char_idx = char_index,
                    char_name = char_name,
                    unlocked = is_character_owned(char_index),
                    found = char_found,
                    total = #rank_names,
                    ranks = ranks,
                }
            end
            stages[#stages + 1] = {
                stage_idx = stage_index,
                stage_name = stage_name,
                unlocked = is_stage_owned(stage_index),
                found = stage_found,
                total = stage_total,
                characters = characters,
            }
        end

        local enabled = (type(merc_data) == "table" and merc_data.enabled == true)
            or (type(slot_data) == "table" and (slot_data.game_mode == "mercenaries_only"
                or slot_data.game_mode == "campaign_and_mercenaries"))
        return {
            enabled = enabled,
            mode = type(slot_data) == "table" and slot_data.game_mode or "campaign",
            score_checks_mode = score_checks_mode,
            found = grand_found,
            total = grand_total,
            stages = stages,
        }
    end
    export("get_mercenaries_checklist", get_mercenaries_checklist)

    local function get_current_merc_play_info()
        local ok, result = pcall(function()
            local controller = get_merc_controller()
            if controller == nil then return nil end
            local stage_index = get_safe_int(controller, "get_StageKind", -1)
            if stage_index < 0 then stage_index = get_safe_field_int(controller, "_StageKind", -1) end
            local chara_kind = get_safe_field_int(controller, "_PlayerCharacterKind", -1)
            local costume_id = get_safe_field_int(controller, "_PlayerCharacterCostumeId", -1)
            local roster = CHAR_COSTUME_TO_ROSTER[string.format("%d:%d", chara_kind, costume_id)]
            local char_index = roster and roster.index or -1
            local stage_name = STAGE_KIND_NAMES[stage_index] or "Unknown Stage"
            local char_name = roster and roster.name or "Unknown"
            local slot_data = ctx.slot_data or bridge.slot_data
            local rank_names = get_active_rank_names(get_score_checks_mode(slot_data))
            local checked_set = bridge.checked_locations or {}
            local done, rank_summary = 0, {}

            for _, rank_name in ipairs(rank_names) do
                local location_id = nil
                if char_index >= 0 and STAGE_KIND_NAMES[stage_index] ~= nil then
                    location_id = get_merc_location_id(char_name, stage_name, rank_name, slot_data)
                end
                local checked = location_id ~= nil and get_location_checked(checked_set, location_id)
                if checked then
                    done = done + 1
                    rank_summary[#rank_summary + 1] = "[" .. rank_name .. ": OK]"
                else
                    rank_summary[#rank_summary + 1] = "[" .. rank_name .. "]"
                end
            end
            return {
                stage_name = stage_name,
                char_name = char_name,
                stage_idx = stage_index,
                char_idx = char_index,
                done = done,
                total = #rank_names,
                ranks_str = table.concat(rank_summary, " "),
            }
        end)
        return ok and result or nil
    end
    export("get_current_merc_play_info", get_current_merc_play_info)

    local result_error_counts = {}
    local function bounded_result_error(epoch, kind, detail)
        local key = tostring(epoch) .. ":" .. tostring(kind)
        local count = (result_error_counts[key] or 0) + 1
        result_error_counts[key] = count
        if count <= 3 then
            log.warn(string.format("[Merc AP] result retry: %s (%s)", tostring(kind), tostring(detail)))
        end
    end

    local function read_open_param_int(open_param, getter_name, field_name, fallback)
        local value = get_safe_int(open_param, getter_name, fallback)
        if value ~= fallback then return value end
        return get_safe_field_int(open_param, field_name, fallback)
    end

    local function read_total_score(open_param)
        local score_object = nil
        local ok_getter = pcall(function() score_object = open_param:call("get_TotalScore") end)
        if not ok_getter or score_object == nil then return nil end
        local ok_value, value = pcall(function() return score_object:call("get_Value()") end)
        if ok_value and type(value) == "number" then return value end
        return nil
    end

    local function build_result_payload(open_param)
        if open_param == nil then return nil, "OpenParam unavailable" end
        local stage_kind = read_open_param_int(open_param, "get_Stage", "Stage", -1)
        local chara_kind = read_open_param_int(open_param, "get_PlChara", "PlChara", -1)
        if STAGE_KIND_NAMES[stage_kind] == nil then return nil, "invalid Stage" end

        local costume_id = read_open_param_int(open_param, "get_PlCostumeId", "PlCostumeId", -1)
        local roster = CHAR_COSTUME_TO_ROSTER[string.format("%d:%d", chara_kind, costume_id)]
        if roster == nil then return nil, "invalid PlChara/costume mapping" end

        local rank = read_open_param_int(open_param, "get_Rank", "Rank", -1)
        local rank_name = SCORE_RANK_NAMES[rank]
        if rank_name == nil then return nil, "invalid rank mapping" end

        local total_score = read_total_score(open_param)
        if total_score == nil then return nil, "TotalScore:get_Value failed" end
        return {
            char_name = roster.name,
            stage_name = STAGE_KIND_NAMES[stage_kind],
            stage_kind = stage_kind,
            chara_kind = chara_kind,
            costume_id = costume_id,
            rank = rank,
            rank_name = rank_name,
            total_score = total_score,
        }
    end

    local function evaluate_result_locations(payload, slot_data)
        local score_checks_mode = get_score_checks_mode(slot_data)
        local rank_names = {}
        if payload.rank >= 2 then rank_names[#rank_names + 1] = "A" end
        if payload.rank >= 3 and (score_checks_mode == "standard" or score_checks_mode == "full") then
            rank_names[#rank_names + 1] = "S"
        end
        if payload.rank >= 4 and score_checks_mode == "full" then rank_names[#rank_names + 1] = "S+" end
        if payload.rank >= 5 and score_checks_mode == "full" then rank_names[#rank_names + 1] = "S++" end

        bridge.pending_checks = bridge.pending_checks or {}
        bridge.pending_check_keys = bridge.pending_check_keys or {}
        bridge.mercenaries_completed_locations = bridge.mercenaries_completed_locations or {}
        local checked_set = bridge.checked_locations or {}
        local completed_set = bridge.mercenaries_completed_locations
        local room_set = get_room_location_set()
        local to_queue = {}

        for _, rank_name in ipairs(rank_names) do
            local location_id, mapping_error = get_merc_location_id(
                payload.char_name, payload.stage_name, rank_name, slot_data)
            if location_id == nil then return false, mapping_error or "location mapping failed" end
            if room_set ~= nil and not location_in_set(room_set, location_id) then
                return false, "location is not in room set"
            end

            local key = "merc:" .. tostring(location_id)
            if not get_location_checked(checked_set, location_id)
                and not get_location_checked(completed_set, location_id)
                and bridge.pending_check_keys[key] ~= true then
                to_queue[#to_queue + 1] = { id = location_id, key = key, rank = rank_name }
            end
        end

        local next_id = math.floor(tonumber(bridge.next_pending_check_id) or 1)
        local completed_changed = false
        local now_unix_ms = ctx.now_unix_ms or _G.now_unix_ms
        local queued_at_unix_ms = type(now_unix_ms) == "function"
            and now_unix_ms() or (os.time() * 1000)
        for _, item in ipairs(to_queue) do
            local entry = {
                id = next_id,
                key = item.key,
                location_id = item.id,
                source = "mercenaries",
                queued_at_unix_ms = queued_at_unix_ms,
            }
            bridge.pending_checks[#bridge.pending_checks + 1] = entry
            bridge.pending_check_keys[item.key] = true
            bridge.mercenaries_completed_locations[item.id] = true
            completed_changed = true
            bridge.next_pending_check_id = next_id + 1
            next_id = next_id + 1
            log.info(string.format(
                "[Merc AP] score location queued: location_id=%d rank=%s",
                item.id, item.rank
            ))
        end
        if #to_queue > 0 then
            bridge.state_dirty = true
            if completed_changed and type(ctx.save_session_state) == "function" then
                ctx.save_session_state()
            end
        end
        return true
    end

    local function poll_result_pipeline()
        local result_gui = get_result_gui_behavior()
        if result_gui == nil then return end
        local open_param = nil
        local ok_param = pcall(function() open_param = result_gui:get_field("_OpenParam") end)
        if not ok_param or open_param == nil then
            bounded_result_error(merc_state.result_epoch, "payload", "OpenParam unavailable")
            return
        end

        if merc_state.lifecycle == STATE_RESULT_PIPELINE then
            local payload, payload_error = build_result_payload(open_param)
            if payload == nil then
                bounded_result_error(merc_state.result_epoch, "payload", payload_error)
                return
            end
            merc_state.result_payload = payload
            merc_state.ready_result_epoch = merc_state.result_epoch
            merc_state.lifecycle = STATE_RESULT_READY
            log.info(string.format(
                "[Merc AP] result ready: epoch=%d stage=%s character=%s costume=%d rank=%s total_score=%d",
                merc_state.result_epoch, payload.stage_name, payload.char_name,
                payload.costume_id, payload.rank_name, payload.total_score
            ))
        end

        if merc_state.lifecycle == STATE_RESULT_READY
            and merc_state.consumed_result_epoch ~= merc_state.result_epoch
            and merc_state.result_payload ~= nil then
            local ok_locations, location_error = evaluate_result_locations(
                merc_state.result_payload, ctx.slot_data or bridge.slot_data)
            if not ok_locations then
                bounded_result_error(merc_state.result_epoch, "mapping", location_error)
                return
            end
            merc_state.consumed_result_epoch = merc_state.result_epoch
            merc_state.lifecycle = STATE_RESULT_CONSUMED
        end
    end

    local function update_mercenaries_state()
        local merc_manager = get_merc_manager()
        if merc_manager == nil then
            merc_state.last_is_result = false
            if merc_state.lifecycle ~= STATE_RESULT_CONSUMED then merc_state.lifecycle = STATE_IDLE end
            return
        end

        local is_result = get_safe_bool(merc_manager, "get_IsResult", merc_state.last_is_result)
        if is_result and not merc_state.last_is_result then
            merc_state.result_epoch = merc_state.result_epoch + 1
            merc_state.ready_result_epoch = -1
            merc_state.result_payload = nil
            merc_state.lifecycle = STATE_RESULT_PIPELINE
            log.info(string.format("[Merc AP] result pipeline entered: epoch=%d", merc_state.result_epoch))
        elseif not is_result then
            merc_state.lifecycle = STATE_IDLE
            merc_state.result_payload = nil
        end
        merc_state.last_is_result = is_result

        if merc_state.lifecycle == STATE_RESULT_PIPELINE or merc_state.lifecycle == STATE_RESULT_READY then
            poll_result_pipeline()
        end
    end
    export("update_mercenaries_state", update_mercenaries_state)

    local function should_enforce_gating()
        return ownership.enabled == true and ownership.ready == true
    end

    local function get_obj_type_name(obj)
        if obj == nil then return "" end
        local ok, type_def = pcall(function() return obj:get_type_definition() end)
        if not ok or type_def == nil then return "" end
        local ok_name, name = pcall(function() return type_def:get_full_name() end)
        return ok_name and type(name) == "string" and name or ""
    end

    local hooks_installed = false
    local hooked_functions = {}
    local decision_delegates = {}
    local decision_hooked_native_keys = {}
    local on_decided_pre

    local DECISION_DELEGATE_TYPE =
        "System.Action`1<chainsaw.Cp1021CharacterSelectMenuActionType>"
    local DECISION_ACTION_TYPE = "chainsaw.Cp1021CharacterSelectMenuActionType"
    local DECISION_INVOKE_NATIVE = 5369594608

    local function safe_hook_unique(method, pre, post)
        if method == nil then return false end
        local function_ptr = nil
        pcall(function() function_ptr = method:get_function() end)
        local key = tostring(function_ptr or method)
        if hooked_functions[key] then return true end
        local ok, hook_result = pcall(function() return sdk.hook(method, pre, post) end)
        if ok and hook_result ~= false then
            hooked_functions[key] = true
            return true
        end
        return false
    end

    local function decode_action(raw)
        if raw == nil then return nil end
        local value = nil
        pcall(function() value = sdk.to_int64(raw) end)
        return tonumber(value)
    end

    local function read_requested_character(gui)
        local requested = get_safe_field_int(gui, "<RequestedCharacter>k__BackingField", -1)
        if requested == -1 then requested = get_safe_int(gui, "get_RequestedCharacter", -1) end
        return requested
    end

    local function read_direct_bool(gui, field_name)
        local value = nil
        local ok = pcall(function() value = gui:get_field(field_name) end)
        if not ok or value == nil then return nil end
        if type(value) == "boolean" then return value end
        if type(value) == "number" and (value == 0 or value == 1) then return value == 1 end
        return nil
    end

    local function get_type_full_name(type_def)
        if type_def == nil then return nil end
        local ok, name = pcall(function() return type_def:get_full_name() end)
        if ok and type(name) == "string" then return name end
        return nil
    end

    local function get_method_parameter_types(method)
        local param_types = nil
        pcall(function() param_types = method:get_param_types() end)
        if type(param_types) ~= "table" then
            pcall(function() param_types = method:get_parameter_types() end)
        end
        return param_types
    end

    local function is_exact_decision_invoke(method)
        if method == nil then return false end
        local ok_static, is_static = pcall(function() return method:is_static() end)
        if not ok_static or is_static ~= false then return false end

        local ok_count, count = pcall(function() return method:get_num_params() end)
        if not ok_count or count ~= 1 then return false end

        local param_types = get_method_parameter_types(method)
        if type(param_types) ~= "table" or #param_types ~= 1 then return false end
        if get_type_full_name(param_types[1]) ~= DECISION_ACTION_TYPE then return false end

        local return_type = nil
        local ok_return = pcall(function() return_type = method:get_return_type() end)
        if not ok_return or get_type_full_name(return_type) ~= "System.Void" then return false end

        local native = nil
        local ok_native = pcall(function() native = method:get_function() end)
        local native_int64 = nil
        local ok_native_int64 = ok_native and pcall(function() native_int64 = sdk.to_int64(native) end)
        if not ok_native_int64 or tonumber(native_int64) ~= DECISION_INVOKE_NATIVE then return false end
        return true
    end

    local function get_live_on_decided(gui)
        if gui == nil then return nil end
        local open_param = nil
        local ok_open = pcall(function() open_param = gui:get_field("_OpenParam") end)
        if not ok_open or open_param == nil then return nil end
        local delegate = nil
        local ok_delegate = pcall(function() delegate = open_param:get_field("OnDecided") end)
        return ok_delegate and delegate or nil
    end

    local function install_decision_invoke_hook(invoke_method)
        if decision_hooked_native_keys[tostring(DECISION_INVOKE_NATIVE)] then return true end
        local ok, hook_result = pcall(function()
            return sdk.hook(invoke_method, on_decided_pre, function(retval) return retval end)
        end)
        if not ok or hook_result == false then
            log.warn("[Merc AP Gating] OnDecided hook failed")
            return false
        end
        decision_hooked_native_keys[tostring(DECISION_INVOKE_NATIVE)] = true
        return true
    end

    on_decided_pre = function(args)
        local delegate_object = nil
        pcall(function() delegate_object = sdk.to_managed_object(args[2]) end)
        local delegate_id = get_obj_address_str(delegate_object)
        local delegate_info = decision_delegates[delegate_id]
        if delegate_info == nil or not same_object(delegate_object, delegate_info.delegate) then
            return sdk.PreHookResult.CALL_ORIGINAL
        end

        local live_delegate = get_live_on_decided(delegate_info.gui)
        if not same_object(live_delegate, delegate_object) then
            return sdk.PreHookResult.CALL_ORIGINAL
        end

        local action = decode_action(args[3])
        local gui = delegate_info.gui
        if action == nil or gui == nil then return sdk.PreHookResult.CALL_ORIGINAL end
        local requested = read_requested_character(gui)
        if action ~= requested then return sdk.PreHookResult.CALL_ORIGINAL end

        local ok_kind, roster = pcall(function() return gui:call("getCharacterKind", action) end)
        if not ok_kind or type(roster) ~= "number" or roster < 0 or roster > 7
            or roster ~= math.floor(roster) then
            return sdk.PreHookResult.CALL_ORIGINAL
        end
        if not should_enforce_gating() or is_character_owned(roster) then
            return sdk.PreHookResult.CALL_ORIGINAL
        end

        local original_decided = read_direct_bool(gui, "_bDecided")
        local original_old_unlock = read_direct_bool(gui, "_bOldCharaUnlock")
        if original_decided ~= true or original_old_unlock == nil then
            return sdk.PreHookResult.CALL_ORIGINAL
        end

        local function rollback()
            pcall(function() gui:set_field("_bDecided", original_decided) end)
            pcall(function() gui:set_field("_bOldCharaUnlock", original_old_unlock) end)
            return read_direct_bool(gui, "_bDecided") == original_decided
                and read_direct_bool(gui, "_bOldCharaUnlock") == original_old_unlock
        end

        local old_unlock_ok = pcall(function() gui:set_field("_bOldCharaUnlock", false) end)
        if not old_unlock_ok or read_direct_bool(gui, "_bOldCharaUnlock") ~= false then
            if not rollback() then return sdk.PreHookResult.SKIP_ORIGINAL end
            return sdk.PreHookResult.CALL_ORIGINAL
        end
        local decided_ok = pcall(function() gui:set_field("_bDecided", false) end)
        if not decided_ok or read_direct_bool(gui, "_bDecided") ~= false then
            if not rollback() then return sdk.PreHookResult.SKIP_ORIGINAL end
            return sdk.PreHookResult.CALL_ORIGINAL
        end

        log.info("[Merc AP Gating] blocked character: " .. (ROSTER_INDEX_TO_NAME[roster] or "Unknown"))
        return sdk.PreHookResult.SKIP_ORIGINAL
    end

    local function register_decision_delegate(gui)
        if gui == nil then return end
        local delegate = get_live_on_decided(gui)
        if delegate == nil then return end
        local delegate_type_name = get_obj_type_name(delegate)
        if delegate_type_name ~= DECISION_DELEGATE_TYPE then return end
        local delegate_id = get_obj_address_str(delegate)
        local delegate_type = nil
        pcall(function() delegate_type = delegate:get_type_definition() end)
        if delegate_type == nil then return end

        local invoke_method = nil
        local invoke_count = 0
        local methods = nil
        pcall(function() methods = delegate_type:get_methods() end)
        for _, method in ipairs(methods or {}) do
            local name = nil
            pcall(function() name = method:get_name() end)
            if name == "Invoke" and is_exact_decision_invoke(method) then
                invoke_method = method
                invoke_count = invoke_count + 1
            end
        end
        if invoke_count ~= 1 or invoke_method == nil then return end
        if not install_decision_invoke_hook(invoke_method) then return end
        decision_delegates[delegate_id] = { delegate = delegate, gui = gui }
    end

    local is_unlock_query_stack = {}
    local function on_is_unlock_pre(args)
        local this_object = nil
        pcall(function() this_object = sdk.to_managed_object(args[2]) end)
        local raw_arg = decode_action(args[3]) or -1
        is_unlock_query_stack[#is_unlock_query_stack + 1] = { this = this_object, arg = raw_arg }
        if get_obj_type_name(this_object) == "chainsaw.Cp1021CharacterSelectGuiBehavior" then
            register_decision_delegate(this_object)
        end
    end

    local function on_is_unlock_post(retval)
        local query = is_unlock_query_stack[#is_unlock_query_stack]
        is_unlock_query_stack[#is_unlock_query_stack] = nil
        if query == nil or not should_enforce_gating() or query.this == nil then return retval end
        local type_name = get_obj_type_name(query.this)

        if type_name == "chainsaw.Cp1021UnlockSettingsUserData.CharacterSetting" then
            local kind = get_safe_field_int(query.this, "KindId", -1)
            if kind < 0 then kind = get_safe_int(query.this, "get_KindId", -1) end
            if kind >= 0 and kind <= 7 then return sdk.to_ptr(is_character_owned(kind) and 1 or 0) end
        elseif type_name == "chainsaw.Cp1021UnlockSettingsUserData.StageSetting" then
            local kind = get_safe_field_int(query.this, "KindId", -1)
            if kind < 0 then kind = get_safe_int(query.this, "get_KindId", -1) end
            if kind >= 0 and kind <= 3 then return sdk.to_ptr(is_stage_owned(kind) and 1 or 0) end
        elseif type_name == "chainsaw.Cp1021CharacterSelectGuiBehavior" and query.arg >= 0 then
            local ok_kind, kind = pcall(function() return query.this:call("getCharacterKind", query.arg) end)
            if ok_kind and type(kind) == "number" and kind >= 0 and kind <= 7 then
                return sdk.to_ptr(is_character_owned(kind) and 1 or 0)
            end
        elseif type_name == "chainsaw.Cp1021StageSelectGuiBehavior" and query.arg >= 0 then
            local ok_kind, kind = pcall(function() return query.this:call("getKindId", query.arg) end)
            if ok_kind and type(kind) == "number" and kind >= 0 and kind <= 3 then
                return sdk.to_ptr(is_stage_owned(kind) and 1 or 0)
            end
        end
        return retval
    end

    local function install_merc_virtual_gating_hooks()
        if hooks_installed then return end
        local unlock_types = {
            "chainsaw.Cp1021UnlockSettingsUserData.StageSetting",
            "chainsaw.Cp1021UnlockSettingsUserData.CharacterSetting",
            "chainsaw.Cp1021StageSelectGuiBehavior",
            "chainsaw.Cp1021CharacterSelectGuiBehavior",
        }
        for _, type_name in ipairs(unlock_types) do
            local type_def = sdk.find_type_definition(type_name)
            if type_def ~= nil then
                for _, method in ipairs(type_def:get_methods() or {}) do
                    local method_name = nil
                    pcall(function() method_name = method:get_name() end)
                    if method_name == "isUnlock" then safe_hook_unique(method, on_is_unlock_pre, on_is_unlock_post) end
                end
            end
        end
        hooks_installed = true
    end

    export("install_merc_virtual_gating_hooks", install_merc_virtual_gating_hooks)
    install_merc_virtual_gating_hooks()

    export("merc_state", merc_state)
    export("merc_ownership", ownership)
end

return install
