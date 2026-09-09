-- ui_gimmick_nudger.lua - move a placed gimmick around, live.
--
-- Built for the spawn save desk and the welcome note (2026-08-24): the fork
-- bakes their transforms at patch time, so dialling a position by rebuild
-- would cost a full regenerate per attempt. This attaches to the NEAREST
-- gimmick of the chosen kind - stand next to the thing you mean - and drags
-- it in world space, then prints the numbers to bake back into the fork
-- (ApTypewriterModifier.Placements / FileModifier's welcome document).
--
-- Runtime moves are per-session by design. The visual and the interact
-- prompt follow the GameObject transform; save-table positions bake at patch
-- time, which is fine for tuning - the look is what is being tuned.
--
-- Lessons inherited from the model tuner: capture before writing, keep a
-- true neutral (RESET puts back exactly the captured values), and never
-- guess the quaternion order - Quaternion.new takes (w, x, y, z), proven by
-- read-back 2026-08-17.
return function(ctx)
    local bridge = ctx.bridge

    local TARGETS = {
        { label = "Save desk (GmSavePoint)", component = "chainsaw.GmSavePoint" },
        { label = "Welcome note (GmReadFile)", component = "chainsaw.GmReadFile" },
    }

    -- ABSOLUTE world values, not deltas (Cam, 2026-08-24 round 3: eye-drag
    -- offsets drifted "way off left" - real coordinates in the widget make
    -- what you see, what you bake). pos and rot seed from the live
    -- transform on ATTACH; Ctrl+click any drag field to type a number.
    local nudger = {
        target_index = 1,
        attached = nil,        -- { transform, name, base = {x,y,z}, quat = {w,x,y,z}, descendants }
        pos = { x = 0.0, y = 0.0, z = 0.0 },
        rot = { yaw = 0.0, pitch = 0.0, roll = 0.0 },
        apply_rotation = false,
        wrote_rotation = false,
        status = "not attached",
    }
    ctx.gimmick_nudger = nudger

    local function try(fn)
        local ok, result = pcall(fn)
        if ok then return result end
        return nil
    end

    -- Local copy of the array walk (same as ui_boat_spike, same reason: a
    -- self-contained dev tool). get_elements() is the walk that works on
    -- these engine containers; the rest are fallbacks.
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
        if type(array) == "table" then
            for _, entry in ipairs(array) do
                if visit(entry) then return true end
            end
        end
        return false
    end

    local function make_vec3(x, y, z)
        if Vector3f == nil or Vector3f.new == nil then return nil end
        return try(function() return Vector3f.new(x, y, z) end)
    end

    -- Euler degrees to quaternion (ZYX), same math the model tuner settled.
    local function euler_to_quat(deg_pitch, deg_yaw, deg_roll)
        local hx, hy, hz = math.rad(deg_pitch) * 0.5, math.rad(deg_yaw) * 0.5, math.rad(deg_roll) * 0.5
        local cx, sx = math.cos(hx), math.sin(hx)
        local cy, sy = math.cos(hy), math.sin(hy)
        local cz, sz = math.cos(hz), math.sin(hz)
        return {
            x = sx * cy * cz - cx * sy * sz,
            y = cx * sy * cz + sx * cy * sz,
            z = cx * cy * sz - sx * sy * cz,
            w = cx * cy * cz + sx * sy * sz,
        }
    end

    local function make_quat(q)
        if Quaternion == nil or Quaternion.new == nil then return nil end
        return try(function() return Quaternion.new(q.w, q.x, q.y, q.z) end)
    end

    -- The inverse of euler_to_quat, so ATTACH can seed the rotation fields
    -- with the object's REAL current angles. Same slot convention (pitch
    -- about X, yaw about Y, roll about Z); the pitch=+-90 gimbal edge is
    -- acceptable in a dev tool. Round-trip verified offline against
    -- euler_to_quat over a full angle grid before shipping.
    local function quat_to_euler(q)
        local sinp = 2 * (q.w * q.y - q.z * q.x)
        if sinp > 1 then sinp = 1 elseif sinp < -1 then sinp = -1 end
        return {
            pitch = math.deg(math.atan(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))),
            yaw = math.deg(math.asin(sinp)),
            roll = math.deg(math.atan(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))),
        }
    end

    local function player_position()
        local getter = ctx.get_player_position or _G.get_player_position
        if type(getter) ~= "function" then return nil end
        return try(getter)
    end

    local function distance_sq(a, b)
        local dx = (a.x or 0) - (b.x or 0)
        local dy = (a.y or 0) - (b.y or 0)
        local dz = (a.z or 0) - (b.z or 0)
        return dx * dx + dy * dy + dz * dz
    end

    local function transform_of(component)
        return try(function()
            local game_object = component:call("get_GameObject")
            if game_object == nil then return nil end
            return game_object:call("get_Transform")
        end)
    end

    local function name_of(transform)
        return try(function()
            local game_object = transform:call("get_GameObject")
            return game_object ~= nil and game_object:call("get_Name") or nil
        end)
    end

    -- Move the gimmick ROOT, not the component's own holder. The holder can
    -- be a child interaction object: moving it moves the interact arrow and
    -- leaves the mesh sibling behind (live 2026-08-24, the typewriter's
    -- machine stayed put while the R prompt wandered). The fork names its
    -- roots, so climb the parent chain and prefer the first ancestor with a
    -- known root name; failing that take the topmost transform, and say
    -- which happened so the status line tells on us.
    local ROOT_NAME_PATTERNS = { "^AP_Typewriter", "^Biorand_Document" }

    local function is_root_name(name)
        if type(name) ~= "string" then return false end
        for _, pattern in ipairs(ROOT_NAME_PATTERNS) do
            if string.find(name, pattern) ~= nil then return true end
        end
        return false
    end

    local function climb_to_root(transform)
        local current = transform
        local hops = 0
        while current ~= nil and hops < 16 do
            local current_name = name_of(current)
            if is_root_name(current_name) then
                return current, tostring(current_name), "named root"
            end
            local parent = try(function() return current:call("get_Parent") end)
            if parent == nil then
                return current, tostring(current_name), "topmost"
            end
            current = parent
            hops = hops + 1
        end
        return transform, tostring(name_of(transform)), "climb gave up"
    end

    local function component_names(game_object)
        local names = {}
        local components = try(function() return game_object:call("get_Components") end)
        each_entry(components, function(component)
            local type_name = try(function()
                return component:get_type_definition():get_full_name()
            end)
            if type_name ~= nil then names[#names + 1] = type_name end
            return false
        end)
        return table.concat(names, ", ")
    end

    -- The engine hides a gimmick's children from get_Children (live
    -- 2026-08-24: AP_Typewriter_0 dumps no mesh component and no walkable
    -- children, yet the machine renders). So find descendants the other way
    -- round: walk EVERY via.Transform in the scene and keep the ones whose
    -- parent chain reaches the attached root's name. One-shot per attach;
    -- a dev-tool hitch is fine.
    local function collect_descendants(root_name)
        local getter = ctx.get_components or _G.get_components
        if type(getter) ~= "function" then return {} end
        local transforms = try(function() return getter("via.Transform") end)
        if transforms == nil then return {} end

        local found = {}
        each_entry(transforms, function(transform)
            if transform ~= nil then
                local current = try(function() return transform:call("get_Parent") end)
                local hops = 0
                while current ~= nil and hops < 16 do
                    if name_of(current) == root_name then
                        local pos = try(function() return transform:call("get_Position") end)
                        if pos ~= nil then
                            found[#found + 1] = {
                                transform = transform,
                                name = tostring(name_of(transform)),
                                base = { x = pos.x, y = pos.y, z = pos.z },
                            }
                        end
                        break
                    end
                    current = try(function() return current:call("get_Parent") end)
                    hops = hops + 1
                end
            end
            return false
        end)
        return found
    end

    -- One click of ground truth: log the attached gimmick's family - parent
    -- chain up, children down - with names, components and world positions.
    -- If moving the root still leaves a mesh behind, this is what says
    -- whether the mesh is a sibling outside the tree or a static that never
    -- follows a runtime transform at all.
    local function dump_hierarchy()
        local a = nudger.attached
        if a == nil then return end
        log.info("[RE4R AP][gimmick nudger] --- hierarchy dump ---")

        local current = a.transform
        local depth = 0
        while current ~= nil and depth < 16 do
            local game_object = try(function() return current:call("get_GameObject") end)
            local pos = try(function() return current:call("get_Position") end)
            log.info(string.format(
                "[RE4R AP][gimmick nudger] up %d: %s (%.2f, %.2f, %.2f) [%s]",
                depth,
                tostring(game_object ~= nil and try(function() return game_object:call("get_Name") end) or "?"),
                pos and pos.x or 0, pos and pos.y or 0, pos and pos.z or 0,
                game_object ~= nil and component_names(game_object) or "?"))
            current = try(function() return current:call("get_Parent") end)
            depth = depth + 1
        end

        -- Descendants come from the inverse transform scan; get_Children is
        -- blind to them on these gimmicks (proven on AP_Typewriter_0).
        local descendants = a.descendants or {}
        if #descendants == 0 then
            log.info("[RE4R AP][gimmick nudger] no descendants found by transform scan")
        end
        for _, child in ipairs(descendants) do
            local game_object = try(function() return child.transform:call("get_GameObject") end)
            local pos = try(function() return child.transform:call("get_Position") end)
            log.info(string.format(
                "[RE4R AP][gimmick nudger] down: %s (%.2f, %.2f, %.2f) [%s]",
                child.name,
                pos and pos.x or 0, pos and pos.y or 0, pos and pos.z or 0,
                game_object ~= nil and component_names(game_object) or "?"))
        end
        nudger.status = string.format("hierarchy logged (%d descendant(s))", #descendants)
    end

    local function attach_nearest()
        local getter = ctx.get_components or _G.get_components
        if type(getter) ~= "function" then
            nudger.status = "component enumeration unavailable"
            return
        end
        local origin = player_position()
        if origin == nil then
            nudger.status = "no player position (load into the game first)"
            return
        end

        local wanted = TARGETS[nudger.target_index].component
        local components = try(function() return getter(wanted) end)
        if components == nil then
            nudger.status = "no " .. wanted .. " in the loaded area"
            return
        end

        local best, best_d = nil, nil
        each_entry(components, function(component)
            if component ~= nil then
                local transform = transform_of(component)
                local pos = transform ~= nil
                    and try(function() return transform:call("get_Position") end) or nil
                if pos ~= nil then
                    local d = distance_sq(origin, pos)
                    if best_d == nil or d < best_d then
                        best_d = d
                        best = { component = component, transform = transform, pos = pos }
                    end
                end
            end
            return false
        end)

        if best == nil then
            nudger.status = "found none with a readable transform"
            return
        end

        local root_transform, root_name, how = climb_to_root(best.transform)
        local root_pos = try(function() return root_transform:call("get_Position") end)
        if root_pos == nil then
            nudger.status = "root transform unreadable - reattach"
            return
        end
        local quat = try(function() return root_transform:call("get_Rotation") end)
        local captured_quat = quat ~= nil and {
            w = try(function() return quat.w end) or 1,
            x = try(function() return quat.x end) or 0,
            y = try(function() return quat.y end) or 0,
            z = try(function() return quat.z end) or 0,
        } or nil
        nudger.attached = {
            transform = root_transform,
            name = root_name,
            base = { x = root_pos.x, y = root_pos.y, z = root_pos.z },
            quat = captured_quat,
            descendants = collect_descendants(root_name),
        }
        -- Seed POSITION with reality; rotation fields stay write-only. A
        -- rotation has many euler names, the decoder picks one in ITS
        -- dialect (which differs from the fork's), and near yaw 90 the
        -- names look nothing like what was typed - adjusting from a
        -- re-decoded name compounds into nonsense (Cam, live rounds 9-16).
        -- Typed values are fork-dialect, the same numbers that get baked.
        nudger.pos.x, nudger.pos.y, nudger.pos.z = root_pos.x, root_pos.y, root_pos.z
        nudger.rot.yaw, nudger.rot.pitch, nudger.rot.roll = 0.0, 0.0, 0.0
        nudger.apply_rotation = false
        nudger.wrote_rotation = false
        nudger.status = string.format(
            "attached to %s (%s) at %.1fm, %d descendant(s) tracked",
            root_name, how, math.sqrt(best_d), #nudger.attached.descendants)
    end

    -- The straggler sweep still thinks in deltas: each locked mesh child
    -- gets its captured base plus however far the root travelled from ITS
    -- base, which with absolute fields is simply pos minus base.
    local function root_delta()
        local a = nudger.attached
        if a == nil then return { x = 0.0, y = 0.0, z = 0.0 } end
        return {
            x = nudger.pos.x - a.base.x,
            y = nudger.pos.y - a.base.y,
            z = nudger.pos.z - a.base.z,
        }
    end

    -- After moving the root, sweep the tracked descendants and place any
    -- that did not follow. Followers are left alone (correcting them too
    -- would double-move); stragglers - the mesh children that ignore their
    -- parent - get their world position set outright. Rotation stays
    -- root-only: orbiting stragglers around the root is repatch territory.
    local function correct_descendants(delta)
        local a = nudger.attached
        if a == nil then return 0 end
        local corrected = 0
        for _, child in ipairs(a.descendants or {}) do
            local expected = {
                x = child.base.x + delta.x,
                y = child.base.y + delta.y,
                z = child.base.z + delta.z,
            }
            local actual = try(function() return child.transform:call("get_Position") end)
            local followed = actual ~= nil
                and math.abs(actual.x - expected.x) < 0.001
                and math.abs(actual.y - expected.y) < 0.001
                and math.abs(actual.z - expected.z) < 0.001
            if not followed then
                local vec = make_vec3(expected.x, expected.y, expected.z)
                if vec ~= nil and try(function()
                    child.transform:call("set_Position", vec)
                    return true
                end) == true then
                    corrected = corrected + 1
                end
            end
        end
        return corrected
    end

    local function apply()
        local a = nudger.attached
        if a == nil then return end
        local vec = make_vec3(nudger.pos.x, nudger.pos.y, nudger.pos.z)
        if vec == nil then
            nudger.status = "could not build a via.vec3"
            return
        end
        local ok = try(function()
            a.transform:call("set_Position", vec)
            if nudger.apply_rotation then
                local rotation = make_quat(euler_to_quat(
                    nudger.rot.pitch, nudger.rot.yaw, nudger.rot.roll))
                if rotation ~= nil then
                    a.transform:call("set_Rotation", rotation)
                    nudger.wrote_rotation = true
                end
            end
            return true
        end)
        if ok ~= true then
            nudger.status = "transform write failed (stale attach? reattach)"
            return
        end
        local corrected = correct_descendants(root_delta())
        nudger.status = corrected > 0
            and string.format("applied (%d straggler(s) placed)", corrected)
            or "applied"
    end

    local function reset()
        local a = nudger.attached
        if a == nil then return end
        nudger.pos.x, nudger.pos.y, nudger.pos.z = a.base.x, a.base.y, a.base.z
        nudger.rot.yaw, nudger.rot.pitch, nudger.rot.roll = 0.0, 0.0, 0.0
        nudger.apply_rotation = false
        local vec = make_vec3(a.base.x, a.base.y, a.base.z)
        try(function()
            a.transform:call("set_Position", vec)
            if nudger.wrote_rotation and a.quat ~= nil then
                local rotation = make_quat(a.quat)
                if rotation ~= nil then a.transform:call("set_Rotation", rotation) end
            end
            return true
        end)
        correct_descendants({ x = 0.0, y = 0.0, z = 0.0 })
        nudger.wrote_rotation = false
        nudger.status = "reset to captured values"
    end

    local function bake_line()
        if nudger.attached == nil then return "attach first" end
        local pos = nudger.pos
        local state = bridge.last_state or {}
        local stage = tostring(state.current_stage or "?")
        -- Rotation appears only when the player TYPED one this session;
        -- otherwise the line says so, and the fork keeps its current bake.
        local rot = nudger.apply_rotation
            and string.format("Yaw=%.1f Pitch=%.1f Roll=%.1f",
                nudger.rot.yaw, nudger.rot.pitch, nudger.rot.roll)
            or "rot=(keep current bake)"
        return string.format(
            "stage=%s  X=%.3f  Y=%.3f  Z=%.3f  %s",
            stage, pos.x, pos.y, pos.z, rot)
    end

    local function draw_gimmick_nudger()
        if bridge.developer_tools_enabled ~= true
            or bridge.gimmick_nudger_window_enabled ~= true then
            return
        end

        bridge.gimmick_nudger_window_enabled =
            imgui.begin_window("AP Gimmick Nudger", true)
        if bridge.gimmick_nudger_window_enabled ~= true then
            imgui.end_window()
            return
        end

        imgui.text("Stand next to the thing you mean, pick its kind, ATTACH,")
        imgui.text("then drag. Numbers below go back into the fork.")

        -- Live player readout: the reference point every placement is
        -- eyeballed against, and the source for the snap button below.
        local player = player_position()
        local state = bridge.last_state or {}
        if player ~= nil and type(player.x) == "number" then
            imgui.text(string.format(
                "Player: X=%.3f  Y=%.3f  Z=%.3f  (stage %s)",
                player.x, player.y, player.z, tostring(state.current_stage or "?")))
        else
            imgui.text("Player: position unavailable")
        end

        local changed_target, target_value = imgui.combo(
            "Target", nudger.target_index,
            { TARGETS[1].label, TARGETS[2].label })
        if changed_target then
            nudger.target_index = target_value
            nudger.attached = nil
            nudger.status = "target changed - reattach"
        end

        if imgui.button("ATTACH nearest") then attach_nearest() end
        imgui.same_line()
        imgui.text(nudger.status)

        if nudger.attached ~= nil then
            -- Absolute world values, seeded from the live transform on
            -- ATTACH. Ctrl+click a field to type an exact number.
            local changed = false
            local c, v
            c, v = imgui.drag_float("World X", nudger.pos.x, 0.01, -100000.0, 100000.0)
            if c then nudger.pos.x = v; changed = true end
            c, v = imgui.drag_float("World Y", nudger.pos.y, 0.01, -100000.0, 100000.0)
            if c then nudger.pos.y = v; changed = true end
            c, v = imgui.drag_float("World Z", nudger.pos.z, 0.01, -100000.0, 100000.0)
            if c then nudger.pos.z = v; changed = true end

            local changed_rot_toggle, rot_enabled =
                imgui.checkbox("Also apply rotation (write-only, fork-dialect angles)", nudger.apply_rotation)
            if changed_rot_toggle then nudger.apply_rotation = rot_enabled; changed = true end
            if nudger.apply_rotation then
                c, v = imgui.drag_float("Yaw", nudger.rot.yaw, 0.5, -180.0, 180.0)
                if c then nudger.rot.yaw = v; changed = true end
                c, v = imgui.drag_float("Pitch", nudger.rot.pitch, 0.5, -180.0, 180.0)
                if c then nudger.rot.pitch = v; changed = true end
                c, v = imgui.drag_float("Roll", nudger.rot.roll, 0.5, -180.0, 180.0)
                if c then nudger.rot.roll = v; changed = true end
            end
            if changed then apply() end

            if imgui.button("Fields = player position") then
                local p = player_position()
                if p ~= nil and type(p.x) == "number" then
                    nudger.pos.x, nudger.pos.y, nudger.pos.z = p.x, p.y, p.z
                    apply()
                else
                    nudger.status = "player position unavailable"
                end
            end

            if imgui.button("RESET to captured") then reset() end
            imgui.same_line()
            if imgui.button("Dump hierarchy to log") then dump_hierarchy() end

            imgui.text("--- numbers to bake ---")
            imgui.text(bake_line())
            if imgui.button("Log bake line") then
                log.info("[RE4R AP][gimmick nudger] " .. nudger.attached.name .. "  " .. bake_line())
                nudger.status = "bake line logged"
            end
        end

        imgui.end_window()
    end

    ctx.draw_gimmick_nudger = draw_gimmick_nudger
    _G.draw_gimmick_nudger = draw_gimmick_nudger
end
