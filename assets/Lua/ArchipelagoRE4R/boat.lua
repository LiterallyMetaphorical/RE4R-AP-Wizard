-- boat.lua - keep a boat within reach of the player (D9).
--
-- Vanilla can never separate you from the boat; our typewriter warp is the
-- only thing that can, so stranding is ours to fix. After a warp into a lake
-- area we move the boat to the pier nearest the player.
--
-- WHAT THIS IS, precisely (Cam, 2026-08-17): the boat has TWO positions. This
-- moves the RENDER position, which brings the boat and its interaction prompt
-- to you. The LOGICAL position does not follow, so boarding still plays the
-- board sequence against the old mooring and travels you there. That is
-- accepted and is the shipped behaviour: it is a SUMMON, not a relocation.
-- You are never stranded, which was the whole complaint.
--
-- The native route (registerReturnPort / startReturnPort) was spiked and
-- rejected: PierPos tracks the boat rather than the player, startReturnPort
-- refuses from step WAIT, and the native move fades the screen, which is bad
-- immediately after a warp. See the D9 section of the round-2 handoff.
return function(ctx)
    local function try(fn)
        local ok, result = pcall(fn)
        if ok then return result end
        return nil
    end

    -- via.vec3 and via.Quaternion are VALUE TYPES. sdk.create_instance gives a
    -- hollow object and writing native fields into it yields nan - that bug
    -- silently invalidated three live experiments on 2026-08-17. Use
    -- REFramework's own types, which marshal correctly.
    local function make_vec3(x, y, z)
        if Vector3f == nil or Vector3f.new == nil then return nil end
        return try(function() return Vector3f.new(x, y, z) end)
    end

    local function vec3_of(value)
        if value == nil then return nil end
        local x = try(function() return value.x end)
        local y = try(function() return value.y end)
        local z = try(function() return value.z end)
        if x == nil or y == nil or z == nil then return nil end
        return { x = x, y = y, z = z }
    end

    local function distance(a, b)
        if a == nil or b == nil then return nil end
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local function find_boat()
        local getter = ctx.get_components or _G.get_components
        if type(getter) ~= "function" then return nil end
        local components = try(function() return getter("chainsaw.GmBoat") end)
        if components == nil then return nil end
        local found = nil
        local each = ctx.each_engine_array_entry or _G.each_engine_array_entry
        if type(each) == "function" then
            each(components, function(component)
                if component ~= nil then
                    found = component
                    return true
                end
                return false
            end)
        end
        if found == nil and type(components) == "table" then
            found = components[1]
        end
        return found
    end

    local function player_position()
        local getter = ctx.get_player_position or _G.get_player_position
        if type(getter) ~= "function" then return nil end
        return vec3_of(try(getter))
    end

    -- Nearest ENABLED pier to the player. A disabled pier is not a legal moor
    -- point, so a closer one must still be skipped.
    local function nearest_pier(boat, origin)
        if boat == nil or origin == nil then return nil end
        local pier_data = try(function() return boat:call("get_PierDataSet") end)
        if pier_data == nil then return nil end
        local groups = try(function() return pier_data:get_field("PierGroupList") end)
        if groups == nil then return nil end
        local each = ctx.each_engine_array_entry or _G.each_engine_array_entry
        if type(each) ~= "function" then return nil end

        local best = nil
        each(groups, function(group)
            local group_enabled = try(function() return group:get_field("Enable") end)
            local list = try(function() return group:get_field("Piers") end)
            each(list, function(pier)
                local enabled = try(function() return pier:get_field("Enable") end)
                if enabled == false or group_enabled == false then
                    return false
                end
                local position = vec3_of(try(function() return pier:get_field("Position") end))
                local d = distance(position, origin)
                if position ~= nil and d ~= nil and (best == nil or d < best.distance) then
                    best = {
                        position = position,
                        degree_y = try(function() return pier:get_field("DegreeY") end),
                        distance = d,
                    }
                end
                return false
            end)
            return false
        end)
        return best
    end

    -- Do not yank a boat the player is standing on or beside: within this many
    -- metres there is nothing to fix, and moving it would be the bug.
    local NEAR_ENOUGH_METRES = 20.0

    local function summon_boat_to_player(reason)
        local boat = find_boat()
        if boat == nil then
            return false, "no boat in this scene"
        end
        local origin = player_position()
        if origin == nil then
            return false, "player position unavailable"
        end

        local transform = nil
        local game_object = try(function() return boat:call("get_GameObject") end)
        if game_object ~= nil then
            transform = try(function() return game_object:call("get_Transform") end)
        end
        if transform == nil then
            return false, "boat transform unavailable"
        end

        local current = vec3_of(try(function() return transform:call("get_Position") end))
        local separation = distance(current, origin)
        if separation ~= nil and separation <= NEAR_ENOUGH_METRES then
            return false, string.format("boat already %.1fm away", separation)
        end

        -- Mid-sequence boats are the game's business, not ours.
        local move_state = try(function() return boat:call("get_MoveState") end)
        if move_state ~= nil and tonumber(move_state) ~= nil and tonumber(move_state) ~= 0 then
            return false, string.format("boat is moving (MoveState %s)", tostring(move_state))
        end

        local pier = nearest_pier(boat, origin)
        if pier == nil then
            return false, "no enabled pier with a position"
        end

        local position = make_vec3(pier.position.x, pier.position.y, pier.position.z)
        if position == nil then
            return false, "could not build a via.vec3"
        end
        local ok = try(function()
            transform:call("set_Position", position)
            return true
        end)
        if ok ~= true then
            return false, "set_Position refused"
        end

        -- NO ROTATION WRITE. Position-only teleport produced a boardable boat
        -- (live 2026-08-17); adding a yaw quaternion built from the pier's
        -- DegreeY produced one that could not be interacted with at all. The
        -- boat keeps the orientation it already had, which may look wrong at
        -- the new pier but is always usable, and usable beats tidy.
        --
        -- If this is ever revisited: the argument order of Quaternion.new is
        -- unverified, so read a known-good rotation off the boat and compare
        -- before constructing one. Do not guess again.

        -- Persist it, or the boat snaps back to its old mooring on reload.
        try(function() boat:call("saveBoatData") end)

        log.info(string.format(
            "[RE4R AP][boat] summoned to a pier %.1fm away (%s); was %.1fm from the player",
            pier.distance, tostring(reason), separation or -1))
        return true, nil
    end

    ctx.summon_boat_to_player = summon_boat_to_player
    _G.summon_boat_to_player = summon_boat_to_player
end
