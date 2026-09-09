-- enemy_gate.lua - possession-keyed spawn admission (ENEMY_CLASS_DESIGN.md).
--
-- The fork rolls the roster at patch time and echoes every spawn it placed
-- into a gated class (ap_enemy_gates.json -> the launcher folds it into
-- ap_room_locations.json as "enemy_gates"). This module vetoes exactly those
-- spawns at chainsaw.*SpawnController.permitSpawn until the gate's AP item is
-- possessed. Ships with one gate: Dread (regenerador family) on the Biosensor
-- Scope. Arsenal gates for other classes are data-scaffolded launcher-side
-- and arrive here through the same section when enabled.
--
-- Design properties:
--   * Vanilla spawns are untouchable BY CONSTRUCTION: they are never in the
--     manifest, and a controller guid that is not listed never matches.
--   * Possession = the AP server ever delivered the item to this slot
--     (apclient's received ledger, rebuilt from the full replay on every
--     connect, own-world finds included), OR the item sits in Storage
--     (belt-and-suspenders for odd flows). Once a gate opens it stays open
--     for the session; items are never taken back.
--   * A vetoed spawn is not destroyed, merely not permitted; once the gate
--     opens the same controller spawns it naturally from the next attempt
--     or room load onward.
--   * Wave controllers are LOG-ONLY in v1: their battle-end accounting
--     (DeadList / IsBattleEnd) has not been proven tolerant of a vetoed
--     member, and a stalled battle gate is worse than an early iron maiden.
--   * Everything is defensive: a missing section, a hook that cannot
--     install, an unreadable guid - each degrades to "log it and spawn
--     everything", which is exactly yesterday's behavior.
return function(ctx)
    local bridge = ctx.bridge

    local gate_state = {
        gates = {},          -- gate key -> gate record
        by_controller = {},  -- lowercase controller guid -> {components=set, gate=key}
        gate_count = 0,
        spawn_count = 0,
        hooks_installed = false,
        vetoed_total = 0,
        wave_would_veto_total = 0,
    }
    ctx.enemy_gate = gate_state

    local function info(text)
        log.info("[RE4R AP][enemy_gate] " .. tostring(text))
    end

    local function warn(text)
        log.warn("[RE4R AP][enemy_gate] " .. tostring(text))
    end

    local ITEM_MAP_FILE = "ArchipelagoRE4R\\ap_item_map.json"

    -- Engine item id -> set of AP item ids. Distinct AP items can share one
    -- engine id (the x4/x5 ammo lesson), so collect every match.
    local function resolve_ap_ids(engine_item_id)
        local ap_ids = {}
        local ok, map = pcall(function() return json.load_file(ITEM_MAP_FILE) end)
        if not ok or type(map) ~= "table" then
            warn("ap_item_map.json unavailable; possession falls back to the Storage check only")
            return ap_ids
        end
        for ap_id, entry in pairs(map) do
            if type(entry) == "table" and tonumber(entry.re4r_item_id) == engine_item_id then
                local numeric = tonumber(ap_id)
                if numeric ~= nil then
                    ap_ids[math.floor(numeric)] = true
                end
            end
        end
        return ap_ids
    end

    -- ------------------------------------------------------------ possession
    local function storage_holds(engine_item_id)
        local ok, count = pcall(function()
            local armoury = sdk.get_managed_singleton("chainsaw.ArmouryManager")
            if armoury == nil then
                return 0
            end
            return armoury:call("getItemCountSum", engine_item_id)
        end)
        return ok and (tonumber(count) or 0) > 0
    end

    local function gate_open(gate)
        if gate.open then
            return true
        end
        local has_received = ctx.ap_has_received_ap_item
        if type(has_received) == "function" then
            for ap_id in pairs(gate.ap_ids) do
                local ok, received = pcall(has_received, ap_id)
                if ok and received then
                    gate.open = true
                end
            end
        end
        if not gate.open and storage_holds(gate.item_id) then
            gate.open = true
        end
        if gate.open then
            info(string.format(
                "gate '%s' OPEN (%s in hand) - its spawns resume from the next spawn attempt",
                tostring(gate.key), tostring(gate.item_name)))
        end
        return gate.open == true
    end

    -- --------------------------------------------------------- guid plumbing
    -- permitSpawn's `this` is the spawn controller; its scene identity is the
    -- System.Guid behind get_GUID(). Struct-to-string is marshalling-fiddly,
    -- so try the obvious routes and cache by object address (controllers live
    -- as long as their room).
    local guid_cache = {}
    local guid_cache_size = 0

    local function to_lua_string(value)
        if type(value) == "string" then
            return value
        end
        if value ~= nil then
            local ok, text = pcall(function() return value:call("ToString()") end)
            if ok and type(text) == "string" then
                return text
            end
        end
        return nil
    end

    local function read_controller_guid(controller)
        local address = controller:get_address()
        local cached = guid_cache[address]
        if cached ~= nil then
            return cached
        end
        local guid_text = nil
        local ok, guid = pcall(function() return controller:call("get_GUID") end)
        if ok and guid ~= nil then
            guid_text = to_lua_string(guid)
            if guid_text == nil then
                local ok_two, text = pcall(function() return tostring(guid) end)
                if ok_two and type(text) == "string" and #text >= 32 then
                    guid_text = text
                end
            end
        end
        if guid_text ~= nil then
            guid_text = string.lower(guid_text)
            if guid_cache_size > 512 then
                guid_cache = {}
                guid_cache_size = 0
            end
            guid_cache[address] = guid_text
            guid_cache_size = guid_cache_size + 1
        end
        return guid_text
    end

    -- ----------------------------------------------------------------- hooks
    -- Veto on the standard and point controllers; the wave controller only
    -- reports what it WOULD have vetoed until its kill accounting is proven.
    local HOOK_SPECS = {
        { type_name = "chainsaw.CharacterSpawnController", veto = true, label = "standard" },
        { type_name = "chainsaw.CharacterSpawnPointController", veto = true, label = "point" },
        { type_name = "chainsaw.CharacterSpawnWaveController", veto = false, label = "wave" },
    }

    local veto_logged = {}

    local function on_permit_spawn(spec, args)
        if gate_state.spawn_count == 0 then
            return nil
        end
        local controller = sdk.to_managed_object(args[2])
        if controller == nil then
            return nil
        end
        local guid = read_controller_guid(controller)
        if guid == nil then
            return nil
        end
        local entry = gate_state.by_controller[guid]
        if entry == nil then
            return nil
        end
        local param = sdk.to_managed_object(args[3])
        if param == nil then
            return nil
        end
        local component = nil
        local ok_type, type_definition = pcall(function() return param:get_type_definition() end)
        if ok_type and type_definition ~= nil then
            component = type_definition:get_full_name()
        end
        if component == nil or not entry.components[component] then
            return nil
        end
        local gate = gate_state.gates[entry.gate]
        if gate == nil or gate_open(gate) then
            return nil
        end

        local log_key = guid .. "|" .. component
        if spec.veto then
            gate_state.vetoed_total = gate_state.vetoed_total + 1
            if not veto_logged[log_key] or bridge.developer_tools_enabled == true then
                veto_logged[log_key] = true
                info(string.format(
                    "veto: %s controller %s holding back %s until %s arrives (total vetoes %d)",
                    spec.label, guid, tostring(component), tostring(gate.item_name),
                    gate_state.vetoed_total))
            end
            return sdk.PreHookResult.SKIP_ORIGINAL
        end

        gate_state.wave_would_veto_total = gate_state.wave_would_veto_total + 1
        if not veto_logged[log_key] or bridge.developer_tools_enabled == true then
            veto_logged[log_key] = true
            info(string.format(
                "wave controller %s WOULD hold back %s (log-only in v1; would-veto total %d)",
                guid, tostring(component), gate_state.wave_would_veto_total))
        end
        return nil
    end

    local function install_hooks()
        if gate_state.hooks_installed then
            return
        end
        for _, spec in ipairs(HOOK_SPECS) do
            local type_definition = sdk.find_type_definition(spec.type_name)
            local method = type_definition and type_definition:get_method("permitSpawn")
            if method == nil then
                warn(spec.type_name .. ".permitSpawn not found - that controller class stays ungated")
            else
                sdk.hook(method, function(args)
                    local decision = nil
                    local ok, hook_error = pcall(function()
                        decision = on_permit_spawn(spec, args)
                    end)
                    if not ok then
                        warn("permitSpawn hook error (spawning normally): " .. tostring(hook_error))
                    end
                    if decision ~= nil then
                        return decision
                    end
                    return sdk.PreHookResult.CALL_ORIGINAL
                end, function(retval)
                    return retval
                end)
                info("hooked " .. spec.type_name .. ".permitSpawn (" .. (spec.veto and "veto" or "log-only") .. ")")
            end
        end
        gate_state.hooks_installed = true
    end

    -- ------------------------------------------------------------- configure
    -- Payload = the room file's "enemy_gates" (the fork's echo, verbatim):
    -- { gates = { { key, item_id, item_name, spawns = { { controller,
    -- component, class, stage } } } }, ungated_orphans = n }
    local function enemy_gate_configure(payload)
        gate_state.gates = {}
        gate_state.by_controller = {}
        gate_state.gate_count = 0
        gate_state.spawn_count = 0
        if type(payload) ~= "table" or type(payload.gates) ~= "table" then
            return
        end
        for _, raw in ipairs(payload.gates) do
            local item_id = math.floor(tonumber(raw and raw.item_id) or 0)
            local key = tostring(raw and raw.key or "")
            if key ~= "" and item_id > 0 then
                local gate = {
                    key = key,
                    item_id = item_id,
                    item_name = tostring(raw.item_name or key),
                    ap_ids = resolve_ap_ids(item_id),
                    open = false,
                }
                gate_state.gates[key] = gate
                gate_state.gate_count = gate_state.gate_count + 1
                for _, spawn in ipairs(raw.spawns or {}) do
                    local controller = string.lower(tostring(spawn and spawn.controller or ""))
                    local component = tostring(spawn and spawn.component or "")
                    if #controller >= 32 and component ~= "" then
                        local entry = gate_state.by_controller[controller]
                        if entry == nil then
                            entry = { components = {}, gate = key }
                            gate_state.by_controller[controller] = entry
                        end
                        entry.components[component] = true
                        gate_state.spawn_count = gate_state.spawn_count + 1
                    end
                end
            end
        end
        if gate_state.spawn_count > 0 then
            install_hooks()
        end
        local orphans = math.floor(tonumber(payload.ungated_orphans) or 0)
        info(string.format(
            "%d gate(s), %d gated spawn(s) loaded from the room file%s",
            gate_state.gate_count, gate_state.spawn_count,
            orphans > 0 and string.format(" (%d orphan spawn(s) ungated by the generator)", orphans) or ""))
    end

    ctx.enemy_gate_configure = enemy_gate_configure
    _G.enemy_gate_configure = enemy_gate_configure
end
