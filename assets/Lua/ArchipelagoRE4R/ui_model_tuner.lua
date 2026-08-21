-- ui_model_tuner.lua - dial in the AP shop model's placement, live.
--
-- The minted AP prefab inherits the fuel canister donor's transform, so the
-- model renders over the tab bar instead of the display area.
-- InGameShopManager.registerItemModelParam(ItemID, ItemModelData) can override
-- that at runtime, which turns an exe-rebuild-per-attempt problem into sliders.
--
-- ROUND 1 FAILED AND COST CAM THE MODEL (2026-08-17). Two mistakes worth not
-- repeating:
--   * It CONSTRUCTED an ItemModelData with sdk.create_instance and never
--     checked the result. Everything else in this engine has needed a borrowed
--     object or a specific route (via.vec3 needs Vector3f, ShopItemParam needs
--     set_field), so assuming a nested userdata builds clean was a guess.
--   * It had NO TRUE NEUTRAL. Zeroing the sliders is not "the pak default":
--     registering any entry overrides the prefab, so "recenter" was just
--     another wrong position and there was no way home short of restarting the
--     game. Registrations live in the manager, not in Lua, so Reset Scripts
--     does not clear them.
--
-- So this round READS before it writes. _ItemModelSettingTable is a live
-- Dictionary<ItemID, ItemModelData> on the manager: capture what is really
-- there, seed the sliders from it, edit THAT object, and keep the captured
-- values so restore puts back something real.
return function(ctx)
    local bridge = ctx.bridge

    local tuner = {
        -- Cam's dialled-in placement, 2026-08-17. Defaults so a Reset Scripts
        -- does not throw the work away; these are the numbers to bake.
        offset = { x = 0.325, y = 0.000, z = 0.175 },
        scale = 1.0,
        rot = { x = 0.0, y = 0.0, z = 0.0 },
        -- SETTLED live 2026-08-17: Quaternion.new takes (w, x, y, z).
        -- Proven by read-back - the value passed as arg2 came back as x.
        -- The old (x,y,z,w) guess built (w=0,x=0,y=0,z=1) at "zero", a
        -- 180 degree flip, which is why zeroing the tilt never undid it.
        quat_order = "wxyz",
        status = "press READ first",
        captured = nil,
        baseline_note = "not read yet",
        seeded = false,
    }
    ctx.model_tuner = tuner

    local function try(fn)
        local ok, result = pcall(fn)
        if ok then return result end
        return nil
    end

    local function vec3(x, y, z)
        if Vector3f == nil or Vector3f.new == nil then return nil end
        return try(function() return Vector3f.new(x, y, z) end)
    end

    -- Euler degrees to quaternion (ZYX). The engine wants a via.Quaternion,
    -- and Quaternion.new's argument order is not documented anywhere we can
    -- see - guessing it is what produced an unboardable boat earlier today.
    -- So: build it, write it, READ IT BACK, and if the components landed
    -- permuted, remember the other order and use that from then on.
    local function euler_to_quat(deg_x, deg_y, deg_z)
        local hx, hy, hz = math.rad(deg_x) * 0.5, math.rad(deg_y) * 0.5, math.rad(deg_z) * 0.5
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
        if tuner.quat_order == "wxyz" then
            return try(function() return Quaternion.new(q.w, q.x, q.y, q.z) end)
        end
        return try(function() return Quaternion.new(q.x, q.y, q.z, q.w) end)
    end

    local function shop_manager()
        return sdk.get_managed_singleton("chainsaw.InGameShopManager")
    end

    local function model_table()
        local manager = shop_manager()
        if manager == nil then return nil end
        return try(function() return manager:get_field("_ItemModelSettingTable") end)
    end

    -- The live entry for an id, or nil when the game has none - in which case
    -- the prefab's own transform is doing the work and registering ANYTHING
    -- will move the model.
    local function entry_for(item_id)
        local tbl = model_table()
        if tbl == nil then return nil end
        local has = try(function() return tbl:call("ContainsKey", item_id) end)
        if has ~= true then return nil end
        return try(function() return tbl:call("get_Item", item_id) end)
    end

    local function read_xyz(data, getter)
        local v = try(function() return data:call(getter) end)
        if v == nil then return nil end
        local x = try(function() return v.x end)
        local y = try(function() return v.y end)
        local z = try(function() return v.z end)
        if x == nil then return nil end
        return { x = x, y = y, z = z }
    end

    local function ap_model_rows()
        local ids = {}
        local merchant = ctx.merchant
        if merchant == nil or type(merchant.rows) ~= "table" then return ids end
        for _, row in ipairs(merchant.rows) do
            local check = merchant.slots_by_item and merchant.slots_by_item[row.item_id]
            if check == nil or check.remote or (check.item_id_real or 0) <= 0 then
                ids[#ids + 1] = row.item_id
            end
        end
        return ids
    end

    -- What does the game actually hold, for our rows and for ordinary items
    -- that display correctly? If our rows have no entry and a working item
    -- does, that item's values are the right starting point, not zeros.
    local function read_table()
        local tbl = model_table()
        if tbl == nil then
            tuner.status = "no _ItemModelSettingTable (open the shop first)"
            return
        end
        local count = try(function() return tbl:call("get_Count") end)
        local ours, sample = 0, nil

        for _, item_id in ipairs(ap_model_rows()) do
            local data = entry_for(item_id)
            if data ~= nil then
                ours = ours + 1
                local off = read_xyz(data, "get_OffsetPosition")
                local scl = read_xyz(data, "get_Scale")
                if off ~= nil then
                    log.info(string.format(
                        "[RE4R AP][model tuner] AP row %d offset=(%.3f, %.3f, %.3f) scale=(%.3f, %.3f, %.3f)",
                        item_id, off.x, off.y, off.z,
                        scl and scl.x or -1, scl and scl.y or -1, scl and scl.z or -1))
                    if sample == nil then sample = { offset = off, scale = scl } end
                end
            end
        end

        -- Ordinary rows for comparison: First Aid Spray, Handcannon, Handgun Ammo.
        for _, probe in ipairs({ 114416000, 275638656, 112800000 }) do
            local data = entry_for(probe)
            if data ~= nil then
                local off = read_xyz(data, "get_OffsetPosition")
                local scl = read_xyz(data, "get_Scale")
                if off ~= nil then
                    log.info(string.format(
                        "[RE4R AP][model tuner] vanilla %d offset=(%.3f, %.3f, %.3f) scale=(%.3f, %.3f, %.3f)",
                        probe, off.x, off.y, off.z,
                        scl and scl.x or -1, scl and scl.y or -1, scl and scl.z or -1))
                    if sample == nil then sample = { offset = off, scale = scl } end
                end
            end
        end

        tuner.baseline_note = string.format(
            "table holds %s entries; %d of our %d rows are in it",
            tostring(count), ours, #ap_model_rows())
        log.info("[RE4R AP][model tuner] " .. tuner.baseline_note)

        if sample ~= nil and not tuner.seeded then
            tuner.offset.x, tuner.offset.y, tuner.offset.z =
                sample.offset.x, sample.offset.y, sample.offset.z
            if sample.scale ~= nil and sample.scale.x > 0 then
                tuner.scale = sample.scale.x
            end
            tuner.seeded = true
            tuner.status = "sliders seeded from a real entry (values in the log)"
        else
            tuner.status = tuner.baseline_note
        end
    end

    -- Edit the LIVE object where one exists; only construct when the game has
    -- no entry, and report that separately, because that is the case that
    -- overrides the prefab.
    local function apply()
        local manager = shop_manager()
        if manager == nil then
            tuner.status = "InGameShopManager unavailable"
            return
        end
        local ids = ap_model_rows()
        if #ids == 0 then
            tuner.status = "no AP-model rows on this shelf"
            return
        end
        local offset = vec3(tuner.offset.x, tuner.offset.y, tuner.offset.z)
        local scale = vec3(tuner.scale, tuner.scale, tuner.scale)
        if offset == nil or scale == nil then
            tuner.status = "could not build a via.vec3"
            return
        end
        local wanted = euler_to_quat(tuner.rot.x, tuner.rot.y, tuner.rot.z)
        local rotation = make_quat(wanted)

        tuner.captured = tuner.captured or {}
        local edited, minted, refused = 0, 0, 0
        for _, item_id in ipairs(ids) do
            local data = entry_for(item_id)
            local is_new = false
            if data == nil then
                data = try(function()
                    return sdk.create_instance(
                        "chainsaw.InGameShopItemModelParamUserData.ItemModelData")
                end)
                is_new = true
            elseif tuner.captured[item_id] == nil then
                tuner.captured[item_id] = {
                    offset = read_xyz(data, "get_OffsetPosition"),
                    scale = read_xyz(data, "get_Scale"),
                }
            end
            if data == nil then
                refused = refused + 1
            else
                local ok = try(function()
                    data:call("set_ItemID", item_id)
                    data:call("set_OffsetPosition", offset)
                    data:call("set_Scale", scale)
                    if rotation ~= nil then
                        data:call("set_Rotation", rotation)
                    end
                    manager:call("registerItemModelParam", item_id, data)
                    return true
                end)
                if ok == true then
                    if is_new then minted = minted + 1 else edited = edited + 1 end
                else
                    refused = refused + 1
                end
            end
        end
        -- Order is settled; keep a cheap sanity read so a future engine
        -- change cannot silently go back to guessing.
        if rotation ~= nil and not tuner.rot_verified then
            local probe = entry_for(ids[1])
            local got = probe and try(function() return probe:call("get_Rotation") end) or nil
            local gx = got and try(function() return got.x end) or nil
            if gx ~= nil then
                tuner.rot_verified = true
                local ok = math.abs(gx - wanted.x) < 0.01
                log.info(string.format(
                    "[RE4R AP][model tuner] rotation read-back x=%.4f wanted=%.4f -> %s",
                    gx, wanted.x, ok and "correct" or "STILL WRONG"))
            end
        end

        tuner.status = string.format(
            "%d edited in place, %d newly registered%s",
            edited, minted,
            refused > 0 and string.format(", %d refused", refused) or "")
        log.info(string.format(
            "[RE4R AP][model tuner] offset=(%.3f, %.3f, %.3f) scale=%.3f -> %d edited, %d minted",
            tuner.offset.x, tuner.offset.y, tuner.offset.z, tuner.scale, edited, minted))
    end

    -- Put back exactly what was there when we first touched it, and drop any
    -- registration we minted ourselves.
    local function restore()
        local manager = shop_manager()
        if manager == nil then
            tuner.status = "InGameShopManager unavailable"
            return
        end
        local restored, dropped = 0, 0
        for _, item_id in ipairs(ap_model_rows()) do
            local original = tuner.captured and tuner.captured[item_id]
            local data = entry_for(item_id)
            if original ~= nil and original.offset ~= nil and data ~= nil then
                local off = vec3(original.offset.x, original.offset.y, original.offset.z)
                local scl = original.scale
                    and vec3(original.scale.x, original.scale.y, original.scale.z) or nil
                if try(function()
                    data:call("set_OffsetPosition", off)
                    if scl ~= nil then data:call("set_Scale", scl) end
                    manager:call("registerItemModelParam", item_id, data)
                    return true
                end) == true then
                    restored = restored + 1
                end
            else
                if try(function()
                    manager:call("unregisterItemModelParam", item_id)
                    return true
                end) == true then
                    dropped = dropped + 1
                end
            end
        end
        tuner.status = string.format(
            "%d restored, %d registrations dropped - reopen the shop",
            restored, dropped)
        log.info("[RE4R AP][model tuner] " .. tuner.status)
    end

    local function draw_model_tuner()
        if bridge.developer_tools_enabled ~= true
            or bridge.model_tuner_window_enabled ~= true then
            return
        end

        bridge.model_tuner_window_enabled =
            imgui.begin_window("AP Shop Model Tuner", true)
        if bridge.model_tuner_window_enabled ~= true then
            imgui.end_window()
            return
        end

        imgui.text("1. Open the merchant BUY tab.  2. READ.  3. Then drag.")
        imgui.text("READ seeds the sliders from a real entry and logs what the")
        imgui.text("game holds. Dragging blind is what lost the model last time.")
        imgui.text(tuner.baseline_note)
        imgui.text(string.format("AP-model rows on this shelf: %d", #ap_model_rows()))

        if imgui.button("READ what is registered") then read_table() end

        local changed = false
        local c, v
        c, v = imgui.drag_float("Offset X", tuner.offset.x, 0.005, -2.0, 2.0)
        if c then tuner.offset.x = v; changed = true end
        c, v = imgui.drag_float("Offset Y", tuner.offset.y, 0.005, -2.0, 2.0)
        if c then tuner.offset.y = v; changed = true end
        c, v = imgui.drag_float("Offset Z", tuner.offset.z, 0.005, -2.0, 2.0)
        if c then tuner.offset.z = v; changed = true end
        c, v = imgui.drag_float("Scale", tuner.scale, 0.01, 0.25, 3.0)
        if c then tuner.scale = v; changed = true end
        c, v = imgui.drag_float("Tilt X (pitch)", tuner.rot.x, 0.5, -180.0, 180.0)
        if c then tuner.rot.x = v; changed = true end
        c, v = imgui.drag_float("Tilt Y (yaw)", tuner.rot.y, 0.5, -180.0, 180.0)
        if c then tuner.rot.y = v; changed = true end
        c, v = imgui.drag_float("Tilt Z (roll)", tuner.rot.z, 0.5, -180.0, 180.0)
        if c then tuner.rot.z = v; changed = true end
        if changed then apply() end

        if imgui.button("Apply now") then apply() end
        if imgui.button("RESTORE captured values") then restore() end

        imgui.text(tuner.status)
        imgui.text("--- numbers to bake ---")
        imgui.text(string.format("OffsetPosition = (%.3f, %.3f, %.3f)   Scale = %.3f",
            tuner.offset.x, tuner.offset.y, tuner.offset.z, tuner.scale))
        imgui.text(string.format("Rotation (deg) = (%.1f, %.1f, %.1f)  quat order: %s",
            tuner.rot.x, tuner.rot.y, tuner.rot.z, tostring(tuner.quat_order or "xyzw")))
        imgui.text("Lost it? RESTORE. If that fails, restart the GAME - Reset")
        imgui.text("Scripts does not clear registrations, they live in the manager.")

        imgui.end_window()
    end

    ctx.draw_model_tuner = draw_model_tuner
    _G.draw_model_tuner = draw_model_tuner
end
