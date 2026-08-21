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
        -- [Rotation] The shelf: row records from the room file, a fixed tier
        -- each. Rows are a display window, not a home for one check.
        rows = {},
        -- Every check in the room, in release order (chapter, then ordinal).
        checks = {},
        -- row item id -> the check that row is CURRENTLY showing. Derived on
        -- every reconcile, never stored, so nothing can drift out of step.
        slots_by_item = {},
        -- location_code -> check record
        slots_by_location = {},
        -- row item id -> the identity it was last re-labelled for, so a row is
        -- only re-registered when the check it shows actually changes
        dressed = {},
        -- released checks with no free row of their tier, surfaced on the HUD
        backlog = 0,
        slot_count = 0,
        hooks_installed = false,
        save_armed = false,
        purchases_this_session = 0,
        -- stand-in item id -> frames left to keep looking for it
        pending_sweeps = {},
        -- slot key -> true for every refund gem handed over in THIS session,
        -- seeded on load from what the loaded save version recorded
        gems_granted = {},
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
        merchant.rows = {}
        merchant.checks = {}
        merchant.slots_by_item = {}
        merchant.slots_by_location = {}
        merchant.slot_count = 0
        merchant.backlog = 0
        if type(payload) ~= "table" or type(payload.slots) ~= "table" then
            return
        end

        -- [Rotation] The shelf and the checks are separate lists now: rows are
        -- a display window and checks rotate through them. A room file from
        -- before rotation has no rows and one check per row, so each check
        -- becomes its own permanent row - that is exactly the old behaviour,
        -- expressed in the new model.
        if type(payload.rows) == "table" and #payload.rows > 0 then
            for _, raw in ipairs(payload.rows) do
                local item_id = tonumber(raw and raw.item_id)
                if item_id ~= nil then
                    merchant.rows[#merchant.rows + 1] = {
                        item_id = math.floor(item_id),
                        classification = tostring(raw.classification or "FILLER"),
                        price = math.floor(tonumber(raw.price) or 0),
                        refund_item_id = math.floor(tonumber(raw.refund_item_id) or 0),
                        refund_item_name = tostring(raw.refund_item_name or "a gemstone"),
                    }
                end
            end
        end

        -- Captured BEFORE the loop: the fallback appends rows as it goes, so
        -- testing the list inside the loop would only ever fire for the first
        -- check and leave every other one without a row.
        local legacy_room_file = (#merchant.rows == 0)
        -- A pre-rotation room's checks stay PINNED to their own row. Letting
        -- them compact onto the lowest free row would change what a row sells
        -- part-way through somebody's existing run, and their save's sold-out
        -- state is already keyed to the old pairing.
        merchant.legacy_pinned = legacy_room_file

        for _, raw in ipairs(payload.slots) do
            local location_code = tonumber(raw and raw.location_code)
            if location_code ~= nil then
                local index = math.floor(tonumber(raw.index) or 0)
                local check = {
                    location_code = math.floor(location_code),
                    index = index,
                    identity = tostring(raw.identity or string.format("shop:slot:%d", index)),
                    unlock_chapter = math.floor(tonumber(raw.unlock_chapter) or 1),
                    chapter_ordinal = math.floor(tonumber(raw.chapter_ordinal) or 1),
                    classification = tostring(raw.classification or "FILLER"),
                    display_name = tostring(raw.display_name or "an item"),
                    player_name = tostring(raw.player_name or ""),
                    remote = (raw.remote == true),
                    -- Engine id of a LOCAL RE4R item, so its row can wear the
                    -- real name, caption, icon and model. Zero keeps the AP
                    -- dressing, which is what every remote check gets.
                    item_id_real = math.floor(tonumber(raw.item_id) or 0),
                    item_stack = math.floor(tonumber(raw.item_stack) or 0),
                    name_msg_guid = raw.name_msg_guid and tostring(raw.name_msg_guid) or nil,
                    caption_msg_guid = raw.caption_msg_guid and tostring(raw.caption_msg_guid) or nil,
                    price = math.floor(tonumber(raw.price) or 0),
                    refund_item_id = math.floor(tonumber(raw.refund_item_id) or 0),
                    refund_item_name = tostring(raw.refund_item_name or "a gemstone"),
                }
                merchant.checks[#merchant.checks + 1] = check
                merchant.slots_by_location[check.location_code] = check
                merchant.slot_count = merchant.slot_count + 1

                -- Pre-rotation room file: the check owns its row forever.
                if legacy_room_file then
                    local standin = tonumber(raw.standin_item_id)
                    if standin ~= nil then
                        check.row_item_id = math.floor(standin)
                        merchant.rows[#merchant.rows + 1] = {
                            item_id = check.row_item_id,
                            classification = check.classification,
                            price = check.price,
                            refund_item_id = check.refund_item_id,
                            refund_item_name = check.refund_item_name,
                        }
                    end
                end
            end
        end

        -- Release order: chapter first, then position within the chapter.
        table.sort(merchant.checks, function(a, b)
            if a.unlock_chapter ~= b.unlock_chapter then
                return a.unlock_chapter < b.unlock_chapter
            end
            if a.chapter_ordinal ~= b.chapter_ordinal then
                return a.chapter_ordinal < b.chapter_ordinal
            end
            return a.index < b.index
        end)

        info(string.format(
            "%d shop check(s) across %d shelf row(s) loaded from the room file",
            merchant.slot_count, #merchant.rows))
    end

    -- ------------------------------------------------------------ ack helpers
    -- Shop slots have no scene GUID, so they use their own durable key in the
    -- same per-seed ack set every world check uses.
    -- The ack keys on the CHECK, never on the row showing it, or a rotated row
    -- would inherit the previous check's acknowledgement. Rooms from before
    -- rotation carry no identity and fall back to the row key they already
    -- acked against, so their saves keep working untouched.
    local function slot_key(slot)
        if type(slot.identity) == "string" and slot.identity ~= "" then
            return slot.identity
        end
        return string.format("shop:slot:%d", slot.index)
    end

    local function slot_is_checked(slot)
        local acknowledged = bridge and bridge.acknowledged_guid_keys
        if type(acknowledged) == "table" and acknowledged[slot_key(slot)] then
            return true
        end
        return false
    end

    -- Forward declaration: a purchase frees a row and re-derives the shelf,
    -- but the reconciler is defined further down. Without this the call would
    -- compile as a global lookup and silently do nothing.
    local reconcile_stock

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

    -- Only remote purchases refund: you fronted the money for someone else's
    -- item, so the gem hands your wealth straight back. Your own items are
    -- yours to buy at face value, progression included (Cam, 2026-08-17).
    local function refund_is_due(slot)
        return slot.remote
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

    -- The case is where a bought stand-in actually lands (live 2026-08-17).
    -- CsInventory.reduce is overloaded three ways, so the call carries its full
    -- signature to pick the ItemID one; the trailing boolean is the engine's
    -- own flag whose meaning is unverified, and a wrong guess here can only
    -- leave the trinket in place, which is today's behaviour anyway.
    local function sweep_case_inventory(item_id, quiet)
        local function note(text)
            if not quiet then info(text) end
        end
        local resolve = ctx.inject_resolve_case_inventory or _G.inject_resolve_case_inventory
        if type(resolve) ~= "function" then
            note(string.format("stand-in %d left in the case (no inventory resolver)", item_id))
            return 0
        end
        local cs_inventory = resolve()
        if cs_inventory == nil then
            note(string.format("stand-in %d left in the case (case inventory unavailable)", item_id))
            return 0
        end
        local ok, result = pcall(function()
            return cs_inventory:call(
                "reduce(chainsaw.ItemID, System.Int32, System.Boolean)", item_id, 1, true)
        end)
        if not ok then
            info(string.format("stand-in %d case sweep errored: %s", item_id, tostring(result)))
            return 0
        end
        return (result == true) and 1 or 0
    end

    -- Returns true once the stand-in has actually been taken back. Quiet
    -- during retries: the interesting line is the one that says it worked, or
    -- the single give-up line when the retry window closes.
    local function suppress_standin(item_id, quiet)
        local function note(text)
            if not quiet then info(text) end
        end
        local controller = resolve_treasure_controller()
        if controller == nil then
            note(string.format("stand-in %d left in place (treasure controller unavailable)", item_id))
            return false
        end
        local items = nil
        pcall(function() items = controller:call("getInventoryItems") end)
        if items == nil then
            pcall(function() items = controller:call("getInventoryItems()") end)
        end
        if items == nil then
            note(string.format("stand-in %d left in place (inventory list unavailable)", item_id))
            return false
        end
        local count = nil
        pcall(function() count = items:call("get_Count") end)
        count = tonumber(count)
        if count == nil then
            note(string.format("stand-in %d left in place (inventory count unavailable)", item_id))
            return false
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
            return true
        end
        -- ANSWERED 2026-08-17: it lands in the main case, not the treasure
        -- tab. The stand-in is a treasure-kind item, but a shop purchase
        -- routes it like ordinary merchandise, so the case is the second
        -- place to look.
        local swept_case = sweep_case_inventory(item_id, quiet)
        if swept_case > 0 then
            info(string.format("stand-in %d swept from the case (%d)", item_id, swept_case))
            return true
        end
        note(string.format(
            "stand-in %d not in the treasure inventory or the case yet", item_id))
        return false
    end

    -- The purchase hook fires BEFORE the game hands the trinket over: live
    -- 2026-08-17 timed the sweep at .841 and the delivery at .083 of the next
    -- second, so an inline sweep searches an inventory the stand-in has not
    -- reached. Queue it and keep looking for a few seconds instead.
    local SWEEP_RETRY_FRAMES = 300

    local function poll_pending_sweeps()
        if next(merchant.pending_sweeps) == nil then
            return
        end
        for item_id, frames_left in pairs(merchant.pending_sweeps) do
            local ok, swept = pcall(suppress_standin, item_id, true)
            if ok and swept then
                merchant.pending_sweeps[item_id] = nil
            elseif frames_left <= 1 then
                merchant.pending_sweeps[item_id] = nil
                info(string.format(
                    "stand-in %d never appeared within the retry window - left alone", item_id))
            else
                merchant.pending_sweeps[item_id] = frames_left - 1
            end
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
        -- the check, not the trinket. Try once now in case the hand-over
        -- already happened, then leave it queued for the frame poll, which is
        -- what actually catches it.
        -- Sweep the ROW's trinket, which is what the till actually handed over.
        local row_item_id = math.floor(tonumber(item_id) or 0)
        local ok_sweep, swept = pcall(suppress_standin, row_item_id, true)
        if not (ok_sweep and swept) then
            merchant.pending_sweeps[row_item_id] = SWEEP_RETRY_FRAMES
        end

        local queued = queue_check(slot)
        info(string.format(
            "check '%s' bought: '%s' (%s, %s)%s",
            slot.identity or tostring(slot.index), slot.display_name,
            slot.player_name, slot.classification,
            queued and "" or " [check already queued]"))

        if refund_is_due(slot) then
            local ok, detail = grant_refund(slot)
            if ok then
                merchant.gems_granted[slot_key(slot)] = true
                push_toast(string.format(
                    "Received %s, a refund for helping a fellow stranger.",
                    slot.refund_item_name))
                info(string.format("check '%s' refunded %s", slot_key(slot), slot.refund_item_name))
            else
                -- Never silent: the player paid and is owed this.
                info(string.format(
                    "check '%s' refund FAILED (%s) - item %d not granted",
                    slot_key(slot), tostring(detail), slot.refund_item_id))
            end
        end

        -- [Rotation] The row is free now. Re-derive immediately so the next
        -- released check of this tier takes its place while the player is
        -- still standing at the merchant, rather than after a reload.
        merchant.dressed[row_item_id] = nil
        pcall(reconcile_stock)
    end

    -- --------------------------------------------------- purchase settlement
    -- A purchase has two halves in different places: the check is server state
    -- and never rolls back, the refund gem is save state and does. Reload
    -- without saving and the slot still reads sold out while the gem is gone,
    -- with no way to earn it again, because a re-purchase is impossible. So the
    -- gem is granted at purchase (immediate, as it should be) AND repaired on
    -- load when the version being loaded never contained it.
    --
    -- Never guesses: a save version we have no record of writing yields nil,
    -- and nil means leave it alone rather than risk minting a second gem. Same
    -- rule the F8 watermarks follow.
    local function settle_refunds_for_loaded_save(guid, save_count)
        if merchant.slot_count == 0 then
            return
        end
        -- One settlement per loaded version. The caller runs once per load
        -- today, but granting is not idempotent on its own and a second pass
        -- would mint a second gem.
        local token = tostring(guid) .. "#" .. tostring(save_count)
        if merchant.settled_for == token then
            return
        end
        merchant.settled_for = token
        local lookup = ctx.lookup_settled_gems or _G.lookup_settled_gems
        if type(lookup) ~= "function" then
            return
        end
        local settled = lookup(guid, save_count)
        if settled == nil then
            info(string.format(
                "settlement: no record of save '%s' #%s -> refunds left alone (safe; pre-fix save)",
                tostring(guid), tostring(save_count)))
            merchant.gems_granted = {}
            return
        end

        -- The loaded version's set becomes the live set: anything it contains
        -- is already in the player's hands.
        local live = {}
        for slot_key_name in pairs(settled) do
            live[slot_key_name] = true
        end
        merchant.gems_granted = live

        -- Every CHECK, not just the ones currently on a row: a bought check has
        -- left the shelf by definition, and it is exactly the bought ones that
        -- can be owed a gem.
        local repaired = 0
        for _, slot in ipairs(merchant.checks) do
            local key = slot_key(slot)
            if refund_is_due(slot) and slot_is_checked(slot) and not live[key] then
                local ok, detail = grant_refund(slot)
                if ok then
                    live[key] = true
                    repaired = repaired + 1
                    info(string.format(
                        "settlement: check '%s' was bought but this save had no %s - re-granted",
                        key, slot.refund_item_name))
                else
                    info(string.format(
                        "settlement: check '%s' owed %s but the grant failed (%s)",
                        key, slot.refund_item_name, tostring(detail)))
                end
            end
        end
        if repaired > 0 then
            bridge.state_dirty = true
        end
    end

    -- ------------------------------------------------------------- reconcile
    -- Stock lives in the per-save shop blob; the server's checked list is the
    -- only truth that survives deaths, reloads and old saves. So stock is
    -- reconciled in BOTH directions on connect and on every shop open:
    --   checked slot with stock  -> reduced to zero (no re-purchase)
    --   unchecked slot with none -> restored to one, PROVIDED the game says
    --     its unlock waypoint has fired (isEnableUpdateFlag) - this heals
    --     saves that walked a chapter before its addition existed (the
    --     2026-08-16 chapter-1 rows) and any future waypoint quirk.
    -- The waypoint flag enum: value N-1 fires entering display chapter N,
    -- value 0 at campaign start; clamped to the cp10 range 0..15.
    local function slot_unlock_flag(slot)
        local chapter = tonumber(slot.unlock_chapter) or 1
        local flag = math.floor(chapter) - 1
        if flag < 0 then flag = 0 end
        if flag > 15 then flag = 15 end
        return flag
    end

    local function slot_is_unlocked(manager, slot)
        local unlocked = nil
        pcall(function()
            unlocked = manager:call("isEnableUpdateFlag", slot_unlock_flag(slot))
        end)
        return unlocked == true
    end

    -- ------------------------------------------------------------- rotation
    -- Which check a row is showing is DERIVED, never stored: ask the server
    -- which checks are already done and the game which chapters have arrived,
    -- then hand each row the oldest released check it can display. That is why
    -- it survives death, reload and save-hopping for free - there is no state
    -- to get out of step.
    --
    -- Rows carry a FIXED tier because their price is baked into the pak, so a
    -- check only ever lands on a row of its own classification.
    local function assign_rows(manager)
        -- Pre-rotation room: every check owns its row, so there is nothing to
        -- derive beyond "is it released and still unbought".
        if merchant.legacy_pinned then
            local assignment = {}
            for _, check in ipairs(merchant.checks) do
                if check.row_item_id ~= nil
                    and not slot_is_checked(check)
                    and slot_is_unlocked(manager, check)
                then
                    assignment[check.row_item_id] = check
                end
            end
            merchant.backlog = 0
            merchant.slots_by_item = assignment
            if bridge ~= nil then
                bridge.merchant_backlog = 0
            end
            return assignment, 0
        end

        local by_class = {}
        for _, check in ipairs(merchant.checks) do
            if not slot_is_checked(check) and slot_is_unlocked(manager, check) then
                local bucket = by_class[check.classification]
                if bucket == nil then
                    bucket = {}
                    by_class[check.classification] = bucket
                end
                bucket[#bucket + 1] = check
            end
        end

        local assignment = {}
        local shown = 0
        local taken = {}
        for _, row in ipairs(merchant.rows) do
            local bucket = by_class[row.classification]
            local next_index = (taken[row.classification] or 0) + 1
            local check = bucket and bucket[next_index] or nil
            if check ~= nil then
                taken[row.classification] = next_index
                assignment[row.item_id] = check
                check.row_item_id = row.item_id
                shown = shown + 1
            end
        end

        -- Anything released but off the shelf is the backlog. It is never
        -- lost: a row frees the moment its check is bought.
        local waiting = 0
        for _, bucket in pairs(by_class) do
            waiting = waiting + #bucket
        end
        merchant.backlog = math.max(0, waiting - shown)
        merchant.slots_by_item = assignment
        if bridge ~= nil then
            bridge.merchant_backlog = merchant.backlog
            bridge.merchant_shown = shown
        end
        return assignment, shown
    end

    -- The proven runtime rename (live 2026-08-17): a Setting of exactly
    -- {_ItemId, _NameMsgId, _CaptionMsgId} handed to the item message manager
    -- re-labels a shop row while the game runs.
    --
    -- A LOCAL check borrows the REAL item's own message ids, so the row reads
    -- as that item rather than as "[AP] something". A remote check points at
    -- the text the fork baked at the launcher's GUIDs. Icons still follow the
    -- row's item id and cannot be moved, which is why remote rows keep the AP
    -- dressing they are already wearing.
    local function dress_row(row_item_id, check)
        local item_manager = sdk.get_managed_singleton("chainsaw.ItemManager")
        if item_manager == nil then
            return false, "ItemManager unavailable"
        end
        local message_manager = nil
        pcall(function()
            message_manager = item_manager:call("get_ItemMessageManager")
        end)
        if message_manager == nil then
            return false, "ItemMessageManager unavailable"
        end

        local name_id, caption_id = nil, nil
        if check.item_id_real > 0 and not check.remote then
            pcall(function()
                name_id = message_manager:call("getItemNameMsgId", check.item_id_real)
                caption_id = message_manager:call("getItemCaptionMsgId", check.item_id_real)
            end)
        end
        if name_id == nil and check.name_msg_guid ~= nil then
            local box = ctx.box_system_guid or _G.box_system_guid
            if type(box) == "function" then
                name_id = box(check.name_msg_guid)
                caption_id = box(check.caption_msg_guid)
            end
        end
        if name_id == nil then
            return false, "no message ids for this check"
        end

        local ok, err = pcall(function()
            local setting = sdk.create_instance("chainsaw.ItemMessageIdOverwriteSettingUserdata.Setting")
            setting._ItemId = row_item_id
            setting._NameMsgId = name_id
            if caption_id ~= nil then
                setting._CaptionMsgId = caption_id
            end
            message_manager:call("registerItemMessageOverwriteSetting", setting)
        end)
        if not ok then
            return false, tostring(err)
        end
        return true, nil
    end

    -- ------------------------------------------------------- row icons
    -- A row's icon is pattern-indexed, and the game has a static helper that
    -- does the item-id-to-pattern work for us, so we never build a lookup
    -- table: hand it the row's texture control and a real engine item id.
    -- Proven live 2026-08-17 (a row was made to wear another row's picture).
    --
    -- Only LOCAL checks get this. A remote check has no RE4R item to show, so
    -- it keeps the AP badge, which is the intended way to tell the two apart.
    local set_item_icon_method = nil
    local set_item_icon_resolved = false

    local function resolve_set_item_icon()
        if set_item_icon_resolved then
            return set_item_icon_method
        end
        set_item_icon_resolved = true
        local ext = sdk.find_type_definition("chainsaw.gui.GuiPlayObjectExtension")
        if ext == nil then
            info("row icons: GuiPlayObjectExtension not found; icons stay AP-branded")
            return nil
        end
        -- The dump decorates overloads, so match by prefix and arity rather
        -- than by an exact name we would have to guess.
        local ok = pcall(function()
            for _, method in ipairs(ext:get_methods()) do
                local name = method:get_name()
                if name:find("setItemIcon", 1, true) == 1
                    and #method:get_params() == 2 then
                    set_item_icon_method = method
                    break
                end
            end
        end)
        if not ok or set_item_icon_method == nil then
            info("row icons: no 2-argument setItemIcon; icons stay AP-branded")
            return nil
        end
        info("row icons: using " .. set_item_icon_method:get_name())
        return set_item_icon_method
    end

    local function dress_row_icons(list_gui)
        if merchant.slot_count == 0 then
            return
        end
        local setter = resolve_set_item_icon()
        if setter == nil then
            return
        end

        local rows = nil
        pcall(function() rows = list_gui:get_field("_AppSelectItems") end)
        if rows == nil then
            return
        end
        local count = nil
        pcall(function() count = rows:call("get_Count") end)
        count = tonumber(count) or 0

        for i = 0, count - 1 do
            pcall(function()
                local row = rows:call("get_Item", i)
                if row == nil then
                    return
                end
                local row_item_id = row:call("get_ItemId")
                if row_item_id == nil then
                    return
                end
                local check = merchant.slots_by_item[math.floor(row_item_id)]
                -- Not one of our rows, or showing a remote check, or a local
                -- item the table could not name: leave it exactly as it is.
                if check == nil or check.remote or check.item_id_real <= 0 then
                    return
                end
                local tex = row:get_field("_ItemIconTex")
                if tex == nil then
                    return
                end
                -- Re-applied every frame on purpose: the GUI stamps its own
                -- icon back whenever it redraws or the list scrolls.
                setter:call(nil, tex, check.item_id_real)
            end)
        end
    end

    -- ------------------------------------------------------- row models
    -- Same trick as the icon, one level up: the shop builds a row's 3D model
    -- through InGameShopManager.instantiateItemModel(ShopItemParam param, ...)
    -- and ShopItemParam carries a plain ItemID field. So instead of hunting a
    -- via.Prefab for the real item (registerItemModelPrefab wants an object
    -- and the manager exposes no getter), we let the game instantiate it and
    -- hand it the real id.
    --
    -- This also sidesteps the AP model's bad transform for local rows: a real
    -- item's shop prefab brings its own framing, so only remote rows are left
    -- needing that fixed.
    --
    -- UNPROVEN. The call is real and the field is real, but writing into a
    -- by-reference struct from Lua is the part that could refuse, so every
    -- route is tried and the first live run says which one answered.
    local model_swap_route = nil

    local function swap_model_item_id(param_arg, real_item_id)
        local target = nil
        pcall(function() target = sdk.to_managed_object(param_arg) end)
        if target ~= nil then
            local ok = pcall(function() target:set_field("ItemID", real_item_id) end)
            if ok then
                return "set_field"
            end
        end
        -- Value types come through as a different wrapper; try it directly.
        if sdk.to_valuetype ~= nil then
            local value = nil
            pcall(function()
                value = sdk.to_valuetype(param_arg, "chainsaw.ShopItemParam")
            end)
            if value ~= nil then
                local ok = pcall(function() value:set_field("ItemID", real_item_id) end)
                if ok then
                    return "valuetype"
                end
            end
        end
        return nil
    end

    local function install_row_model_hook()
        if merchant.model_hook_installed then
            return
        end
        local manager_type = sdk.find_type_definition("chainsaw.InGameShopManager")
        if manager_type == nil then
            return
        end
        local method = manager_type:get_method("instantiateItemModel")
        if method == nil then
            info("row models: instantiateItemModel not found; models stay AP-branded")
            return
        end
        merchant.model_hook_installed = true
        sdk.hook(method, function(args)
            pcall(function()
                -- args: [1] context, [2] this, [3] the ShopItemParam.
                local param_arg = args[3]
                if param_arg == nil then
                    return
                end
                local holder = sdk.to_managed_object(param_arg)
                local row_item_id = nil
                if holder ~= nil then
                    pcall(function() row_item_id = holder:get_field("ItemID") end)
                end
                if row_item_id == nil then
                    return
                end
                local check = merchant.slots_by_item[math.floor(row_item_id)]
                if check == nil or check.remote or check.item_id_real <= 0 then
                    return
                end
                local route = swap_model_item_id(param_arg, check.item_id_real)
                if route ~= nil and model_swap_route == nil then
                    model_swap_route = route
                    info(string.format(
                        "row models: swapped row %d to item %d via %s",
                        math.floor(row_item_id), check.item_id_real, route))
                elseif route == nil and model_swap_route == nil then
                    model_swap_route = "refused"
                    info("row models: ShopItemParam.ItemID would not take a write - "
                        .. "local rows keep the AP model")
                end
            end)
        end, nil)
        info("row models: local check rows will show their real item")
    end

    local function install_row_icon_hook()
        if merchant.icon_hook_installed then
            return
        end
        local list_type = sdk.find_type_definition("chainsaw.gui.shop.PurchaseItemListGui")
        if list_type == nil then
            info("row icons: PurchaseItemListGui not found")
            return
        end
        local method = list_type:get_method("onLateUpdate")
        if method == nil then
            info("row icons: PurchaseItemListGui.onLateUpdate not found")
            return
        end
        merchant.icon_hook_installed = true
        sdk.hook(method, function(args)
            local ok, list_gui = pcall(function()
                return sdk.to_managed_object(args[2])
            end)
            if ok and list_gui ~= nil then
                pcall(dress_row_icons, list_gui)
            end
        end, nil)
        info("row icons: local check rows will wear their real item's icon")
    end

    local function dress_assigned_rows(assignment)
        local dressed, failed = 0, 0
        local first_error = nil
        for row_item_id, check in pairs(assignment) do
            if merchant.dressed[row_item_id] ~= check.identity then
                local ok, err = dress_row(row_item_id, check)
                if ok then
                    merchant.dressed[row_item_id] = check.identity
                    dressed = dressed + 1
                else
                    failed = failed + 1
                    first_error = first_error or err
                end
            end
        end
        if dressed > 0 then
            info(string.format("%d row(s) re-labelled for the check they now show", dressed))
        end
        if failed > 0 then
            info(string.format(
                "%d row(s) could NOT be re-labelled (%s) - they still sell the right check, "
                .. "they just read as the generic AP row", failed, tostring(first_error)))
        end
    end

    function reconcile_stock()
        if merchant.slot_count == 0 then
            return
        end
        local manager = shop_manager()
        if manager == nil then
            return
        end
        -- Derive the shelf first, then make the game's stock agree with it: a
        -- row showing a check is stocked, a row showing nothing is emptied.
        local assignment = assign_rows(manager)

        local zeroed, restored = 0, 0
        for _, row in ipairs(merchant.rows) do
            local current = nil
            pcall(function()
                current = manager:call("getCurrStock", row.item_id)
            end)
            current = tonumber(current)
            if current ~= nil then
                if assignment[row.item_id] ~= nil then
                    if current < 1 then
                        local ok = pcall(function()
                            manager:call("addStock", row.item_id, 1 - current)
                        end)
                        if ok then
                            restored = restored + 1
                        end
                    end
                elseif current > 0 then
                    -- Nothing left to show here: either every check of this
                    -- tier is bought, or none has been released yet.
                    local ok = pcall(function()
                        manager:call("reduceStock", row.item_id, current)
                    end)
                    if ok then
                        zeroed = zeroed + 1
                    end
                end
            end
        end

        dress_assigned_rows(assignment)

        if zeroed > 0 then
            info(string.format("%d row(s) emptied - nothing of that tier left to show", zeroed))
        end
        if restored > 0 then
            info(string.format("%d row(s) restocked with the check they now carry", restored))
        end
        if merchant.backlog > 0 then
            info(string.format(
                "%d released check(s) waiting for a free row", merchant.backlog))
        end
    end

    -- The old name stays callable: connect-time and shop-open call sites
    -- predate the two-way rename.
    local reconcile_sold_out = reconcile_stock

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
            "probe: shop opened, difficulty=%s, %d check(s) over %d row(s), %d waiting",
            difficulty, merchant.slot_count, #merchant.rows, merchant.backlog))

        -- Read the shelf ROW by row, and say which check each one is carrying:
        -- an empty row is expected whenever that tier has nothing released.
        for _, row in ipairs(merchant.rows) do
            local stock, stock_via = probe_call(manager, PROBE_STOCK_METHODS, row.item_id)
            local max_stock = probe_call(manager, PROBE_MAX_STOCK_METHODS, row.item_id)
            local sold_out = probe_call(manager, PROBE_SOLD_OUT_METHODS, row.item_id)
            local carrying = merchant.slots_by_item[row.item_id]
            info(string.format(
                "probe: row %d (%s) stock=%s max=%s soldout=%s carrying=%s%s",
                row.item_id, row.classification, stock, max_stock, sold_out,
                carrying ~= nil and string.format("'%s' %s", carrying.identity, carrying.display_name)
                    or "nothing",
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
        -- The real signature is requestSaveGameData(int slotId,
        -- GameSaveRequestArgs args). This asked with one argument and then with
        -- none, and REFramework rejected both without raising, so the old code
        -- logged "game save requested" every time while saving nothing (found
        -- live 2026-08-17, after a refund gem was lost to a reload). Writing a
        -- save needs a slot id, and a wrong slot id overwrites the wrong file,
        -- so this stays honest rather than guessing. Correctness is meant to
        -- come from reconciling against the server's checked list, not from
        -- this save; the refund gem is the one consequence not yet covered
        -- that way, which is why losing it to a reload is currently possible.
        local call_verified = ctx.inject_call_verified or _G.inject_call_verified
        local ok, detail = false, "verified-call helper unavailable"
        if type(call_verified) == "function" then
            ok, detail = call_verified(manager, "requestSaveGameData")
        end
        if ok then
            info("shop closed after a purchase - game save requested")
        else
            info("shop closed after a purchase; no game save was made ("
                .. tostring(detail) .. ") - the purchase is reconciled on load instead")
        end
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
        -- Local check rows wear their real item's icon. Needs the buy list, so
        -- it hooks separately from the purchase hooks above.
        if merchant.slot_count > 0 then
            pcall(install_row_icon_hook)
            pcall(install_row_model_hook)
        end
    end

    local function merchant_on_connected()
        if merchant.slot_count == 0 then
            return
        end
        pcall(reconcile_sold_out)
    end

    -- [Purchase delivery] apclient's own-find skip assumes an own-world item
    -- was already granted by the world pickup. A shop check has no pickup:
    -- the till hands over the STAND-IN, so the real item must still be
    -- injected. apclient asks this before skipping (live 2026-08-17: a bought
    -- Insignia Key was skipped and never arrived).
    local function merchant_is_shop_location(location_code)
        local code = tonumber(location_code)
        if code == nil then
            return false
        end
        return merchant.slots_by_location[math.floor(code)] ~= nil
    end

    ctx.merchant_configure = merchant_configure
    ctx.merchant_is_shop_location = merchant_is_shop_location
    ctx.merchant_poll_pending_sweeps = poll_pending_sweeps
    ctx.merchant_settle_refunds_for_loaded_save = settle_refunds_for_loaded_save
    -- The save hook asks for this at the instant a version is written, which is
    -- the only moment we know what that file actually contains.
    ctx.merchant_granted_gem_keys = function()
        return merchant.gems_granted
    end
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
