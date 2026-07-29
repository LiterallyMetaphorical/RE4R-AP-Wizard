local function install(ctx)
    ctx.runtime = ctx.runtime or {}
    local type_cache = {}

    local function cached_typeof(type_name)
        if type_cache[type_name] == nil then
            type_cache[type_name] = sdk.typeof(type_name)
        end
        return type_cache[type_name]
    end

    local function safe_call(target, method_name, ...)
        if target == nil then
            return nil
        end

        local args = { ... }
        local ok, result = pcall(function()
            return target:call(method_name, table.unpack(args))
        end)
        if ok then
            return result
        end

        return nil
    end

    local function safe_call_bool(target, method_names)
        if type(method_names) == "string" then
            method_names = { method_names }
        end

        for _, method_name in ipairs(method_names) do
            local result = safe_call(target, method_name)
            if type(result) == "boolean" then
                return result
            end
        end

        return nil
    end

    local function get_scene_object()
        local scene_manager = sdk.get_native_singleton("via.SceneManager")
        local scene_manager_type = sdk.find_type_definition("via.SceneManager")
        if scene_manager == nil or scene_manager_type == nil then
            return nil
        end

        return sdk.call_native_func(scene_manager, scene_manager_type, "get_CurrentScene")
    end

    local function get_components(types)
        local scene_object = get_scene_object()
        if scene_object == nil then
            return {}
        end

        if type(types) == "string" then
            local component_type = cached_typeof(types)
            if component_type == nil then
                return {}
            end
            return scene_object:call("findComponents", component_type) or {}
        end

        if type(types) ~= "table" then
            return {}
        end

        local results = {}
        local seen = {}
        for _, type_name in ipairs(types) do
            local component_type = cached_typeof(type_name)
            if component_type ~= nil then
                local components = scene_object:call("findComponents", component_type) or {}
                for _, component in ipairs(components) do
                    local address = nil
                    local ok, res = pcall(function()
                        return component:get_address()
                    end)
                    if ok and res ~= nil then
                        address = tostring(res)
                    else
                        address = tostring(component)
                    end
                    if not seen[address] then
                        table.insert(results, component)
                        seen[address] = true
                    end
                end
            end
        end
        return results
    end

    local function get_game_object_guid(game_object)
        if game_object == nil then
            return nil
        end

        local ok, object_string = pcall(function()
            return game_object:call("ToString()")
        end)
        if not ok or type(object_string) ~= "string" then
            return nil
        end

        local guid = object_string:match("@(.-)%]")
        return normalize_guid(guid)
    end

    local function get_component(game_object, type_name)
        if game_object == nil then
            return nil
        end

        local type_object = cached_typeof(type_name)
        if type_object == nil then
            return nil
        end

        local ok_component, component = pcall(function()
            return game_object:call("getComponent(System.Type)", type_object)
        end)
        if ok_component then
            return component
        end

        return nil
    end

    local function get_parent_game_object(game_object)
        if game_object == nil then
            return nil
        end

        local ok_parent, parent_game_object = pcall(function()
            local transform = game_object:call("get_Transform()")
            local parent_transform = transform ~= nil and transform:call("get_Parent()") or nil
            return parent_transform ~= nil and parent_transform:call("get_GameObject()") or nil
        end)
        if ok_parent then
            return parent_game_object
        end

        return nil
    end

    local function get_scene_name(scene_object)
        if scene_object == nil then
            return nil
        end

        local ok, scene_name = pcall(function()
            return scene_object:get_Name()
        end)
        if ok and type(scene_name) == "string" then
            return scene_name
        end

        return nil
    end

    local function get_master_object(object_name)
        local scene_object = get_scene_object()
        if scene_object == nil then
            return nil
        end

        local masters = scene_object:findGameObjectsWithTag("Masters")
        if masters == nil then
            return nil
        end

        for _, master in pairs(masters) do
            if master ~= nil and master:get_Name() == object_name then
                return master
            end
        end

        return nil
    end

    local function get_main_flow_manager()
        local game_master = get_master_object("30_GameMaster")
        if game_master == nil then
            return nil
        end

        local type_name = sdk.game_namespace("gamemastering.MainFlowManager")
        local type_definition = sdk.typeof(type_name)
        if type_definition == nil then
            return nil
        end

        local ok, main_flow_manager = pcall(function()
            return game_master:call("getComponent(System.Type)", type_definition)
        end)
        if ok then
            return main_flow_manager
        end

        return nil
    end

    local function get_player_info()
        local character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
        if character_manager == nil then
            return nil
        end

        local ok_player, player = pcall(function()
            return character_manager:getPlayerContextRef()
        end)
        if not ok_player or player == nil then
            return nil
        end

        local ok_body, body = pcall(function()
            return player:get_BodyGameObject()
        end)
        if not ok_body or body == nil then
            return nil
        end

        local ok_stage, stage = pcall(function()
            return player:get_CurrentStageID()
        end)
        if not ok_stage or type(stage) ~= "number" then
            stage = nil
        end

        return {
            context = player,
            stage = stage,
        }
    end

    local function get_player_position()
        local player_info = get_player_info()
        if player_info == nil or player_info.context == nil then
            return nil
        end

        local ok_body, body = pcall(function()
            return player_info.context:get_BodyGameObject()
        end)
        if not ok_body or body == nil then
            return nil
        end

        local ok_transform, transform = pcall(function()
            return body:get_Transform()
        end)
        if not ok_transform or transform == nil then
            return nil
        end

        local ok_pos, pos = pcall(function()
            return transform:get_Position()
        end)
        if not ok_pos or pos == nil then
            return nil
        end

        return pos
    end

    local function get_player_transform()
        local player_info = get_player_info()
        if player_info == nil or player_info.context == nil then
            return nil
        end

        local ok_body, body = pcall(function()
            return player_info.context:get_BodyGameObject()
        end)
        if not ok_body or body == nil then
            return nil
        end

        local ok_transform, transform = pcall(function()
            return body:get_Transform()
        end)
        if not ok_transform or transform == nil then
            return nil
        end

        return transform
    end

    local function set_player_position(x, y, z)
        local transform = get_player_transform()
        if transform == nil then
            return false
        end

        local ok_pos, pos = pcall(function()
            return transform:get_Position()
        end)
        if not ok_pos or pos == nil then
            return false
        end

        pos.x = tonumber(x) or pos.x
        pos.y = tonumber(y) or pos.y
        pos.z = tonumber(z) or pos.z

        local ok_set = pcall(function()
            transform:set_Position(pos)
        end)
        return ok_set
    end

    local function get_runtime_state()
        local player_info = get_player_info()
        local main_flow_manager = get_main_flow_manager()
        local scene_object = get_scene_object()

        local is_in_game = safe_call_bool(main_flow_manager, { "get_IsInGame" })
        if is_in_game == nil then
            is_in_game = player_info ~= nil
        end

        local is_title_screen = safe_call_bool(main_flow_manager, { "get_IsInTitle" }) or false
        local is_paused = safe_call_bool(main_flow_manager, { "get_IsInPause" }) or false
        local is_loading = safe_call_bool(main_flow_manager, { "get_IsNowLoading", "get_IsLoading" }) or false
        local is_cutscene = safe_call_bool(
            main_flow_manager,
            { "get_IsInMovie", "get_IsNowMovie", "get_IsInEvent", "get_IsEventScene" }
        ) or false

        local current_stage = nil
        if player_info ~= nil then
            current_stage = player_info.stage
        end

        return {
            scene_name = get_scene_name(scene_object),
            player_present = player_info ~= nil,
            current_stage = current_stage,
            is_in_game = is_in_game,
            is_title_screen = is_title_screen,
            is_paused = is_paused,
            is_loading = is_loading,
            is_cutscene = is_cutscene,
            is_playable = (player_info ~= nil) and is_in_game and not is_title_screen and not is_paused and not is_loading and not is_cutscene,
        }
    end

    local function get_active_runtime_stage(runtime_state)
        if type(runtime_state) == "table" and type(runtime_state.current_stage) == "number" then
            return runtime_state.current_stage
        end

        local last_state = ctx.bridge.last_state
        if type(last_state) == "table" and type(last_state.current_stage) == "number" then
            return last_state.current_stage
        end

        return nil
    end

    -- [DeathLink] Read the player's death flag off the HitPoint
    -- (context -> get_HitPoint -> get_IsDead). Returns true/false, or nil when
    -- unavailable (not in game / no player context). Verified live via the
    -- DeathLink reflection probe (2026-07-15).
    local function get_player_is_dead()
        local player_info = get_player_info()
        if player_info == nil or player_info.context == nil then
            return nil
        end
        local hit_point = safe_call(player_info.context, "get_HitPoint")
        if hit_point == nil then
            return nil
        end
        local is_dead = safe_call(hit_point, "get_IsDead")
        if is_dead == nil then
            return nil
        end
        return is_dead == true
    end

    -- [DeathLink] Trigger the game's own game-over -> checkpoint-reload flow. This IS
    -- the death for DeathLink: it needs no attacker and no damage pipeline (all of
    -- which soft-lock or throw when synthesized). chainsaw.GameOverManager is a shell
    -- whose Mediator holds the API; requestGameOver(new GameOverRequest) advances the
    -- game-over phase and shows the continue/reload screen. A BLANK GameOverRequest is
    -- sufficient (RequestArg/Priority default). Verified live via the probe: the
    -- game-over screen appears and Continue reloads the last checkpoint cleanly.
    -- Cosmetic caveat: Leon stays standing (no death animation) since we skip the
    -- damage path; the reload is the actual death.
    local function trigger_game_over()
        local game_over_manager = sdk.get_managed_singleton("chainsaw.GameOverManager")
        if game_over_manager == nil then
            return false
        end
        local mediator = safe_call(game_over_manager, "get_Mediator")
        if mediator == nil then
            return false
        end
        local ok_request, request = pcall(function()
            return sdk.create_instance("chainsaw.GameOverRequest")
        end)
        if not ok_request or request == nil then
            return false
        end
        local ok_call = pcall(function()
            mediator:call("requestGameOver", request)
        end)
        return ok_call == true
    end

    -- The game's own current campaign chapter as a 1-16 number, read from
    -- CampaignManager (authoritative, unlike the stage-derived map). Returns nil
    -- outside an active campaign (menus/boot) so callers fall back. The values are
    -- the ChapterID enum ids the chapter-select also uses (21100 = Ch1 ...).
    local CHAPTER_ID_TO_NUMBER = {
        [21100] = 1, [21200] = 2, [21300] = 3,
        [22100] = 4, [22200] = 5, [22300] = 6,
        [23100] = 7, [23200] = 8, [23300] = 9,
        [24100] = 10, [24200] = 11, [24300] = 12,
        [25100] = 13, [25200] = 14, [25300] = 15, [25400] = 16,
    }
    local function get_authoritative_chapter()
        local manager = sdk.get_managed_singleton("chainsaw.CampaignManager")
        if manager == nil then
            return nil
        end
        local chapter_id = tonumber(safe_call(manager, "get_CurrentChapter"))
        if chapter_id == nil then
            return nil
        end
        return CHAPTER_ID_TO_NUMBER[chapter_id]
    end

    local exports = {
        safe_call = safe_call,
        safe_call_bool = safe_call_bool,
        get_player_is_dead = get_player_is_dead,
        trigger_game_over = trigger_game_over,
        get_scene_object = get_scene_object,
        get_components = get_components,
        get_game_object_guid = get_game_object_guid,
        get_component = get_component,
        get_parent_game_object = get_parent_game_object,
        get_scene_name = get_scene_name,
        get_main_flow_manager = get_main_flow_manager,
        get_player_info = get_player_info,
        get_player_position = get_player_position,
        get_player_transform = get_player_transform,
        set_player_position = set_player_position,
        get_runtime_state = get_runtime_state,
        get_active_runtime_stage = get_active_runtime_stage,
        get_authoritative_chapter = get_authoritative_chapter,
    }

    for key, value in pairs(exports) do
        ctx[key] = value
        _G[key] = value
    end
end

return install
