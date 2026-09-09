-- [Merchant, both tabs] Bought checks are hidden from the shelf and the trade
-- tiles by the per-seed ack set, which is marked on send and lives on this
-- machine. The server's own checked list only ever fed the Mercenaries goal,
-- so on a fresh machine, or after the session folder was wiped, every bought
-- check went back on sale: the server refused the duplicate and the money
-- was gone (found 2026-09-02, built 2026-09-04 in apclient, moved here the
-- same day so it can run under an offline harness).
--
-- This module folds the server's list into the ack set for the shop and
-- trade identities. Each tab module maps a location id to its own ack key
-- (merchant_ack_key_for_location, trade_ack_key_for_location); world checks
-- keep their own path, because their markers roll back with the save on
-- purpose. No engine calls: only ctx and the log.
return function(ctx)
    local function info(text)
        if log ~= nil and type(log.info) == "function" then
            log.info("[RE4R AP] " .. text)
        end
    end

    -- Returns true when something new was marked. `source` names the caller
    -- in the log line ("connect" or "server update").
    local function fold_server_checked_merchant_acks(location_ids, source)
        local bridge = ctx.bridge
        if bridge == nil or type(location_ids) ~= "table" then
            return false
        end
        if type(bridge.acknowledged_guid_keys) ~= "table" then
            return false
        end
        local shop_key = ctx.merchant_ack_key_for_location or _G.merchant_ack_key_for_location
        local trade_key = ctx.trade_ack_key_for_location or _G.trade_ack_key_for_location
        local marked = 0
        for _, raw in ipairs(location_ids) do
            local lid = tonumber(raw)
            if lid ~= nil then
                lid = math.floor(lid)
                local key = nil
                if type(shop_key) == "function" then
                    local ok, value = pcall(shop_key, lid)
                    if ok and type(value) == "string" then
                        key = value
                    end
                end
                if key == nil and type(trade_key) == "function" then
                    local ok, value = pcall(trade_key, lid)
                    if ok and type(value) == "string" then
                        key = value
                    end
                end
                if key ~= nil and not bridge.acknowledged_guid_keys[key] then
                    bridge.acknowledged_guid_keys[key] = true
                    marked = marked + 1
                end
            end
        end
        if marked > 0 then
            bridge.state_dirty = true
            if type(ctx.save_session_state) == "function" then
                ctx.save_session_state()
            end
            info(string.format(
                "%d merchant check(s) the server already holds were marked bought locally (%s); they stay off both tabs",
                marked, tostring(source)))
        end
        return marked > 0
    end

    ctx.fold_server_checked_merchant_acks = fold_server_checked_merchant_acks
    _G.fold_server_checked_merchant_acks = fold_server_checked_merchant_acks
end
