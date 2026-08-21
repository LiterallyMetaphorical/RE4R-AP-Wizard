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
        enabled = false, -- True iff slot is connected and Mercenaries is enabled
        ready = false,   -- True iff starting/received ownership inventory is populated
    }

    local MERC_P1_TRACE_REV = "2026-08-19-TRACE-V2-FORENSIC"
    log.info(string.format("[Merc AP Trace] Initializing Mercenaries runtime module (rev %s)", MERC_P1_TRACE_REV))

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
        if addr ~= nil then
            return string.format("0x%X", addr)
        end
        return tostring(obj)
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

    local function get_all_components(type_name)
        local scene = get_scene_object()
        if scene == nil then return {} end
        local t = cached_typeof(type_name)
        if t == nil then return {} end
        local result = nil
        pcall(function() result = scene:call("findComponents", t) end)
        if result == nil then return {} end

        local list = {}
        local ok_el, elements = pcall(function() return result:get_elements() end)
        if ok_el and type(elements) == "table" then
            for _, e in ipairs(elements) do
                if e ~= nil then table.insert(list, e) end
            end
            if #list > 0 then return list end
        end

        local ok_count, count = pcall(function() return result:get_Count() end)
        if not ok_count then
            ok_count, count = pcall(function() return result:get_size() end)
        end
        count = tonumber(count) or 0
        for i = 0, count - 1 do
            local ok_item, item = pcall(function() return result:get_Item(i) end)
            if not ok_item or item == nil then
                ok_item, item = pcall(function() return result:get_element(i) end)
            end
            if ok_item and item ~= nil then
                table.insert(list, item)
            end
        end
        return list
    end

    local function find_first_component(type_name)
        local components = get_all_components(type_name)
        if #components > 0 then return components[1] end
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
        ownership.enabled = false
        ownership.ready = false

        if type(slot_data) ~= "table" then return end
        local is_merc_mode = (slot_data.game_mode == "mercenaries_only" or slot_data.game_mode == "campaign_and_mercenaries")
        local merc_data = slot_data.mercenaries
        local is_merc_enabled = is_merc_mode or (type(merc_data) == "table" and merc_data.enabled == true)

        if not is_merc_enabled then return end

        ownership.enabled = true

        local start_char = type(merc_data) == "table" and merc_data.starting_character or nil
        if type(start_char) == "string" then
            for key, roster in pairs(CHAR_COSTUME_TO_ROSTER) do
                if roster.item_name == start_char or roster.name == start_char then
                    ownership.characters[roster.index] = true
                    log.info(string.format("[Merc AP Gating] granted starting character: %s (index %d)", roster.name, roster.index))
                    break
                end
            end
        end

        local start_stage = type(merc_data) == "table" and merc_data.starting_stage or nil
        if type(start_stage) == "string" then
            for stage_name, stage_kind in pairs(STAGE_NAME_TO_KIND) do
                if start_stage == ("Mercenaries Stage: " .. stage_name) or start_stage == stage_name then
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
        if stage_gui ~= nil then
            local ok = pcall(function()
                stage_gui:call("updateViewStage")
            end)
            if ok then
                log.info("[Merc AP Gating] menu refresh: updated StageSelect view after ownership change")
            end
        end

        local char_gui = find_first_component("chainsaw.Cp1021CharacterSelectGuiBehavior")
        if char_gui ~= nil then
            local ok = pcall(function()
                char_gui:call("updateSelectCharacterList")
            end)
            if ok then
                log.info("[Merc AP Gating] menu refresh: updated CharacterSelect view after ownership change")
            end
        end
    end
    export("refresh_open_merc_menus", refresh_open_merc_menus)

    local function handle_merc_item_received(item_name)
        if type(item_name) ~= "string" then return false end
        local changed = false

        -- Check character items
        for key, roster in pairs(CHAR_COSTUME_TO_ROSTER) do
            if roster.item_name == item_name or roster.name == item_name then
                if not ownership.characters[roster.index] then
                    ownership.characters[roster.index] = true
                    changed = true
                    log.info(string.format("[Merc AP Gating] received character unlock: %s (index %d)", roster.name, roster.index))
                end
                break
            end
        end

        -- Check stage items
        for stage_name, stage_kind in pairs(STAGE_NAME_TO_KIND) do
            local expected_item = "Mercenaries Stage: " .. stage_name
            if expected_item == item_name or stage_name == item_name then
                if not ownership.stages[stage_kind] then
                    ownership.stages[stage_kind] = true
                    changed = true
                    log.info(string.format("[Merc AP Gating] received stage unlock: %s (kind %d)", stage_name, stage_kind))
                end
                break
            end
        end

        if changed then
            refresh_open_merc_menus()
        end

        return changed
    end
    export("handle_merc_item_received", handle_merc_item_received)

    local function reconcile_merc_ownership(items)
        if type(items) ~= "table" then return false end
        local any_changed = false
        for _, it in pairs(items) do
            local name = nil
            if type(it) == "string" then
                name = it
            elseif type(it) == "table" then
                name = it.name
            end
            if type(name) == "string" then
                if handle_merc_item_received(name) then
                    any_changed = true
                end
            end
        end
        return any_changed
    end
    export("reconcile_merc_ownership", reconcile_merc_ownership)

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

    local ACTION_TYPE_TO_ROSTER_INDEX = {
        [1] = 0, -- Character01: Leon (Default)
        [2] = 1, -- Character01_01: Leon (Pinstripe)
        [3] = 2, -- Character02: Luis
        [4] = 3, -- Character03: Krauser
        [5] = 4, -- Character04: HUNK
        [6] = 5, -- Character05: Ada (Default)
        [7] = 6, -- Character05_01: Ada (Dress)
        [8] = 7, -- Character06: Wesker
    }

    local function action_type_to_roster_index(action_type, gui_obj)
        if type(action_type) == "number" then
            if ACTION_TYPE_TO_ROSTER_INDEX[action_type] ~= nil then
                return ACTION_TYPE_TO_ROSTER_INDEX[action_type]
            end
            if action_type >= 1 and action_type <= 8 then
                return action_type - 1
            end
            if action_type >= 0 and action_type <= 7 then
                return action_type
            end
        end
        if gui_obj ~= nil and action_type ~= nil then
            local ok_k, k = pcall(function() return gui_obj:call("getCharacterKind", action_type) end)
            if ok_k and type(k) == "number" and k >= 0 and k <= 7 then
                return k
            end
        end
        return -1
    end

    local function resolve_highlighted_character_kind(char_gui)
        if char_gui == nil then return -1 end

        -- 1. Try <RequestedCharacter>k__BackingField
        local req_char = get_safe_field_int(char_gui, "<RequestedCharacter>k__BackingField", -1)
        if req_char > 0 then
            local idx = action_type_to_roster_index(req_char, char_gui)
            if idx >= 0 then return idx end
        end

        -- 2. Try _PanelThumbList._SlCharacter cursor index
        local panel_thumb = nil
        pcall(function() panel_thumb = char_gui:get_field("_PanelThumbList") end)
        local cursor_idx = -1
        if panel_thumb ~= nil then
            local sl = nil
            pcall(function() sl = panel_thumb:get_field("_SlCharacter") end)
            if sl ~= nil then
                cursor_idx = get_safe_int(sl, "get_CursorIndex", -1)
            end
            if cursor_idx < 0 then
                cursor_idx = get_safe_int(panel_thumb, "get_SelectedIndex", -1)
            end
        end

        -- 3. Map cursor index through _CharacterItemList / getCharacterKind
        if cursor_idx >= 0 then
            local item_list = nil
            pcall(function() item_list = char_gui:get_field("_CharacterItemList") end)
            if item_list ~= nil then
                local item_count = get_safe_int(item_list, "get_Count", -1)
                if item_count < 0 then
                    item_count = get_safe_int(item_list, "get_size", -1)
                end
                if cursor_idx < item_count then
                    local ok_it, action_type = pcall(function() return item_list:call("get_Item", cursor_idx) end)
                    if ok_it and action_type ~= nil then
                        local idx = action_type_to_roster_index(action_type, char_gui)
                        if idx >= 0 then return idx end
                    end
                end
            end

            local ok_k, kind = pcall(function() return char_gui:call("getCharacterKind", cursor_idx) end)
            if ok_k and type(kind) == "number" and kind >= 0 and kind <= 7 then
                return kind
            end
            if cursor_idx >= 0 and cursor_idx <= 7 then
                return cursor_idx
            end
        end

        -- 4. Fallback: get_CurrCharacter
        local ok_curr, curr = pcall(function() return char_gui:call("get_CurrCharacter") end)
        if ok_curr and curr ~= nil then
            local idx = action_type_to_roster_index(curr, char_gui)
            if idx >= 0 then return idx end
        end

        return -1
    end

    local function resolve_highlighted_stage_kind(stage_gui)
        if stage_gui == nil then return -1 end

        local panel_stage = nil
        pcall(function() panel_stage = stage_gui:get_field("_PanelStage") end)
        local cursor_idx = -1
        if panel_stage ~= nil then
            local sl = nil
            pcall(function() sl = panel_stage:get_field("_SlStage") end)
            if sl ~= nil then
                cursor_idx = get_safe_int(sl, "get_CursorIndex", -1)
            end
        end

        if cursor_idx >= 0 then
            local item_list = nil
            pcall(function() item_list = stage_gui:get_field("_MenuItemList") end)
            if item_list ~= nil then
                local ok_it, action_type = pcall(function() return item_list:call("get_Item", cursor_idx) end)
                if ok_it and action_type ~= nil then
                    local ok_k, kind = pcall(function() return stage_gui:call("getKindId", action_type) end)
                    if ok_k and type(kind) == "number" and kind >= 0 and kind <= 3 then
                        return kind
                    end
                end
            end

            local ok_k, kind = pcall(function() return stage_gui:call("getKindId", cursor_idx) end)
            if ok_k and type(kind) == "number" and kind >= 0 and kind <= 3 then
                return kind
            end
            if cursor_idx >= 0 and cursor_idx <= 3 then
                return cursor_idx
            end
        end

        return -1
    end

    local function should_enforce_gating()
        return ownership.enabled == true and ownership.ready == true
    end

    local function enforce_character_decision_gate(gui, source)
        if not should_enforce_gating() or gui == nil then return false end

        local decided = get_safe_field_bool(gui, "_bDecided", false)
        if decided ~= true then return false end

        local requested = get_safe_field_int(gui, "<RequestedCharacter>k__BackingField", -1)
        if requested == -1 then
            requested = get_safe_int(gui, "get_RequestedCharacter", -1)
        end

        local ok_kind, roster = pcall(function()
            return gui:call("getCharacterKind", requested)
        end)
        if not ok_kind or type(roster) ~= "number" or roster < 0 or roster > 7 then
            return false
        end

        if is_character_owned(roster) then return false end

        pcall(function() gui:set_field("_bDecided", false) end)
        pcall(function() gui:set_field("_bOldCharaUnlock", false) end)
        log.info(string.format(
            "[Merc AP Gating] character decision rejected: source=%s action=%d roster=%d name=%s",
            tostring(source or "unknown"), requested, roster, ROSTER_INDEX_TO_NAME[roster]
        ))
        return true
    end

    -- Forensic observation infrastructure records hook activity and delegate
    -- identity. Retained post-decision helper below is legacy diagnostics only.
    local tracked_char_guis = {}
    local tracked_ac_ctrls = {}
    local tracked_controllers = {}
    local call_counts = {}
    local inspected_on_decided = {}
    local install_live_on_decided_invoke_hook = nil
    local dump_live_on_decided_internals = nil

    local function record_call(name)
        local key = tostring(name or "<nil>")
        local count = (call_counts[key] or 0) + 1
        call_counts[key] = count
        return count
    end

    local function emit_call_counts_summary(reason)
        local names = {}
        for name in pairs(call_counts) do
            table.insert(names, name)
        end
        table.sort(names)

        local entries = {}
        for _, name in ipairs(names) do
            table.insert(entries, string.format("%s=%d", name, call_counts[name]))
        end

        log.info(string.format(
            "[Merc AP Trace][CALL_COUNTS_SUMMARY] reason=%s counts=%s",
            tostring(reason or "unknown"), #entries > 0 and table.concat(entries, ",") or "none"
        ))
    end

    local function inspect_on_decided_delegate(open_param, owner_id, gui)
        if open_param == nil then return end

        local delegate = nil
        local ok = pcall(function() delegate = open_param:get_field("OnDecided") end)
        if not ok or delegate == nil then return end

        local delegate_id = get_obj_address_str(delegate)
        if delegate_id ~= "nil" and not inspected_on_decided[delegate_id] then
            inspected_on_decided[delegate_id] = true
            local content = "<unavailable>"
            pcall(function() content = tostring(delegate) end)
            log.info(string.format(
                "[Merc AP Trace][ON_DECIDED_INSPECT] owner=%s delegate=%s content=%s",
                tostring(owner_id or "unknown"), delegate_id, content
            ))
            if dump_live_on_decided_internals ~= nil then
                dump_live_on_decided_internals(delegate, delegate_id)
            end
        end

        if install_live_on_decided_invoke_hook ~= nil then
            install_live_on_decided_invoke_hook(delegate, gui)
        end
    end

    local function poll_character_select_guis()
        local guis = get_all_components("chainsaw.Cp1021CharacterSelectGuiBehavior")
        local seen = {}

        for _, gui in ipairs(guis) do
            if gui ~= nil then
                local addr_str = get_obj_address_str(gui)
                seen[addr_str] = true

                if not tracked_char_guis[addr_str] then
                    tracked_char_guis[addr_str] = { gui = gui, active = false, last_fp = "" }
                    log.info(string.format("[Merc AP Trace][CHAR_GUI_CREATED] obj=%s total_count=%d", addr_str, #guis))
                end

                local go = nil
                pcall(function() go = gui:call("get_GameObject") end)
                local is_act = false
                if go ~= nil then
                    local ok_act, act_val = pcall(function() return go:call("get_ActiveSelf") end)
                    if ok_act and act_val == true then is_act = true end
                end

                if is_act ~= tracked_char_guis[addr_str].active then
                    tracked_char_guis[addr_str].active = is_act
                    log.info(string.format("[Merc AP Trace][%s] obj=%s", is_act and "CHAR_GUI_ACTIVE" or "CHAR_GUI_INACTIVE", addr_str))
                end

                local step_field = get_safe_field_int(gui, "<CurrStep>k__BackingField", -1)
                local step_getter = get_safe_int(gui, "get_CurrStep", -1)
                local req_field = get_safe_field_int(gui, "<RequestedCharacter>k__BackingField", -1)
                local req_getter = get_safe_int(gui, "get_RequestedCharacter", -1)
                local curr_char = -1
                if step_field > 0 or step_getter > 0 then
                    curr_char = get_safe_int(gui, "get_CurrCharacter", -1)
                end
                local decided = get_safe_field_bool(gui, "_bDecided", false)
                local old_unlock = get_safe_field_bool(gui, "_bOldCharaUnlock", false)
                local sub = get_safe_field_int(gui, "_SelectedSubCharacter", -1)

                local open_param = nil
                pcall(function() open_param = gui:get_field("_OpenParam") end)
                local on_decided = nil
                if open_param ~= nil then
                    pcall(function() on_decided = open_param:get_field("OnDecided") end)
                    inspect_on_decided_delegate(open_param, addr_str, gui)
                end

                local ac_ctrl = nil
                pcall(function() ac_ctrl = gui:call("get_AcCtrl") end)

                local highlight_roster = -1
                if step_field > 0 or step_getter > 0 then
                    highlight_roster = resolve_highlighted_character_kind(gui)
                end
                local highlight_owned = is_character_owned(highlight_roster)

                local fp = string.format(
                    "%d|%d|%d|%d|%d|%s|%s|%d|%s|%s|%s|%d|%s",
                    step_field, step_getter, req_field, req_getter, curr_char,
                    tostring(decided), tostring(old_unlock), sub,
                    get_obj_address_str(open_param), get_obj_address_str(on_decided),
                    get_obj_address_str(ac_ctrl), highlight_roster, tostring(highlight_owned)
                )

                if fp ~= tracked_char_guis[addr_str].last_fp then
                    tracked_char_guis[addr_str].last_fp = fp
                    log.info(string.format(
                        "[Merc AP Trace][CHAR_STATE] t=%.3f obj=%s active=%s step_field=%d step_getter=%d req_field=%d req_getter=%d curr_char=%d decided=%s old_unlock=%s sub=%d highlight_roster=%d (%s) owned=%s open_param=%s on_decided=%s ac_ctrl=%s",
                        os.clock(), addr_str, tostring(is_act), step_field, step_getter, req_field, req_getter, curr_char,
                        tostring(decided), tostring(old_unlock), sub, highlight_roster,
                        ROSTER_INDEX_TO_NAME[highlight_roster] or "None", tostring(highlight_owned),
                        get_obj_address_str(open_param), get_obj_address_str(on_decided), get_obj_address_str(ac_ctrl)
                    ))
                end

                if ac_ctrl ~= nil then
                    local ac_addr = get_obj_address_str(ac_ctrl)
                    local rno = get_safe_field_int(ac_ctrl, "Rno", -1)
                    if rno == -1 then rno = get_safe_int(ac_ctrl, "get_Rno", -1) end
                    local next_val = get_safe_field_int(ac_ctrl, "Next", -1)
                    if next_val == -1 then next_val = get_safe_int(ac_ctrl, "get_Next", -1) end
                    local routine = get_safe_field_int(ac_ctrl, "RoutineType", -1)
                    if routine == -1 then routine = get_safe_int(ac_ctrl, "get_RoutineType", -1) end
                    local curr_ac = get_safe_field_int(ac_ctrl, "CurrAcKey", -1)
                    if curr_ac == -1 then curr_ac = get_safe_int(ac_ctrl, "get_CurrAcKey", -1) end

                    local ac_fp = string.format("%d|%d|%d|%d", rno, next_val, routine, curr_ac)
                    if not tracked_ac_ctrls[ac_addr] or tracked_ac_ctrls[ac_addr].last_fp ~= ac_fp then
                        tracked_ac_ctrls[ac_addr] = { last_fp = ac_fp }
                        log.info(string.format(
                            "[Merc AP Trace][AC_STATE] t=%.3f character_gui=%s ac_ctrl=%s rno=%d next=%d routine=%d curr_ac_key=%d",
                            os.clock(), addr_str, ac_addr, rno, next_val, routine, curr_ac
                        ))
                    end
                end
            end
        end

        for tracked_addr, info in pairs(tracked_char_guis) do
            if not seen[tracked_addr] then
                log.info(string.format("[Merc AP Trace][CHAR_GUI_DESTROYED] obj=%s", tracked_addr))
                emit_call_counts_summary("gui_destroyed")
                tracked_char_guis[tracked_addr] = nil
            end
        end
    end

    local function poll_controllers_and_parent()
        local ctrl = get_merc_controller()
        if ctrl ~= nil then
            local c_addr = get_obj_address_str(ctrl)
            local st = get_safe_field_int(ctrl, "_StageKind", -1)
            local ch = get_safe_field_int(ctrl, "_PlayerCharacterKind", -1)
            local co = get_safe_field_int(ctrl, "_PlayerCharacterCostumeId", 0)
            local rt = get_safe_field_int(ctrl, "_Routine", -1)
            local c_fp = string.format("%d|%d|%d|%d", st, ch, co, rt)

            if not tracked_controllers[c_addr] then
                tracked_controllers[c_addr] = { last_fp = c_fp }
                local key = string.format("%d:%d", ch, co)
                local entry = CHAR_COSTUME_TO_ROSTER[key]
                local roster_idx = entry and entry.index or ch
                local st_owned = is_stage_owned(st)
                local ch_owned = is_character_owned(roster_idx)
                log.info(string.format(
                    "[Merc AP Trace][MERC_CONTROLLER_CREATED] obj=%s stage=%d (%s, owned=%s) char=%d costume=%d roster=%d (%s, owned=%s) routine=%d t=%.3f",
                    c_addr, st, STAGE_KIND_NAMES[st] or "Unknown", tostring(st_owned),
                    ch, co, roster_idx, ROSTER_INDEX_TO_NAME[roster_idx] or "Unknown", tostring(ch_owned), rt, os.clock()
                ))
            elseif tracked_controllers[c_addr].last_fp ~= c_fp then
                tracked_controllers[c_addr].last_fp = c_fp
                log.info(string.format(
                    "[Merc AP Trace][MERC_CONTROLLER_STATE] obj=%s stage=%d char=%d costume=%d routine=%d t=%.3f",
                    c_addr, st, ch, co, rt, os.clock()
                ))
            end
        end

        local game_start_gui = find_first_component("chainsaw.Cp1021GameStartGuiBehavior")
        if game_start_gui ~= nil then
            local gs_addr = get_obj_address_str(game_start_gui)
            local gs_step = get_safe_field_int(game_start_gui, "<CurrStep>k__BackingField", -1)
            if gs_step == -1 then gs_step = get_safe_int(game_start_gui, "get_CurrStep", -1) end
            local gs_fp = string.format("%d", gs_step)
            if not tracked_controllers[gs_addr] or tracked_controllers[gs_addr].last_fp ~= gs_fp then
                tracked_controllers[gs_addr] = { last_fp = gs_fp }
                log.info(string.format(
                    "[Merc AP Trace][PARENT_COMMIT] Cp1021GameStartGuiBehavior obj=%s step=%d t=%.3f",
                    gs_addr, gs_step, os.clock()
                ))
            end
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

        -- 2. Forensic state-machine polling
        poll_character_select_guis()
        poll_controllers_and_parent()

        -- 3. Observe MercenariesManager.get_IsResult() boundary
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

        -- 4. Poll payload if inside result pipeline
        if merc_state.lifecycle == STATE_RESULT_PIPELINE then
            poll_result_pipeline()
        end
    end
    export("update_mercenaries_state", update_mercenaries_state)

    -- Virtual Selection Gating (Unified Multi-Tier Architecture & Forensic Tracing)
    local hooks_installed = false

    local function install_merc_virtual_gating_hooks()
        if hooks_installed then return end

        local function get_obj_type_name(obj)
            if obj == nil then return "" end
            local ok, td = pcall(function() return obj:get_type_definition() end)
            if ok and td ~= nil then
                local ok_n, name = pcall(function() return td:get_full_name() end)
                if ok_n and type(name) == "string" then
                    return name
                end
            end
            return ""
        end

        local hooked_functions = {}
        local function safe_hook_unique(method, pre, post)
            if method == nil then return false end
            local func_ptr = nil
            pcall(function() func_ptr = method:get_function() end)
            local key = tostring(func_ptr or method)
            if hooked_functions[key] then return true end

            local ok = pcall(function()
                sdk.hook(method, pre, post)
            end)
            if ok then
                hooked_functions[key] = true
                return true
            end
            return false
        end

        local function trace_safe_string(value)
            local ok, result = pcall(function() return tostring(value) end)
            if not ok or result == nil then return "<unavailable>" end
            result = tostring(result):gsub("[%c]", "?")
            if #result > 160 then
                return result:sub(1, 157) .. "..."
            end
            return result
        end

        local function trace_raw_string(value)
            local ok, result = pcall(function() return tostring(value) end)
            if not ok or result == nil then return "<unavailable>" end
            return tostring(result):gsub("[%c]", "?")
        end

        local function trace_numeric_value(value)
            if value == nil then return "nil" end
            local converted = nil
            local ok = pcall(function() converted = sdk.to_int64(value) end)
            if ok and converted ~= nil then
                return trace_safe_string(converted)
            end
            return "nil"
        end

        local function trace_pointer_value(value)
            if value == nil then return "nil" end
            local address = nil
            local ok = pcall(function() address = value:get_address() end)
            if ok and address ~= nil then
                return trace_safe_string(address)
            end
            return trace_safe_string(value)
        end

        local function safe_array_value(array, index)
            if array == nil then return nil end
            local value = nil
            pcall(function() value = array[index] end)
            return value
        end

        local function trace_typed_value(raw, param)
            if param == nil then return "type=<unreflected>" end
            local type_name = tostring(param.type_name or ""):lower()
            local typed = {}

            if type_name:find("single", 1, true) or type_name:find("float", 1, true) then
                if type(sdk.to_float) == "function" then
                    local value = nil
                    local ok = pcall(function() value = sdk.to_float(raw) end)
                    if ok and value ~= nil then typed[#typed + 1] = "float=" .. trace_safe_string(value) end
                end
            elseif type_name:find("double", 1, true) then
                if type(sdk.to_double) == "function" then
                    local value = nil
                    local ok = pcall(function() value = sdk.to_double(raw) end)
                    if ok and value ~= nil then typed[#typed + 1] = "double=" .. trace_safe_string(value) end
                end
            elseif type_name:find("class", 1, true)
                or type_name:find("object", 1, true)
                or type_name:find("interface", 1, true)
                or type_name:find("string", 1, true) then
                if type(sdk.to_managed_object) == "function" then
                    local value = nil
                    local ok = pcall(function() value = sdk.to_managed_object(raw) end)
                    if ok and value ~= nil then typed[#typed + 1] = "managed=" .. trace_pointer_value(value) end
                end
            elseif type_name:find("valuetype", 1, true)
                or type_name:find("struct", 1, true) then
                if type(sdk.to_valuetype) == "function" then
                    local value = nil
                    local ok = pcall(function() value = sdk.to_valuetype(raw, param.type_name) end)
                    if ok and value ~= nil then typed[#typed + 1] = "valuetype=" .. trace_safe_string(value) end
                end
            end

            return #typed > 0 and table.concat(typed, ",") or "typed=nil"
        end

        local function trace_enum_symbol(raw, param)
            if param == nil or param.type_obj == nil then return "enum=unknown" end

            local numeric = trace_numeric_value(raw)
            if numeric == "nil" then return "enum=unknown" end
            local fields = nil
            local ok_fields = pcall(function() fields = param.type_obj:get_fields() end)
            if not ok_fields or fields == nil then return "enum=unknown" end

            for _, field in ipairs(fields) do
                local is_static = false
                local ok_static = pcall(function() is_static = field:is_static() end)
                if ok_static and (is_static == true or is_static == 1) then
                    local field_value = nil
                    local field_name = nil
                    local ok_value = pcall(function() field_value = field:get_data(nil) end)
                    pcall(function() field_name = field:get_name() end)
                    if ok_value and field_name ~= nil and trace_numeric_value(field_value) == numeric then
                        return "enum=" .. trace_safe_string(field_name)
                    end
                end
            end
            return "enum=unknown"
        end

        local function capture_input_args(args, metadata)
            local captured = {}
            local param_count = metadata and metadata.param_count or 0
            local param_offset = metadata and metadata.param_offset or 3
            local params = metadata and metadata.params or {}
            for param_index = 0, param_count - 1 do
                local arg_index = param_offset + param_index
                local raw = args[arg_index]
                local param = params[param_index + 1]
                captured[#captured + 1] = string.format(
                    "%d:param=%d,name=%s,type=%s,raw=%s,num=%s,ptr=%s,%s,%s",
                    arg_index,
                    param_index,
                    param and trace_safe_string(param.name) or "<unreflected>",
                    param and trace_safe_string(param.type_name) or "<unreflected>",
                    trace_raw_string(raw),
                    trace_numeric_value(raw),
                    trace_pointer_value(raw),
                    trace_typed_value(raw, param),
                    trace_enum_symbol(raw, param)
                )
            end
            return table.concat(captured, ";")
        end

        local function trace_type_name(type_obj)
            if type_obj == nil then return "<unavailable>" end
            local full_name = nil
            local ok = pcall(function() full_name = type_obj:get_full_name() end)
            if ok and type(full_name) == "string" and full_name ~= "" then
                return full_name
            end
            local short_name = nil
            ok = pcall(function() short_name = type_obj:get_name() end)
            if ok and type(short_name) == "string" and short_name ~= "" then
                return short_name
            end
            return trace_safe_string(type_obj)
        end

        local function probe_input_method(method)
            local name = "<unavailable>"
            pcall(function() name = method:get_name() end)

            local param_count = "<unavailable>"
            local numeric_count = nil
            local ok_count = pcall(function() numeric_count = method:get_num_params() end)
            if ok_count and type(numeric_count) == "number" then
                param_count = tostring(numeric_count)
            end

            local return_type = nil
            pcall(function() return_type = method:get_return_type() end)
            local function_address = nil
            local function_ok = pcall(function() function_address = method:get_function() end)
            local native_address = "<unavailable>"
            if function_ok and function_address ~= nil then
                native_address = trace_numeric_value(function_address)
                if native_address == "nil" then
                    native_address = trace_pointer_value(function_address)
                end
            end

            local param_names = nil
            local param_types = nil
            local names_ok = pcall(function() param_names = method:get_param_names() end)
            local types_ok = pcall(function() param_types = method:get_param_types() end)
            local params = {}
            if type(numeric_count) == "number" then
                for index = 1, numeric_count do
                    local param_name = names_ok and safe_array_value(param_names, index) or nil
                    local param_type = types_ok and safe_array_value(param_types, index) or nil
                    params[#params + 1] = {
                        index = index - 1,
                        arg_index = index + 2,
                        name = param_name ~= nil and trace_safe_string(param_name) or "<name-unavailable>",
                        type_name = param_type ~= nil and trace_type_name(param_type) or "<type-unavailable>",
                        type_obj = param_type,
                    }
                end
            end

            return {
                declaring_type = "chainsaw.Cp1021CharacterSelectGuiBehavior",
                name = name,
                param_count = numeric_count,
                param_count_text = param_count,
                param_offset = 3,
                return_type = trace_type_name(return_type),
                native_address = native_address,
                params = params,
            }
        end

        local function same_gui(left, right)
            if left == nil or right == nil then return false end
            if left == right then return true end
            local left_address = get_obj_address_str(left)
            local right_address = get_obj_address_str(right)
            return left_address ~= "nil" and left_address == right_address
        end

        local function get_decision_state(gui)
            local requested = get_safe_field_int(gui, "<RequestedCharacter>k__BackingField", -1)
            if requested == -1 then
                requested = get_safe_int(gui, "get_RequestedCharacter", -1)
            end

            local step = get_safe_field_int(gui, "<CurrStep>k__BackingField", -1)
            if step == -1 then
                step = get_safe_int(gui, "get_CurrStep", -1)
            end

            local roster = action_type_to_roster_index(requested, gui)
            local highlight = resolve_highlighted_character_kind(gui)
            return {
                gui = gui,
                gui_address = get_obj_address_str(gui),
                requested = requested,
                roster = roster,
                roster_name = ROSTER_INDEX_TO_NAME[roster] or "None",
                owned = is_character_owned(roster),
                highlight = highlight,
                highlight_name = ROSTER_INDEX_TO_NAME[highlight] or "None",
                highlight_owned = is_character_owned(highlight),
                decided = get_safe_field_bool(gui, "_bDecided", nil),
                curr_step = step,
                old_unlock = get_safe_field_bool(gui, "_bOldCharaUnlock", false),
                selected_sub = get_safe_field_int(gui, "_SelectedSubCharacter", -1),
            }
        end

        local function find_active_epoch(gui, epoch_stack)
            for index = #epoch_stack, 1, -1 do
                local epoch = epoch_stack[index]
                if same_gui(epoch.gui, gui) then
                    return epoch
                end
            end
            return nil
        end

        local function epoch_is_active(epoch, epoch_stack)
            for index = #epoch_stack, 1, -1 do
                if epoch_stack[index] == epoch then return true end
            end
            return false
        end

        local function dump_decision_epoch(epoch, post_state)
            log.info(string.format(
                "[Merc AP Trace][DECISION_EPOCH] gui=%s requested_before=%d roster_before=%d(%s) owned_before=%s requested_after=%d roster_after=%d(%s) owned_after=%s decided_before=%s decided_after=%s step_before=%d step_after=%d highlight_after=%d(%s) highlight_owned=%s old_unlock_after=%s selected_sub_after=%d input_calls=%d t=%.3f",
                epoch.gui_address, epoch.requested, epoch.roster, epoch.roster_name, tostring(epoch.owned),
                post_state.requested, post_state.roster, post_state.roster_name, tostring(post_state.owned),
                tostring(epoch.decided_before), tostring(post_state.decided), epoch.curr_step, post_state.curr_step,
                post_state.highlight, post_state.highlight_name, tostring(post_state.highlight_owned),
                tostring(post_state.old_unlock), post_state.selected_sub, #epoch.input_calls, epoch.timestamp
            ))
            for index, input_call in ipairs(epoch.input_calls) do
                log.info(string.format(
                    "[Merc AP Trace][DECISION_INPUT] gui=%s call=%d param_count=%s param_offset=%d signatures=%s return_type=%s pre_t=%.3f args=%s post_raw=%s post_num=%s post_typed=%s",
                    epoch.gui_address, index, tostring(input_call.param_count), input_call.param_offset,
                    input_call.signatures, input_call.return_type, input_call.timestamp, input_call.args,
                    input_call.post_raw, input_call.post_num, input_call.post_typed
                ))
            end
        end

        -- ==================================================================
        -- 1. UNIFIED isUnlock HOOKS (Visual Presentation & Native Locks)
        -- ==================================================================
        local last_is_unlock_query = nil
        local logged_gui_is_unlock = {}
        local function on_is_unlock_pre(args)
            local this_obj = sdk.to_managed_object(args[2])
            local raw_arg = -1
            if args[3] ~= nil then
                local parsed = sdk.to_int64(args[3])
                if parsed ~= nil then raw_arg = tonumber(parsed) end
            end
            last_is_unlock_query = { this = this_obj, arg = raw_arg }
        end

        local function on_is_unlock_post(retval)
            local query = last_is_unlock_query
            last_is_unlock_query = nil
            if query == nil or not should_enforce_gating() or query.this == nil then
                return retval
            end

            local type_name = get_obj_type_name(query.this)

            local function trace_gui_is_unlock(kind, owned)
                local key = string.format("%s:%d:%d", type_name, query.arg, kind)
                if not logged_gui_is_unlock[key] then
                    logged_gui_is_unlock[key] = true
                    log.info(string.format(
                        "[Merc AP Trace][IS_UNLOCK] type=%s raw=%d kind=%d owned=%s",
                        type_name, query.arg, kind, tostring(owned)
                    ))
                end
            end

            if type_name == "chainsaw.Cp1021UnlockSettingsUserData.CharacterSetting" then
                local kind = get_safe_field_int(query.this, "KindId", -1)
                if kind < 0 then
                    kind = get_safe_int(query.this, "get_KindId", -1)
                end
                if kind >= 0 and kind <= 7 then
                    local owned = is_character_owned(kind)
                    return sdk.to_ptr(owned and 1 or 0)
                end
            elseif type_name == "chainsaw.Cp1021UnlockSettingsUserData.StageSetting" then
                local kind = get_safe_field_int(query.this, "KindId", -1)
                if kind < 0 then
                    kind = get_safe_int(query.this, "get_KindId", -1)
                end
                if kind >= 0 and kind <= 3 then
                    local owned = is_stage_owned(kind)
                    return sdk.to_ptr(owned and 1 or 0)
                end
            elseif type_name == "chainsaw.Cp1021CharacterSelectGuiBehavior" then
                if query.arg >= 0 then
                    local ok_kind, kind = pcall(function()
                        return query.this:call("getCharacterKind", query.arg)
                    end)
                    if ok_kind and type(kind) == "number" and kind >= 0 and kind <= 7 then
                        local owned = is_character_owned(kind)
                        trace_gui_is_unlock(kind, owned)
                        return sdk.to_ptr(owned and 1 or 0)
                    end
                end
            elseif type_name == "chainsaw.Cp1021StageSelectGuiBehavior" then
                if query.arg >= 0 then
                    local ok_kind, kind = pcall(function()
                        return query.this:call("getKindId", query.arg)
                    end)
                    if ok_kind and type(kind) == "number" and kind >= 0 and kind <= 3 then
                        local owned = is_stage_owned(kind)
                        trace_gui_is_unlock(kind, owned)
                        return sdk.to_ptr(owned and 1 or 0)
                    end
                end
            end

            return retval
        end

        local is_unlock_types = {
            "chainsaw.Cp1021UnlockSettingsUserData.StageSetting",
            "chainsaw.Cp1021UnlockSettingsUserData.CharacterSetting",
            "chainsaw.Cp1021StageSelectGuiBehavior",
            "chainsaw.Cp1021CharacterSelectGuiBehavior",
        }
        for _, tname in ipairs(is_unlock_types) do
            local td = sdk.find_type_definition(tname)
            if td ~= nil then
                for _, method in ipairs(td:get_methods() or {}) do
                    if method:get_name() == "isUnlock" then
                        safe_hook_unique(method, on_is_unlock_pre, on_is_unlock_post)
                    end
                end
            end
        end

        -- ==================================================================
        -- 2. FORENSIC HOOKS ON CharacterSelectGuiBehavior CANDIDATE METHODS
        -- ==================================================================
        local char_td = sdk.find_type_definition("chainsaw.Cp1021CharacterSelectGuiBehavior")
        if char_td ~= nil then
            local function startup_method_metadata(method_name)
                local method = nil
                pcall(function() method = char_td:get_method(method_name) end)
                if method == nil then
                    return "method=" .. method_name .. " native=unavailable static=unavailable return=unavailable params=unavailable"
                end

                local probe = probe_input_method(method)
                local static_value = nil
                local static_ok = pcall(function() static_value = method:is_static() end)
                local static_text = "unavailable"
                if static_ok and type(static_value) == "boolean" then
                    static_text = tostring(static_value)
                elseif static_ok and type(static_value) == "number" then
                    static_text = tostring(static_value ~= 0)
                end

                local params = {}
                for _, param in ipairs(probe.params) do
                    params[#params + 1] = string.format(
                        "%s:%s",
                        trace_safe_string(param.name),
                        trace_safe_string(param.type_name)
                    )
                end
                local params_text = "unavailable"
                if probe.param_count ~= nil then
                    params_text = table.concat(params, ";")
                end
                return string.format(
                    "method=%s native=%s static=%s return=%s params=[%s]",
                    method_name, probe.native_address, static_text, probe.return_type, params_text
                )
            end

            local function startup_field_offset(field_name)
                local field = nil
                local field_ok = pcall(function() field = char_td:get_field(field_name) end)
                if not field_ok or field == nil then return field_name .. "=unavailable" end
                local offset = nil
                local offset_ok = pcall(function() offset = field:get_offset_from_base() end)
                if not offset_ok or offset == nil then return field_name .. "=unavailable" end
                return field_name .. "=" .. trace_safe_string(offset)
            end

            log.info(string.format(
                "[Merc AP Trace][LATE_METADATA] type=chainsaw.Cp1021CharacterSelectGuiBehavior %s %s fields=[%s;%s;%s;%s]",
                startup_method_metadata("lateUpdateOnActive"),
                startup_method_metadata("getCharacterKind"),
                startup_field_offset("_bDecided"),
                startup_field_offset("<RequestedCharacter>k__BackingField"),
                startup_field_offset("_bOldCharaUnlock"),
                startup_field_offset("_OpenParam")
            ))

            local live_delegate_diagnostics = {}
            local live_delegate_native_hooks = {}

            local function live_delegate_generic_args(type_definition, full_name)
                local generic_args = nil
                local args_ok = pcall(function() generic_args = type_definition:get_generic_argument_types() end)
                if args_ok and generic_args ~= nil then
                    local names = {}
                    for _, arg_type in ipairs(generic_args) do
                        names[#names + 1] = trace_type_name(arg_type)
                    end
                    if #names > 0 then return table.concat(names, ",") end
                end
                local angle_start = type(full_name) == "string" and full_name:find("<", 1, true) or nil
                local angle_end = type(full_name) == "string" and full_name:match(".*()>") or nil
                if angle_start ~= nil and angle_end ~= nil and angle_end > angle_start then
                    return full_name:sub(angle_start + 1, angle_end - 1)
                end
                return "unavailable"
            end

            local function live_delegate_method_metadata(delegate_type, full_name, method)
                local method_name = "<unavailable>"
                pcall(function() method_name = method:get_name() end)
                local static_value = nil
                local static_ok = pcall(function() static_value = method:is_static() end)
                local param_count = nil
                local count_ok = pcall(function() param_count = method:get_num_params() end)
                local return_type = nil
                local return_ok = pcall(function() return_type = method:get_return_type() end)
                local param_types = nil
                local types_ok = pcall(function() param_types = method:get_param_types() end)
                local param_names = nil
                local names_ok = pcall(function() param_names = method:get_param_names() end)
                local function_address = nil
                local function_ok = pcall(function() function_address = method:get_function() end)
                local native_address = "unavailable"
                if function_ok and function_address ~= nil then
                    native_address = trace_numeric_value(function_address)
                    if native_address == "nil" then native_address = trace_pointer_value(function_address) end
                end

                local params = {}
                if count_ok and type(param_count) == "number" then
                    for index = 1, param_count do
                        params[#params + 1] = string.format(
                            "index=%d,name=%s,type=%s",
                            index - 1,
                            names_ok and trace_safe_string(safe_array_value(param_names, index)) or "unavailable",
                            types_ok and trace_type_name(safe_array_value(param_types, index)) or "unavailable"
                        )
                    end
                end
                return {
                    method = method,
                    name = method_name,
                    static = static_ok and static_value or nil,
                    static_text = static_ok and trace_safe_string(static_value) or "unavailable",
                    param_count = count_ok and param_count or nil,
                    params = table.concat(params, ";"),
                    return_type = return_ok and trace_type_name(return_type) or "unavailable",
                    native_address = native_address,
                    param_type = types_ok and safe_array_value(param_types, 1) or nil,
                    declaring_type = full_name,
                    generic_args = live_delegate_generic_args(delegate_type, full_name),
                }
            end

            local function live_delegate_invoke_metadata(delegate)
                local delegate_type = nil
                local type_ok = pcall(function() delegate_type = delegate:get_type_definition() end)
                if not type_ok or delegate_type == nil then return nil, "type unavailable" end
                local full_name = nil
                local full_ok = pcall(function() full_name = delegate_type:get_full_name() end)
                if not full_ok or type(full_name) ~= "string" or full_name == "" then full_name = "<unavailable>" end
                local methods = nil
                local methods_ok = pcall(function() methods = delegate_type:get_methods() end)
                if not methods_ok or methods == nil then
                    return { full_name = full_name, generic_args = "unavailable" }, "methods unavailable"
                end
                local invoke_methods = {}
                for _, method in ipairs(methods) do
                    local method_name = nil
                    pcall(function() method_name = method:get_name() end)
                    if method_name == "Invoke" then
                        invoke_methods[#invoke_methods + 1] = live_delegate_method_metadata(delegate_type, full_name, method)
                    end
                end
                local metadata = {
                    delegate_type = delegate_type,
                    full_name = full_name,
                    generic_args = live_delegate_generic_args(delegate_type, full_name),
                    invokes = invoke_methods,
                }
                if #invoke_methods == 1 then metadata.invoke = invoke_methods[1] end
                if #invoke_methods == 0 then return metadata, "Invoke unavailable" end
                if #invoke_methods > 1 then return metadata, "Invoke ambiguous" end
                return metadata, nil
            end

            local function live_pointer_key(value)
                if value == nil then return nil end
                local key = trace_numeric_value(value)
                if key == "nil" then key = trace_pointer_value(value) end
                if key == "nil" or key == "0" then return nil end
                return key
            end

            local function live_read_dword(offset, object)
                local value = nil
                local ok = pcall(function() value = object:read_dword(offset) end)
                return value, ok and value ~= nil
            end

            local function live_read_qword(offset, object)
                local value = nil
                local ok = pcall(function() value = object:read_qword(offset) end)
                return value, ok and value ~= nil
            end

            dump_live_on_decided_internals = function(delegate, delegate_id)
                local field_parts = {}
                local delegate_type = nil
                pcall(function() delegate_type = delegate:get_type_definition() end)
                local seen_types = {}
                local current_type = delegate_type
                while current_type ~= nil do
                    local declaring_type = trace_type_name(current_type)
                    local type_key = declaring_type ~= "<unavailable>" and declaring_type or get_obj_address_str(current_type)
                    if seen_types[type_key] then break end
                    seen_types[type_key] = true
                    local fields = nil
                    local fields_ok = pcall(function() fields = current_type:get_fields() end)
                    if fields_ok and fields ~= nil then
                        for _, field in ipairs(fields) do
                            local is_static = nil
                            local static_ok = pcall(function() is_static = field:is_static() end)
                            if static_ok and is_static == false then
                                local field_name = "<unavailable>"
                                pcall(function() field_name = field:get_name() end)
                                local field_type = nil
                                pcall(function() field_type = field:get_type() end)
                                local offset = nil
                                pcall(function() offset = field:get_offset_from_base() end)
                                local value = nil
                                pcall(function() value = field:get_data(delegate) end)
                                local managed = nil
                                if type(sdk.to_managed_object) == "function" then
                                    pcall(function() managed = sdk.to_managed_object(value) end)
                                end
                                local managed_text = "unavailable"
                                if managed ~= nil then
                                    managed_text = get_obj_address_str(managed) .. "/" .. (get_obj_type_name(managed) ~= "" and get_obj_type_name(managed) or "unavailable")
                                end
                                field_parts[#field_parts + 1] = string.format(
                                    "%s.%s:type=%s,offset=%s,raw=%s,num=%s,ptr=%s,managed=%s",
                                    declaring_type, field_name, trace_type_name(field_type),
                                    offset ~= nil and trace_safe_string(offset) or "unavailable",
                                    trace_raw_string(value), trace_numeric_value(value), trace_pointer_value(value), managed_text
                                )
                            end
                        end
                    end
                    local parent = nil
                    local parent_ok = pcall(function() parent = current_type:get_parent_type() end)
                    if not parent_ok then break end
                    current_type = parent
                end
                log.info(string.format(
                    "[Merc AP Trace][CHAR_ON_DECIDED_INTERNALS] delegate=%s fields=[%s]",
                    delegate_id, #field_parts > 0 and table.concat(field_parts, ";") or "unavailable"
                ))

                local count, count_ok = live_read_dword(0x10, delegate)
                count = count_ok and tonumber(count) or nil
                if count == nil or count < 0 or count > 16 then
                    log.info(string.format("[Merc AP Trace][CHAR_ON_DECIDED_METHODPTR] delegate=%s unavailable=invocation_count value=%s", delegate_id, trace_safe_string(count)))
                    return
                end
                for index = 0, count - 1 do
                    local record_offset = 0x18 + index * 0x18
                    local target, target_ok = live_read_qword(record_offset, delegate)
                    local method_ptr, method_ok = live_read_qword(record_offset + 8, delegate)
                    local target_key = target_ok and live_pointer_key(target) or nil
                    local method_key = method_ok and live_pointer_key(method_ptr) or nil
                    log.info(string.format(
                        "[Merc AP Trace][CHAR_ON_DECIDED_METHODPTR] delegate=%s entry=%d target=%s method_ptr=%s invocation_count=%d",
                        delegate_id, index, target_ok and trace_safe_string(target) or "unavailable",
                        method_ok and trace_safe_string(method_ptr) or "unavailable", count
                    ))
                    if target_key ~= nil then
                        local target_obj = nil
                        if type(sdk.to_ptr) == "function" and type(sdk.to_managed_object) == "function" then
                            pcall(function() target_obj = sdk.to_managed_object(sdk.to_ptr(target)) end)
                        end
                        local target_type = nil
                        if target_obj ~= nil then pcall(function() target_type = target_obj:get_type_definition() end) end
                        local target_type_name = target_obj and get_obj_type_name(target_obj) or "unavailable"
                        log.info(string.format(
                            "[Merc AP Trace][CHAR_ON_DECIDED_TARGET] delegate=%s entry=%d target=%s type=%s",
                            delegate_id, index, target_obj and get_obj_address_str(target_obj) or target_key, target_type_name
                        ))
                        local matched = false
                        local current_target_type = target_type
                        local seen_target_types = {}
                        while current_target_type ~= nil do
                            local declaring_type = trace_type_name(current_target_type)
                            local type_key = declaring_type ~= "<unavailable>" and declaring_type or get_obj_address_str(current_target_type)
                            if seen_target_types[type_key] then break end
                            seen_target_types[type_key] = true
                            local methods = nil
                            local methods_ok = pcall(function() methods = current_target_type:get_methods() end)
                            if methods_ok and methods ~= nil then
                                for _, method in ipairs(methods) do
                                    local function_address = nil
                                    local function_ok = pcall(function() function_address = method:get_function() end)
                                    if function_ok and method_key ~= nil and live_pointer_key(function_address) == method_key then
                                        local metadata = live_delegate_method_metadata(current_target_type, declaring_type, method)
                                        log.info(string.format(
                                            "[Merc AP Trace][CHAR_ON_DECIDED_METHOD_MATCH] target=%s declaring=%s method=%s params=[%s] return=%s native=%s",
                                            target_key, declaring_type, metadata.name, metadata.params, metadata.return_type, metadata.native_address
                                        ))
                                        matched = true
                                    end
                                end
                            end
                            local parent = nil
                            local parent_ok = pcall(function() parent = current_target_type:get_parent_type() end)
                            if not parent_ok then break end
                            current_target_type = parent
                        end
                        if not matched then
                            log.info(string.format(
                                "[Merc AP Trace][CHAR_ON_DECIDED_METHOD_MATCH] delegate=%s entry=%d target=%s method_ptr=%s unmatched=true",
                                delegate_id, index, target_key, method_key or "unavailable"
                            ))
                        end
                    end
                end
            end

            install_live_on_decided_invoke_hook = function(delegate)
                local metadata, metadata_error = live_delegate_invoke_metadata(delegate)
                if metadata == nil then
                    local unavailable_key = get_obj_address_str(delegate)
                    if not live_delegate_diagnostics[unavailable_key] then
                        live_delegate_diagnostics[unavailable_key] = true
                        log.info("[Merc AP Trace][CHAR_ON_DECIDED_REFLECT] type=unavailable generic_args=unavailable Invoke=unavailable status=type unavailable")
                    end
                    return
                end
                local diagnostic_key = metadata.full_name or get_obj_address_str(delegate)
                if live_delegate_diagnostics[diagnostic_key] then return end
                live_delegate_diagnostics[diagnostic_key] = true

                local invoke = metadata.invoke
                local mismatch = metadata_error
                if mismatch == nil and invoke ~= nil then
                    if invoke.static ~= false then
                        mismatch = invoke.static == nil and "static unavailable" or "Invoke static"
                    elseif invoke.param_count ~= 1 then
                        mismatch = invoke.param_count == nil and "parameter count unavailable" or "parameter count mismatch"
                    elseif invoke.param_type == nil then
                        mismatch = "parameter type unavailable"
                    elseif trace_type_name(invoke.param_type) ~= "chainsaw.Cp1021CharacterSelectMenuActionType" then
                        mismatch = "parameter type mismatch"
                    elseif invoke.return_type ~= "System.Void" then
                        mismatch = invoke.return_type == "unavailable" and "return type unavailable" or "return type mismatch"
                    end
                end

                local invoke_text = "unavailable"
                if invoke ~= nil then
                    invoke_text = string.format(
                        "native=%s static=%s return=%s params=%s",
                        invoke.native_address, invoke.static_text, invoke.return_type,
                        invoke.params ~= "" and ("[" .. invoke.params .. "]") or "[]"
                    )
                end
                log.info(string.format(
                    "[Merc AP Trace][CHAR_ON_DECIDED_REFLECT] type=%s generic_args=%s %s status=%s",
                    metadata.full_name or "unavailable", metadata.generic_args or "unavailable",
                    invoke_text, mismatch == nil and "valid" or mismatch
                ))
                if mismatch ~= nil or invoke == nil or invoke.native_address == "unavailable" then return end
                if live_delegate_native_hooks[invoke.native_address] then return end

                local delegate_type_name = metadata.full_name
                local function on_live_invoke_pre(args)
                    local invoke_this = nil
                    local action = nil
                    pcall(function() invoke_this = sdk.to_managed_object(args[2]) end)
                    pcall(function()
                        local value = sdk.to_int64(args[3])
                        if value ~= nil then action = tonumber(value) end
                    end)
                    if invoke_this == nil or type(action) ~= "number" then return end

                    local matches = {}
                    local invoke_address = get_obj_address_str(invoke_this)
                    for _, info in pairs(tracked_char_guis) do
                        if info.active == true and info.gui ~= nil then
                            local open_param = nil
                            local live_delegate = nil
                            pcall(function() open_param = info.gui:get_field("_OpenParam") end)
                            if open_param ~= nil then
                                pcall(function() live_delegate = open_param:get_field("OnDecided") end)
                            end
                            if live_delegate ~= nil and get_obj_address_str(live_delegate) == invoke_address then
                                matches[#matches + 1] = info.gui
                            end
                        end
                    end
                    if #matches ~= 1 then return end

                    local gui = matches[1]
                    if action < 0 or action ~= math.floor(action) then
                        log.info(string.format("[Merc AP Trace][CHAR_ON_DECIDED_PRE] invalid_action delegate=%s gui=%s action=%s type=%s", invoke_address, get_obj_address_str(gui), tostring(action), delegate_type_name))
                        return
                    end
                    local ok_kind, roster = pcall(function() return gui:call("getCharacterKind", action) end)
                    local requested = get_safe_field_int(gui, "<RequestedCharacter>k__BackingField", -1)
                    if requested == -1 then requested = get_safe_int(gui, "get_RequestedCharacter", -1) end
                    if not ok_kind or type(roster) ~= "number" or roster < 0 or roster > 7 then
                        log.info(string.format("[Merc AP Trace][CHAR_ON_DECIDED_PRE] invalid_roster delegate=%s gui=%s action=%d roster=%s type=%s", invoke_address, get_obj_address_str(gui), action, tostring(roster), delegate_type_name))
                        return
                    end
                    if requested ~= action then
                        log.info(string.format("[Merc AP Trace][CHAR_ON_DECIDED_PRE] requested_mismatch delegate=%s gui=%s action=%d requested=%d type=%s", invoke_address, get_obj_address_str(gui), action, requested, delegate_type_name))
                        return
                    end
                    log.info(string.format(
                        "[Merc AP Trace][CHAR_ON_DECIDED_PRE] delegate=%s gui=%s action=%d requested=%d roster=%d owned=%s decided=%s old_unlock=%s type=%s",
                        invoke_address, get_obj_address_str(gui), action, requested, roster,
                        tostring(is_character_owned(roster)), tostring(get_safe_field_bool(gui, "_bDecided", false)),
                        tostring(get_safe_field_bool(gui, "_bOldCharaUnlock", false)), delegate_type_name
                    ))
                end

                local ok_hook = safe_hook_unique(invoke.method, on_live_invoke_pre, function(retval)
                    return retval
                end)
                if ok_hook then live_delegate_native_hooks[invoke.native_address] = true end
            end

            local input_method_groups = {}
            local input_group_order = {}
            local all_char_methods = {}
            pcall(function() all_char_methods = char_td:get_methods() or {} end)
            for _, method in ipairs(all_char_methods) do
                local method_name = nil
                pcall(function() method_name = method:get_name() end)
                if method_name == "onInputCheckEvent" then
                    local probe = probe_input_method(method)
                    local native_key = probe.native_address
                    if native_key == "nil" or native_key == "<unavailable>" then
                        native_key = "method:" .. tostring(method)
                    else
                        native_key = "native:" .. native_key
                    end
                    local group = input_method_groups[native_key]
                    if group == nil then
                        group = {
                            native_key = native_key,
                            native_address = probe.native_address,
                            representative = method,
                            signatures = {},
                        }
                        input_method_groups[native_key] = group
                        input_group_order[#input_group_order + 1] = group
                    end
                    group.signatures[#group.signatures + 1] = probe
                end
            end

            for _, group in ipairs(input_group_order) do
                local signature_names = {}
                local shared_native = group.native_address ~= "nil"
                    and group.native_address ~= "<unavailable>"
                    and #group.signatures > 1
                for _, probe in ipairs(group.signatures) do
                    local params = {}
                    for _, param in ipairs(probe.params) do
                        params[#params + 1] = string.format(
                            "index=%d,arg=%d,name=%s,type=%s",
                            param.index, param.arg_index, param.name, param.type_name
                        )
                    end
                    signature_names[#signature_names + 1] = string.format(
                        "%s/%s",
                        probe.name,
                        probe.param_count_text
                    )
                    log.info(string.format(
                        "[Merc AP Trace][INPUT_REFLECT] declaring=%s method=%s return_type=%s param_count=%s param_offset=%d function_address=%s params=[%s] aliases_share_native=%s",
                        probe.declaring_type, probe.name, probe.return_type, probe.param_count_text,
                        probe.param_offset, probe.native_address, table.concat(params, ";"), tostring(shared_native)
                    ))
                end
                group.signature_summary = table.concat(signature_names, ",")
                group.primary = group.signatures[1]
                group.param_count = group.primary and group.primary.param_count or nil
                group.param_offset = group.primary and group.primary.param_offset or 3
            end

            local candidate_methods = {
                "onInputCheckEvent",
                "onSelectionChanged",
                "changeStep",
                "set_RequestedCharacter",
                "set_CurrStep",
                "lateUpdateOnActive",
                "selectCostume",
                "openCostumeSelectList",
                "closeCostumeSelectList",
                "getCharacterKind",
                "setCharacterInfo",
                "onDeactivateEvent",
                "recieveGuiParam",
            }

            local input_context_stack = {}
            local late_update_epoch_stack = {}
            for _, mname in ipairs(candidate_methods) do
                local m = char_td:get_method(mname)
                if m ~= nil or (mname == "onInputCheckEvent" and #input_group_order > 0) then
                    local ok_h = false
                    if mname == "onInputCheckEvent" then
                        for _, input_group in ipairs(input_group_order) do
                            local function grouped_input_pre(args)
                                record_call("onInputCheckEvent")
                                local this_obj = nil
                                pcall(function() this_obj = sdk.to_managed_object(args[2]) end)
                                local epoch = find_active_epoch(this_obj, late_update_epoch_stack)
                                local frame = {
                                    this_obj = this_obj,
                                    epoch = epoch,
                                    input_call = nil,
                                }
                                if epoch ~= nil then
                                    frame.input_call = {
                                        timestamp = os.clock(),
                                        args = capture_input_args(args, input_group.primary),
                                        post_raw = "<not-returned>",
                                        post_num = "<not-returned>",
                                        param_count = input_group.param_count,
                                        param_offset = input_group.param_offset,
                                        signatures = input_group.signature_summary,
                                        return_type = input_group.primary.return_type,
                                        post_typed = "<not-returned>",
                                    }
                                    epoch.input_calls[#epoch.input_calls + 1] = frame.input_call
                                end
                                input_context_stack[#input_context_stack + 1] = frame
                            end

                            local function grouped_input_post(retval)
                                local frame = input_context_stack[#input_context_stack]
                                input_context_stack[#input_context_stack] = nil
                                if frame ~= nil and frame.input_call ~= nil and frame.epoch ~= nil
                                    and epoch_is_active(frame.epoch, late_update_epoch_stack) then
                                    frame.input_call.post_raw = trace_raw_string(retval)
                                    frame.input_call.post_num = trace_numeric_value(retval)
                                    frame.input_call.post_typed = trace_typed_value(retval, {
                                        type_name = frame.input_call.return_type,
                                    })
                                end
                                return retval
                            end

                            local hooked = safe_hook_unique(input_group.representative, grouped_input_pre, grouped_input_post)
                            ok_h = ok_h or hooked
                        end
                    elseif mname == "lateUpdateOnActive" then
                        ok_h = safe_hook_unique(m, function(args)
                            record_call(mname)
                            local this_obj = nil
                            pcall(function() this_obj = sdk.to_managed_object(args[2]) end)
                            local before = get_decision_state(this_obj)
                            local epoch = {
                                gui = this_obj,
                                gui_address = before.gui_address,
                                requested = before.requested,
                                roster = before.roster,
                                roster_name = before.roster_name,
                                owned = before.owned,
                                decided_before = before.decided,
                                curr_step = before.curr_step,
                                timestamp = os.clock(),
                                input_calls = {},
                            }
                            late_update_epoch_stack[#late_update_epoch_stack + 1] = epoch
                        end, function(retval)
                            local epoch = late_update_epoch_stack[#late_update_epoch_stack]
                            late_update_epoch_stack[#late_update_epoch_stack] = nil
                            local this_obj = epoch and epoch.gui or nil
                            local after = get_decision_state(this_obj)
                            if epoch ~= nil and epoch.decided_before == false and after.decided == true then
                                dump_decision_epoch(epoch, after)
                            end
                            enforce_character_decision_gate(this_obj, "lateUpdateOnActive_post")
                            return retval
                        end)
                    elseif mname == "getCharacterKind" then
                        ok_h = safe_hook_unique(m, function(args)
                            record_call(mname)
                        end, function(retval)
                            return retval
                        end)
                    else
                        ok_h = safe_hook_unique(m, function(args)
                            local cnt = record_call(mname)
                            local this_obj = sdk.to_managed_object(args[2])
                            local p1 = args[3] ~= nil and sdk.to_int64(args[3]) or nil
                            local p2 = args[4] ~= nil and sdk.to_int64(args[4]) or nil
                            local roster_idx = resolve_highlighted_character_kind(this_obj)
                            log.info(string.format(
                                "[Merc AP Trace][CALL_PRE] method=%s this=%s p1=%s p2=%s highlight_roster=%d (%s) owned=%s cnt=%d t=%.3f",
                                mname, get_obj_address_str(this_obj), tostring(p1), tostring(p2),
                                roster_idx, ROSTER_INDEX_TO_NAME[roster_idx] or "None", tostring(is_character_owned(roster_idx)), cnt, os.clock()
                            ))
                        end, function(retval)
                            local ret_val = sdk.to_int64(retval)
                            if ret_val ~= nil then
                                log.info(string.format(
                                    "[Merc AP Trace][CALL_POST] method=%s return=%s t=%.3f",
                                    mname, tostring(ret_val), os.clock()
                                ))
                            end
                            return retval
                        end)
                    end

                    if ok_h then
                        log.info(string.format("[Merc AP Trace][HOOK_REGISTERED] chainsaw.Cp1021CharacterSelectGuiBehavior.%s", mname))
                    else
                        log.warn(string.format("[Merc AP Trace][HOOK_FAILED] chainsaw.Cp1021CharacterSelectGuiBehavior.%s", mname))
                    end
                else
                    log.warn(string.format("[Merc AP Trace][HOOK_NOT_FOUND] chainsaw.Cp1021CharacterSelectGuiBehavior.%s", mname))
                end
            end
        end

        -- ==================================================================
        -- 3. COMPILER-GENERATED CLOSURES INSPECTION & TRACING
        -- ==================================================================
        local closure_types = {
            "chainsaw.Cp1021CharacterSelectGuiBehavior.<>c__DisplayClass50_0",
            "chainsaw.Cp1021CharacterSelectGuiBehavior.<>c__DisplayClass53_0",
            "chainsaw.Cp1021CharacterSelectGuiBehavior.<>c__DisplayClass57_0",
            "chainsaw.Cp1021CharacterSelectGuiBehavior.<>c__DisplayClass66_0",
        }
        for _, cname in ipairs(closure_types) do
            local td = sdk.find_type_definition(cname)
            if td ~= nil then
                local method_names = {}
                for _, m in ipairs(td:get_methods() or {}) do
                    local mname = m:get_name()
                    table.insert(method_names, mname)
                    if mname ~= ".ctor" and mname ~= "Finalize" then
                        safe_hook_unique(m, function(args)
                            record_call(cname .. "." .. mname)
                            local this_obj = sdk.to_managed_object(args[2])
                            local p1 = args[3] ~= nil and sdk.to_int64(args[3]) or nil
                            local p2 = args[4] ~= nil and sdk.to_int64(args[4]) or nil
                            log.info(string.format(
                                "[Merc AP Trace][CLOSURE_CALL] type=%s method=%s this=%s p1=%s p2=%s t=%.3f",
                                cname, mname, get_obj_address_str(this_obj), tostring(p1), tostring(p2), os.clock()
                            ))
                        end, function(retval)
                            return retval
                        end)
                    end
                end
                local field_names = {}
                for _, f in ipairs(td:get_fields() or {}) do
                    table.insert(field_names, f:get_name())
                end
                log.info(string.format(
                    "[Merc AP Trace][CLOSURE_INSPECT] type=%s methods=[%s] fields=[%s]",
                    cname, table.concat(method_names, ", "), table.concat(field_names, ", ")
                ))
            else
                log.info(string.format("[Merc AP Trace][CLOSURE_INSPECT] type=%s (not found in TypeDB)", cname))
            end
        end

        -- ==================================================================
        -- 4. TERMINAL DIAGNOSTIC ASSERTION ON startGame
        -- ==================================================================
        local merc_ctrl_type = sdk.find_type_definition("chainsaw.MercenariesModeController")
        if merc_ctrl_type ~= nil then
            local start_game = merc_ctrl_type:get_method("startGame")
            if start_game ~= nil then
                safe_hook_unique(start_game, function(args)
                    local this_ptr = sdk.to_managed_object(args[2])
                    if this_ptr ~= nil then
                        local st = get_safe_field_int(this_ptr, "_StageKind", -1)
                        local ch = get_safe_field_int(this_ptr, "_PlayerCharacterKind", -1)
                        local co = get_safe_field_int(this_ptr, "_PlayerCharacterCostumeId", 0)
                        local key = string.format("%d:%d", ch, co)
                        local entry = CHAR_COSTUME_TO_ROSTER[key]
                        local char_idx = entry and entry.index or ch

                        local st_owned = is_stage_owned(st)
                        local ch_owned = is_character_owned(char_idx)

                        log.info(string.format(
                            "[Merc AP Trace][START_GAME_INVOKED] obj=%s stage=%d (%s, owned=%s) char=%d costume=%d roster=%d (%s, owned=%s) t=%.3f",
                            get_obj_address_str(this_ptr), st, STAGE_KIND_NAMES[st] or "Unknown", tostring(st_owned),
                            ch, co, char_idx, ROSTER_INDEX_TO_NAME[char_idx] or "Unknown", tostring(ch_owned), os.clock()
                        ))
                        emit_call_counts_summary("start_game")

                        if should_enforce_gating() and not (st_owned and ch_owned) then
                            log.error(string.format(
                                "[Merc AP Gating] ASSERTION FAILURE: unowned selection reached startGame (Stage: %d owned=%s, Character: %d owned=%s)",
                                st, tostring(st_owned), char_idx, tostring(ch_owned)
                            ))
                        end
                    end
                    return nil
                end, function(retval)
                    return retval
                end)
            end
        end

        hooks_installed = true
        log.info(string.format("[Merc AP Trace] virtual selection forensic hooks initialized (rev %s)", MERC_P1_TRACE_REV))
    end

    export("install_merc_virtual_gating_hooks", install_merc_virtual_gating_hooks)

    -- Install hooks immediately on boot
    install_merc_virtual_gating_hooks()

    export("merc_state", merc_state)
    export("merc_ownership", ownership)
end

return install
