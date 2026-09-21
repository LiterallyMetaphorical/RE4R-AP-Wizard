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

    local ROSTER_INDEX_TO_KIND_NAME = {
        [0] = "Chi0_0",
        [1] = "Chi0_1",
        [2] = "Chi1_0",
        [3] = "Chi2_0",
        [4] = "Chi3_0",
        [5] = "Chi4_0",
        [6] = "Chi4_1",
        [7] = "Chi5_0",
    }

    local PLAYER_CHARACTER_KIND_TYPE =
        "chainsaw.MercenariesDefine.PlayerCharacterWithCostumeKind"
    local vanilla_diag_target = nil

    local function get_roster_identity(roster_index)
        for key, roster in pairs(CHAR_COSTUME_TO_ROSTER) do
            if roster.index == roster_index then
                local chara_kind, costume_id = key:match("^(%d+):(%d+)$")
                return {
                    roster = roster_index,
                    character = roster.name,
                    base_kind = tonumber(chara_kind),
                    costume = tonumber(costume_id),
                    kind_name = ROSTER_INDEX_TO_KIND_NAME[roster_index],
                }
            end
        end
        return nil
    end

    local function resolve_diag_enum_value(kind_name)
        if type(kind_name) ~= "string" then return nil end
        local type_def = nil
        pcall(function() type_def = sdk.find_type_definition(PLAYER_CHARACTER_KIND_TYPE) end)
        if type_def == nil then return nil end
        local field = nil
        pcall(function() field = type_def:get_field(kind_name) end)
        if field == nil then return nil end
        local raw = nil
        local ok = pcall(function() raw = field:get_data(nil) end)
        if not ok or raw == nil then
            ok = pcall(function() raw = field:get_value() end)
        end
        if not ok or raw == nil then return nil end
        local value = nil
        pcall(function() value = sdk.to_int64(raw) end)
        if type(value) == "number" then return value end
        return type(raw) == "number" and raw or nil
    end

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
        last_valid_run_identity = nil,
        expected_result_identity = nil,
        -- [Result screen] What this run sent and received, shown through
        -- the screen's own unlock notice list (Cam, 2026-09-06). nil when no
        -- result screen is open.
        result_summary = nil,
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

    local function get_type_full_name(type_def)
        if type_def == nil then return nil end
        local ok, name = pcall(function() return type_def:get_full_name() end)
        if ok and type(name) == "string" then return name end
        return nil
    end

    local function get_obj_type_name(obj)
        if obj == nil then return "" end
        local ok, type_def = pcall(function() return obj:get_type_definition() end)
        if not ok or type_def == nil then return "" end
        local ok_name, name = pcall(function() return type_def:get_full_name() end)
        return ok_name and type(name) == "string" and name or ""
    end

    local function reflection_sequence_to_table(sequence)
        if sequence == nil then
            return nil, "nil sequence"
        end

        local out = {}
        local ok, err = pcall(function()
            for _, value in ipairs(sequence) do
                out[#out + 1] = value
            end
        end)

        if ok and #out > 0 then
            return out
        end
        if ok and type(sequence) == "table" then
            return out
        end

        -- Compatibility fallback 1: pairs
        local pairs_out = {}
        local ok_pairs, err_pairs = pcall(function()
            for _, value in pairs(sequence) do
                pairs_out[#pairs_out + 1] = value
            end
        end)
        if ok_pairs and #pairs_out > 0 then
            return pairs_out
        end

        -- Compatibility fallback 2: length + indexed access
        local ok_len, len = pcall(function() return #sequence end)
        if ok_len and type(len) == "number" and len >= 0 then
            if len == 0 then
                return {}
            end
            local index_out = {}
            local ok_idx = pcall(function()
                for i = 1, len do
                    local elem = sequence[i]
                    if elem ~= nil then
                        index_out[#index_out + 1] = elem
                    end
                end
            end)
            if ok_idx and #index_out > 0 then
                return index_out
            end
            local index0_out = {}
            local ok_idx0 = pcall(function()
                for i = 0, len - 1 do
                    local elem = sequence[i]
                    if elem ~= nil then
                        index0_out[#index0_out + 1] = elem
                    end
                end
            end)
            if ok_idx0 and #index0_out > 0 then
                return index0_out
            end
        end

        if ok then
            return out
        end

        return nil, tostring(err or err_pairs or "iteration failed")
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

    -- The controller lookup is a scene-wide component search. It used to run
    -- on every tick from the state tracker and up to three times per frame
    -- from the HUD header, in the campaign too (2026-09-05 review). One
    -- answer per quarter second is plenty for everything that asks; a
    -- controller torn down inside that window just answers nil to its
    -- callers' guarded reads.
    local controller_cache_value = nil
    local controller_cache_clock = -1.0
    local function get_merc_controller()
        local now = os.clock()
        if controller_cache_clock >= 0 and now - controller_cache_clock < 0.25 then
            return controller_cache_value
        end
        controller_cache_value = find_first_component("chainsaw.MercenariesModeController")
        controller_cache_clock = now
        return controller_cache_value
    end
    export("get_merc_controller", get_merc_controller)

    local function get_result_gui_behavior()
        return find_first_component("chainsaw.Cp1021GameClearResultGuiBehavior")
    end
    export("get_result_gui_behavior", get_result_gui_behavior)

    -- The scene-wide component searches below are not free, and this is
    -- asked every frame by the overlay, the markers, the detector and the
    -- delivery drain. One answer per quarter second is plenty.
    local domain_cache_value = nil
    local domain_cache_clock = -1.0
    local get_runtime_domain_uncached

    local function get_runtime_domain()
        local now = os.clock()
        if domain_cache_value ~= nil and now - domain_cache_clock < 0.25 then
            return domain_cache_value
        end
        domain_cache_value = get_runtime_domain_uncached()
        domain_cache_clock = now
        return domain_cache_value
    end

    -- Which of the game's modes is really running. Live evidence only: the
    -- mode's controller, or one of its Cp1021 screens, has to exist in the
    -- current scene. The MercenariesManager is an AppSingleton that outlives
    -- the mode and its IsResult stays raised after a run until the next one
    -- starts, so reading it here kept a save loaded after an S rank in
    -- "MERCENARIES": the campaign pickup scan stayed paused, the header kept
    -- the mode's name and a remote check was lost (live 2026-09-05). Its
    -- get_Routine never existed on the manager (it is the controller's), so
    -- that half of the old test was always false.
    local MERC_SCREEN_TYPES = {
        "chainsaw.Cp1021GameClearResultGuiBehavior",
        "chainsaw.Cp1021StageSelectGuiBehavior",
        "chainsaw.Cp1021CharacterSelectGuiBehavior",
        "chainsaw.Cp1021MainMenuGuiBehavior",
        "chainsaw.Cp1021MainMenuBGGuiBehavior",
    }
    local last_reported_domain = nil
    local last_full_scan_clock = -100.0

    get_runtime_domain_uncached = function()
        local runtime_state = type(ctx.get_runtime_state) == "function" and ctx.get_runtime_state() or nil
        local in_play = runtime_state ~= nil and runtime_state.is_in_game and not runtime_state.is_title_screen
        -- Fast path for the common case. The mode is only entered from the
        -- title menu, so a campaign that is still in-game cannot have turned
        -- into The Mercenaries since the last full look; the six scene scans
        -- below ran every quarter second of every campaign session for
        -- nothing (2026-09-05 review). A full look still happens every two
        -- seconds, so a wrong assumption here costs at most that.
        if last_reported_domain == "CAMPAIGN" and in_play
            and os.clock() - last_full_scan_clock < 2.0 then
            return "CAMPAIGN"
        end
        last_full_scan_clock = os.clock()
        local domain = nil
        if get_merc_controller() ~= nil then
            domain = "MERCENARIES"
        else
            for _, type_name in ipairs(MERC_SCREEN_TYPES) do
                if find_first_component(type_name) ~= nil then
                    domain = "MERCENARIES"
                    break
                end
            end
        end
        if domain == nil then
            if in_play then
                domain = "CAMPAIGN"
            else
                domain = "MENU_OR_OTHER"
            end
        end
        -- One line per change, so the log shows when the mode was entered
        -- and, above all, when it was left.
        if domain ~= last_reported_domain then
            log.info(string.format("[RE4R AP] runtime domain: %s -> %s",
                tostring(last_reported_domain or "start"), domain))
            last_reported_domain = domain
        end
        return domain
    end
    export("get_runtime_domain", get_runtime_domain)

    local function init_merc_ownership(slot_data)
        ownership.characters = {}
        ownership.stages = {}
        ownership.enabled = false
        ownership.ready = false
        vanilla_diag_target = nil
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
                    vanilla_diag_target = get_roster_identity(roster.index)
                    log.info(string.format("[Merc AP Gating] granted starting character: %s (index %d)", roster.name, roster.index))
                    log.info(string.format("[Merc VanillaDiag] starter target resolved: character=%s roster=%d base_kind=%d costume=%d kind=%s",
                        vanilla_diag_target.character,
                        vanilla_diag_target.roster,
                        vanilla_diag_target.base_kind,
                        vanilla_diag_target.costume,
                        vanilla_diag_target.kind_name))
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

    -- [0.7.5] Two settings shape the rank list: the highest rank that counts
    -- (a / s / s_plus / s_plus_plus, every rank up to it) and whether the two
    -- ranks under A (C and B) count too. A 0.7.4 room still says
    -- score_checks (a_only / standard / full) and has no ranks under A; it
    -- reads the same as before.
    local RANK_LADDER = { "C", "B", "A", "S", "S+", "S++" }
    local RANK_ORDER = { C = 0, B = 1, A = 2, S = 3, ["S+"] = 4, ["S++"] = 5 }
    local RANK_KEY_INDEX = { c = 0, b = 1, a = 2, s = 3, s_plus = 4, s_plus_plus = 5 }
    -- 0.7.5 said "every rank up to X", 0.7.4 and earlier said a_only /
    -- standard / full. Both become a range so a room made on either still
    -- reads right in a newer mod.
    local LEGACY_TOP_INDEX = { a = 2, s = 3, s_plus = 4, s_plus_plus = 5 }
    local LEGACY_SCORE_CHECKS = { a_only = "a", standard = "s", full = "s_plus_plus" }

    -- [0.7.6] Ranks as Checks is a range: the lowest and the highest rank that
    -- counts, everything between them included.
    local function get_rank_range(slot_data)
        local merc_data = type(slot_data) == "table" and slot_data.mercenaries or nil
        local floor_key = (type(merc_data) == "table" and merc_data.rank_floor)
            or (type(slot_data) == "table" and slot_data.mercenaries_rank_floor)
        local ceiling_key = (type(merc_data) == "table" and merc_data.rank_ceiling)
            or (type(slot_data) == "table" and slot_data.mercenaries_rank_ceiling)
        local low = RANK_KEY_INDEX[floor_key]
        local high = RANK_KEY_INDEX[ceiling_key]
        if low ~= nil and high ~= nil then
            if high < low then low, high = high, low end
            return low, high
        end

        -- 0.7.5: a top rank plus a switch for the two below A.
        local top_key = (type(merc_data) == "table" and merc_data.ranks_that_count)
            or (type(slot_data) == "table" and slot_data.mercenaries_ranks_that_count)
        local below = (type(merc_data) == "table" and merc_data.ranks_below_a)
        if below == nil and type(slot_data) == "table" then below = slot_data.mercenaries_ranks_below_a end
        if LEGACY_TOP_INDEX[top_key] == nil then
            -- 0.7.4 and earlier: a_only / standard / full, never any rank below A.
            local legacy = (type(merc_data) == "table" and merc_data.score_checks)
                or (type(slot_data) == "table" and slot_data.mercenaries_score_checks)
            top_key = LEGACY_SCORE_CHECKS[legacy] or "s"
            if below == nil then below = false end
        end
        return (below == true) and 0 or 2, LEGACY_TOP_INDEX[top_key] or 3
    end

    -- Ascending, lowest rank first.
    local function get_active_rank_names(low, high)
        local ranks = {}
        for index = low, high do
            local name = RANK_LADDER[index + 1]
            if name ~= nil then ranks[#ranks + 1] = name end
        end
        return ranks
    end

    local function get_active_rank_names_for(slot_data)
        return get_active_rank_names(get_rank_range(slot_data))
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

    local function is_merc_location_completed(location_id)
        if location_id == nil then return false end
        return get_location_checked(bridge.checked_locations or {}, location_id)
            or get_location_checked(bridge.mercenaries_completed_locations or {}, location_id)
    end

    local function get_mercenaries_checklist()
        local slot_data = ctx.slot_data or bridge.slot_data
        local merc_data = type(slot_data) == "table" and slot_data.mercenaries or nil
        local rank_names = get_active_rank_names_for(slot_data)
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
                    local checked = is_merc_location_completed(location_id)
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
            rank_names = table.concat(get_active_rank_names_for(slot_data), ", "),
            found = grand_found,
            total = grand_total,
            stages = stages,
        }
    end
    export("get_mercenaries_checklist", get_mercenaries_checklist)

    -- Capture run identity from the live controller before result GUI fields can
    -- lag or retain a previous run's OpenParam.
    local function get_live_result_identity()
        local ok, identity = pcall(function()
            local controller = get_merc_controller()
            if controller == nil then return nil end
            local stage_kind = get_safe_int(controller, "get_StageKind", -1)
            if stage_kind < 0 then stage_kind = get_safe_field_int(controller, "_StageKind", -1) end
            local chara_kind = get_safe_field_int(controller, "_PlayerCharacterKind", -1)
            local costume_id = get_safe_field_int(controller, "_PlayerCharacterCostumeId", -1)
            if type(stage_kind) ~= "number" or stage_kind ~= math.floor(stage_kind)
                or STAGE_KIND_NAMES[stage_kind] == nil then
                return nil
            end
            if type(chara_kind) ~= "number" or chara_kind ~= math.floor(chara_kind)
                or type(costume_id) ~= "number" or costume_id ~= math.floor(costume_id)
                or CHAR_COSTUME_TO_ROSTER[string.format("%d:%d", chara_kind, costume_id)] == nil then
                return nil
            end
            return {
                stage_kind = stage_kind,
                chara_kind = chara_kind,
                costume_id = costume_id,
            }
        end)
        return ok and identity or nil
    end

    local function copy_result_identity(identity)
        if type(identity) ~= "table" then return nil end
        return {
            stage_kind = identity.stage_kind,
            chara_kind = identity.chara_kind,
            costume_id = identity.costume_id,
        }
    end

    local function get_current_merc_play_info()
        -- Asked up to three times a frame by the HUD; outside the mode the
        -- answer is nil without touching the scene (2026-09-05 review).
        if get_runtime_domain() ~= "MERCENARIES" then return nil end
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
            local rank_names = get_active_rank_names_for(slot_data)
            local done, rank_summary, ranks = 0, {}, {}

            for _, rank_name in ipairs(rank_names) do
                local location_id = nil
                if char_index >= 0 and STAGE_KIND_NAMES[stage_index] ~= nil then
                    location_id = get_merc_location_id(char_name, stage_name, rank_name, slot_data)
                end
                local checked = is_merc_location_completed(location_id)
                if checked then done = done + 1 end
                -- "[x] A" once the check went, "[ ] A" until then; the header
                -- colours each one (Cam, 2026-09-06).
                rank_summary[#rank_summary + 1] = (checked and "[x] " or "[ ] ") .. rank_name
                ranks[#ranks + 1] = { name = rank_name, checked = checked }
            end
            return {
                stage_name = stage_name,
                char_name = char_name,
                stage_idx = stage_index,
                char_idx = char_index,
                done = done,
                total = #rank_names,
                ranks = ranks,
                ranks_str = table.concat(rank_summary, "  "),
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

    local function read_open_param_identity(open_param)
        local stage_kind = read_open_param_int(open_param, "get_Stage", "Stage", -1)
        local chara_kind = read_open_param_int(open_param, "get_PlChara", "PlChara", -1)
        local costume_id = read_open_param_int(open_param, "get_PlCostumeId", "PlCostumeId", -1)
        if STAGE_KIND_NAMES[stage_kind] == nil then return nil, "invalid Stage" end
        if CHAR_COSTUME_TO_ROSTER[string.format("%d:%d", chara_kind, costume_id)] == nil then
            return nil, "invalid PlChara/costume mapping"
        end
        return {
            stage_kind = stage_kind,
            chara_kind = chara_kind,
            costume_id = costume_id,
        }
    end

    local score_get_value_method = nil
    local score_get_value_resolved = false
    local score_diag_logged = false
    local total_score_diagnostic_logged = false
    local cached_score_accessor = nil
    local cached_score_accessor_type_name = nil

    local function is_valid_score_get_value(method)
        if method == nil then return false end
        local ok_name, name = pcall(function() return method:get_name() end)
        if not ok_name or name ~= "get_Value" then return false end

        local ok_static, is_static = pcall(function() return method:is_static() end)
        if not ok_static or is_static ~= false then return false end

        local ok_count, count = pcall(function() return method:get_num_params() end)
        if not ok_count or count ~= 0 then return false end

        local return_type = nil
        local ok_return = pcall(function() return_type = method:get_return_type() end)
        if not ok_return or get_type_full_name(return_type) ~= "System.Int32" then return false end

        return true
    end

    local function resolve_score_get_value()
        if score_get_value_resolved then
            return score_get_value_method
        end

        local type_def = sdk.find_type_definition("chainsaw.SimpleAntiMemoryCheatInteger")
        if type_def == nil then
            score_get_value_resolved = true
            score_get_value_method = nil
            return nil, "chainsaw.SimpleAntiMemoryCheatInteger type not found"
        end

        local method = nil
        local ok_m = pcall(function() method = type_def:get_method("get_Value()") end)
        if not ok_m or method == nil or not is_valid_score_get_value(method) then
            pcall(function() method = type_def:get_method("get_Value") end)
        end

        if method ~= nil and is_valid_score_get_value(method) then
            score_get_value_method = method
            score_get_value_resolved = true
            return score_get_value_method
        end

        local ok_methods, raw_methods = pcall(function() return type_def:get_methods() end)
        if ok_methods and raw_methods ~= nil then
            local methods_list = reflection_sequence_to_table(raw_methods)
            if methods_list ~= nil then
                for _, candidate in ipairs(methods_list) do
                    if is_valid_score_get_value(candidate) then
                        score_get_value_method = candidate
                        score_get_value_resolved = true
                        return score_get_value_method
                    end
                end
            end
        end

        score_get_value_resolved = true
        score_get_value_method = nil
        return nil, "SimpleAntiMemoryCheatInteger.get_Value method not found"
    end

    local function is_valid_open_param_score_method(method)
        if method == nil then return false end
        local ok_static, is_static = pcall(function() return method:is_static() end)
        if not ok_static or is_static ~= false then return false end

        local ok_count, count = pcall(function() return method:get_num_params() end)
        if not ok_count or count ~= 0 then return false end

        local return_type = nil
        local ok_return = pcall(function() return_type = method:get_return_type() end)
        if not ok_return or get_type_full_name(return_type) ~= "chainsaw.SimpleAntiMemoryCheatInteger" then
            return false
        end

        local name = nil
        pcall(function() name = method:get_name() end)
        if name == nil then return false end

        return true, name
    end

    local function is_valid_open_param_score_field(field)
        if field == nil then return false end
        local ok_static, is_static = pcall(function() return field:is_static() end)
        if not ok_static or is_static ~= false then return false end

        local field_type = nil
        local ok_type = pcall(function() field_type = field:get_type() end)
        if not ok_type or get_type_full_name(field_type) ~= "chainsaw.SimpleAntiMemoryCheatInteger" then
            return false
        end

        local name = nil
        pcall(function() name = field:get_name() end)
        if name == nil then return false end

        return true, name
    end

    local function log_score_diagnostics_once(open_param_type, open_param_type_name)
        if score_diag_logged then return end
        score_diag_logged = true

        log.info(string.format("[Merc AP ScoreDiag] open_param_type=%s", tostring(open_param_type_name)))

        if open_param_type == nil then return end

        local ok_m, raw_m = pcall(function() return open_param_type:get_methods() end)
        if ok_m and raw_m ~= nil then
            local methods = reflection_sequence_to_table(raw_m)
            if methods ~= nil then
                for _, m in ipairs(methods) do
                    local m_name = nil
                    pcall(function() m_name = m:get_name() end)
                    if m_name ~= nil and (m_name:find("Score") or m_name:find("Total") or m_name:find("Rank")) then
                        local num_p = 0
                        pcall(function() num_p = m:get_num_params() end)
                        local ret_t = nil
                        pcall(function() ret_t = m:get_return_type() end)
                        local ret_name = get_type_full_name(ret_t) or "unknown"
                        local is_stat = false
                        pcall(function() is_stat = m:is_static() end)
                        log.info(string.format(
                            "[Merc AP ScoreDiag] method name=%s static=%s params=%d return=%s",
                            tostring(m_name), tostring(is_stat), num_p or 0, tostring(ret_name)
                        ))
                    end
                end
            end
        end

        local ok_f, raw_f = pcall(function() return open_param_type:get_fields() end)
        if ok_f and raw_f ~= nil then
            local fields = reflection_sequence_to_table(raw_f)
            if fields ~= nil then
                for _, f in ipairs(fields) do
                    local f_name = nil
                    pcall(function() f_name = f:get_name() end)
                    if f_name ~= nil and (f_name:find("Score") or f_name:find("Total") or f_name:find("Rank")) then
                        local f_t = nil
                        pcall(function() f_t = f:get_type() end)
                        local f_t_name = get_type_full_name(f_t) or "unknown"
                        local is_stat = false
                        pcall(function() is_stat = f:is_static() end)
                        log.info(string.format(
                            "[Merc AP ScoreDiag] field name=%s static=%s type=%s",
                            tostring(f_name), tostring(is_stat), tostring(f_t_name)
                        ))
                    end
                end
            end
        end
    end

    local function resolve_open_param_score_accessor(open_param_type)
        if open_param_type == nil then return nil end

        local method_candidates = {}
        local field_candidates = {}

        -- 1. Scan methods
        local ok_m, raw_m = pcall(function() return open_param_type:get_methods() end)
        if ok_m and raw_m ~= nil then
            local methods = reflection_sequence_to_table(raw_m)
            if methods ~= nil then
                for _, m in ipairs(methods) do
                    local is_valid, m_name = is_valid_open_param_score_method(m)
                    if is_valid then
                        local prio = 3
                        if m_name == "get_TotalScore" or m_name == "get_TotalScore()" then
                            prio = 1
                        elseif m_name:find("TotalScore") then
                            prio = 2
                        end
                        method_candidates[#method_candidates + 1] = {
                            method = m,
                            name = m_name,
                            priority = prio,
                        }
                    end
                end
            end
        end

        if #method_candidates == 0 then
            local ok_direct, direct_m = pcall(function() return open_param_type:get_method("get_TotalScore()") end)
            if not ok_direct or direct_m == nil or not is_valid_open_param_score_method(direct_m) then
                pcall(function() direct_m = open_param_type:get_method("get_TotalScore") end)
            end
            if direct_m ~= nil and is_valid_open_param_score_method(direct_m) then
                method_candidates[#method_candidates + 1] = {
                    method = direct_m,
                    name = "get_TotalScore",
                    priority = 1,
                }
            end
        end

        -- 2. Scan fields
        local ok_f, raw_f = pcall(function() return open_param_type:get_fields() end)
        if ok_f and raw_f ~= nil then
            local fields = reflection_sequence_to_table(raw_f)
            if fields ~= nil then
                for _, f in ipairs(fields) do
                    local is_valid, f_name = is_valid_open_param_score_field(f)
                    if is_valid then
                        local prio = 5
                        if f_name == "TotalScore" then
                            prio = 1
                        elseif f_name == "<TotalScore>k__BackingField" then
                            prio = 2
                        elseif f_name == "_TotalScore" then
                            prio = 3
                        elseif f_name:find("TotalScore") then
                            prio = 4
                        end
                        field_candidates[#field_candidates + 1] = {
                            field = f,
                            name = f_name,
                            priority = prio,
                        }
                    end
                end
            end
        end

        if #field_candidates == 0 then
            local field_names = { "TotalScore", "<TotalScore>k__BackingField", "_TotalScore" }
            for prio, fname in ipairs(field_names) do
                local ok_direct, direct_f = pcall(function() return open_param_type:get_field(fname) end)
                if ok_direct and direct_f ~= nil and is_valid_open_param_score_field(direct_f) then
                    field_candidates[#field_candidates + 1] = {
                        field = direct_f,
                        name = fname,
                        priority = prio,
                    }
                end
            end
        end

        table.sort(method_candidates, function(a, b) return a.priority < b.priority end)
        table.sort(field_candidates, function(a, b) return a.priority < b.priority end)

        local selected_method = #method_candidates > 0 and method_candidates[1].method or nil
        local selected_method_name = #method_candidates > 0 and method_candidates[1].name or nil
        local selected_field_name = #field_candidates > 0 and field_candidates[1].name or nil

        if selected_method == nil and selected_field_name == nil then
            return nil
        end

        return {
            method = selected_method,
            method_name = selected_method_name,
            field_name = selected_field_name,
            member_type = "chainsaw.SimpleAntiMemoryCheatInteger",
        }
    end

    local function read_total_score(open_param)
        if open_param == nil then return nil, "OpenParam unavailable" end

        local open_param_type = nil
        pcall(function() open_param_type = open_param:get_type_definition() end)
        local open_param_type_name = get_type_full_name(open_param_type)
        if open_param_type_name == nil or open_param_type_name == "" then
            open_param_type_name = get_obj_type_name(open_param)
        end
        if open_param_type_name == nil or open_param_type_name == "" then
            open_param_type_name = "chainsaw.Cp1021GameClearResultGuiBehavior.OpenParam"
        end

        log_score_diagnostics_once(open_param_type, open_param_type_name)

        if cached_score_accessor == nil or cached_score_accessor_type_name ~= open_param_type_name then
            cached_score_accessor = resolve_open_param_score_accessor(open_param_type)
            cached_score_accessor_type_name = open_param_type_name
        end

        local accessor = cached_score_accessor
        if accessor == nil then
            return nil, string.format("no valid SimpleAntiMemoryCheatInteger accessor on %s", open_param_type_name)
        end

        local score_container = nil
        local accessor_source = nil
        local accessor_member = nil

        -- A. Try method accessor
        if accessor.method ~= nil then
            local ok_call, res = pcall(function() return accessor.method:call(open_param) end)
            if ok_call and res ~= nil then
                score_container = res
                accessor_source = "method"
                accessor_member = accessor.method_name or "get_TotalScore"
            end
        end

        -- B. Try field accessor
        if score_container == nil and accessor.field_name ~= nil then
            local ok_f, val = pcall(function() return open_param:get_field(accessor.field_name) end)
            if ok_f and val ~= nil then
                score_container = val
                accessor_source = "field"
                accessor_member = accessor.field_name
            end
        end

        if score_container == nil then
            return nil, string.format("TotalScore container returned nil via %s", tostring(accessor_member or "accessor"))
        end

        if not total_score_diagnostic_logged then
            total_score_diagnostic_logged = true
            log.info(string.format(
                "[Merc AP] TotalScore accessor ready: source=%s member=%s member_type=chainsaw.SimpleAntiMemoryCheatInteger container_type=%s",
                tostring(accessor_source), tostring(accessor_member), type(score_container)
            ))
        end

        local getter, resolve_err = resolve_score_get_value()
        if getter == nil then
            return nil, resolve_err or "SimpleAntiMemoryCheatInteger.get_Value unavailable"
        end

        local ok_value, value = pcall(function() return getter:call(score_container) end)
        if not ok_value then
            return nil, "get_Value invocation failed"
        end
        if type(value) ~= "number" then
            return nil, "get_Value returned non-number"
        end

        return value
    end

    local function build_result_payload(open_param)
        if open_param == nil then return nil, "OpenParam unavailable" end
        local identity, identity_error = read_open_param_identity(open_param)
        if identity == nil then return nil, identity_error end
        local stage_kind = identity.stage_kind
        local chara_kind = identity.chara_kind
        local costume_id = identity.costume_id
        local roster = CHAR_COSTUME_TO_ROSTER[string.format("%d:%d", chara_kind, costume_id)]

        local rank = read_open_param_int(open_param, "get_Rank", "Rank", -1)
        local rank_name = SCORE_RANK_NAMES[rank]
        if rank_name == nil then return nil, "invalid rank mapping" end

        local total_score, score_error = read_total_score(open_param)
        if total_score == nil then return nil, score_error or "TotalScore:get_Value failed" end
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

    -- What sits on a location, from the connect-time scouts: the item's name,
    -- its owner's name, whether it is ours, and its classification. Names
    -- may be missing (no scout yet); callers cope.
    local function describe_location_item(location_id)
        local key = tostring(location_id)
        local item_id = type(bridge.location_scout_item) == "table" and bridge.location_scout_item[key] or nil
        local player = type(bridge.location_scout_player) == "table" and bridge.location_scout_player[key] or nil
        local item_name_fn = ctx.ap_item_name or _G.ap_item_name
        local player_name_fn = ctx.ap_player_name or _G.ap_player_name
        local item_name = nil
        if type(item_name_fn) == "function" and type(item_id) == "number" then
            local ok_name, name = pcall(item_name_fn, item_id, player)
            if ok_name and type(name) == "string" and name ~= "" then item_name = name end
        end
        local who = nil
        if type(player_name_fn) == "function" and player ~= nil then
            local ok_who, name = pcall(player_name_fn, player)
            if ok_who and type(name) == "string" and name ~= "" then who = name end
        end
        local mine = player == nil or player == bridge.ap_numeric_slot
        local classification = type(bridge.location_classifications) == "table"
            and bridge.location_classifications[key] or "FILLER"
        return { item_name = item_name, who = who, mine = mine, classification = classification }
    end

    -- Where one of your own items is going. "(yours)" said nothing you did not
    -- already know; which of your contents it serves is the useful half (Cam,
    -- 2026-09-07). A Mercenaries item needs no label at all, since the name
    -- already carries it.
    local function own_item_destination(item_name)
        if type(item_name) == "string" and item_name:match("^Mercenaries ") then
            return nil
        end
        local slot_data = bridge.slot_data
        local campaign = type(slot_data) == "table" and slot_data.patched_campaign or nil
        if campaign == "Separate Ways" then return "Separate Ways" end
        if campaign == "Main Story" then return "Leon's Campaign" end
        return nil
    end

    -- One toast per rank check the result screen just earned. On the result
    -- screen itself the same words go through the screen's own notice list
    -- (below), and native_log leaves these records to the Message Log.
    local function announce_rank_check(rank_name, location_id, payload)
        local enqueue = ctx.enqueue_toast or _G.enqueue_toast
        if type(enqueue) ~= "function" then return end
        local desc = describe_location_item(location_id)
        local detail = "check sent"
        if desc.item_name ~= nil then
            if desc.who ~= nil and not desc.mine then
                detail = desc.item_name .. " for " .. desc.who
            else
                local where = own_item_destination(desc.item_name)
                detail = where ~= nil and (desc.item_name .. " to " .. where) or desc.item_name
            end
        end
        pcall(enqueue,
            string.format("Rank %s: %s, %s", rank_name, payload.char_name, payload.stage_name),
            detail, desc.classification, "sent")
    end

    -- ------------------------------------------------------------------
    -- [Result screen] The screen's own unlock notice list carries what this
    -- run did for the multiworld (Cam, 2026-09-06: "use the game's native
    -- unlocked list"). The screen walks fixed steps (WaitOpen 0,
    -- ResultShowing 1, DrumRollWait 2, Next 3, NextWait 4, UnlockNoticePre 5,
    -- UnlockNotice 6, UnlockNoticeWait 7, RankingSend 8/9, End 10); its own
    -- unlock rules fill _UnlockNoticeList at UnlockNoticePre and the screen
    -- shows the list at UnlockNotice. Our lines go in as soon as the result
    -- is read and stay in; the vanilla lines (a lie under AP: those unlocks
    -- are items elsewhere) are taken out whenever they appear, and logged
    -- once so their format is on record.
    -- Our lines go in AT the notice steps, not before them. Going in early
    -- lost a race nobody can win: the screen's own UnlockNoticePre fills the
    -- list from its unlock rules, which wiped ours, and re-adding a few times
    -- left one line by the time it displayed (Cam, live 2026-09-07: three set,
    -- one in the list at UnlockNotice, none of it ours on screen).
    --
    -- The window is UnlockNoticePre through UnlockNoticeWait, and the lines are
    -- re-asserted on every pass inside it, so whichever frame the screen reads
    -- from, ours are what is there.
    local STEP_UNLOCK_NOTICE_PRE = 5
    local STEP_UNLOCK_NOTICE = 6
    local STEP_UNLOCK_NOTICE_WAIT = 7
    local STEP_NAMES = {
        [0] = "WaitOpen", [1] = "ResultShowing", [2] = "DrumRollWait", [3] = "Next",
        [4] = "NextWait", [5] = "UnlockNoticePre", [6] = "UnlockNotice", [7] = "UnlockNoticeWait",
        [8] = "RankingSend", [9] = "RankingSendWait", [10] = "End",
    }
    local unlock_notice_suppressed_logged = false
    -- What the screen's notice text treats as a line break. Named because it is
    -- the one thing in the layout we cannot check offline: if the widget shows
    -- the notice as one run-on line, this is the knob to turn.
    local NOTICE_LINE_BREAK = string.char(10)

    local function open_result_summary(payload, epoch)
        merc_state.result_summary = {
            epoch = epoch,
            char_name = payload.char_name,
            stage_name = payload.stage_name,
            rank_name = payload.rank_name,
            lines = {},             -- the long form, for the log and the overlay
            sent = {},              -- "C: Handgun Ammo x10", in rank order
            sent_dest = {},         -- where each of those went, or false
            named = {},             -- item names a sent clause already covers
            extras = {},            -- items that arrived from somewhere else
            remaining = {},         -- ranks this pair still owes
            notice = nil,           -- the ONE line the result screen shows
            notice_injected = false,
            notice_injected_at_step = nil,
            notice_injections = 0,
            notice_consumed = false,
            injected = {},          -- line -> true once it went into the list
            display_passed = false, -- the screen reached UnlockNotice
            consumed_logged = false,
            last_step = nil,
            vanilla_logged = false,
            gui_misses = 0,
            last_gui_poll_clock = os.clock(),
        }
        return merc_state.result_summary
    end

    local function summary_has_line(text)
        local summary = merc_state.result_summary
        if summary == nil then return false end
        for _, existing in ipairs(summary.lines) do
            if existing == text then return true end
        end
        return false
    end

    local function summary_add_line(text)
        local summary = merc_state.result_summary
        if summary == nil or type(text) ~= "string" or text == "" then return false end
        if summary_has_line(text) then return false end
        summary.lines[#summary.lines + 1] = text
        return true
    end

    local function format_sent_line(rank_name, desc)
        if desc.item_name == nil then
            return string.format("Rank %s check sent", rank_name)
        end
        if desc.who ~= nil and not desc.mine then
            return string.format("Rank %s sent: %s for %s", rank_name, desc.item_name, desc.who)
        end
        local where = own_item_destination(desc.item_name)
        if where ~= nil then
            return string.format("Rank %s sent: %s to %s", rank_name, desc.item_name, where)
        end
        return string.format("Rank %s sent: %s", rank_name, desc.item_name)
    end

    -- The short form for the notice: the rank and what it held, plus where it
    -- went kept separate. compose_notice groups the ranks under one heading per
    -- destination, so nothing repeats the destination per rank.
    local function format_sent_clause(rank_name, desc)
        if desc.item_name == nil then
            return string.format("%s: check sent", rank_name), nil
        end
        if desc.who ~= nil and not desc.mine then
            return string.format("%s: %s", rank_name, desc.item_name), desc.who
        end
        return string.format("%s: %s", rank_name, desc.item_name),
            own_item_destination(desc.item_name)
    end

    local function strip_merc_item_prefix(name)
        local text = tostring(name or "")
        local character = text:match("^Mercenaries Character: (.+)$")
        if character then return character, "character" end
        local stage = text:match("^Mercenaries Stage: (.+)$")
        if stage then return stage, "stage" end
        return text, nil
    end

    -- apclient calls this for every Mercenaries item it delivers; only a
    -- result screen that is open takes note.
    local function merc_result_note_received(kind, name, from)
        local summary = merc_state.result_summary
        if summary == nil then return false end
        if kind == "merc_filler" then
            return summary_add_line("Nothing this time: that rank held no item for you")
        end
        -- The rank clause already said this. Saying it again as an unlock is
        -- how the Docks stage appeared twice on one screen (Cam, 2026-09-07).
        if summary.named[tostring(name)] then
            return false
        end
        local short, what = strip_merc_item_prefix(name)
        local line
        if what == "stage" then
            line = short .. " stage unlocked for The Mercenaries"
        else
            line = short .. " unlocked for The Mercenaries"
        end
        if type(from) == "string" and from ~= "" then
            line = line .. " (from " .. from .. ")"
        end
        -- The same delivery announced twice is still one thing that happened.
        -- extras used to grow even when the line was a repeat, which put the
        -- unlock on the notice twice over (Cam, 2026-09-07).
        if summary_has_line(line) then return false end
        local short_extra = short
        if what == "stage" then short_extra = short_extra .. " stage" end
        if type(from) == "string" and from ~= "" then
            short_extra = short_extra .. " from " .. from
        end
        summary.extras[#summary.extras + 1] = short_extra
        -- Rebuilt on the next pass, but only while the screen has not been
        -- handed it: changing the text after that would leave the injected
        -- line unrecognised and read as a confirmation that never happened.
        if not summary.notice_injected then summary.notice = nil end
        return summary_add_line(line)
    end
    export("merc_result_note_received", merc_result_note_received)

    -- (4) ONE notice for the screen, laid out over several lines: the pair,
    -- what each rank sent and to whom, anything that arrived from elsewhere,
    -- and what the pair still owes. The screen shows its notices one at a time
    -- and wants an OK for each, so several notices meant several confirmations
    -- for one run (Cam, 2026-09-07). Line breaks are Cam's layout, 2026-09-07.
    local function compose_notice(summary)
        if summary == nil then return nil end
        if summary.notice ~= nil then return summary.notice end
        if summary.notice_injected then return nil end

        local lines = {}
        local head = string.format("%s / %s",
            tostring(summary.stage_name or "?"), tostring(summary.char_name or "?"))
        if summary.rank_name ~= nil and summary.rank_name ~= "" then
            head = head .. " - Rank " .. tostring(summary.rank_name)
        end
        lines[#lines + 1] = head

        -- One heading per destination, in the order the ranks reached them.
        local order, groups = {}, {}
        for index = 1, #summary.sent do
            local dest = summary.sent_dest[index]
            if dest == false then dest = nil end
            local key = dest or ""
            if groups[key] == nil then
                groups[key] = { dest = dest, clauses = {} }
                order[#order + 1] = key
            end
            local clauses = groups[key].clauses
            clauses[#clauses + 1] = summary.sent[index]
        end
        lines[#lines + 1] = ""
        if #order == 0 then
            lines[#lines + 1] = "No check this time"
        else
            for _, key in ipairs(order) do
                local group = groups[key]
                lines[#lines + 1] = group.dest ~= nil
                    and ("Sent to " .. group.dest .. ":") or "Sent:"
                lines[#lines + 1] = table.concat(group.clauses, ", ")
            end
        end

        if #summary.extras > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Received: " .. table.concat(summary.extras, ", ")
        end
        if #summary.remaining > 0 then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Ranks left on this Stage/Character combination: "
                .. table.concat(summary.remaining, ", ")
        end

        summary.notice = table.concat(lines, NOTICE_LINE_BREAK)
        return summary.notice
    end

    -- native_log.lua holds every toast queued while the result screen is up so
    -- the screen's own notice is the only thing on it. If that notice was never
    -- shown, the news still has to reach the player: give the held records back
    -- to the overlay on the way out.
    local function release_held_result_toasts(summary)
        if type(bridge.check_notifications) ~= "table" then return 0 end
        local released = 0
        for _, rec in ipairs(bridge.check_notifications) do
            if rec.held_by_result_screen then
                rec.held_by_result_screen = nil
                if not summary.notice_consumed then
                    rec.rendered_natively = false
                    rec.display_started_at_unix_ms = nil
                    rec.display_started_clock = nil
                    released = released + 1
                end
            end
        end
        return released
    end

    local function close_result_summary(reason)
        local summary = merc_state.result_summary
        if summary == nil then return end
        local released = release_held_result_toasts(summary)
        log.info(string.format(
            "[Merc AP] result screen summary closed (%s): %d line(s), notice %s%s",
            tostring(reason), #summary.lines,
            summary.notice_consumed and "shown"
                or (summary.notice_injected and "set but never shown" or "never set"),
            released > 0 and string.format(", %d toast(s) handed back to the overlay", released) or ""))
        merc_state.result_summary = nil
    end

    -- Polled from the state tracker: the summary lives as long as the result
    -- screen does (two consecutive misses half a second apart close it).
    local function refresh_result_summary()
        local summary = merc_state.result_summary
        if summary == nil then return end
        if get_runtime_domain() ~= "MERCENARIES" then
            close_result_summary("left the mode")
            return
        end
        local now = os.clock()
        if now - summary.last_gui_poll_clock < 0.5 then return end
        summary.last_gui_poll_clock = now
        if get_result_gui_behavior() == nil then
            summary.gui_misses = summary.gui_misses + 1
            if summary.gui_misses >= 2 then close_result_summary("result screen gone") end
        else
            summary.gui_misses = 0
        end
    end

    local function get_merc_result_summary()
        return merc_state.result_summary
    end
    export("get_merc_result_summary", get_merc_result_summary)

    -- Where a toast can be seen right now inside the mode (native_log asks):
    --   "result" - the result screen is open and has not shown its notice
    --              list yet: the list carries the words, no rail, no overlay
    --   "run"    - a run is going: the game's own rail shows (DeathLink
    --              proved it, Cam 2026-09-06)
    --   "menu"   - the mode's menus, or a result screen past its notice:
    --              the imgui overlay, the rail is not on screen there
    --   nil      - not in the mode
    local function merc_presentation()
        if get_runtime_domain() ~= "MERCENARIES" then return nil end
        local summary = merc_state.result_summary
        if summary ~= nil then
            if summary.display_passed then return "menu" end
            return "result"
        end
        if get_current_merc_play_info() ~= nil then return "run" end
        return "menu"
    end
    export("merc_presentation", merc_presentation)

    local function list_count(list)
        local ok, n = pcall(function() return list:call("get_Count") end)
        return ok and tonumber(n) or 0
    end

    local function list_item_text(list, index)
        local ok, value = pcall(function() return list:call("get_Item", index) end)
        if not ok or value == nil then return nil end
        if type(value) == "string" then return value end
        local ok_str, text = pcall(function() return value:call("ToString") end)
        if ok_str and type(text) == "string" then return text end
        return tostring(value)
    end

    local function list_add(list, text)
        local value = text
        if type(sdk) == "table" and type(sdk.create_managed_string) == "function" then
            local ok_ms, managed = pcall(sdk.create_managed_string, text)
            if ok_ms and managed ~= nil then value = managed end
        end
        return pcall(function() list:call("Add", value) end)
    end

    -- The per-frame body of the result screen hook. `step` is the screen's
    -- current step (a number) or nil when it could not be read.
    local function maintain_result_notice_list(list, step)
        local summary = merc_state.result_summary
        if list == nil then return end
        if summary ~= nil and step ~= nil and step ~= summary.last_step then
            log.info(string.format("[Merc AP] result screen step: %s -> %s (notice list: %d)",
                tostring(STEP_NAMES[summary.last_step] or summary.last_step or "start"),
                tostring(STEP_NAMES[step] or step), list_count(list)))
            summary.last_step = step
            -- Past the wait, the screen is done with the list for good. If our
            -- line was in when it got there, the screen showed it.
            if step > STEP_UNLOCK_NOTICE_WAIT and not summary.display_passed then
                summary.display_passed = true
                if summary.notice_injected and not summary.notice_consumed then
                    summary.notice_consumed = true
                    log.info("[Merc AP] result notice shown; the screen moved on")
                end
            end
        end

        -- 1. The game's own lines out, logged once per result.
        local ours = {}
        if summary ~= nil then
            local notice = compose_notice(summary)
            if notice ~= nil then ours[notice] = true end
        end
        local count = list_count(list)
        local vanilla = {}
        local present = {}
        for index = count - 1, 0, -1 do
            local text = list_item_text(list, index)
            if text ~= nil and ours[text] then
                present[text] = true
            else
                vanilla[#vanilla + 1] = tostring(text)
                pcall(function() list:call("RemoveAt", index) end)
            end
        end
        if #vanilla > 0 then
            if summary == nil then
                if not unlock_notice_suppressed_logged then
                    unlock_notice_suppressed_logged = true
                    log.info(string.format(
                        "[Merc AP] vanilla unlock notice suppressed (%d line(s)): the unlocks are multiworld items",
                        #vanilla))
                end
            elseif not summary.vanilla_logged then
                summary.vanilla_logged = true
                local shown = {}
                for i = 1, math.min(#vanilla, 4) do shown[#shown + 1] = "'" .. vanilla[i] .. "'" end
                log.info(string.format(
                    "[Merc AP] vanilla unlock notice line(s) replaced (%d): %s",
                    #vanilla, table.concat(shown, ", ")))
            end
        end
        if summary == nil then return end

        -- 2. ONE notice, in once, never put back. The screen shows its notices
        -- one at a time and asks for an OK on each, so re-asserting on every
        -- pass meant it could never finish: the player confirmed forever (Cam,
        -- 2026-09-07). A notice that was in the list and is gone was taken by
        -- the screen, which is the only confirmation available that it showed.
        local notice = compose_notice(summary)
        if notice == nil then return end
        local step_now = summary.last_step
        if summary.notice_injected and not present[notice] then
            -- One exception to "gone means shown": the screen fills this list
            -- with its own unlock lines on the way out of UnlockNoticePre, and
            -- that fill can clear ours before anyone saw it. So a line that
            -- goes missing while the screen is still at UnlockNoticePre buys
            -- one more attempt, at UnlockNotice. Two attempts, ever: the count
            -- is what keeps this from becoming the loop again.
            local wiped_before_showing = summary.notice_injected_at_step == STEP_UNLOCK_NOTICE_PRE
                and step_now ~= nil and step_now <= STEP_UNLOCK_NOTICE
                and summary.notice_injections < 2
            if not wiped_before_showing then
                if not summary.notice_consumed then
                    summary.notice_consumed = true
                    log.info("[Merc AP] result notice shown and confirmed by the screen")
                end
                summary.display_passed = true
                return
            end
            if step_now < STEP_UNLOCK_NOTICE then return end
            summary.notice_injected = false
            log.info("[Merc AP] result notice was cleared before it showed; setting it once more")
        end
        if summary.display_passed or summary.notice_injected then
            return
        end
        if step_now == nil
            or step_now < STEP_UNLOCK_NOTICE_PRE
            or step_now > STEP_UNLOCK_NOTICE_WAIT then
            return
        end
        if list_add(list, notice) then
            summary.notice_injected = true
            summary.notice_injected_at_step = step_now
            summary.notice_injections = summary.notice_injections + 1
            log.info(string.format("[Merc AP] result notice set (attempt %d, %d in the list): %s",
                summary.notice_injections, list_count(list),
                (notice:gsub(NOTICE_LINE_BREAK, " / "))))
        end
    end
    export("merc_maintain_result_notice_list", maintain_result_notice_list)

    local result_mapping_warned = {}
    local function evaluate_result_locations(payload, slot_data, epoch)
        -- Every rank that counts in this slot and that this result reached
        -- (C for any finished run when the ranks below A count).
        local rank_names = {}
        for _, rank_name in ipairs(get_active_rank_names_for(slot_data)) do
            if RANK_ORDER[rank_name] <= (tonumber(payload.rank) or -1) then
                rank_names[#rank_names + 1] = rank_name
            end
        end

        bridge.pending_checks = bridge.pending_checks or {}
        bridge.pending_check_keys = bridge.pending_check_keys or {}
        bridge.mercenaries_completed_locations = bridge.mercenaries_completed_locations or {}
        local checked_set = bridge.checked_locations or {}
        local completed_set = bridge.mercenaries_completed_locations
        local room_set = get_room_location_set()
        local to_queue = {}
        local problems = {}
        local already_sent = {}
        open_result_summary(payload, epoch or 0)
        -- What this pair still owes, so the screen can say it in the same
        -- breath (Cam asked, 2026-09-07).
        do
            local reached = {}
            for _, rank_name in ipairs(rank_names) do reached[rank_name] = true end
            local summary = merc_state.result_summary
            for _, rank_name in ipairs(get_active_rank_names_for(slot_data)) do
                if not reached[rank_name] then
                    summary.remaining[#summary.remaining + 1] = rank_name
                end
            end
        end
        if #rank_names == 0 then
            summary_add_line("No check this time: Rank A or better sends one")
        end

        -- Each rank stands on its own: a rank whose mapping is missing is
        -- reported and skipped, the others still go (until 2026-09-05 one
        -- bad rank threw the whole result away and it was lost when the
        -- screen closed). The slot's own map is authoritative; the launcher's
        -- room file is a copy of the same room, so a miss there is a warning,
        -- not a veto.
        for _, rank_name in ipairs(rank_names) do
            local location_id, mapping_error = get_merc_location_id(
                payload.char_name, payload.stage_name, rank_name, slot_data)
            if location_id == nil then
                problems[#problems + 1] = string.format("rank %s: %s",
                    rank_name, tostring(mapping_error or "location mapping failed"))
            else
                if room_set ~= nil and not location_in_set(room_set, location_id) then
                    problems[#problems + 1] = string.format(
                        "rank %s: location %d is not in the launcher's room set (queued anyway)",
                        rank_name, location_id)
                end
                local key = "merc:" .. tostring(location_id)
                if not get_location_checked(checked_set, location_id)
                    and not get_location_checked(completed_set, location_id)
                    and bridge.pending_check_keys[key] ~= true then
                    to_queue[#to_queue + 1] = { id = location_id, key = key, rank = rank_name }
                else
                    already_sent[#already_sent + 1] = rank_name
                end
            end
        end
        if #already_sent > 0 then
            summary_add_line(string.format("Rank %s: sent on an earlier run", table.concat(already_sent, "/")))
        end
        if #problems > 0 then
            local warn_key = tostring(epoch or 0)
            if not result_mapping_warned[warn_key] then
                result_mapping_warned[warn_key] = true
                log.warn("[Merc AP] result mapping: " .. table.concat(problems, "; "))
            end
        end
        if #rank_names > 0 and #to_queue == 0 and #problems >= #rank_names then
            return false, "no rank of this result maps to a location"
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
            local desc = describe_location_item(item.id)
            summary_add_line(format_sent_line(item.rank, desc))
            local summary = merc_state.result_summary
            if summary ~= nil then
                local clause, dest = format_sent_clause(item.rank, desc)
                summary.sent[#summary.sent + 1] = clause
                summary.sent_dest[#summary.sent_dest + 1] = dest or false
                if desc.item_name ~= nil then
                    summary.named[tostring(desc.item_name)] = true
                end
                summary.notice = nil
            end
            announce_rank_check(item.rank, item.id, payload)
        end
        if #to_queue > 0 then
            bridge.state_dirty = true
            if completed_changed and type(ctx.save_session_state) == "function" then
                ctx.save_session_state()
            end
        end
        return true
    end
    export("merc_evaluate_result_locations", evaluate_result_locations)

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
            local open_identity = read_open_param_identity(open_param)
            if open_identity == nil then
                return
            end
            local expected = merc_state.expected_result_identity
            if expected == nil then
                -- The live identity was never captured during the run (a
                -- getter renamed by a patch, a run entered before the
                -- controller could be read). The screen that just opened is
                -- this result's own record, so its identity stands rather
                -- than the ranks being thrown away (2026-09-05 review).
                expected = copy_result_identity(open_identity)
                merc_state.expected_result_identity = expected
                local roster = CHAR_COSTUME_TO_ROSTER[string.format("%d:%d",
                    open_identity.chara_kind, open_identity.costume_id)]
                log.warn(string.format(
                    "[Merc AP] result identity taken from the result screen (live identity was not captured): stage=%s character=%s",
                    tostring(STAGE_KIND_NAMES[open_identity.stage_kind]),
                    tostring(roster and roster.name or "?")))
            end
            if open_identity.stage_kind ~= expected.stage_kind
                or open_identity.chara_kind ~= expected.chara_kind
                or open_identity.costume_id ~= expected.costume_id then
                return
            end
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
                merc_state.result_payload, ctx.slot_data or bridge.slot_data, merc_state.result_epoch)
            if not ok_locations then
                bounded_result_error(merc_state.result_epoch, "mapping", location_error)
                return
            end
            merc_state.consumed_result_epoch = merc_state.result_epoch
            merc_state.lifecycle = STATE_RESULT_CONSUMED
        end
    end

    local VANILLA_DIAG_EMULATION = "none" -- none | infosave_locked | old_chara_locked
    local vanilla_diag_emulation = VANILLA_DIAG_EMULATION
    if vanilla_diag_emulation ~= "none"
        and vanilla_diag_emulation ~= "infosave_locked"
        and vanilla_diag_emulation ~= "old_chara_locked" then
        log.error("[Merc VanillaDiag] unknown emulation mode; using none: "
            .. tostring(vanilla_diag_emulation))
        vanilla_diag_emulation = "none"
    end

    local MERC_START_DIAG_WINDOW_SECONDS = 2.0
    local MERC_START_DIAG_RETENTION_SECONDS = 12.0
    local merc_start_diag = {
        attempt = 0,
        active = false,
    }

    local function restore_merc_diag_old_unlock(record)
        if record == nil or not record.active then return end
        if get_obj_address_str(record.gui) ~= record.gui_id then
            record.active = false
            if merc_start_diag.old_chara_restore == record then
                merc_start_diag.field_restore_verified = false
            end
            log.warn("[Merc VanillaDiag] _bOldCharaUnlock restore skipped; GUI identity changed")
            return
        end
        local restored = pcall(function()
            record.gui:set_field("_bOldCharaUnlock", record.original)
        end) and get_safe_field_bool(record.gui, "_bOldCharaUnlock", nil) == record.original
        if restored then
            record.active = false
            if merc_start_diag.old_chara_restore == record then
                merc_start_diag.field_restore_verified = true
            end
            log.info("[Merc VanillaDiag] restored _bOldCharaUnlock=" .. tostring(record.original)
                .. " scope=OnDecided POST same_gui=true")
        else
            if merc_start_diag.old_chara_restore == record then
                merc_start_diag.field_restore_verified = false
            end
            log.error("[Merc VanillaDiag] _bOldCharaUnlock restore failed")
        end
    end

    local function diag_status()
        if vanilla_diag_emulation == "none" then return "CONTROL_OBSERVED" end
        if merc_start_diag.target_matches == nil then
            return "NOT_EXERCISED: no target selection observed"
        end
        if not merc_start_diag.target_matches then
            return "NOT_EXERCISED: target mismatch"
        end
        if vanilla_diag_emulation == "infosave_locked"
            and merc_start_diag.relevant_query_count == 0 then
            return "NOT_EXERCISED: no matching query observed"
        end
        if vanilla_diag_emulation == "old_chara_locked"
            and (merc_start_diag.field_write_verified ~= true
                or merc_start_diag.field_restore_verified ~= true) then
            return "INTERVENTION_FAILED"
        end
        if merc_start_diag.override_applied_count > 0
            or merc_start_diag.field_write_verified == true then
            return "INTERVENTION_APPLIED"
        end
        return "INTERVENTION_FAILED"
    end

    local function finish_merc_start_diag(outcome)
        if not merc_start_diag.active then return end
        restore_merc_diag_old_unlock(merc_start_diag.old_chara_restore)
        merc_start_diag.old_chara_restore = nil
        if merc_start_diag.observation_closed_reason == nil then
            merc_start_diag.observation_closed_reason = outcome == "run_observed"
                and "run_observed"
                or tostring(outcome)
        end
        local selected_unlock = merc_start_diag.selected_vanilla_unlock
        log.info(string.format(
            "[Merc VanillaDiag] attempt=%d summary mode_requested=%s target_character=%s target_roster=%s selected_character=%s selected_roster=%s target_matches=%s ap_owned=%s relevant_query_count=%d override_applied_count=%d field_write_verified=%s field_restore_verified=%s startGame_hook_observed=%s run_observed=%s run_observation=%s observation_closed_reason=%s pre_confirm_queries=%d decision_queries=%d transition_queries=%d vanilla_unlock=%s initial_settings=%s status=%s outcome=%s",
            merc_start_diag.attempt,
            vanilla_diag_emulation,
            tostring(merc_start_diag.target_character),
            tostring(merc_start_diag.target_roster),
            tostring(merc_start_diag.selected_character),
            tostring(merc_start_diag.selected_roster),
            tostring(merc_start_diag.target_matches),
            tostring(merc_start_diag.ap_owned),
            merc_start_diag.relevant_query_count,
            merc_start_diag.override_applied_count,
            tostring(merc_start_diag.field_write_verified),
            tostring(merc_start_diag.field_restore_verified),
            tostring(merc_start_diag.startGame_hook_observed),
            tostring(merc_start_diag.run_observed),
            tostring(merc_start_diag.run_observation),
            tostring(merc_start_diag.observation_closed_reason),
            merc_start_diag.pre_confirm_queries,
            merc_start_diag.decision_queries,
            merc_start_diag.transition_queries,
            selected_unlock == nil and "unseen" or tostring(selected_unlock),
            tostring(#merc_start_diag.initial_settings > 0),
            diag_status(),
            tostring(outcome)
        ))
        merc_start_diag.active = false
    end

    local function arm_merc_start_diag(gui)
        local target = vanilla_diag_target
        if target == nil then return false end
        if merc_start_diag.active then finish_merc_start_diag("superseded") end
        merc_start_diag.attempt = merc_start_diag.attempt + 1
        merc_start_diag.active = true
        merc_start_diag.gui = gui
        merc_start_diag.gui_id = get_obj_address_str(gui)
        merc_start_diag.target_character = target.character
        merc_start_diag.target_roster = target.roster
        merc_start_diag.target_base_kind = target.base_kind
        merc_start_diag.target_costume = target.costume
        merc_start_diag.target_kind_name = target.kind_name
        merc_start_diag.target_kind_value = resolve_diag_enum_value(target.kind_name)
        merc_start_diag.ap_owned = is_character_owned(target.roster) and true or false
        merc_start_diag.selected_action = nil
        merc_start_diag.selected_character = nil
        merc_start_diag.selected_roster = nil
        merc_start_diag.target_matches = nil
        merc_start_diag.old_chara_unlock = get_safe_field_bool(gui, "_bOldCharaUnlock", nil)
        merc_start_diag.decided = get_safe_field_bool(gui, "_bDecided", nil)
        merc_start_diag.main_menu_callback = false
        merc_start_diag.vanilla_queries = {}
        merc_start_diag.vanilla_query_keys = {}
        merc_start_diag.relevant_query_count = 0
        merc_start_diag.override_applied_count = 0
        merc_start_diag.pre_confirm_queries = 0
        merc_start_diag.decision_queries = 0
        merc_start_diag.transition_queries = 0
        merc_start_diag.decision_callback_active = false
        merc_start_diag.field_write_verified = nil
        merc_start_diag.field_restore_verified = nil
        merc_start_diag.selected_vanilla_unlock = nil
        merc_start_diag.initial_settings = {}
        merc_start_diag.start_game = false
        merc_start_diag.startGame_hook_observed = false
        merc_start_diag.run_observed = false
        merc_start_diag.run_observation = nil
        merc_start_diag.observation_open = true
        merc_start_diag.observation_closed_reason = nil
        merc_start_diag.emulation_logged = false
        merc_start_diag.old_chara_restore = nil
        merc_start_diag.started_at = os.clock()
        log.info(string.format(
            "[Merc VanillaDiag] attempt=%d menu_visit mode_requested=%s target_character=%s target_roster=%d base_kind=%d costume=%d kind=%s enum_value=%s ap_owned=%s",
            merc_start_diag.attempt,
            vanilla_diag_emulation,
            merc_start_diag.target_character,
            merc_start_diag.target_roster,
            merc_start_diag.target_base_kind,
            merc_start_diag.target_costume,
            merc_start_diag.target_kind_name,
            tostring(merc_start_diag.target_kind_value),
            tostring(merc_start_diag.ap_owned)
        ))
        if merc_start_diag.target_kind_value == nil then
            log.warn("[Merc VanillaDiag] target enum value unavailable; matching/intervention remains not observed")
        end
        return true
    end

    local function update_merc_start_diag()
        if not merc_start_diag.active then return end
        local elapsed = os.clock() - merc_start_diag.started_at
        if merc_start_diag.observation_open and elapsed >= MERC_START_DIAG_WINDOW_SECONDS then
            merc_start_diag.observation_open = false
            merc_start_diag.observation_closed_reason = "INCONCLUSIVE / observation window ended"
            log.info(string.format(
                "[Merc VanillaDiag] attempt=%d checkpoint=%s startGame_hook_observed=%s; retaining attempt correlation",
                merc_start_diag.attempt,
                merc_start_diag.observation_closed_reason,
                tostring(merc_start_diag.startGame_hook_observed)
            ))
        end
        if merc_start_diag.startGame_hook_observed and not merc_start_diag.run_observed then
            local controller = get_merc_controller()
            local identity = get_live_result_identity()
            if identity ~= nil then
                merc_start_diag.run_observed = true
                merc_start_diag.run_observation = "controller_identity"
            elseif controller ~= nil then
                merc_start_diag.run_observed = true
                merc_start_diag.run_observation = "controller_present_only"
            end
            if merc_start_diag.run_observed then
                log.info(string.format(
                    "[Merc VanillaDiag] attempt=%d run observation=%s (controller presence is not proof of playable gameplay)",
                    merc_start_diag.attempt, merc_start_diag.run_observation))
                finish_merc_start_diag("run_observed")
                return
            end
        end
        if elapsed >= MERC_START_DIAG_RETENTION_SECONDS then
            finish_merc_start_diag("INCONCLUSIVE / observation window ended")
        end
    end

    local function update_mercenaries_state()
        update_merc_start_diag()
        refresh_result_summary()
        local merc_manager = get_merc_manager()
        if merc_manager == nil then
            merc_state.last_is_result = false
            if merc_state.lifecycle ~= STATE_RESULT_CONSUMED then merc_state.lifecycle = STATE_IDLE end
            merc_state.last_valid_run_identity = nil
            merc_state.expected_result_identity = nil
            return
        end

        local is_result = get_safe_bool(merc_manager, "get_IsResult", merc_state.last_is_result)
        if is_result and not merc_state.last_is_result then
            merc_state.result_epoch = merc_state.result_epoch + 1
            merc_state.ready_result_epoch = -1
            merc_state.result_payload = nil
            -- Freeze identity captured during active gameplay. Do not query the
            -- controller at this edge: game transition can already have torn it down.
            merc_state.expected_result_identity = copy_result_identity(
                merc_state.last_valid_run_identity)
            merc_state.lifecycle = STATE_RESULT_PIPELINE
            log.info(string.format("[Merc AP] result pipeline entered: epoch=%d", merc_state.result_epoch))
        elseif not is_result then
            if merc_state.last_is_result then
                -- Result transition ends prior run. Do not reuse its identity for
                -- a later result; next active run repopulates cache.
                merc_state.last_valid_run_identity = nil
            elseif get_runtime_domain() == "MERCENARIES" then
                -- Only while the mode runs: in the campaign this used to scan
                -- the scene for the controller on every tick (2026-09-05
                -- review). A valid controller identity is authoritative;
                -- clear it only once the controller itself is gone. (The
                -- manager's get_Routine this once consulted never existed;
                -- that method is the controller's.)
                local live_identity = get_live_result_identity()
                if live_identity ~= nil then
                    merc_state.last_valid_run_identity = live_identity
                elseif get_merc_controller() == nil then
                    merc_state.last_valid_run_identity = nil
                end
            end
            merc_state.lifecycle = STATE_IDLE
            merc_state.result_payload = nil
            merc_state.expected_result_identity = nil
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

    local hooks_installed = false
    local hooked_functions = {}
    local decision_delegates = {}
    local decision_hooked_function_keys = {}
    local decision_unresolved_logged = false
    local decision_diag_restore_stack = {}
    local on_decided_pre
    local on_decided_post

    local DECISION_DELEGATE_TYPE =
        "System.Action`1<chainsaw.Cp1021CharacterSelectMenuActionType>"
    local DECISION_ACTION_TYPE = "chainsaw.Cp1021CharacterSelectMenuActionType"

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

    local function get_method_parameter_types(method)
        if method == nil then return nil end
        local raw_params = nil
        local ok = pcall(function() raw_params = method:get_param_types() end)
        if not ok or raw_params == nil then
            return nil
        end
        local params, _ = reflection_sequence_to_table(raw_params)
        return params
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

        return true
    end

    -- Native addresses are runtime data only: use them for hook dedupe/logging,
    -- never as semantic method validation.
    local function get_decision_function_key(method)
        if method == nil then return "nil", "nil" end
        local function_ptr = nil
        pcall(function() function_ptr = method:get_function() end)
        local native_int64 = nil
        if function_ptr ~= nil and pcall(function() native_int64 = sdk.to_int64(function_ptr) end)
            and native_int64 ~= nil then
            local hex_str = nil
            local ok_hex = pcall(function() hex_str = string.format("0x%X", native_int64) end)
            if ok_hex and type(hex_str) == "string" then
                return tostring(native_int64), hex_str
            end
            return tostring(native_int64), tostring(native_int64)
        end
        return tostring(method), tostring(function_ptr or method)
    end

    local function log_decision_unresolved(detail)
        if decision_unresolved_logged then return end
        decision_unresolved_logged = true
        log.warn("[Merc AP Gating] OnDecided Invoke unresolved; keeping vanilla character selection ("
            .. tostring(detail) .. ")")
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
        if invoke_method == nil then return false, "nil" end
        local function_key, function_log = get_decision_function_key(invoke_method)
        if decision_hooked_function_keys[function_key] then return true, function_log end
        local ok, hook_result = pcall(function()
            return sdk.hook(invoke_method, on_decided_pre, on_decided_post)
        end)
        if not ok or hook_result == false then
            return false, function_log
        end
        decision_hooked_function_keys[function_key] = true
        return true, function_log
    end

    on_decided_pre = function(args)
        local restore_record = { active = false }
        decision_diag_restore_stack[#decision_diag_restore_stack + 1] = restore_record

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
        if should_enforce_gating() then
            if not merc_start_diag.active or merc_start_diag.gui_id ~= get_obj_address_str(gui) then
                arm_merc_start_diag(gui)
            end
            if merc_start_diag.active and merc_start_diag.gui_id == get_obj_address_str(gui) then
                local selected = get_roster_identity(roster)
                merc_start_diag.selected_action = action
                merc_start_diag.selected_roster = roster
                merc_start_diag.selected_character = selected and selected.character or "Unknown"
                merc_start_diag.target_matches = roster == merc_start_diag.target_roster
                merc_start_diag.decided = get_safe_field_bool(gui, "_bDecided", nil)
                merc_start_diag.old_chara_unlock = get_safe_field_bool(gui, "_bOldCharaUnlock", nil)
                merc_start_diag.decision_callback_active = true
                log.info(string.format(
                    "[Merc VanillaDiag] attempt=%d confirm selected_action=%s selected_character=%s selected_roster=%s target_matches=%s",
                    merc_start_diag.attempt,
                    tostring(action),
                    tostring(merc_start_diag.selected_character),
                    tostring(merc_start_diag.selected_roster),
                    tostring(merc_start_diag.target_matches)))
            end
        end
        if vanilla_diag_emulation == "old_chara_locked"
            and merc_start_diag.active
            and merc_start_diag.target_matches == true
            and merc_start_diag.ap_owned == true
            and should_enforce_gating() then
            local original = read_direct_bool(gui, "_bOldCharaUnlock")
            local wrote = original ~= nil
                and pcall(function() gui:set_field("_bOldCharaUnlock", false) end)
                and read_direct_bool(gui, "_bOldCharaUnlock") == false
            if wrote then
                restore_record.active = true
                restore_record.gui = gui
                restore_record.gui_id = get_obj_address_str(gui)
                restore_record.original = original
                merc_start_diag.old_chara_restore = restore_record
                merc_start_diag.field_write_verified = true
                merc_start_diag.override_applied_count = merc_start_diag.override_applied_count + 1
                if not merc_start_diag.emulation_logged then
                    merc_start_diag.emulation_logged = true
                    log.info(string.format(
                        "[Merc VanillaDiag] emulation=old_chara_locked original=%s effective=false field_write_verified=true scope=OnDecided PRE->POST",
                        tostring(original)))
                end
            elseif not merc_start_diag.emulation_logged then
                merc_start_diag.emulation_logged = true
                merc_start_diag.field_write_verified = false
                log.error("[Merc VanillaDiag] emulation=old_chara_locked could not set _bOldCharaUnlock")
            end
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

    on_decided_post = function(retval)
        local restore_record = decision_diag_restore_stack[#decision_diag_restore_stack]
        decision_diag_restore_stack[#decision_diag_restore_stack] = nil
        if merc_start_diag.active then merc_start_diag.decision_callback_active = false end
        if restore_record ~= nil and restore_record.active then
            restore_merc_diag_old_unlock(restore_record)
            if not restore_record.active and merc_start_diag.old_chara_restore == restore_record then
                merc_start_diag.old_chara_restore = nil
            end
        end
        return retval
    end

    local function register_decision_delegate(gui)
        if gui == nil then return end
        local delegate = get_live_on_decided(gui)
        if delegate == nil then return end
        local delegate_type_name = get_obj_type_name(delegate)
        if delegate_type_name ~= DECISION_DELEGATE_TYPE then return end
        local delegate_id = get_obj_address_str(delegate)
        if decision_delegates[delegate_id] ~= nil and decision_delegates[delegate_id].gui == gui then
            return
        end

        local delegate_type = nil
        pcall(function() delegate_type = delegate:get_type_definition() end)
        if delegate_type == nil then
            log_decision_unresolved("failed to get delegate type definition")
            return
        end

        local ok_methods, methods_raw = pcall(function()
            return delegate_type:get_methods()
        end)

        local semantic_candidates = {}
        local resolution_mode = "enumerated"
        local methods_container_type = type(methods_raw)

        if ok_methods and methods_raw ~= nil then
            local methods_list, enum_err = reflection_sequence_to_table(methods_raw)
            if methods_list ~= nil then
                for _, method in ipairs(methods_list) do
                    local name = nil
                    pcall(function() name = method:get_name() end)
                    if name == "Invoke" and is_exact_decision_invoke(method) then
                        semantic_candidates[#semantic_candidates + 1] = method
                    end
                end
                if #semantic_candidates == 0 then
                    local fallback_method = nil
                    local ok_fb = pcall(function()
                        fallback_method = delegate_type:get_method(
                            "Invoke(" .. DECISION_ACTION_TYPE .. ")"
                        )
                    end)
                    if ok_fb and fallback_method ~= nil and is_exact_decision_invoke(fallback_method) then
                        semantic_candidates[#semantic_candidates + 1] = fallback_method
                        resolution_mode = "prototype_fallback"
                    else
                        log_decision_unresolved("no semantic Invoke candidate")
                        return
                    end
                end
            else
                local fallback_method = nil
                local ok_fb = pcall(function()
                    fallback_method = delegate_type:get_method(
                        "Invoke(" .. DECISION_ACTION_TYPE .. ")"
                    )
                end)
                if ok_fb and fallback_method ~= nil and is_exact_decision_invoke(fallback_method) then
                    semantic_candidates[#semantic_candidates + 1] = fallback_method
                    resolution_mode = "prototype_fallback"
                else
                    log_decision_unresolved("sequence iteration error: " .. tostring(enum_err))
                    return
                end
            end
        else
            local fallback_method = nil
            local ok_fb = pcall(function()
                fallback_method = delegate_type:get_method(
                    "Invoke(" .. DECISION_ACTION_TYPE .. ")"
                )
            end)
            if ok_fb and fallback_method ~= nil and is_exact_decision_invoke(fallback_method) then
                semantic_candidates[#semantic_candidates + 1] = fallback_method
                resolution_mode = "prototype_fallback"
            else
                local err_reason = not ok_methods and ("get_methods pcall error: " .. tostring(methods_raw))
                    or "get_methods returned nil"
                log_decision_unresolved(err_reason)
                return
            end
        end

        local semantic_count = #semantic_candidates
        local unique_targets_by_key = {}
        local target_keys_order = {}
        for _, method in ipairs(semantic_candidates) do
            local function_key, function_log = get_decision_function_key(method)
            if unique_targets_by_key[function_key] == nil then
                unique_targets_by_key[function_key] = {
                    method = method,
                    log_name = function_log,
                    count = 1,
                }
                target_keys_order[#target_keys_order + 1] = function_key
            else
                unique_targets_by_key[function_key].count = unique_targets_by_key[function_key].count + 1
            end
        end

        local unique_targets = #target_keys_order
        local hooks_ready = 0
        local diag_functions = {}
        local hook_errors = {}

        for _, key in ipairs(target_keys_order) do
            local target = unique_targets_by_key[key]
            local ok_hook, fn_log = install_decision_invoke_hook(target.method)
            if ok_hook then
                hooks_ready = hooks_ready + 1
                diag_functions[#diag_functions + 1] = fn_log
            else
                hook_errors[#hook_errors + 1] = fn_log
            end
        end

        if hooks_ready < 1 then
            local err_detail = "no semantic Invoke target could be hooked"
            if #hook_errors > 0 then
                err_detail = err_detail .. " (failed: " .. table.concat(hook_errors, ", ") .. ")"
            end
            log_decision_unresolved(err_detail)
            return
        end

        decision_delegates[delegate_id] = { delegate = delegate, gui = gui }

        local diag_str = #diag_functions > 0 and (" functions=" .. table.concat(diag_functions, ",")) or ""
        log.info(string.format(
            "[Merc AP Gating] OnDecided Invoke hooks ready: methods_container=%s semantic_methods=%d unique_functions=%d hooks_ready=%d resolution=%s%s",
            methods_container_type, semantic_count, unique_targets, hooks_ready, resolution_mode, diag_str
        ))
    end

    local function is_exact_diag_method(method, name, is_static, parameter_types, return_type)
        if method == nil then return false end
        local actual_name = nil
        pcall(function() actual_name = method:get_name() end)
        if actual_name ~= name then return false end

        local ok_static, actual_static = pcall(function() return method:is_static() end)
        if not ok_static or actual_static ~= is_static then return false end

        local ok_count, count = pcall(function() return method:get_num_params() end)
        if not ok_count or count ~= #parameter_types then return false end
        local actual_parameters = get_method_parameter_types(method)
        if type(actual_parameters) ~= "table" or #actual_parameters ~= #parameter_types then return false end
        for index, expected in ipairs(parameter_types) do
            if get_type_full_name(actual_parameters[index]) ~= expected then return false end
        end

        local actual_return = nil
        local ok_return = pcall(function() actual_return = method:get_return_type() end)
        if not ok_return then return false end
        actual_return = get_type_full_name(actual_return)
        if return_type == "CampaignInitialSettingKey" then
            return type(actual_return) == "string"
                and actual_return:sub(-#return_type) == return_type
        end
        return actual_return == return_type
    end

    local function hook_exact_diag_method(type_name, signature, validator, pre, post)
        local type_def = sdk.find_type_definition(type_name)
        if type_def == nil then
            log.warn("[Merc VanillaDiag] hook unavailable: " .. signature .. " (type not found)")
            return false
        end
        local methods = nil
        local ok_methods, raw_methods = pcall(function() return type_def:get_methods() end)
        if ok_methods then methods = reflection_sequence_to_table(raw_methods) end
        local matches = {}
        for _, method in ipairs(methods or {}) do
            if validator(method) then matches[#matches + 1] = method end
        end
        if #matches ~= 1 or not safe_hook_unique(matches[1], pre, post) then
            log.warn(string.format(
                "[Merc VanillaDiag] hook unavailable: %s (semantic_matches=%d)", signature, #matches))
            return false
        end
        log.info("[Merc VanillaDiag] hook ready: " .. signature)
        return true
    end

    local function install_merc_start_diag_hooks()
        local character_action_type = "chainsaw.Cp1021CharacterSelectMenuActionType"
        local stage_action_type = "chainsaw.Cp1021StageSelectMenuActionType"
        local character_kind_type = "chainsaw.MercenariesDefine.PlayerCharacterWithCostumeKind"

        hook_exact_diag_method(
            "chainsaw.GameStateMSMainMenu",
            "GameStateMSMainMenu.onDecidedCharacterSelectMenu(Cp1021CharacterSelectMenuActionType)",
            function(method)
                return is_exact_diag_method(method, "onDecidedCharacterSelectMenu", false,
                    { character_action_type }, "System.Void")
            end,
            function(args)
                if not merc_start_diag.active then return sdk.PreHookResult.CALL_ORIGINAL end
                local selected = decode_action(args[3])
                local roster = selected == merc_start_diag.selected_action and merc_start_diag.selected_roster or nil
                merc_start_diag.main_menu_callback = true
                log.info(string.format(
                    "[Merc VanillaDiag] attempt=%d main-menu decision selected=%s character=%s roster=%s kind=%s",
                    merc_start_diag.attempt,
                    tostring(selected),
                    tostring(roster and ROSTER_INDEX_TO_NAME[roster] or "Unknown"),
                    tostring(roster),
                    tostring(roster and ROSTER_INDEX_TO_KIND_NAME[roster] or "Unknown")
                ))
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)

        local vanilla_query_stack = {}
        hook_exact_diag_method(
            "chainsaw.InfoSaveData1021",
            "InfoSaveData1021.isUnlock(PlayerCharacterWithCostumeKind): Boolean",
            function(method)
                return is_exact_diag_method(method, "isUnlock", false,
                    { character_kind_type }, "System.Boolean")
            end,
            function(args)
                vanilla_query_stack[#vanilla_query_stack + 1] = {
                    attempt = merc_start_diag.active and merc_start_diag.attempt or -1,
                    kind = decode_action(args[3]),
                    phase = merc_start_diag.decision_callback_active
                        and "during_decision_callback"
                        or (merc_start_diag.selected_roster ~= nil and "during_transition" or "before_confirmation"),
                }
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                local query = vanilla_query_stack[#vanilla_query_stack]
                vanilla_query_stack[#vanilla_query_stack] = nil
                local kind = query and query.kind or nil
                if query == nil or not merc_start_diag.active
                    or query.attempt ~= merc_start_diag.attempt
                    or type(kind) ~= "number" or kind < 0 or kind > 7 then
                    return retval
                end
                local result = nil
                pcall(function() result = sdk.to_int64(retval) ~= 0 end)
                if result == nil then return retval end
                local target_matches = merc_start_diag.target_kind_value ~= nil
                    and kind == merc_start_diag.target_kind_value
                if target_matches then
                    merc_start_diag.relevant_query_count = merc_start_diag.relevant_query_count + 1
                    if query.phase == "before_confirmation" then
                        merc_start_diag.pre_confirm_queries = merc_start_diag.pre_confirm_queries + 1
                    elseif query.phase == "during_decision_callback" then
                        merc_start_diag.decision_queries = merc_start_diag.decision_queries + 1
                    else
                        merc_start_diag.transition_queries = merc_start_diag.transition_queries + 1
                    end
                end
                local emulate_lock = vanilla_diag_emulation == "infosave_locked"
                    and target_matches
                    and merc_start_diag.target_matches == true
                    and merc_start_diag.ap_owned == true
                    and should_enforce_gating()
                local effective_result = emulate_lock and false or result
                if emulate_lock then
                    merc_start_diag.override_applied_count = merc_start_diag.override_applied_count + 1
                    if not merc_start_diag.emulation_logged then
                        merc_start_diag.emulation_logged = true
                        log.info(string.format(
                            "[Merc VanillaDiag] emulation=infosave_locked target=%s kind=%s original=%s effective=false phase=%s",
                            merc_start_diag.target_character,
                            merc_start_diag.target_kind_name,
                            tostring(result),
                            query.phase))
                    end
                end
                if target_matches then
                    local key = string.format("%d|%s|%s", kind, tostring(result), tostring(effective_result))
                    if not merc_start_diag.vanilla_query_keys[key] then
                        merc_start_diag.vanilla_query_keys[key] = true
                        merc_start_diag.vanilla_queries[#merc_start_diag.vanilla_queries + 1] = {
                            kind = kind,
                            phase = query.phase,
                            original = result,
                            effective = effective_result,
                        }
                        log.info(string.format(
                            "[Merc VanillaDiag] attempt=%d vanilla unlock query phase=%s kind=%s raw=%d original=%s effective=%s",
                            merc_start_diag.attempt,
                            query.phase,
                            merc_start_diag.target_kind_name,
                            kind,
                            tostring(result),
                            tostring(effective_result)
                        ))
                    end
                end
                if target_matches and merc_start_diag.target_matches == true then
                    merc_start_diag.selected_vanilla_unlock = effective_result
                end
                if emulate_lock then return sdk.to_ptr(0) end
                return retval
            end)

        local initial_settings_stack = {}
        hook_exact_diag_method(
            "chainsaw.Cp1021GuiDataDefine",
            "Cp1021GuiDataDefine.getInitialSettingsKey(StageAction, CharacterAction): CampaignInitialSettingKey",
            function(method)
                return is_exact_diag_method(method, "getInitialSettingsKey", true,
                    { stage_action_type, character_action_type }, "CampaignInitialSettingKey")
            end,
            function(args)
                initial_settings_stack[#initial_settings_stack + 1] = {
                    attempt = merc_start_diag.active and merc_start_diag.attempt or -1,
                    stage = decode_action(args[2]),
                    selected = decode_action(args[3]),
                }
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                local query = initial_settings_stack[#initial_settings_stack]
                initial_settings_stack[#initial_settings_stack] = nil
                if query == nil or not merc_start_diag.active
                    or query.attempt ~= merc_start_diag.attempt then
                    return retval
                end
                local settings_key = decode_action(retval)
                local roster = query.selected == merc_start_diag.selected_action
                    and merc_start_diag.selected_roster or nil
                merc_start_diag.initial_settings[#merc_start_diag.initial_settings + 1] = {
                    stage = query.stage,
                    selected = query.selected,
                    settings_key = settings_key,
                }
                log.info(string.format(
                    "[Merc VanillaDiag] attempt=%d initial settings stage=%s selected=%s character=%s roster=%s kind=%s key=%s",
                    merc_start_diag.attempt,
                    tostring(query.stage),
                    tostring(query.selected),
                    tostring(roster and ROSTER_INDEX_TO_NAME[roster] or "Unknown"),
                    tostring(roster),
                    tostring(roster and ROSTER_INDEX_TO_KIND_NAME[roster] or "Unknown"),
                    tostring(settings_key)
                ))
                return retval
            end)

        hook_exact_diag_method(
            "chainsaw.MercenariesModeController",
            "MercenariesModeController.startGame(): Void",
            function(method)
                return is_exact_diag_method(method, "startGame", false, {}, "System.Void")
            end,
            function(_)
                if merc_start_diag.active then
                    merc_start_diag.start_game = true
                    merc_start_diag.startGame_hook_observed = true
                    log.info(string.format(
                        "[Merc VanillaDiag] attempt=%d startGame reached", merc_start_diag.attempt))
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end)
    end

    -- ------------------------------------------------------------------
    -- [Menu unlock answers] The stage and character select screens ask whether
    -- each entry is unlocked, and the NAME and the big preview panel follow
    -- whatever they are told. Their artwork does not: see the [Menu art] block
    -- below for that, which took two builds of wrong guesses to find.
    --
    -- Hooked and then removed on 2026-09-07, because a live visit proved each
    -- one installs and is then never called: Cp1021GuiManager.IsUnlock (both
    -- overloads), Cp1021MainMenuBGGuiBehavior.isUnlock, and the
    -- UnlockSettingsUserData pair. Do not add them back without a log line
    -- showing them run.
    --
    -- Menu action enums, from the il2cpp dump: a character action is Exit 0
    -- then Character01.. at 1..8, so the character kind is the action less one.
    local STAGE_KIND_MAX = 3
    local CHARACTER_KIND_MAX = 7

    -- One line per distinct answer, so a single visit to both menus says who
    -- asked, about what, and whether we changed the answer. The key carries
    -- both answers, so an unlock arriving later logs a fresh line by itself and
    -- there is nothing to reset.
    local unlock_answer_logged = {}
    local function log_unlock_answer(source, what, kind, vanilla, ours)
        local key = string.format("%s|%s|%d|%s|%s", source, what, kind,
            tostring(vanilla), tostring(ours))
        if unlock_answer_logged[key] then return end
        unlock_answer_logged[key] = true
        log.info(string.format(
            "[Merc AP Gating] %s asked about %s %d: game said %s, AP says %s%s",
            source, what, kind, tostring(vanilla), tostring(ours),
            (vanilla ~= ours) and " (changed)" or ""))
    end
    -- ------------------------------------------------------------------
    -- [Menu art] MOD -128 answered every unlock question the menus ask, and
    -- the NAME and the big preview panel followed. The tile art and the two
    -- portrait strips did not: after that build Docks still showed a padlock,
    -- and the only greyed-out character in either strip was Hunk, who is the
    -- one character Cam's SAVE has not unlocked (Cam, 2026-09-07).
    --
    -- The log says why the extra hooks did nothing: Cp1021GuiManager.IsUnlock
    -- and Cp1021MainMenuBGGuiBehavior.isUnlock installed and were never once
    -- called, and neither was the UnlockSettingsUserData pair. The art asks
    -- nothing we can answer, so this reaches the art itself instead.
    --
    -- Two of these take the lock state as a writable input and are corrected
    -- outright; the rest only report, because their vocabulary is unknown
    -- until a menu visit prints it. Every line is logged once per distinct
    -- observation, and says whether it reports or corrects.
    local CHARACTER_ACTION_OFFSET = 1  -- Exit 0, then Character01.. at 1..8

    local art_logged = {}
    local function log_art(key, message)
        if art_logged[key] then return end
        art_logged[key] = true
        log.info("[Merc AP Art] " .. message)
    end

    -- A menu action is not a kind. Translating here rather than through
    -- getKindId keeps the two overloads of that name out of it. The stage side
    -- needs no such helper: its tiles are corrected by array index, which is
    -- already the kind.
    local function character_kind_of_action(action)
        if type(action) ~= "number" then return -1 end
        return action - CHARACTER_ACTION_OFFSET
    end

    local function ap_says_stage(kind)
        if kind < 0 or kind > STAGE_KIND_MAX then return nil end
        return is_stage_owned(kind) and true or false
    end
    local function ap_says_character(kind)
        if kind < 0 or kind > CHARACTER_KIND_MAX then return nil end
        return is_character_owned(kind) and true or false
    end

    -- [Menu art, round 2] Both portrait strips keep TWO pieces of art per
    -- character and pick one: the character screen's strip has SelectTextureId
    -- and SelectLockTextureId, and the stage screen's records row has
    -- UVSettingDefault and UVSettingLock. The picking is done by something that
    -- asks nothing we can hook, which is why -128 and -129 left both strips
    -- reading the save (Cam, 2026-09-07: the only greyed-out face was Hunk, the
    -- one character his save has not unlocked).
    --
    -- So stop trying to influence the choice. Set BOTH halves of the pair to
    -- the art Archipelago says is right, and whichever the game reaches for is
    -- the correct one. The pristine values are kept from the first sighting, so
    -- this stays correct when an unlock arrives later and never compounds.
    local art_originals = {}
    local function original_pair(owner, key, read_a, read_b)
        local id = get_obj_address_str(owner) .. "|" .. tostring(key)
        local kept = art_originals[id]
        if kept == nil then
            kept = { unlocked = read_a(), locked = read_b() }
            art_originals[id] = kept
        end
        return kept
    end

    local function answer_unlock(source, what, kind, retval)
        local vanilla = nil
        pcall(function() vanilla = sdk.to_int64(retval) ~= 0 end)
        local ours
        if what == "stage" then
            if kind < 0 or kind > STAGE_KIND_MAX then return retval end
            ours = is_stage_owned(kind) and true or false
        else
            if kind < 0 or kind > CHARACTER_KIND_MAX then return retval end
            ours = is_character_owned(kind) and true or false
        end
        log_unlock_answer(source, what, kind, vanilla, ours)
        return sdk.to_ptr(ours and 1 or 0)
    end

    local is_unlock_query_stack = {}
    local function on_is_unlock_pre(args)
        local this_object = nil
        pcall(function() this_object = sdk.to_managed_object(args[2]) end)
        local raw_arg = decode_action(args[3]) or -1
        is_unlock_query_stack[#is_unlock_query_stack + 1] = { this = this_object, arg = raw_arg }
        if get_obj_type_name(this_object) == "chainsaw.Cp1021CharacterSelectGuiBehavior" then
            register_decision_delegate(this_object)
            if should_enforce_gating() and vanilla_diag_target ~= nil
                and (not merc_start_diag.active
                    or merc_start_diag.gui_id ~= get_obj_address_str(this_object)) then
                arm_merc_start_diag(this_object)
            end
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
            if kind >= 0 then return answer_unlock("CharacterSetting", "character", kind, retval) end
        elseif type_name == "chainsaw.Cp1021UnlockSettingsUserData.StageSetting" then
            local kind = get_safe_field_int(query.this, "KindId", -1)
            if kind < 0 then kind = get_safe_int(query.this, "get_KindId", -1) end
            if kind >= 0 then return answer_unlock("StageSetting", "stage", kind, retval) end
        elseif type_name == "chainsaw.Cp1021CharacterSelectGuiBehavior" and query.arg >= 0 then
            local ok_kind, kind = pcall(function() return query.this:call("getCharacterKind", query.arg) end)
            if ok_kind and type(kind) == "number" and kind >= 0 then
                return answer_unlock("CharacterSelectGui", "character", kind, retval)
            end
        elseif type_name == "chainsaw.Cp1021StageSelectGuiBehavior" and query.arg >= 0 then
            local ok_kind, kind = pcall(function() return query.this:call("getKindId", query.arg) end)
            if ok_kind and type(kind) == "number" and kind >= 0 then
                return answer_unlock("StageSelectGui", "stage", kind, retval)
            end
        end
        return retval
    end

    local function install_merc_virtual_gating_hooks()
        if hooks_installed then return end
        install_merc_start_diag_hooks()
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

        -- [Menu art] Reach the functions that actually paint the tiles and the
        -- portrait strips. MOD -128 answered every unlock question the menus
        -- ask and the NAME and the big preview followed, but the tiles and both
        -- portrait strips did not: Docks still showed a padlock, and the only
        -- greyed-out character was Hunk, the one character Cam's SAVE has not
        -- unlocked (Cam, 2026-09-07). The log said why: Cp1021GuiManager and
        -- Cp1021MainMenuBGGuiBehavior installed and were never once called.
        --
        -- Two of these take the lock state as a writable input and are
        -- corrected outright. The rest only report, because their vocabulary is
        -- not in the dump and inventing a state name that does not exist would
        -- leave a panel with no state at all.
        local function hook_by_name(type_name, method_name, pre, post)
            local type_def = sdk.find_type_definition(type_name)
            if type_def == nil then
                log.info("[Merc AP Art] type not found: " .. type_name)
                return false
            end
            local found = false
            for _, method in ipairs(type_def:get_methods() or {}) do
                local name = nil
                pcall(function() name = method:get_name() end)
                if name == method_name then
                    found = safe_hook_unique(method, pre, post) or found
                end
            end
            if not found then
                log.info(string.format("[Merc AP Art] %s.%s not hooked", type_name, method_name))
            end
            return found
        end

        -- The stage tiles. PanelStage.Param is { bUnlock, uvSetting }, one per
        -- tile, and both of these are handed the array.
        local function correct_stage_params(params, source)
            if params == nil then return end
            local size = nil
            pcall(function() size = params:get_size() end)
            if type(size) ~= "number" then
                log_art(source .. "|noarray", source .. ": the Param array could not be read")
                return
            end
            for index = 0, size - 1 do
                local param = nil
                pcall(function() param = params:get_element(index) end)
                if param ~= nil then
                    local was = nil
                    pcall(function() was = param:get_field("bUnlock") end)
                    -- The array is in menu order, which is stage kind order.
                    local ours = ap_says_stage(index)
                    if ours ~= nil then
                        pcall(function() param:set_field("bUnlock", ours) end)
                        local now = nil
                        pcall(function() now = param:get_field("bUnlock") end)
                        log_art(string.format("%s|%d|%s|%s", source, index, tostring(was), tostring(now)),
                            string.format("%s tile %d: was %s, set %s, reads %s",
                                source, index, tostring(was), tostring(ours), tostring(now)))
                    end
                end
            end
        end

        hook_by_name("chainsaw.Cp1021StageSelectGuiBehavior.PanelStage", "set", function(args)
            if not should_enforce_gating() then return sdk.PreHookResult.CALL_ORIGINAL end
            pcall(function() correct_stage_params(sdk.to_managed_object(args[4]), "PanelStage.set") end)
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval) return retval end)

        hook_by_name("chainsaw.Cp1021StageSelectGuiBehavior.PanelStage", "setStageTexture", function(args)
            if not should_enforce_gating() then return sdk.PreHookResult.CALL_ORIGINAL end
            pcall(function() correct_stage_params(sdk.to_managed_object(args[3]), "setStageTexture") end)
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval) return retval end)

        -- The character screen's strip: align SelectTextureId with
        -- SelectLockTextureId on every Setting the userdata carries.
        local function align_character_textures(gui)
            local userdata = nil
            pcall(function() userdata = gui:get_field("_UserData") end)
            if userdata == nil then
                log_art("chara_userdata", "character select: _UserData could not be read")
                return
            end
            local settings = nil
            pcall(function() settings = userdata:get_field("Settings") end)
            local size = nil
            pcall(function() size = settings:get_size() end)
            if type(size) ~= "number" then
                log_art("chara_settings", "character select: Settings could not be read")
                return
            end
            for index = 0, size - 1 do
                local setting = nil
                pcall(function() setting = settings:get_element(index) end)
                if setting ~= nil then
                    local action = nil
                    pcall(function() action = setting:get_field("Character") end)
                    local kind = character_kind_of_action(tonumber(action))
                    local ours = ap_says_character(kind)
                    if ours ~= nil then
                        local kept = original_pair(setting, "tex",
                            function()
                                local v = nil
                                pcall(function() v = setting:get_field("SelectTextureId") end)
                                return v
                            end,
                            function()
                                local v = nil
                                pcall(function() v = setting:get_field("SelectLockTextureId") end)
                                return v
                            end)
                        local want = ours and kept.unlocked or kept.locked
                        if want ~= nil then
                            pcall(function() setting:set_field("SelectTextureId", want) end)
                            pcall(function() setting:set_field("SelectLockTextureId", want) end)
                            log_art(string.format("tex|%d|%s", kind, tostring(ours)),
                                string.format(
                                    "character %d: AP says %s, both strip textures set to the %s art (%s/%s)",
                                    kind, tostring(ours), ours and "unlocked" or "locked",
                                    tostring(kept.unlocked), tostring(kept.locked)))
                        end
                    end
                end
            end
        end

        hook_by_name("chainsaw.Cp1021CharacterSelectGuiBehavior", "updateSelectCharacterList",
            function(args)
                if not should_enforce_gating() then return sdk.PreHookResult.CALL_ORIGINAL end
                pcall(function() align_character_textures(sdk.to_managed_object(args[2])) end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)

        hook_by_name("chainsaw.Cp1021CharacterSelectGuiBehavior", "setup",
            function(args)
                if not should_enforce_gating() then return sdk.PreHookResult.CALL_ORIGINAL end
                pcall(function() align_character_textures(sdk.to_managed_object(args[2])) end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)

        -- The stage screen's records row: same idea, but the pair is a UV
        -- setting rather than a texture id.
        local function align_record_uvs(gui)
            local datas = nil
            pcall(function() datas = gui:get_field("_UserDatas") end)
            local outer = nil
            pcall(function() outer = datas:get_size() end)
            if type(outer) ~= "number" then
                log_art("record_userdata", "stage select: _UserDatas could not be read")
                return
            end
            for d = 0, outer - 1 do
                local userdata = nil
                pcall(function() userdata = datas:get_element(d) end)
                local settings = nil
                if userdata ~= nil then
                    pcall(function() settings = userdata:get_field("CharacterSettings") end)
                end
                local size = nil
                pcall(function() size = settings:get_size() end)
                if type(size) == "number" then
                    for index = 0, size - 1 do
                        local setting = nil
                        pcall(function() setting = settings:get_element(index) end)
                        if setting ~= nil then
                            local action = nil
                            pcall(function() action = setting:get_field("Character") end)
                            local kind = character_kind_of_action(tonumber(action))
                            local ours = ap_says_character(kind)
                            if ours ~= nil then
                                local kept = original_pair(setting, "uv",
                                    function()
                                        local v = nil
                                        pcall(function() v = setting:get_field("UVSettingDefault") end)
                                        return v
                                    end,
                                    function()
                                        local v = nil
                                        pcall(function() v = setting:get_field("UVSettingLock") end)
                                        return v
                                    end)
                                local want = ours and kept.unlocked or kept.locked
                                if want ~= nil then
                                    pcall(function() setting:set_field("UVSettingDefault", want) end)
                                    pcall(function() setting:set_field("UVSettingLock", want) end)
                                    log_art(string.format("uvpair|%d|%s", kind, tostring(ours)),
                                        string.format(
                                            "records character %d: AP says %s, both UV settings set to the %s art",
                                            kind, tostring(ours), ours and "unlocked" or "locked"))
                                end
                            end
                        end
                    end
                end
            end
        end

        -- The records row's own params carry a bUnlock that greys the score.
        hook_by_name("chainsaw.Cp1021StageSelectGuiBehavior.PanelRecord", "setRecord",
            function(args)
                if not should_enforce_gating() then return sdk.PreHookResult.CALL_ORIGINAL end
                pcall(function()
                    local list = sdk.to_managed_object(args[3])
                    if list == nil then return end
                    local count = list:call("get_Count")
                    if type(count) ~= "number" then
                        log_art("record_list", "PanelRecord.setRecord: the Param list could not be read")
                        return
                    end
                    for index = 0, count - 1 do
                        local param = list:call("get_Item", index)
                        if param ~= nil then
                            local action = nil
                            pcall(function() action = param:get_field("Character") end)
                            local kind = character_kind_of_action(tonumber(action))
                            local ours = ap_says_character(kind)
                            if ours ~= nil then
                                local was = nil
                                pcall(function() was = param:get_field("bUnlock") end)
                                pcall(function() param:set_field("bUnlock", ours) end)
                                local now = nil
                                pcall(function() now = param:get_field("bUnlock") end)
                                log_art(string.format("record|%d|%s|%s", kind, tostring(was), tostring(now)),
                                    string.format("records character %d: bUnlock was %s, set %s, reads %s",
                                        kind, tostring(was), tostring(ours), tostring(now)))
                            end
                        end
                    end
                end)
                return sdk.PreHookResult.CALL_ORIGINAL
            end, function(retval) return retval end)

        hook_by_name("chainsaw.Cp1021StageSelectGuiBehavior", "setRecord", function(args)
            if not should_enforce_gating() then return sdk.PreHookResult.CALL_ORIGINAL end
            pcall(function() align_record_uvs(sdk.to_managed_object(args[2])) end)
            return sdk.PreHookResult.CALL_ORIGINAL
        end, function(retval) return retval end)

        -- [Result screen] The screen's _UnlockNoticeList is ours while the
        -- gate is armed: the vanilla "unlocked <character> / <stage>" lines
        -- (a lie under AP, live 2026-09-05) come out and this run's own
        -- lines go in, before each step of the screen runs. See
        -- maintain_result_notice_list. The profile's unlock records
        -- (unlockCharacter / unlockStage) are left alone.
        local result_type = sdk.find_type_definition("chainsaw.Cp1021GameClearResultGuiBehavior")
        if result_type ~= nil then
            local late_update = nil
            pcall(function() late_update = result_type:get_method("lateUpdateOnActive") end)
            if late_update ~= nil then
                safe_hook_unique(late_update, function(args)
                    if not should_enforce_gating() then return sdk.PreHookResult.CALL_ORIGINAL end
                    pcall(function()
                        local gui = sdk.to_managed_object(args[2])
                        if gui == nil then return end
                        local notices = gui:get_field("_UnlockNoticeList")
                        if notices == nil then return end
                        local step = nil
                        pcall(function() step = tonumber(gui:call("get_CurrStep")) end)
                        maintain_result_notice_list(notices, step)
                    end)
                    return sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval) return retval end)
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
