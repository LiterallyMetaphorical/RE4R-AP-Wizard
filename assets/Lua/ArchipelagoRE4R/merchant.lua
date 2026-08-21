-- merchant.lua - the AP-aware merchant's runtime half (D4).
--
-- The fork writes the shop catalog at patch time: one buy-tab row per shop
-- check, on a stand-in item id, priced by the credit-check tier, stock 1 so
-- the game's own SOLD OUT panel does the bookkeeping. Everything that has to
-- happen WHEN the player buys one lives here.
--
-- On purchase (chainsaw.InGameShopManager.notifyPurchaseItem, the exact twin
-- of the notifySellItems hook the storage reconciler rides):
--   1. queue the slot's location check (bridge.pending_checks, same queue the
--      detector fills, so room filtering / ack set / persistence all apply)
--   2. hand back the tier's gemstone when the purchase helped someone else
--      (or bought back your OWN progression) - the credit check: you must
--      HAVE the money, you do not lose it. Treasures sell at full value and
--      live in the treasure tab, so the refund is exactly recoverable and can
--      never fail for case space.
--   3. push the refund toast onto the native rail, after the normal sent-item
--      toast the delivery path already shows
--   4. arm a save: buying is a real transaction and the shop's stock lives in
--      the per-save blob, so we ask for a game save when the player closes the
--      shop (one save per visit, not per purchase, and the shop screen is a
--      safe moment - no combat, no cutscene)
--
-- Correctness does NOT depend on that save. Shop stock rolls back with the
-- save; the server's checked list never does. So on connect and on every shop
-- open we FORWARD-RECONCILE: any slot whose location is already checked gets
-- its stock zeroed, which is the inverse of the marker rollback (D8) and
-- makes a re-purchase impossible rather than merely unlikely. If a
-- reconcile ever loses the race, a second purchase is still economically
-- neutral - the player pays again and is refunded again.
--
-- Everything is defensive: an old room file with no merchant section, a
-- missing method, a failed grant - each degrades to "log it and behave like
-- the merchant always did".
return function(ctx)
    local bridge = ctx.bridge

    local merchant = {
        -- standin item id -> slot record from the room file
        slots_by_item = {},
        -- location_code -> slot record
        slots_by_location = {},
        slot_count = 0,
        hooks_installed = false,
        save_armed = false,
        purchases_this_session = 0,
    }
    ctx.merchant = merchant

    local function info(text)
        log.info("[RE4R AP][merchant] " .. tostring(text))
    end

    local function shop_manager()
        return sdk.get_managed_singleton("chainsaw.InGameShopManager")
    end

    -- ------------------------------------------------------------- room file
    -- The launcher stamps "merchant_shop" into ap_room_locations.json beside
    -- the location ids (same channel as D5's allow_bonus_items). Slot records
    -- carry everything the runtime needs, so the mod never has to know the
    -- tier table or the stand-in id assignment.
    local function load_slots(payload)
        merchant.slots_by_item = {}
        merchant.slots_by_location = {}
        merchant.slot_count = 0
        if type(payload) ~= "table" or type(payload.slots) ~= "table" then
            return
        end
        for _, raw in ipairs(payload.slots) do
            local item_id = tonumber(raw and raw.standin_item_id)
            local location_code = tonumber(raw and raw.location_code)
            if item_id ~= nil and location_code ~= nil then
                local slot = {
                    item_id = math.floor(item_id),
                    location_code = math.floor(location_code),
                    index = math.floor(tonumber(raw.index) or 0),
                    classification = tostring(raw.classification or "FILLER"),
                    display_name = tostring(raw.display_name or "an item"),
                    player_name = tostring(raw.player_name or ""),
                    remote = (raw.remote == true),
                    price = math.floor(tonumber(raw.price) or 0),
                    refund_item_id = math.floor(tonumber(raw.refund_item_id) or 0),
                    refund_item_name = tostring(raw.refund_item_name or "a gemstone"),
                }
                merchant.slots_by_item[slot.item_id] = slot
                merchant.slots_by_location[slot.location_code] = slot
                merchant.slot_count = merchant.slot_count + 1
            end
        end
        info(string.format("%d shop slot(s) loaded from the room file", merchant.slot_count))
    end

    -- ------------------------------------------------------------ ack helpers
    -- Shop slots have no scene GUID, so they use their own durable key in the
    -- same per-seed ack set every world check uses.
    local function slot_key(slot)
        return string.format("shop:slot:%d", slot.index)
    end

    local function slot_is_checked(slot)
        local acknowledged = bridge and bridge.acknowledged_guid_keys
        if type(acknowledged) == "table" and acknowledged[slot_key(slot)] then
            return true
        end
        return false
    end

    -- --------------------------------------------------------------- purchase
    local function queue_check(slot)
        if type(bridge.pending_checks) ~= "table" then
            return false
        end
        local key = slot_key(slot)
        bridge.pending_check_keys = bridge.pending_check_keys or {}
        if bridge.pending_check_keys[key] then
            return false
        end
        bridge.pending_check_keys[key] = true
        table.insert(bridge.pending_checks, {
            id = bridge.next_pending_check_id or 1,
            guid = nil,
            stage = bridge.last_state and bridge.last_state.current_stage or nil,
            key = key,
            location_id = slot.location_code,
            queued_at_unix_ms = (ctx.now_unix_ms and ctx.now_unix_ms()) or 0,
        })
        bridge.next_pending_check_id = (bridge.next_pending_check_id or 1) + 1
        bridge.state_dirty = true
        return true
    end

    -- Remote purchases refund (you fronted the money for someone else's item)
    -- and so does your OWN progression, which is the one case where a price
    -- could otherwise stand between a player and something they need.
    local function refund_is_due(slot)
        if slot.remote then return true end
        return slot.classification == "PROGRESSION"
    end

    local function grant_refund(slot)
        if slot.refund_item_id <= 0 then
            return false, "no refund item id in the room file"
        end
        local inject = ctx.inject_item_to_inventory or _G.inject_item_to_inventory
        local succeeded = ctx.inject_status_succeeded or _G.inject_status_succeeded
        if type(inject) ~= "function" then
            return false, "injection unavailable"
        end
        local status = tostring(inject(slot.refund_item_id, 1))
        if type(succeeded) == "function" and not succeeded(status) then
            return false, status
        end
        return true, status
    end

    local function push_toast(text)
        local push = ctx.push_native_text or _G.push_native_text
        if type(push) == "function" then
            pcall(push, text)
        end
    end

    -- ------------------------------------------------- stand-in suppression
    -- Buying a slot hands the player the stand-in item itself: the row has to
    -- BE something for the shop to sell it. The stand-in is the AP placeholder
    -- (a Separate Ways trinket the fork re-skins per slot), so what lands is a
    -- worthless duplicate of the row you just bought. Sweep it back out.
    --
    -- Deliberately id-gated and safe-failing: it only ever touches ids this
    -- room's own slots use, and a stand-in it cannot find is logged and left
    -- alone. Removal keys on the INVENTORY-INSTANCE guid (reduce takes a Guid,
    -- not an ItemID), so the sweep enumerates, matches on item id, and reduces
    -- by guid.
    --
    -- NOTE (unconfirmed offline): which inventory a purchased treasure-kind
    -- item lands in has not been observed - vanilla never sells treasures. The
    -- sweep looks in the treasure inventory, which is where the mod's own
    -- treasure delivery routes; if the live test shows it landing elsewhere,
    -- the "not found" log line below says so and the resolver gains a case.
    local function resolve_treasure_controller()
        local character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
        if character_manager == nil then return nil end
        local player = nil
        pcall(function() player = character_manager:call("getPlayerContextRef()") end)
        if player == nil then
            pcall(function() player = character_manager:call("getPlayerContextRef") end)
        end
        if player == nil then return nil end
        local head_updater = nil
        pcall(function() head_updater = player:call("get_HeadUpdater()") end)
        if head_updater == nil then
            pcall(function() head_updater = player:call("get_HeadUpdater") end)
        end
        if head_updater == nil then return nil end
        local controller = nil
        pcall(function() controller = head_updater:call("get_TreasureInventoryController()") end)
        if controller == nil then
            pcall(function() controller = head_updater:call("get_TreasureInventoryController") end)
        end
        return controller
    end

    -- An inventory entry wraps the item; both the wrapper and the inner item
    -- have been seen carrying the id in this codebase, so try both. The
    -- instance guid likewise lives under one of a few names across the
    -- inventory types.
    local ITEM_ID_FIELDS = { "_ItemId", "_ItemID" }
    local INSTANCE_GUID_FIELDS = { "_Id", "_ID", "_Guid", "_InventoryItemId" }

    local function read_first_field(managed, names)
        for _, name in ipairs(names) do
            local value = nil
            local ok = pcall(function() value = managed:get_field(name) end)
            if ok and value ~= nil then
                return value
            end
        end
        return nil
    end

    local function entry_item_id(entry)
        local direct = tonumber(read_first_field(entry, ITEM_ID_FIELDS))
        if direct ~= nil then return math.floor(direct) end
        local inner = nil
        pcall(function() inner = entry:get_field("_Item") end)
        if inner ~= nil then
            local nested = tonumber(read_first_field(inner, ITEM_ID_FIELDS))
            if nested ~= nil then return math.floor(nested) end
        end
        return nil
    end

    local function suppress_standin(item_id)
        local controller = resolve_treasure_controller()
        if controller == nil then
            info(string.format("stand-in %d left in place (treasure controller unavailable)", item_id))
            return
        end
        local items = nil
        pcall(function() items = controller:call("getInventoryItems") end)
        if items == nil then
            pcall(function() items = controller:call("getInventoryItems()") end)
        end
        if items == nil then
            info(string.format("stand-in %d left in place (inventory list unavailable)", item_id))
            return
        end
        local count = nil
        pcall(function() count = items:call("get_Count") end)
        count = tonumber(count)
        if count == nil then
            info(string.format("stand-in %d left in place (inventory count unavailable)", item_id))
            return
        end
        local removed = 0
        for index = 0, count - 1 do
            local entry = nil
            pcall(function() entry = items:call("get_Item", index) end)
            if entry ~= nil and entry_item_id(entry) == item_id then
                local guid = read_first_field(entry, INSTANCE_GUID_FIELDS)
                if guid ~= nil then
                    local ok = pcall(function() controller:call("remove", guid) end)
                    if ok then removed = removed + 1 end
                end
            end
        end
        if removed > 0 then
            info(string.format("stand-in %d swept from the treasure inventory (%d)", item_id, removed))
        else
            -- The live test reads this line: it means the purchased stand-in
            -- is somewhere the sweep does not look yet.
            info(string.format(
                "stand-in %d NOT found in the treasure inventory after purchase - it may live elsewhere",
                item_id))
        end
    end

    local function on_purchase(item_id)
        local slot = merchant.slots_by_item[item_id]
        if slot == nil then
            return
        end

        merchant.purchases_this_session = merchant.purchases_this_session + 1
        merchant.save_armed = true

        -- The row had to BE an item for the shop to sell it; the player wanted
        -- the check, not the trinket. Sweep it before anything else touches
        -- the inventory (the refund gem is added right after).
        local ok_sweep, sweep_err = pcall(suppress_standin, slot.item_id)
        if not ok_sweep then
            info("stand-in sweep error: " .. tostring(sweep_err))
        end

        local queued = queue_check(slot)
        info(string.format(
            "slot %d bought: '%s' (%s, %s)%s",
            slot.index, slot.display_name, slot.player_name, slot.classification,
            queued and "" or " [check already queued]"))

        if refund_is_due(slot) then
            local ok, detail = grant_refund(slot)
            if ok then
                if slot.remote then
                    push_toast(string.format(
                        "Received %s, a refund for helping a fellow stranger.",
                        slot.refund_item_name))
                else
                    push_toast(string.format(
                        "Received %s, the merchant returns your coin.",
                        slot.refund_item_name))
                end
                info(string.format("slot %d refunded %s", slot.index, slot.refund_item_name))
            else
                -- Never silent: the player paid and is owed this.
                info(string.format(
                    "slot %d refund FAILED (%s) - item %d not granted",
                    slot.index, tostring(detail), slot.refund_item_id))
            end
        end
    end

    -- ------------------------------------------------------------- reconcile
    -- Stock lives in the per-save shop blob, so a death after buying puts the
    -- row back on the shelf while the check stays sent. Zero the stock of
    -- every already-checked slot instead of trusting the save.
    local function reconcile_sold_out()
        if merchant.slot_count == 0 then
            return
        end
        local manager = shop_manager()
        if manager == nil then
            return
        end
        local zeroed = 0
        for _, slot in pairs(merchant.slots_by_item) do
            if slot_is_checked(slot) then
                local current = nil
                pcall(function()
                    current = manager:call("getCurrStock", slot.item_id)
                end)
                current = tonumber(current)
                if current ~= nil and current > 0 then
                    local ok = pcall(function()
                        manager:call("reduceStock", slot.item_id, current)
                    end)
                    if ok then
                        zeroed = zeroed + 1
                    end
                end
            end
        end
        if zeroed > 0 then
            info(string.format("%d already-checked slot(s) reconciled back to sold out", zeroed))
        end
    end

    -- ------------------------------------------------------------- dev probe
    -- [Live-test probe] With Developer Tools on, every shop open logs what
    -- the game itself reports for each AP slot row. The buy tab showed no AP
    -- rows on 2026-08-14 while the pak demonstrably carried all 22 rows, so
    -- this reads the shelf from the runtime side to say which layer hides
    -- them. Best-effort by design: every call is guarded, unanswered calls
    -- log as "-", and the method that answered is named so the follow-up fix
    -- can use it directly.
    local PROBE_STOCK_METHODS = { "getCurrStock", "getCurrentStock", "getStock" }
    local PROBE_MAX_STOCK_METHODS = { "getMaxStock", "getStockMax" }
    local PROBE_SOLD_OUT_METHODS = { "checkSoldOut", "isSoldOut" }

    local function probe_call(manager, names, item_id)
        for _, name in ipairs(names) do
            local value = nil
            local ok = pcall(function() value = manager:call(name, item_id) end)
            if ok and value ~= nil then
                return tostring(value), name
            end
        end
        return "-", nil
    end

    local function probe_shelf()
        if bridge.developer_tools_enabled ~= true or merchant.slot_count == 0 then
            return
        end
        local manager = shop_manager()
        if manager == nil then
            info("probe: InGameShopManager unavailable")
            return
        end

        local difficulty = "?"
        pcall(function()
            local campaign = sdk.get_managed_singleton("chainsaw.CampaignManager")
            if campaign ~= nil then
                difficulty = tostring(campaign:call("get_CurrentDifficulty"))
            end
        end)
        info(string.format(
            "probe: shop opened, difficulty=%s, %d AP slot(s)",
            difficulty, merchant.slot_count))

        local ordered = {}
        for _, slot in pairs(merchant.slots_by_item) do
            ordered[#ordered + 1] = slot
        end
        table.sort(ordered, function(a, b) return a.index < b.index end)
        for _, slot in ipairs(ordered) do
            local stock, stock_via = probe_call(manager, PROBE_STOCK_METHODS, slot.item_id)
            local max_stock = probe_call(manager, PROBE_MAX_STOCK_METHODS, slot.item_id)
            local sold_out = probe_call(manager, PROBE_SOLD_OUT_METHODS, slot.item_id)
            info(string.format(
                "probe: slot %d standin=%d stock=%s max=%s soldout=%s%s",
                slot.index, slot.item_id, stock, max_stock, sold_out,
                stock_via ~= nil and (" (via " .. stock_via .. ")") or ""))
        end

        -- Baseline: real catalog rows (the parked pool items) so the slot
        -- readings have something known-good to compare against.
        for _, baseline_id in ipairs({ 274995456, 275158656, 275478656, 116004800 }) do
            local stock = probe_call(manager, PROBE_STOCK_METHODS, baseline_id)
            local sold_out = probe_call(manager, PROBE_SOLD_OUT_METHODS, baseline_id)
            info(string.format(
                "probe: baseline item=%d stock=%s soldout=%s",
                baseline_id, stock, sold_out))
        end
    end

    -- ---------------------------------------------------------------- saving
    local function request_game_save()
        if not merchant.save_armed then
            return
        end
        merchant.save_armed = false
        local manager = sdk.get_managed_singleton("share.SaveDataManager")
        if manager == nil then
            info("save requested but share.SaveDataManager is missing")
            return
        end
        local ok = pcall(function()
            manager:call("requestSaveGameData", true)
        end)
        if not ok then
            ok = pcall(function()
                manager:call("requestSaveGameData")
            end)
        end
        info(ok and "shop closed after a purchase - game save requested"
            or "shop closed after a purchase but requestSaveGameData failed")
    end

    -- ----------------------------------------------------------------- hooks
    local function install_hooks()
        if merchant.hooks_installed then
            return
        end

        local shop_type = sdk.find_type_definition("chainsaw.InGameShopManager")
        local notify = shop_type and shop_type:get_method("notifyPurchaseItem")
        if notify == nil then
            info("notifyPurchaseItem not found - shop checks cannot fire")
            return
        end
        sdk.hook(
            notify,
            function(args)
                -- (this, kind, itemId, count, ptas) - args[3] is the first
                -- parameter, matching the notifySellItems hook next door.
                local ok, e = pcall(function()
                    local item_id = sdk.to_int64(args[4]) & 0xFFFFFFFF
                    on_purchase(math.floor(tonumber(item_id) or 0))
                end)
                if not ok then
                    info("purchase hook error: " .. tostring(e))
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval) return retval end
        )

        -- Shop opened: reconcile before the player can look at the shelf.
        local enter_type = sdk.find_type_definition("chainsaw.gui.shop.InGameShopGuiState_Enter")
            or sdk.find_type_definition("chainsaw.gui.shop.InGameShopGuiState_PurchaseEnter")
        local enter_method = enter_type and (enter_type:get_method("enter") or enter_type:get_method("onEnter"))
        if enter_method ~= nil then
            sdk.hook(
                enter_method,
                function()
                    pcall(reconcile_sold_out)
                    pcall(probe_shelf)
                    return sdk.PreHookResult.CALL_ORIGINAL
                end,
                function(retval) return retval end
            )
        end

        -- Shop closed: commit the visit if anything was bought.
        local close_type = sdk.find_type_definition("chainsaw.gui.shop.InGameShopGuiState_Close")
        local close_method = close_type and (close_type:get_method("enter") or close_type:get_method("onEnter"))
        if close_method ~= nil then
            sdk.hook(
                close_method,
                function()
                    pcall(request_game_save)
                    return sdk.PreHookResult.CALL_ORIGINAL
                end,
                function(retval) return retval end
            )
        else
            info("shop close state not found - purchases will save with the next normal save")
        end

        merchant.hooks_installed = true
        info("purchase hook installed")
    end

    -- ---------------------------------------------------------------- public
    -- apclient calls these: load_slots when the room file is read, and
    -- on_connected once the per-seed ack set is in memory.
    local function merchant_configure(payload)
        load_slots(payload)
        if merchant.slot_count > 0 then
            install_hooks()
        end
    end

    local function merchant_on_connected()
        if merchant.slot_count == 0 then
            return
        end
        pcall(reconcile_sold_out)
    end

    ctx.merchant_configure = merchant_configure
    ctx.merchant_on_connected = merchant_on_connected
    ctx.merchant_reconcile_sold_out = reconcile_sold_out
    ctx.merchant_probe_shelf = probe_shelf
    -- The operations the hooks trigger, exposed by name: the hooks are only
    -- the triggers, so a purchase can also be driven from Developer Tools or
    -- an offline harness without faking a transaction.
    ctx.merchant_apply_purchase = on_purchase
    ctx.merchant_commit_save = request_game_save
    _G.merchant_configure = merchant_configure
    _G.merchant_on_connected = merchant_on_connected
end
