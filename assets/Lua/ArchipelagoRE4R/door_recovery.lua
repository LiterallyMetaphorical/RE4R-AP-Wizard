-- [A2 recovery lever] Un-brick a door whose key-use trigger got consumed.
--
-- Reported (Arutairu, 2026-08): the Insignia Key arrived, showed in the Key
-- Items tab, then vanished from the "use here" list the moment they tried it on
-- the ch3 gate, which never opened. Permanently stuck.
--
-- Mechanism, from the dump:
--   * chainsaw.InteractTriggerUseItem is what lists an item as usable at a
--     door. Its _ItemSuccess is a list of ItemData {Item, CanReuse}, and
--     collectUsableItemIDs() is what the menu actually reads.
--   * CanReuse is the one-shot switch. Once a non-reusable entry has fired, the
--     trigger stops offering that item, which is exactly "it vanished from the
--     menu".
--   * checkContainsInSuccess(itemId) hands back the ItemData for one item, so
--     the entry can be flipped back on individually rather than rebuilding the
--     list.
--
-- So the recovery is: if the player HOLDS a key the trigger accepts, and the
-- trigger is no longer offering it, set that entry's CanReuse back to true.
-- Both halves of that condition matter. Possession is what makes it safe -
-- nothing is touched for doors the player has no key for, so this cannot open
-- anything they had not already earned the means to open.
--
-- HONEST LIMIT, and the reason this logs the way it does: the working theory
-- for A2 is that the trigger being consumed is only HALF the failure. The other
-- half is that the door's open sequence bails because it wants scenario flags
-- that only the vanilla pickup sets, and an injected key never fired them. If
-- that is right, re-arming lets the player select the key again and the door
-- still refuses. That is not a silent failure here: the same trigger comes back
-- around and gets re-armed again, and the third time that happens this says so
-- explicitly. Repeated re-arms on one trigger ARE the evidence that the
-- force-open lever is needed; a single re-arm followed by silence means the
-- re-arm was the whole fix. Either way the live session answers it without
-- anyone having to set the experiment up.
local function install(ctx)
    ctx.door_recovery = ctx.door_recovery or {}
    local bridge = ctx.bridge

    local function export(name, value)
        ctx.door_recovery[name] = value
        ctx[name] = value
        _G[name] = value
    end

    -- Slower than the pickup scan on purpose: this is a repair for a state that
    -- persists until fixed, not something that needs catching in a frame.
    local POLL_SECONDS = 4.0
    local next_poll = 0.0
    -- Trigger UniqueName -> how many times we have re-armed it. The count is the
    -- diagnostic described above.
    local rearm_counts = {}
    local rearm_total = 0

    local function try(fn)
        local ok, value = pcall(fn)
        if ok then return value end
        return nil
    end

    local function each(array, visit)
        local helper = ctx.each_engine_array_entry or _G.each_engine_array_entry
        if type(helper) ~= "function" or array == nil then return end
        helper(array, visit)
    end

    -- The ItemIDs a trigger accepts as a SUCCESS, i.e. the keys that open it.
    local function success_item_ids(trigger)
        local ids = {}
        each(try(function() return trigger:get_field("_ItemSuccess") end), function(data)
            local id = tonumber(try(function() return data:get_field("Item") end))
            if id ~= nil then ids[#ids + 1] = id end
            return false
        end)
        -- ItemSuccessAdditional is the runtime-appended half of the same list.
        each(try(function() return trigger:call("get_ItemSuccessAdditional") end), function(data)
            local id = tonumber(try(function() return data:get_field("Item") end))
            if id ~= nil then ids[#ids + 1] = id end
            return false
        end)
        return ids
    end

    -- What the trigger is offering RIGHT NOW. A consumed one-shot drops out.
    local function offered_item_ids(trigger)
        local offered = {}
        each(try(function() return trigger:call("collectUsableItemIDs") end), function(entry)
            local id = tonumber(entry)
            if id ~= nil then offered[id] = true end
            return false
        end)
        return offered
    end

    local function trigger_name(trigger)
        local name = try(function() return trigger:get_field("UniqueName") end)
        if type(name) == "string" and name ~= "" then return name end
        local address = try(function() return trigger:get_address() end)
        return "trigger@" .. tostring(address)
    end

    local function rearm(trigger, item_id)
        local name = trigger_name(trigger)
        local data = try(function()
            return trigger:call("checkContainsInSuccess", item_id)
        end)
        if data == nil then
            return false
        end
        local ok = pcall(function() data:set_field("CanReuse", true) end)
        if not ok then
            return false
        end

        local count = (rearm_counts[name] or 0) + 1
        rearm_counts[name] = count
        rearm_total = rearm_total + 1
        bridge.door_rearm_count = rearm_total

        if count == 1 then
            log.info(string.format(
                "[RE4R AP] door recovery: '%s' had stopped offering key item %d that the player " ..
                "is holding; re-armed it (CanReuse -> true)", name, item_id))
        elseif count == 3 then
            log.info(string.format(
                "[RE4R AP] door recovery: '%s' has now been re-armed %d times for key item %d. " ..
                "The trigger is NOT the whole problem - the door's open sequence is refusing " ..
                "separately, which is the A2 root cause (native pickup flags an injected key " ..
                "never fired). This is the case that needs the force-open lever.",
                name, count, item_id))
        end
        return true
    end

    local function poll_door_recovery(runtime_state)
        if runtime_state == nil
            or runtime_state.is_in_game ~= true
            or runtime_state.is_playable ~= true
            or runtime_state.is_loading == true then
            return
        end
        local now = os.clock()
        if now < next_poll then return end
        next_poll = now + POLL_SECONDS

        local read_keys = ctx.inject_read_key_item_ids or _G.inject_read_key_item_ids
        if type(read_keys) ~= "function" then return end
        local held_list = try(read_keys)
        if type(held_list) ~= "table" or #held_list == 0 then return end
        local held = {}
        for _, id in ipairs(held_list) do
            local n = tonumber(id)
            if n ~= nil then held[n] = true end
        end

        local get_comps = ctx.get_components or _G.get_components
        if type(get_comps) ~= "function" then return end
        local triggers = try(function() return get_comps("chainsaw.InteractTriggerUseItem") end)
        if triggers == nil then return end

        each(triggers, function(trigger)
            if trigger == nil then return false end
            local accepted = success_item_ids(trigger)
            if #accepted == 0 then return false end

            -- Only ever act on a key the player actually has. This is the whole
            -- safety property: no possession, no touch.
            local holding = nil
            for _, id in ipairs(accepted) do
                if held[id] then holding = id break end
            end
            if holding == nil then return false end

            -- Still offered means nothing is wrong here.
            if offered_item_ids(trigger)[holding] then return false end

            rearm(trigger, holding)
            return false
        end)
    end

    export("poll_door_recovery", poll_door_recovery)
end

return install
