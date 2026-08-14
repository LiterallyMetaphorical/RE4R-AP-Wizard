-- [D9 spike] Boat-follows-the-player. This is a PROBE, not the feature.
--
-- Typewriter-warping during the boat era can strand the boat on a far shore.
-- Vanilla can never separate you from it; our live warp (executeWarpNow, no
-- area reload) is the only thing that can, so it is ours to fix. The intended
-- shape is "the boat moors at the pier nearest the player, post-Del Lago".
--
-- The il2cpp dump answered most of the design and killed one assumption:
--   * startReturnPort() takes NO ARGUMENTS. The handoff hoped we could hand it
--     a target pier and ride the native path. We cannot. The target lives in
--     the boat's _ReturnPortInfo field (Enable / PierPos / PierRot / PierVec /
--     PierTrans / PierYaw / PierDegY / BoatTrans / BoatYaw / BoatDegY /
--     IsPlayerWerp / PlayerWerpPos / IsLeft / IsReturnPort).
--   * The piers ARE first-class and enumerable: get_PierDataSet() -> PierData
--     -> PierGroupList -> PierGroup.Piers -> Pier {Enable, Position, DegreeY,
--     StopDir, Width_L, Width_R, IsPlayerWerp, PlayerWerpPos}.
--   * The native move is a state machine with a FADE in it: BOATSTEP runs
--     INIT / WAIT / DEFAULT / BATTLE_END / RETURN_PORT_FADE_OUT /
--     RETURN_PORT_FADE_IN_WAIT / RETURN_PORT_SAVE / RETURN_PORT.
--
-- Three questions are left that only the running game can settle, and this
-- window exists to answer all three in one visit to the lake:
--   1. Does CheckReturnPort() populate _ReturnPortInfo on its own, and with
--      which pier (nearest? scripted? the one you launched from)?
--   2. Is _ReturnPortInfo writable from Lua, so we can aim it at a pier of our
--      choosing and let the game do the moving?
--   3. Does the native path fade the screen, and is that tolerable right after
--      a warp - or do we want the silent position write instead?
--
-- Safety: reads nothing destructive on its own. Every native call is behind an
-- explicit button press, dev-gated twice, and pcall-wrapped, and each press
-- writes a labelled before/after snapshot to re2_framework_log.txt and to
-- boat_spike.json. Delete this module (and its three bootstrap lines) when D9
-- is built.
local function install(ctx)
    ctx.ui_boat_spike = ctx.ui_boat_spike or {}
    local bridge = ctx.bridge

    local function export(name, value)
        ctx.ui_boat_spike[name] = value
        ctx[name] = value
        _G[name] = value
    end

    local SPIKE_FILE = "ArchipelagoRE4R/boat_spike.json"

    local BOAT_STEP_NAMES = {
        [0] = "INIT",
        [1] = "WAIT",
        [2] = "DEFAULT",
        [3] = "BATTLE_END",
        [4] = "RETURN_PORT_FADE_OUT",
        [5] = "RETURN_PORT_FADE_IN_WAIT",
        [6] = "RETURN_PORT_SAVE",
        [7] = "RETURN_PORT",
    }

    -- Local copy of runtime.lua's array walk. runtime does not export it, and
    -- a self-contained spike is one file to delete instead of two edits to
    -- undo. Same order of attempts for the same reason: these engine
    -- containers are not Lua tables and get_elements() is the walk that works.
    local function each_entry(array, visit)
        if array == nil then
            return false
        end
        local ok_elements, elements = pcall(function() return array:get_elements() end)
        if ok_elements and type(elements) == "table" then
            for _, entry in ipairs(elements) do
                if visit(entry) then return true end
            end
            return false
        end
        local ok_count, count = pcall(function() return array:get_Count() end)
        if not ok_count or tonumber(count) == nil then
            ok_count, count = pcall(function() return array:get_size() end)
        end
        count = tonumber(count)
        if count ~= nil then
            for index = 0, math.floor(count) - 1 do
                local ok_entry, entry = pcall(function() return array:get_Item(index) end)
                if not ok_entry or entry == nil then
                    ok_entry, entry = pcall(function() return array:get_element(index) end)
                end
                if ok_entry and entry ~= nil and visit(entry) then
                    return true
                end
            end
        end
        return false
    end

    local function try(fn)
        local ok, value = pcall(fn)
        if ok then return value end
        return nil
    end

    -- via.vec3 reads back as a userdata with x/y/z; be tolerant anyway, a nil
    -- here should degrade to "?" in the readout rather than kill the window.
    local function vec3_of(value)
        if value == nil then return nil end
        local x = try(function() return value.x end)
        local y = try(function() return value.y end)
        local z = try(function() return value.z end)
        if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
            return nil
        end
        return { x = x, y = y, z = z }
    end

    local function vec3_text(v)
        if v == nil then return "?" end
        return string.format("%.2f, %.2f, %.2f", v.x, v.y, v.z)
    end

    local function distance(a, b)
        if a == nil or b == nil then return nil end
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local function get_boat()
        local getter = ctx.get_components or _G.get_components
        if type(getter) ~= "function" then return nil end
        local components = try(function() return getter("chainsaw.GmBoat") end)
        if components == nil then return nil end
        local found = nil
        each_entry(components, function(component)
            if component ~= nil then
                found = component
                return true
            end
            return false
        end)
        if found == nil and type(components) == "table" then
            found = components[1]
        end
        return found
    end

    local function boat_world_position(boat)
        if boat == nil then return nil end
        return vec3_of(try(function()
            local game_object = boat:call("get_GameObject")
            local transform = game_object ~= nil and game_object:call("get_Transform") or nil
            return transform ~= nil and transform:call("get_Position") or nil
        end))
    end

    local function player_position()
        local getter = ctx.get_player_position or _G.get_player_position
        if type(getter) ~= "function" then return nil end
        return vec3_of(try(getter))
    end

    -- Flat list of every pier the boat knows about, tagged with its group so a
    -- readout can say which one the game would consider. Distance is from the
    -- PLAYER, because "nearest pier to the player" is the whole feature.
    local function read_piers(boat)
        local piers = {}
        if boat == nil then return piers end
        local pier_data = try(function() return boat:call("get_PierDataSet") end)
        if pier_data == nil then return piers end
        local groups = try(function() return pier_data:get_field("PierGroupList") end)
        if groups == nil then return piers end

        local origin = player_position()
        local group_index = 0
        each_entry(groups, function(group)
            group_index = group_index + 1
            local pier_index = 0
            local group_enabled = try(function() return group:get_field("Enable") end)
            local list = try(function() return group:get_field("Piers") end)
            each_entry(list, function(pier)
                pier_index = pier_index + 1
                local position = vec3_of(try(function() return pier:get_field("Position") end))
                table.insert(piers, {
                    group = group_index,
                    index = pier_index,
                    group_enabled = group_enabled,
                    enabled = try(function() return pier:get_field("Enable") end),
                    position = position,
                    degree_y = try(function() return pier:get_field("DegreeY") end),
                    stop_dir = try(function() return pier:get_field("StopDir") end),
                    is_player_werp = try(function() return pier:get_field("IsPlayerWerp") end),
                    player_werp_pos = vec3_of(try(function() return pier:get_field("PlayerWerpPos") end)),
                    distance = distance(position, origin),
                })
                return false
            end)
            return false
        end)
        return piers
    end

    local function nearest_pier(piers)
        local best, best_distance = nil, nil
        for _, pier in ipairs(piers) do
            if pier.enabled ~= false and pier.distance ~= nil then
                if best_distance == nil or pier.distance < best_distance then
                    best, best_distance = pier, pier.distance
                end
            end
        end
        return best
    end

    local function read_return_port_info(boat)
        if boat == nil then return nil end
        local info = try(function() return boat:get_field("_ReturnPortInfo") end)
        if info == nil then return nil end
        return {
            enable = try(function() return info:get_field("Enable") end),
            pier_pos = vec3_of(try(function() return info:get_field("PierPos") end)),
            pier_trans = vec3_of(try(function() return info:get_field("PierTrans") end)),
            pier_yaw = try(function() return info:get_field("PierYaw") end),
            pier_deg_y = try(function() return info:get_field("PierDegY") end),
            boat_trans = vec3_of(try(function() return info:get_field("BoatTrans") end)),
            boat_yaw = try(function() return info:get_field("BoatYaw") end),
            boat_deg_y = try(function() return info:get_field("BoatDegY") end),
            is_left = try(function() return info:get_field("IsLeft") end),
            is_return_port = try(function() return info:get_field("IsReturnPort") end),
            is_player_werp = try(function() return info:get_field("IsPlayerWerp") end),
        }
    end

    local function read_save_data(boat)
        if boat == nil then return nil end
        local save = try(function() return boat:get_field("_SaveData") end)
        if save == nil then return nil end
        return {
            is_save_data = try(function() return save:get_field("IsSaveData") end),
            position = vec3_of(try(function() return save:get_field("Position") end)),
            rotation_y = try(function() return save:get_field("RotationY") end),
            is_left = try(function() return save:get_field("IsLeft") end),
        }
    end

    local function read_status(boat)
        if boat == nil then return nil end
        local step = try(function() return boat:get_field("_BoatStep") end)
        local step_number = tonumber(step)
        return {
            step = step_number,
            step_name = step_number ~= nil and (BOAT_STEP_NAMES[step_number] or "UNKNOWN") or "?",
            move_state = try(function() return boat:call("get_MoveState") end),
            is_return_port = try(function() return boat:call("IsReturnPort") end),
            return_port_is_left = try(function() return boat:call("get_ReturnPortIsLeft") end),
            is_end_step1 = try(function() return boat:call("get_IsEndStep1") end),
            position = boat_world_position(boat),
        }
    end

    -- One labelled snapshot: the whole readable surface at a moment in time.
    -- Written to the log AND accumulated in boat_spike.json so a live session
    -- leaves a diffable before/after for every button pressed.
    local function snapshot(label)
        local boat = get_boat()
        local status = read_status(boat)
        local info = read_return_port_info(boat)
        local save = read_save_data(boat)
        local piers = read_piers(boat)
        local origin = player_position()
        local near = nearest_pier(piers)

        log.info(string.format("[RE4R AP] boat spike [%s] boat=%s step=%s(%s) move=%s isReturnPort=%s isLeft=%s",
            tostring(label),
            boat ~= nil and "found" or "MISSING",
            status ~= nil and tostring(status.step) or "?",
            status ~= nil and status.step_name or "?",
            status ~= nil and tostring(status.move_state) or "?",
            status ~= nil and tostring(status.is_return_port) or "?",
            status ~= nil and tostring(status.return_port_is_left) or "?"))
        log.info(string.format("[RE4R AP] boat spike [%s] boatPos=(%s) playerPos=(%s) piers=%d nearest=%s",
            tostring(label),
            vec3_text(status ~= nil and status.position or nil),
            vec3_text(origin),
            #piers,
            near ~= nil and string.format("g%d#%d at %.2fm", near.group, near.index, near.distance or -1) or "none"))
        if info ~= nil then
            log.info(string.format("[RE4R AP] boat spike [%s] ReturnPortInfo enable=%s isReturnPort=%s pierPos=(%s) boatTrans=(%s) boatYaw=%s isLeft=%s",
                tostring(label),
                tostring(info.enable), tostring(info.is_return_port),
                vec3_text(info.pier_pos), vec3_text(info.boat_trans),
                tostring(info.boat_yaw), tostring(info.is_left)))
        else
            log.info(string.format("[RE4R AP] boat spike [%s] ReturnPortInfo UNREADABLE", tostring(label)))
        end
        if save ~= nil then
            log.info(string.format("[RE4R AP] boat spike [%s] SaveData isSave=%s pos=(%s) rotY=%s isLeft=%s",
                tostring(label), tostring(save.is_save_data), vec3_text(save.position),
                tostring(save.rotation_y), tostring(save.is_left)))
        end
        for _, pier in ipairs(piers) do
            log.info(string.format("[RE4R AP] boat spike [%s]   pier g%d#%d enable=%s pos=(%s) degY=%s stop=%s dist=%s",
                tostring(label), pier.group, pier.index, tostring(pier.enabled),
                vec3_text(pier.position), tostring(pier.degree_y), tostring(pier.stop_dir),
                pier.distance ~= nil and string.format("%.2fm", pier.distance) or "?"))
        end

        pcall(function()
            local existing = json.load_file(SPIKE_FILE)
            if type(existing) ~= "table" then
                existing = { version = 1, snapshots = {} }
            end
            if type(existing.snapshots) ~= "table" then
                existing.snapshots = {}
            end
            table.insert(existing.snapshots, {
                label = tostring(label),
                boat_found = boat ~= nil,
                status = status,
                return_port_info = info,
                save_data = save,
                player_position = origin,
                piers = piers,
            })
            json.dump_file(SPIKE_FILE, existing)
        end)

        return boat ~= nil
    end

    -- Press a native method, snapshotting either side of it. The whole point is
    -- the diff: if CheckReturnPort populates _ReturnPortInfo, the "after" shows
    -- it; if startReturnPort moves the boat, boatPos changes and step walks into
    -- the RETURN_PORT_* range.
    local function call_and_report(method)
        local boat = get_boat()
        if boat == nil then
            bridge.boat_spike_status = "no GmBoat in this scene"
            return
        end
        snapshot("before " .. method)
        local ok, err = pcall(function() boat:call(method) end)
        snapshot("after " .. method)
        if ok then
            bridge.boat_spike_status = method .. "() called"
            log.info("[RE4R AP] boat spike called " .. method .. "()")
        else
            bridge.boat_spike_status = method .. "() THREW: " .. tostring(err)
            log.error("[RE4R AP] boat spike " .. method .. "() threw: " .. tostring(err))
        end
    end

    local function make_vec3(v)
        local instance = sdk.create_instance("via.vec3")
        local vec3_type = sdk.find_type_definition("via.vec3")
        if instance == nil or vec3_type == nil then return nil end
        sdk.set_native_field(instance, vec3_type, "x", v.x)
        sdk.set_native_field(instance, vec3_type, "y", v.y)
        sdk.set_native_field(instance, vec3_type, "z", v.z)
        return instance
    end

    -- Question 2, the one that decides whether D9 rides the native path.
    -- Writes the nearest pier into _ReturnPortInfo field by field, reporting
    -- which writes took. A field that refuses is a real answer, so nothing here
    -- aborts on the first failure.
    local function retarget_to_nearest()
        local boat = get_boat()
        if boat == nil then
            bridge.boat_spike_status = "no GmBoat in this scene"
            return
        end
        local piers = read_piers(boat)
        local near = nearest_pier(piers)
        if near == nil or near.position == nil then
            bridge.boat_spike_status = "no enabled pier with a position"
            return
        end
        local info = try(function() return boat:get_field("_ReturnPortInfo") end)
        if info == nil then
            bridge.boat_spike_status = "_ReturnPortInfo unreadable"
            return
        end

        snapshot(string.format("before retarget g%d#%d", near.group, near.index))
        local wrote, failed = {}, {}
        local function write(field, value)
            local ok = pcall(function() info:set_field(field, value) end)
            table.insert(ok and wrote or failed, field)
        end
        write("Enable", true)
        write("IsReturnPort", true)
        local pier_pos = make_vec3(near.position)
        if pier_pos ~= nil then
            write("PierPos", pier_pos)
            write("PierTrans", make_vec3(near.position))
            write("BoatTrans", make_vec3(near.position))
        else
            table.insert(failed, "via.vec3 construction")
        end
        if type(near.degree_y) == "number" then
            write("PierDegY", near.degree_y)
            write("BoatDegY", near.degree_y)
        end
        snapshot(string.format("after retarget g%d#%d", near.group, near.index))

        bridge.boat_spike_status = string.format("retarget wrote {%s}; refused {%s}",
            table.concat(wrote, ","), table.concat(failed, ","))
        log.info("[RE4R AP] boat spike " .. bridge.boat_spike_status)
    end

    -- The fallback the handoff named: skip the native sequence and put the boat
    -- where we want it. If this works and looks right, D9 can ship without
    -- depending on startReturnPort semantics at all - at the cost of doing the
    -- physics/rotation ourselves and writing BoatSaveData so it survives a save.
    local function teleport_boat_to_nearest()
        local boat = get_boat()
        if boat == nil then
            bridge.boat_spike_status = "no GmBoat in this scene"
            return
        end
        local near = nearest_pier(read_piers(boat))
        if near == nil or near.position == nil then
            bridge.boat_spike_status = "no enabled pier with a position"
            return
        end
        snapshot("before teleport")
        local ok, err = pcall(function()
            local game_object = boat:call("get_GameObject")
            local transform = game_object ~= nil and game_object:call("get_Transform") or nil
            if transform == nil then error("no transform") end
            transform:call("set_Position", make_vec3(near.position))
        end)
        snapshot("after teleport")
        if ok then
            bridge.boat_spike_status = string.format("teleported to pier g%d#%d", near.group, near.index)
        else
            bridge.boat_spike_status = "teleport THREW: " .. tostring(err)
            log.error("[RE4R AP] boat spike teleport threw: " .. tostring(err))
        end
    end

    local function draw_boat_spike()
        if bridge.developer_tools_enabled ~= true
            or bridge.boat_spike_window_enabled ~= true then
            return
        end

        imgui.begin_window("AP Boat Spike (D9)", true)
        imgui.text("Stand near the lake with the boat loaded, then work down.")
        imgui.text("Every button logs a before/after pair to the framework log.")

        local boat = get_boat()
        if boat == nil then
            imgui.text("No chainsaw.GmBoat in this scene.")
            imgui.text("(Expected outside the lake stages - that is itself a result.)")
            if imgui.button("Snapshot to log anyway") then snapshot("manual") end
            imgui.end_window()
            return
        end

        local status = read_status(boat)
        local origin = player_position()
        imgui.text(string.format("Step: %s (%s)   MoveState: %s",
            status.step_name, tostring(status.step), tostring(status.move_state)))
        imgui.text(string.format("IsReturnPort: %s   ReturnPortIsLeft: %s   IsEndStep1: %s",
            tostring(status.is_return_port), tostring(status.return_port_is_left),
            tostring(status.is_end_step1)))
        imgui.text("Boat:   " .. vec3_text(status.position))
        imgui.text("Player: " .. vec3_text(origin))
        local gap = distance(status.position, origin)
        imgui.text(gap ~= nil and string.format("Separation: %.2fm", gap) or "Separation: ?")

        local piers = read_piers(boat)
        local near = nearest_pier(piers)
        imgui.text(string.format("Piers known: %d", #piers))
        if near ~= nil then
            imgui.text(string.format("Nearest enabled: group %d pier %d at %.2fm (%s)",
                near.group, near.index, near.distance or -1, vec3_text(near.position)))
        else
            imgui.text("Nearest enabled: none")
        end
        for _, pier in ipairs(piers) do
            imgui.text(string.format("   g%d#%d en=%s %s degY=%s %s",
                pier.group, pier.index, tostring(pier.enabled), vec3_text(pier.position),
                tostring(pier.degree_y),
                pier.distance ~= nil and string.format("%.1fm", pier.distance) or "?"))
        end

        local info = read_return_port_info(boat)
        if info ~= nil then
            imgui.text(string.format("ReturnPortInfo: enable=%s isReturnPort=%s isLeft=%s",
                tostring(info.enable), tostring(info.is_return_port), tostring(info.is_left)))
            imgui.text("   PierPos:   " .. vec3_text(info.pier_pos))
            imgui.text("   BoatTrans: " .. vec3_text(info.boat_trans))
        else
            imgui.text("ReturnPortInfo: unreadable")
        end

        local save = read_save_data(boat)
        if save ~= nil then
            imgui.text(string.format("SaveData: isSave=%s rotY=%s isLeft=%s pos=(%s)",
                tostring(save.is_save_data), tostring(save.rotation_y),
                tostring(save.is_left), vec3_text(save.position)))
        end

        if imgui.button("Snapshot") then snapshot("manual") end
        imgui.same_line()
        if imgui.button("CheckReturnPort()") then call_and_report("CheckReturnPort") end
        imgui.same_line()
        if imgui.button("initReturnPort()") then call_and_report("initReturnPort") end

        if imgui.button("startReturnPort()") then call_and_report("startReturnPort") end
        imgui.same_line()
        if imgui.button("endReturnPort()") then call_and_report("endReturnPort") end
        imgui.same_line()
        if imgui.button("saveBoatData()") then call_and_report("saveBoatData") end

        imgui.text("Experimental - these WRITE:")
        if imgui.button("Retarget ReturnPortInfo to nearest pier") then retarget_to_nearest() end
        if imgui.button("Teleport boat to nearest pier") then teleport_boat_to_nearest() end

        if type(bridge.boat_spike_status) == "string" then
            imgui.text(bridge.boat_spike_status)
        end

        imgui.end_window()
    end

    export("draw_boat_spike", draw_boat_spike)
    export("boat_spike_snapshot", snapshot)
end

return install
