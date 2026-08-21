local function install(ctx)
    ctx.injection = ctx.injection or {}

    local bridge = ctx.bridge
    local config = ctx.config or {}
    local injection = ctx.injection

    local function export(name, value)
        injection[name] = value
        ctx[name] = value
        _G[name] = value
    end

    local function clear_array(values)
        for index = #values, 1, -1 do
            values[index] = nil
        end
    end

    local function clear_lookup(values)
        for key, _ in pairs(values or {}) do
            values[key] = nil
        end
    end

    injection.items = injection.items or {}
    injection.item_names = injection.item_names or {}
    injection.item_kind_by_id = injection.item_kind_by_id or {}
    injection.item_class_by_id = injection.item_class_by_id or {}
    injection.item_stack_by_id = injection.item_stack_by_id or {}
    injection.ammo_item_id_by_class = injection.ammo_item_id_by_class or {}
    injection.category_counts = injection.category_counts or {}
    injection.category_names = injection.category_names or { "All" }

    local injectable_items = injection.items
    local injectable_item_names = injection.item_names
    local injectable_item_kind_by_id = injection.item_kind_by_id
    local injectable_item_class_by_id = injection.item_class_by_id
    local injectable_item_stack_by_id = injection.item_stack_by_id
    local injectable_ammo_item_id_by_class = injection.ammo_item_id_by_class
    local injectable_category_counts = injection.category_counts
    local injectable_category_names = injection.category_names

    local inject_item_to_inventory
    local inject_get_item_kind
    local inject_is_weapon_item_kind
    local inject_is_ptas_item
    local inject_is_spinel_item
    local inject_is_currency_item
    local inject_is_key_item_kind
    local inject_is_unique_item_kind
    local inject_is_token_kind
    local inject_is_treasure_kind
    local inject_get_route_label
    local inject_get_expected_commit_count
    local inject_get_route_hint
    local inject_record_recent_item

    local INJECT_RHINOCEROS_BEETLE_ITEM_ID = 114424000

    local FALLBACK_INJECTABLE_ITEMS = {
        { label = "First Aid Spray", item_id = 114416000, kind = "health" },
        { label = "Flash Grenade", item_id = 277078656, kind = "grenade" },
        { label = "Green Herb", item_id = 114400000, kind = "health" },
        { label = "Gunpowder", item_id = 117600000, kind = "gunpowder" },
        { label = "Hand Grenade", item_id = 277075456, kind = "grenade" },
        { label = "Handgun Ammo", item_id = 112800000, kind = "ammo" },
        { label = "Hunter's Lodge Key", item_id = 119281600, kind = "key" },
    }

    local INJECTABLE_KIND_DISPLAY_LABELS = {
        accessory = "Accessory",
        ammo = "Ammo",
        armor = "Armor",
        attachment = "Attachment",
        charm = "Charm",
        ["case-perk"] = "Case Perk",
        ["case-size"] = "Case Upgrade",
        egg = "Egg",
        fish = "Fish",
        grenade = "Grenade",
        gunpowder = "Resource",
        health = "Healing",
        key = "Key Item",
        knife = "Knife",
        map = "Map",
        money = "Money",
        recipe = "Recipe",
        resource = "Resource",
        ["small-key"] = "Key Item",
        special = "Special",
        token = "Token",
        treasure = "Treasure",
        viper = "Viper",
        weapon = "Weapon",
    }

    local function get_injectable_base_category(kind, label)
        if type(kind) == "string" and kind ~= "" then
            local mapped_label = INJECTABLE_KIND_DISPLAY_LABELS[string.lower(kind)]
            if type(mapped_label) == "string" and mapped_label ~= "" then
                return mapped_label
            end
        end

        local normalized_label = tostring(label or "")
        if normalized_label == "" then
            return "Unknown"
        end

        if string.find(normalized_label, "Accessory:", 1, true) == 1 then
            return "Accessory"
        end

        if normalized_label == "Blue" or normalized_label == "Red" or normalized_label == "Wellington" then
            return "Accessory"
        end

        if string.find(normalized_label, "Recipe:", 1, true) == 1 then
            return "Recipe"
        end

        if string.find(normalized_label, "Knife", 1, true) ~= nil then
            return "Knife"
        end

        if normalized_label == "Special" then
            return "Special"
        end

        return "Unknown"
    end

    local function get_injectable_display_category(kind, label)
        local base_category = get_injectable_base_category(kind, label)
        local normalized_label = tostring(label or "")
        if normalized_label == "Pesetas" or normalized_label == "Spinel" then
            return "Currency"
        end
        if base_category == "Egg" or base_category == "Fish" or base_category == "Map" then
            return "Misc"
        end
        if base_category == "Weapon"
            or base_category == "Grenade"
            or base_category == "Knife"
            or base_category == "Attachment"
            or base_category == "Armor" then
            return "Gear"
        end
        if base_category == "Case Perk" or base_category == "Case Upgrade" or base_category == "Charm" then
            return "Case"
        end
        local category_count = tonumber(injectable_category_counts[base_category]) or 0
        if category_count > 0 and category_count <= 2 then
            return "Misc"
        end
        return base_category
    end

    inject_get_route_hint = function(kind, item_id)
        if inject_is_currency_item(item_id) then
            return "Manager call"
        end
        if inject_is_weapon_item_kind(kind) then
            return "Storage delivery"
        end
        if inject_is_key_item_kind(kind) then
            return "Key item partition"
        end
        if inject_is_unique_item_kind(kind) then
            return "Unique inventory"
        end
        if inject_is_token_kind(kind) then
            return "Key item partition"
        end
        if inject_is_treasure_kind(kind, item_id) then
            return "Treasure partition"
        end
        return "Main inventory, Storage fallback when full"
    end

    local function get_injectable_short_label(entry)
        if type(entry) ~= "table" then
            return "Unknown"
        end

        local label = tostring(entry.label or "Unknown")
        local category = get_injectable_base_category(entry.kind, entry.label)
        if category == "Accessory" and string.find(label, "Accessory: ", 1, true) == 1 then
            return string.sub(label, #"Accessory: " + 1)
        end
        if category == "Charm" and string.find(label, "Charm: ", 1, true) == 1 then
            return string.sub(label, #"Charm: " + 1)
        end
        if category == "Recipe" and string.find(label, "Recipe: ", 1, true) == 1 then
            return string.sub(label, #"Recipe: " + 1)
        end

        return label
    end

    local function rebuild_injectable_item_names()
        clear_array(injectable_item_names)
        for index, entry in ipairs(injectable_items) do
            injectable_item_names[index] = get_injectable_short_label(entry)
        end
    end

    local function rebuild_injectable_categories()
        clear_lookup(injectable_category_counts)
        for _, entry in ipairs(injectable_items) do
            local base_category = get_injectable_base_category(entry.kind, entry.label)
            injectable_category_counts[base_category] = (tonumber(injectable_category_counts[base_category]) or 0) + 1
        end

        local seen = { ["All"] = true }
        clear_array(injectable_category_names)
        table.insert(injectable_category_names, "All")

        for _, entry in ipairs(injectable_items) do
            local category = get_injectable_display_category(entry.kind, entry.label)
            if not seen[category] then
                seen[category] = true
                table.insert(injectable_category_names, category)
            end
        end

        table.sort(injectable_category_names, function(left, right)
            if left == "All" then
                return true
            end
            if right == "All" then
                return false
            end
            return string.lower(left) < string.lower(right)
        end)
    end

    local function set_injectable_items(items)
        clear_array(injectable_items)
        clear_lookup(injectable_item_kind_by_id)
        clear_lookup(injectable_item_class_by_id)
        clear_lookup(injectable_item_stack_by_id)
        clear_lookup(injectable_ammo_item_id_by_class)

        for _, entry in ipairs(items) do
            if type(entry) == "table" and type(entry.label) == "string" and type(entry.item_id) == "number" then
                local normalized_kind = nil
                if type(entry.kind) == "string" and entry.kind ~= "" then
                    normalized_kind = string.lower(entry.kind)
                end
                if entry.item_id == INJECT_RHINOCEROS_BEETLE_ITEM_ID then
                    normalized_kind = "health"
                elseif normalized_kind == nil and entry.label == "Broken Knife" then
                    normalized_kind = "knife"
                elseif normalized_kind == nil and string.find(entry.label, "Recipe:", 1, true) == 1 then
                    normalized_kind = "recipe"
                elseif normalized_kind == nil
                    and (string.find(entry.label, "Accessory:", 1, true) == 1
                        or entry.label == "Blue"
                        or entry.label == "Red"
                        or entry.label == "Wellington") then
                    normalized_kind = "accessory"
                end

                local normalized_class = nil
                if type(entry.class_type) == "string" and entry.class_type ~= "" then
                    normalized_class = string.lower(entry.class_type)
                    if normalized_class == "none" then
                        normalized_class = nil
                    end
                end
                if normalized_class == nil and entry.label == "Broken Knife" then
                    normalized_class = "knife"
                end

                local normalized_stack = nil
                if type(entry.stack) == "number" then
                    normalized_stack = math.floor(entry.stack)
                end

                table.insert(injectable_items, {
                    label = entry.label,
                    item_id = entry.item_id,
                    kind = normalized_kind,
                    class_type = normalized_class,
                    stack = normalized_stack,
                })
                if normalized_kind ~= nil then
                    injectable_item_kind_by_id[entry.item_id] = normalized_kind
                end
                if normalized_class ~= nil then
                    injectable_item_class_by_id[entry.item_id] = normalized_class
                end
                if normalized_stack ~= nil then
                    injectable_item_stack_by_id[entry.item_id] = normalized_stack
                end
                if normalized_kind == "ammo" and normalized_class ~= nil then
                    injectable_ammo_item_id_by_class[normalized_class] = entry.item_id
                end
            end
        end

        if #injectable_items == 0 then
            for _, entry in ipairs(FALLBACK_INJECTABLE_ITEMS) do
                table.insert(injectable_items, {
                    label = entry.label,
                    item_id = entry.item_id,
                    kind = entry.kind,
                })
                if type(entry.kind) == "string" and entry.kind ~= "" then
                    injectable_item_kind_by_id[entry.item_id] = string.lower(entry.kind)
                end
            end
        end

        table.sort(injectable_items, function(left, right)
            local left_category = string.lower(get_injectable_display_category(left.kind, left.label))
            local right_category = string.lower(get_injectable_display_category(right.kind, right.label))
            if left_category ~= right_category then
                return left_category < right_category
            end

            local left_label = string.lower(tostring(left.label or ""))
            local right_label = string.lower(tostring(right.label or ""))
            if left_label ~= right_label then
                return left_label < right_label
            end

            return (tonumber(left.item_id) or 0) < (tonumber(right.item_id) or 0)
        end)

        rebuild_injectable_item_names()
        rebuild_injectable_categories()
    end

    local function load_injectable_items()
        local payload = json.load_file(config.INJECTABLE_ITEMS_FILE)
        local items = {}

        if type(payload) == "table" then
            local raw_items = payload.items
            if type(raw_items) ~= "table" then
                raw_items = payload
            end

            for _, entry in ipairs(raw_items) do
                if type(entry) == "table" then
                    local label = entry.label
                    local item_id = tonumber(entry.item_id)
                    local kind = nil
                    local class_type = nil
                    local stack = nil
                    if type(entry.kind) == "string" and entry.kind ~= "" then
                        kind = string.lower(entry.kind)
                    end
                    if type(entry.class_type) == "string" and entry.class_type ~= "" then
                        class_type = string.lower(entry.class_type)
                    end
                    if type(entry.stack) == "number" then
                        stack = math.floor(entry.stack)
                    end
                    if type(label) == "string" and item_id ~= nil then
                        table.insert(items, {
                            label = label,
                            item_id = math.floor(item_id),
                            kind = kind,
                            class_type = class_type,
                            stack = stack,
                        })
                    end
                end
            end
        end

        set_injectable_items(items)
    end

    local function prune_local_injection_suppressions()
        local now_ms = (ctx.now_unix_ms or _G.now_unix_ms)()
        local kept = {}
        for _, entry in ipairs(bridge.local_injection_suppressions or {}) do
            local expires_at_unix_ms = tonumber(entry.expires_at_unix_ms) or 0
            local accept_ignore_until_unix_ms = tonumber(entry.accept_ignore_until_unix_ms) or 0
            if expires_at_unix_ms > now_ms or accept_ignore_until_unix_ms > now_ms then
                table.insert(kept, entry)
            end
        end
        bridge.local_injection_suppressions = kept
    end

    local function record_local_injection_suppression(item_id, count)
        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        local normalized_count = math.max(1, math.floor(tonumber(count) or 0))
        if normalized_item_id <= 0 then
            return
        end

        prune_local_injection_suppressions()
        local now_ms = (ctx.now_unix_ms or _G.now_unix_ms)()
        table.insert(bridge.local_injection_suppressions, {
            item_id = normalized_item_id,
            count = normalized_count,
            recorded_at_unix_ms = now_ms,
            expires_at_unix_ms = now_ms + config.LOCAL_INJECTION_SUPPRESSION_WINDOW_MS,
            accept_ignore_until_unix_ms = now_ms + config.LOCAL_INJECTION_ACCEPT_SUPPRESSION_WINDOW_MS,
        })
    end

    local function consume_local_injection_suppression(item_id, count)
        prune_local_injection_suppressions()

        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        local normalized_count = math.max(1, math.floor(tonumber(count) or 0))
        if normalized_item_id <= 0 then
            return false
        end

        for index, entry in ipairs(bridge.local_injection_suppressions) do
            if entry.item_id == normalized_item_id and entry.count == normalized_count then
                table.remove(bridge.local_injection_suppressions, index)
                return true
            end
        end
        return false
    end

    local function inject_command_succeeded(status_text)
        local normalized_status = string.lower(trim_string(status_text))
        return normalized_status ~= "" and not string.find(normalized_status, "failed", 1, true)
    end

    local function select_known_injectable_item(index)
        if #injectable_items == 0 then
            return
        end

        local normalized_index = math.max(1, math.min(#injectable_items, math.floor(tonumber(index) or 1)))
        bridge.inject_selected_item_index = normalized_index
        bridge.inject_item_id_text = tostring(injectable_items[normalized_index].item_id)
    end

    local function find_known_injectable_item_index(item_id)
        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        for index, entry in ipairs(injectable_items) do
            if entry.item_id == normalized_item_id then
                return index
            end
        end

        return nil
    end

    inject_record_recent_item = function(item_id)
        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        if normalized_item_id <= 0 then
            return
        end

        local recent = {}
        table.insert(recent, normalized_item_id)
        for _, existing_item_id in ipairs(bridge.inject_recent_item_ids or {}) do
            local normalized_existing_id = math.floor(tonumber(existing_item_id) or 0)
            if normalized_existing_id > 0 and normalized_existing_id ~= normalized_item_id then
                table.insert(recent, normalized_existing_id)
            end
            if #recent >= 3 then
                break
            end
        end
        bridge.inject_recent_item_ids = recent
    end

    local function get_injectable_label_for_item_id(item_id)
        local matched_index = find_known_injectable_item_index(item_id)
        if matched_index ~= nil and injectable_items[matched_index] ~= nil then
            return get_injectable_short_label(injectable_items[matched_index]), matched_index
        end
        return tostring(item_id), nil
    end

    local function inject_status_succeeded(status)
        local normalized_status = string.lower(tostring(status or ""))
        return normalized_status ~= "" and string.find(normalized_status, "failed", 1, true) == nil
    end

    local function build_filtered_injectable_view(selected_category)
        local normalized_category = tostring(selected_category or "All")
        local filtered_names = {}
        local filtered_indices = {}

        for index, entry in ipairs(injectable_items) do
            local display_label = get_injectable_short_label(entry)
            local item_id_text = tostring(entry.item_id or "")
            local category_label = get_injectable_display_category(entry.kind, entry.label)
            local matches = normalized_category == "All" or category_label == normalized_category

            if matches then
                table.insert(filtered_names, string.format("%s [%s]", display_label, item_id_text))
                table.insert(filtered_indices, index)
            end
        end

        return filtered_names, filtered_indices
    end

    local function coerce_to_bool(value)
        if type(value) == "boolean" then
            return value
        end
        if value == nil then
            return false
        end

        local ok_bool, bool_value = pcall(function()
            return sdk.to_bool(value)
        end)
        if ok_bool and type(bool_value) == "boolean" then
            return bool_value
        end

        local ok_boolean, boolean_value = pcall(function()
            return sdk.to_boolean(value)
        end)
        if ok_boolean and type(boolean_value) == "boolean" then
            return boolean_value
        end

        return false
    end

    local function inject_safe_call(fn)
        local ok, value = pcall(fn)
        if ok then
            return value
        end
        return nil
    end

    local function inject_get_managed(value)
        if value == nil then
            return nil
        end

        local managed = inject_safe_call(function()
            return sdk.to_managed_object(value)
        end)
        if managed ~= nil then
            return managed
        end

        local type_def = inject_safe_call(function()
            return value:get_type_definition()
        end)
        if type_def ~= nil then
            return value
        end

        return nil
    end

    local function inject_try_add_ref(value)
        local managed = inject_get_managed(value)
        if managed == nil then
            return value
        end

        local add_ref_value = inject_safe_call(function()
            return managed:add_ref()
        end)
        if add_ref_value ~= nil then
            return add_ref_value
        end

        return managed
    end

    local function inject_get_type_name(type_object)
        if type_object == nil then
            return "(nil)"
        end

        local full_name = inject_safe_call(function()
            return type_object:get_full_name()
        end)
        if full_name ~= nil then
            return tostring(full_name)
        end

        local name = inject_safe_call(function()
            return type_object:get_name()
        end)
        if name ~= nil then
            return tostring(name)
        end

        return tostring(type_object)
    end

    local function inject_get_value_type(value)
        local managed = inject_get_managed(value)
        if managed == nil then
            return nil
        end

        return inject_safe_call(function()
            return managed:get_type_definition()
        end)
    end

    local function inject_get_value_type_name(value)
        local type_def = inject_get_value_type(value)
        if type_def ~= nil then
            return inject_get_type_name(type_def)
        end
        if value == nil then
            return "nil"
        end
        return type(value)
    end

    local function inject_value_to_string(value)
        if value == nil then
            return "nil"
        end

        if type(value) == "boolean" or type(value) == "number" or type(value) == "string" then
            return tostring(value)
        end

        local int_value = inject_safe_call(function()
            return sdk.to_int64(value)
        end)
        if int_value ~= nil then
            return tostring(int_value)
        end

        local managed = inject_get_managed(value)
        if managed ~= nil then
            local tostring_value = inject_safe_call(function()
                return managed:call("ToString()")
            end)
            if tostring_value ~= nil then
                return tostring(tostring_value)
            end
        end

        return tostring(value)
    end

    local function inject_get_parent_type(type_def)
        if type_def == nil then
            return nil
        end

        local parent = inject_safe_call(function()
            return type_def:get_parent_type()
        end)
        if parent ~= nil then
            return parent
        end

        return inject_safe_call(function()
            return type_def:get_parent_type_definition()
        end)
    end

    local function inject_find_method(type_def, method_name, param_count)
        local current_type = type_def
        while current_type ~= nil do
            for _, method in ipairs(current_type:get_methods()) do
                if tostring(method:get_name()) == method_name and method:get_num_params() == param_count then
                    return method
                end
            end
            current_type = inject_get_parent_type(current_type)
        end
        return nil
    end

    -- [Verified calls] REFramework does NOT raise when an invoke is rejected
    -- for a bad name or the wrong argument count: it prints a warning and
    -- returns nothing. So the house idiom
    --
    --     local ok = pcall(function() manager:call("whatever", true) end)
    --
    -- sets ok = true for a call that never happened, and any log line written
    -- on the strength of it is a lie. Two save requests lied that way for as
    -- long as they existed (found live 2026-08-17: the merchant's
    -- post-purchase save passed the wrong argument count, and the bonus-weapon
    -- unlock called requestSystemSave, which lives on an unrelated boot-flow
    -- class, not on SaveDataManager). Both logged success while saving
    -- nothing, and a player lost a refund gem to it.
    --
    -- Resolve the method off the type first and refuse when it is absent, so a
    -- typo or a signature change is a loud failure instead of a silent no-op.
    -- Returns ok, result-or-reason.
    local function inject_call_verified(target, method_name, ...)
        if target == nil then
            return false, "target is nil"
        end
        local managed = inject_get_managed(target)
        if managed == nil then
            return false, "target is not a managed object"
        end
        local type_def = inject_get_value_type(target)
        if type_def == nil then
            return false, "type definition unavailable"
        end
        local argument_count = select("#", ...)
        local method = inject_find_method(type_def, method_name, argument_count)
        if method == nil then
            return false, string.format(
                "%s has no %s taking %d argument(s)",
                tostring(inject_get_type_name(type_def)), method_name, argument_count)
        end
        local ok, result = pcall(method.call, method, managed, ...)
        if not ok then
            return false, tostring(result)
        end
        return true, result
    end

    local function inject_get_collection_count(collection)
        local managed = inject_get_managed(collection)
        if managed == nil then
            return nil
        end

        local count = inject_safe_call(function()
            return managed:call("get_Count()")
        end)
        if type(count) == "number" then
            return count
        end

        local length = inject_safe_call(function()
            return managed:call("get_Length()")
        end)
        if type(length) == "number" then
            return length
        end

        local elements = inject_safe_call(function()
            return managed:get_elements()
        end)
        if type(elements) == "table" then
            return #elements
        end

        return nil
    end

    local function inject_get_collection_item(collection, index)
        local managed = inject_get_managed(collection)
        if managed == nil then
            return nil
        end

        local value = inject_safe_call(function()
            return managed:call("get_Item", index)
        end)
        if value ~= nil then
            return value
        end

        local elements = inject_safe_call(function()
            return managed:get_elements()
        end)
        if type(elements) == "table" then
            return elements[index + 1]
        end

        return nil
    end

    local function inject_create_context_id(category, kind, group, index)
        local context_type = sdk.find_type_definition("chainsaw.ContextID")
        if context_type == nil then
            return nil
        end

        local context_id = inject_safe_call(function()
            return context_type:create_instance()
        end)
        if context_id == nil then
            context_id = inject_safe_call(function()
                return sdk.create_instance("chainsaw.ContextID")
            end)
        end
        if context_id == nil then
            return nil
        end

        local managed = inject_get_managed(context_id)
        if managed == nil then
            return nil
        end

        for field_name, field_value in pairs({
            _Category = category,
            _Kind = kind,
            _Group = group,
            _Index = index,
        }) do
            local ok = pcall(function()
                managed:set_field(field_name, field_value)
            end)
            if not ok then
                return nil
            end
        end

        return managed
    end

    local function inject_direct_dictionary_lookup(dictionary, key)
        local managed = inject_get_managed(dictionary)
        if managed == nil then
            return nil
        end

        for _, method_name in ipairs({ "ContainsKey", "ContainsKey(chainsaw.ContextID)" }) do
            local contains_result = inject_safe_call(function()
                return managed:call(method_name, key)
            end)
            if type(contains_result) == "boolean" and contains_result == false then
                return nil
            end
            if type(contains_result) == "boolean" then
                break
            end
        end

        for _, method_name in ipairs({ "get_Item", "get_Item(chainsaw.ContextID)" }) do
            local value = inject_safe_call(function()
                return managed:call(method_name, key)
            end)
            if value ~= nil then
                return value
            end
        end

        return nil
    end

    local function inject_set_field(instance, field_name, value)
        local managed = inject_get_managed(instance)
        if managed == nil then
            return false
        end

        local ok = pcall(function()
            managed:set_field(field_name, value)
        end)
        return ok
    end

    local function inject_generate_item(item_id, item_count)
        local gui_util_type = sdk.find_type_definition("chainsaw.ChainsawGuiUtil")
        if gui_util_type == nil then
            return nil, "ChainsawGuiUtil type missing"
        end

        -- generateItem discovery/call pattern credited to chenstack's item_adder.lua.
        local generate_item = gui_util_type:get_method("generateItem")
        if generate_item == nil then
            return nil, "generateItem method missing"
        end

        local generated_item = inject_safe_call(function()
            return generate_item:call(nil, item_id, item_count, -1, -1, 100, 0)
        end)
        if generated_item == nil then
            return nil, "generateItem returned nil"
        end

        generated_item = inject_try_add_ref(generated_item)
        return generated_item, nil
    end

    local function inject_get_storage_count(manager)
        local value = inject_safe_call(function()
            return manager:call("getStoredItemCount()")
        end)
        if value ~= nil then
            return value
        end

        return inject_safe_call(function()
            return manager:call("getStoredItemCount")
        end)
    end

    local function inject_create_armoury_item(item, item_id)
        local armoury_item = inject_safe_call(function()
            return sdk.create_instance("chainsaw.ArmouryItem", true)
        end)
        if armoury_item == nil then
            armoury_item = inject_safe_call(function()
                return sdk.create_instance("chainsaw.ArmouryItem")
            end)
        end
        if armoury_item == nil then
            return nil, "ArmouryItem creation failed"
        end

        armoury_item = inject_try_add_ref(armoury_item)
        inject_set_field(armoury_item, "_Item", item)
        inject_set_field(armoury_item, "_CurrVirtualStackCount", 1)
        inject_set_field(armoury_item, "_VirtualStackableCountMax", 1)

        local nested_item = inject_safe_call(function()
            return inject_get_managed(armoury_item):get_field("_Item")
        end)
        local nested_item_id = tonumber(inject_safe_call(function()
            return inject_get_managed(nested_item):get_field("_ItemId")
        end))
        if nested_item_id ~= tonumber(item_id) then
            return nil, "ArmouryItem wrapper verification failed"
        end

        return armoury_item, nil
    end

    local function inject_get_slot_row_column(slot_index)
        local managed = inject_get_managed(slot_index)
        if managed == nil then
            return nil, nil
        end

        local row = inject_safe_call(function()
            return managed:get_field("Row")
        end)
        local column = inject_safe_call(function()
            return managed:get_field("Column")
        end)

        return row, column
    end

    local INJECT_PTAS_ITEM_ID = 124000000
    local INJECT_SPINEL_ITEM_ID = 120800000
    -- Keys are engine item ids and MUST match items.py / re4r_ap_static.json.
    -- They were mistyped during the monolith split (a6c645c): the table shipped
    -- keyed on 1194xxxxx, which matches no item anywhere in the pipeline, so
    -- the lookup below could never hit and a received case upgrade added the
    -- item without ever calling changeSize. Corrected 2026-08-17 back to the
    -- ids the old monolith used. Verified by sweeping every 8-10 digit table
    -- key in the mod against the 138 known engine ids; this was the only miss.
    local INJECT_ATTACHE_CASE_SIZE_BY_ITEM_ID = {
        [124161600] = 1,  -- Case: 7x12
        [124163200] = 2,  -- Case: 8x12
        [124164800] = 3,  -- Case: 8x13
        [124166400] = 4,  -- Case: 9x13
    }

    inject_is_ptas_item = function(item_id)
        return math.floor(tonumber(item_id) or 0) == INJECT_PTAS_ITEM_ID
    end

    inject_is_spinel_item = function(item_id)
        return math.floor(tonumber(item_id) or 0) == INJECT_SPINEL_ITEM_ID
    end

    inject_is_currency_item = function(item_id)
        return inject_is_ptas_item(item_id) or inject_is_spinel_item(item_id)
    end

    inject_get_item_kind = function(item_id)
        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        if normalized_item_id <= 0 then
            return nil
        end

        local kind = injectable_item_kind_by_id[normalized_item_id]
        if type(kind) == "string" and kind ~= "" then
            return kind
        end
        return nil
    end

    inject_is_weapon_item_kind = function(kind)
        return kind == "weapon" or kind == "grenade" or kind == "knife" or kind == "egg"
    end

    inject_is_key_item_kind = function(kind)
        return kind == "key" or kind == "small-key"
    end

    inject_is_unique_item_kind = function(kind)
        return kind == "accessory"
            or kind == "armor"
            or kind == "charm"
            or kind == "case-perk"
            or kind == "case-size"
            or kind == "map"
            or kind == "recipe"
    end

    inject_is_token_kind = function(kind)
        return kind == "token"
    end

    inject_is_treasure_kind = function(kind, item_id)
        -- Tokens are deliberately excluded. TreasureInventoryController accepts
        -- their generated Item object but leaves a malformed entry which crashes
        -- Key Items & Treasures UI while dereferencing it. Tokens must go through
        -- KeyItemInventoryController:pickupItem so the controller can initialize
        -- and stack them using the same path as a normal in-game pickup.
        return kind == "treasure" and not inject_is_spinel_item(item_id)
    end

    inject_get_route_label = function(kind, item_id)
        if inject_is_currency_item(item_id) then
            return "Currency"
        end
        if inject_is_weapon_item_kind(kind) then
            return "Storage"
        end
        if inject_is_key_item_kind(kind) then
            return "Key Item"
        end
        if inject_is_unique_item_kind(kind) then
            return "Unique"
        end
        if inject_is_token_kind(kind) then
            return "Token"
        end
        if inject_is_treasure_kind(kind, item_id) then
            return "Treasure"
        end
        return "Main Inventory"
    end

    -- Player-facing destination for the "routing to <where>" receive toast:
    -- where does THIS item id actually land when injected? Mirrors
    -- inject_get_route_label's partitions in player vocabulary.
    local function inject_get_route_destination(item_id)
        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        local kind = inject_get_item_kind(normalized_item_id)
        if inject_is_currency_item(normalized_item_id) then
            return "wallet"
        end
        if inject_is_weapon_item_kind(kind) then
            return "storage"
        end
        if inject_is_key_item_kind(kind) or inject_is_unique_item_kind(kind) then
            return "key items"
        end
        if inject_is_token_kind(kind) then
            return "key items"
        end
        if inject_is_treasure_kind(kind, normalized_item_id) then
            return "treasures"
        end
        return "inventory"
    end

    inject_get_expected_commit_count = function(item_id, count)
        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        local normalized_count = math.max(1, math.floor(tonumber(count) or 0))
        local item_kind = inject_get_item_kind(normalized_item_id)

        if inject_is_currency_item(normalized_item_id) then
            return normalized_count
        end

        if inject_is_weapon_item_kind(item_kind)
            or inject_is_key_item_kind(item_kind)
            or inject_is_token_kind(item_kind)
            or inject_is_unique_item_kind(item_kind)
            or inject_is_treasure_kind(item_kind, normalized_item_id) then
            return 1
        end

        return normalized_count
    end

    local function inject_lookup_controller(controller_table, category, kind, group, index)
        local key = inject_create_context_id(category, kind, group, index)
        if key == nil then
            return nil, "context key creation failed"
        end

        local controller = inject_direct_dictionary_lookup(controller_table, key)
        if controller ~= nil then
            controller = inject_try_add_ref(controller)
        end
        if controller == nil then
            return nil, "controller lookup failed"
        end

        return controller, nil
    end

    -- [Ashley section] Walk _ControllerTable's backing entries so a controller can
    -- be found by TYPE instead of by a guessed ContextID. Leon's inventory keys are
    -- known constants, but the Ashley section runs a different character with its
    -- own contexts, so every hardcoded lookup missed and NOTHING from the
    -- multiworld could be delivered while playing as her - including the Salazar
    -- Family Insignia her own section needs, which is a hard softlock (Cam, live
    -- 2026-07-29). Field name varies with the runtime's Dictionary layout, so try
    -- the known spellings and give up quietly.
    local function inject_enumerate_controllers(controller_table)
        local managed = inject_get_managed(controller_table)
        if managed == nil then
            return {}
        end

        local function value_of(entry)
            if entry == nil then
                return nil
            end
            for _, value_field in ipairs({ "value", "_value" }) do
                local value = inject_safe_call(function() return entry:get_field(value_field) end)
                if value ~= nil then
                    return value
                end
            end
            -- Deliberately NO "return entry" fallback: an unextracted
            -- Dictionary Entry struct is not a controller, and returning it
            -- fed the type match a name like
            -- "Dictionary`2.Entry<ContextID,InventoryControllerBase>" that
            -- matched the hint by substring and produced a controller with no
            -- CsInventory (live 2026-07-30, "Main Inventory inject failed:
            -- CsInventory missing").
            return nil
        end

        local results = {}
        for _, field_name in ipairs({ "_entries", "entries", "_values", "values" }) do
            local entries = inject_safe_call(function()
                return managed:get_field(field_name)
            end)
            if entries ~= nil then
                -- get_elements() is the array walk this file already relies on
                -- (inject_get_collection_count); indexed access is the fallback.
                local elements = inject_safe_call(function() return entries:get_elements() end)
                if type(elements) == "table" then
                    for _, entry in ipairs(elements) do
                        local value = value_of(entry)
                        if value ~= nil then
                            results[#results + 1] = value
                        end
                    end
                end
                if #results == 0 then
                    local count = tonumber(inject_safe_call(function() return entries:get_size() end))
                        or tonumber(inject_safe_call(function() return entries:call("get_Length()") end))
                    if count ~= nil and count > 0 then
                        -- Cap the walk: the table is small, and a bogus size must
                        -- not spin the frame.
                        for i = 0, math.min(math.floor(count), 64) - 1 do
                            local value = value_of(
                                inject_safe_call(function() return entries:get_element(i) end))
                            if value ~= nil then
                                results[#results + 1] = value
                            end
                        end
                    end
                end
                if #results > 0 then
                    return results
                end
            end
        end
        return results
    end

    -- Find a controller in the table whose type name contains type_hint (for
    -- example "KeyItemInventory"). Character-agnostic: whoever the player
    -- currently is, their controllers are the ones registered in the table.
    -- EXACT class match only. A substring test is unsafe here: the table's own
    -- Dictionary Entry type spells its value class inside the generic
    -- parameters, so "chainsaw.InventoryController" matched
    -- "...Entry<ContextID,chainsaw.InventoryControllerBase>" and handed back a
    -- struct with no inventory behind it. Callers pass every acceptable class.
    local function inject_find_controller_by_type(controller_table, type_names)
        local wanted = {}
        for _, name in ipairs(type_names) do
            wanted[name] = true
        end
        for _, candidate in ipairs(inject_enumerate_controllers(controller_table)) do
            local type_name = inject_get_value_type_name(candidate)
            if type(type_name) == "string" and wanted[type_name] then
                local resolved = inject_try_add_ref(candidate)
                if resolved ~= nil then
                    return resolved, type_name
                end
            end
        end
        return nil, nil
    end

    -- Failure diagnostic: name every controller actually registered right now.
    -- Fires only when resolution failed completely, so a stuck player's log
    -- carries what we need without asking them to run a probe.
    local function inject_log_controller_table(controller_table, route_label)
        local names = {}
        for _, candidate in ipairs(inject_enumerate_controllers(controller_table)) do
            names[#names + 1] = tostring(inject_get_value_type_name(candidate))
        end
        if #names == 0 then
            log.error(string.format(
                "[RE4R AP] %s: _ControllerTable could not be enumerated (Dictionary layout unknown) - report this log",
                tostring(route_label)))
            return
        end
        log.error(string.format(
            "[RE4R AP] %s: _ControllerTable holds %d controller(s): %s",
            tostring(route_label), #names, table.concat(names, ", ")))
    end

    -- The resolution ladder for an inventory controller: the known-good key
    -- (Leon, unchanged fast path), then a type match over the live table (any
    -- character, including Ashley). Logs which route won so the Ashley-section
    -- contexts become documented fact rather than a guess.
    local function inject_resolve_controller(controller_table, category, kind, group, index, type_names, route_label)
        local controller, lookup_error = inject_lookup_controller(controller_table, category, kind, group, index)
        if controller ~= nil then
            return controller, nil
        end

        local found, type_name = inject_find_controller_by_type(controller_table, type_names)
        if found ~= nil then
            log.info(string.format(
                "[RE4R AP] %s: ContextID (%d,%d,%d,%d) missed, using %s found in _ControllerTable by class",
                tostring(route_label), category, kind, group, index, tostring(type_name)))
            return found, nil
        end

        inject_log_controller_table(controller_table, route_label)
        return nil, string.format(
            "%s (no %s registered)", tostring(lookup_error), table.concat(type_names, "/"))
    end

    -- True while the campaign lead (Leon) owns the live inventories. The Ashley
    -- section registers HER controllers under different ContextIDs, so Leon's
    -- known key-item ID being absent is a reliable, cheap "someone else is
    -- playing" test - no character-type reflection needed.
    --
    -- This matters because that section's inventories are DISCARDED when it
    -- ends: proven live 2026-07-30, items injected into Ashley's main grid AND
    -- into Storage were both gone once Leon returned. Delivering to her would
    -- tell the multiworld an item was received that the player never keeps.
    local function inject_is_default_character_active()
        local inventory_manager = sdk.get_managed_singleton("chainsaw.InventoryManager")
        if inventory_manager == nil then
            return true -- no manager yet (menus/loading): do not claim a swap
        end
        inventory_manager = inject_try_add_ref(inventory_manager)
        if inventory_manager == nil then
            return true
        end
        local manager_managed = inject_get_managed(inventory_manager)
        local controller_table = inject_safe_call(function()
            return manager_managed:get_field("_ControllerTable")
        end)
        if controller_table == nil then
            return true
        end
        local controller = inject_lookup_controller(controller_table, 4, 2, 1, 4000)
        return controller ~= nil
    end
    export("inject_is_default_character_active", inject_is_default_character_active)

    -- ===== Key-item mirror for character-swap sections =====
    -- Key items do NOT cross between characters in either direction (Cam,
    -- live 2026-07-30): the lead's insignia never reaches Ashley, and anything
    -- delivered to her is discarded with her section. Vanilla never notices
    -- because she FINDS her own insignia inside the section; AP shuffles that
    -- item away, so her door can become unopenable.
    --
    -- Fix: while the lead plays we keep a snapshot of his key-item ids, and the
    -- moment another character takes over we replay that snapshot into THEIR key
    -- inventory. Her inventory is thrown away at section end, so duplicates are
    -- inert and nothing needs cleaning up afterwards.
    local key_item_snapshot = {}
    local key_item_snapshot_logged = false
    local key_item_read_dump_logged = false

    -- Candidate accessors for "what key items are held". The class is not
    -- documented anywhere in this repo, so probe the plausible names and dump the
    -- real member list once if every guess misses.
    -- The working accessor (il2cpp dump): getInventoryItems() -> List<
    -- KeyItemInventoryItem>, zero-arg. getItems() is NOT usable here - it takes
    -- a Predicate<ItemID> (getItems304253), so the old zero-arg call threw
    -- "Invalid number of arguments" on EVERY 2s poll, spamming the log before
    -- falling through to the accessor that works (live: 1.7k-4.7k warnings per
    -- session). Dropped outright.
    local KEY_ITEM_LIST_ACCESSORS = {
        "getInventoryItems",
        "get_ItemList", "getItemList", "get_Items", "get_KeyItemList", "get_ItemDataList",
    }
    local KEY_ITEM_LIST_FIELDS = {
        "_ItemList", "_Items", "_KeyItemList", "_ItemDataList", "<ItemList>k__BackingField",
    }

    local function inject_dump_key_controller_members(controller)
        if key_item_read_dump_logged then
            return
        end
        key_item_read_dump_logged = true
        local controller_type = inject_get_value_type(controller)
        if controller_type == nil then
            log.error("[RE4R AP] key-item mirror: controller type unavailable")
            return
        end
        local names = {}
        local ok_methods = pcall(function()
            for _, method in ipairs(controller_type:get_methods()) do
                local name = method:get_name()
                if string.find(name, "tem", 1, true) or string.find(name, "ist", 1, true) then
                    names[#names + 1] = "m:" .. name
                end
            end
        end)
        local ok_fields = pcall(function()
            for _, field in ipairs(controller_type:get_fields()) do
                names[#names + 1] = "f:" .. field:get_name()
            end
        end)
        log.error(string.format(
            "[RE4R AP] key-item mirror: no known accessor on %s (methods_ok=%s fields_ok=%s) members: %s",
            tostring(inject_get_value_type_name(controller)),
            tostring(ok_methods), tostring(ok_fields),
            table.concat(names, ", ")))
    end

    -- Read the live key-item ids out of whichever key controller is registered.
    local function inject_read_key_item_ids()
        local inventory_manager = sdk.get_managed_singleton("chainsaw.InventoryManager")
        if inventory_manager == nil then
            return nil
        end
        inventory_manager = inject_try_add_ref(inventory_manager)
        local manager_managed = inject_get_managed(inventory_manager)
        if manager_managed == nil then
            return nil
        end
        local controller_table = inject_safe_call(function()
            return manager_managed:get_field("_ControllerTable")
        end)
        if controller_table == nil then
            return nil
        end
        local controller = inject_lookup_controller(controller_table, 4, 2, 1, 4000)
        if controller == nil then
            return nil -- lead's controller absent: not the lead, nothing to snapshot
        end

        local controller_managed = inject_get_managed(controller)
        if controller_managed == nil then
            return nil
        end

        local list = nil
        for _, accessor in ipairs(KEY_ITEM_LIST_ACCESSORS) do
            list = inject_safe_call(function() return controller_managed:call(accessor) end)
            if list ~= nil then break end
        end
        if list == nil then
            for _, field_name in ipairs(KEY_ITEM_LIST_FIELDS) do
                list = inject_safe_call(function() return controller_managed:get_field(field_name) end)
                if list ~= nil then break end
            end
        end
        if list == nil then
            inject_dump_key_controller_members(controller)
            return nil
        end

        local count = inject_get_collection_count(list)
        if type(count) ~= "number" then
            return nil
        end

        local ids = {}
        for index = 0, math.min(math.floor(count), 128) - 1 do
            local entry = inject_get_collection_item(list, index)
            if entry ~= nil then
                -- The entry may be the item itself or a holder with _ItemId.
                local item_id = nil
                for _, getter in ipairs({ "get_ItemId", "get_ItemID", "get_Id" }) do
                    item_id = tonumber(inject_safe_call(function() return entry:call(getter) end))
                    if item_id ~= nil then break end
                end
                if item_id == nil then
                    for _, field_name in ipairs({ "_ItemId", "_ItemID", "ItemId", "ItemID" }) do
                        item_id = tonumber(inject_safe_call(function() return entry:get_field(field_name) end))
                        if item_id ~= nil then break end
                    end
                end
                if item_id ~= nil and item_id > 0 then
                    ids[#ids + 1] = math.floor(item_id)
                end
            end
        end
        return ids
    end

    local function inject_write_storage(item, normalized_item_id, normalized_count, route_label, fallback_reason)
        local armoury_manager = sdk.get_managed_singleton("chainsaw.ArmouryManager")
        if armoury_manager ~= nil then
            armoury_manager = inject_try_add_ref(armoury_manager)
        end
        if armoury_manager == nil then
            return string.format("%s inject failed: ArmouryManager singleton missing", route_label)
        end

        local armoury_item, wrapper_error = inject_create_armoury_item(item, normalized_item_id)
        if armoury_item == nil then
            return string.format("%s inject failed: %s", route_label, tostring(wrapper_error))
        end

        local before_count = inject_get_storage_count(armoury_manager)
        local ok, err = pcall(function()
            armoury_manager:call("addArmouryItem(chainsaw.ArmouryItem)", armoury_item)
        end)
        if not ok then
            return string.format("%s inject failed: addArmouryItem err=%s", route_label, tostring(err))
        end

        local after_count = inject_get_storage_count(armoury_manager)
        local stored = type(before_count) == "number" and type(after_count) == "number" and after_count > before_count
        if stored then
            if type(fallback_reason) == "string" and fallback_reason ~= "" then
                return string.format(
                    "%s full; sent %d x%d to Storage",
                    route_label,
                    normalized_item_id,
                    normalized_count
                )
            end
            return string.format(
                "Storage added %d x%d (count %s->%s)",
                normalized_item_id,
                normalized_count,
                tostring(before_count),
                tostring(after_count)
            )
        end

        return string.format(
            "%s inject failed: addArmouryItem no count change (%s->%s)",
            route_label,
            tostring(before_count),
            tostring(after_count)
        )
    end

    local function inject_write_treasure_inventory(normalized_item_id, normalized_count, item, route_label)
        -- Treasure delivery via TreasureInventoryController:add(...) matches chenstack's
        -- item_adder.lua routing instead of using pickupItem(...).
        local character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
        if character_manager == nil then
            return string.format("%s inject failed: CharacterManager singleton missing", route_label)
        end

        local player = inject_safe_call(function()
            return character_manager:call("getPlayerContextRef()")
        end)
        if player == nil then
            player = inject_safe_call(function()
                return character_manager:call("getPlayerContextRef")
            end)
        end
        if player == nil then
            return string.format("%s inject failed: player context missing", route_label)
        end
        player = inject_try_add_ref(player)

        local head_updater = inject_safe_call(function()
            return player:call("get_HeadUpdater()")
        end)
        if head_updater == nil then
            head_updater = inject_safe_call(function()
                return player:call("get_HeadUpdater")
            end)
        end
        if head_updater == nil then
            return string.format("%s inject failed: HeadUpdater missing", route_label)
        end
        head_updater = inject_try_add_ref(head_updater)

        local controller = inject_safe_call(function()
            return head_updater:call("get_TreasureInventoryController()")
        end)
        if controller == nil then
            controller = inject_safe_call(function()
                return head_updater:call("get_TreasureInventoryController")
            end)
        end
        if controller == nil then
            return string.format("%s inject failed: TreasureInventoryController missing", route_label)
        end
        controller = inject_try_add_ref(controller)

        local add_result = inject_safe_call(function()
            return controller:call("add", item)
        end)
        if add_result == nil then
            add_result = inject_safe_call(function()
                return controller:call("add(chainsaw.Item)", item)
            end)
        end
        if add_result ~= nil then
            return string.format(
                "%s added %d x%d (%s)",
                route_label,
                normalized_item_id,
                normalized_count,
                inject_value_to_string(add_result)
            )
        end

        return string.format("%s inject failed: treasure add returned nil", route_label)
    end

    local function inject_write_unique_inventory(normalized_item_id, normalized_count, item, route_label)
        -- Unique-item routing and attaché-case size follow-up are based on chenstack's
        -- item_adder.lua handling for charms, case perks, and case-size upgrades.
        local character_manager = sdk.get_managed_singleton("chainsaw.CharacterManager")
        if character_manager == nil then
            return string.format("%s inject failed: CharacterManager singleton missing", route_label)
        end

        local player = inject_safe_call(function()
            return character_manager:call("getPlayerContextRef()")
        end)
        if player == nil then
            player = inject_safe_call(function()
                return character_manager:call("getPlayerContextRef")
            end)
        end
        if player == nil then
            return string.format("%s inject failed: player context missing", route_label)
        end
        player = inject_try_add_ref(player)

        local head_updater = inject_safe_call(function()
            return player:call("get_HeadUpdater()")
        end)
        if head_updater == nil then
            head_updater = inject_safe_call(function()
                return player:call("get_HeadUpdater")
            end)
        end
        if head_updater == nil then
            return string.format("%s inject failed: HeadUpdater missing", route_label)
        end
        head_updater = inject_try_add_ref(head_updater)

        local controller = inject_safe_call(function()
            return head_updater:call("get_UniqueInventoryController()")
        end)
        if controller == nil then
            controller = inject_safe_call(function()
                return head_updater:call("get_UniqueInventoryController")
            end)
        end
        if controller == nil then
            return string.format("%s inject failed: UniqueInventoryController missing", route_label)
        end
        controller = inject_try_add_ref(controller)

        local add_result = inject_safe_call(function()
            return controller:call("add", item)
        end)
        if add_result == nil then
            add_result = inject_safe_call(function()
                return controller:call("add(chainsaw.Item)", item)
            end)
        end
        if add_result == nil then
            return string.format("%s inject failed: unique add returned nil", route_label)
        end

        local attache_case_size = INJECT_ATTACHE_CASE_SIZE_BY_ITEM_ID[normalized_item_id]
        if attache_case_size ~= nil then
            local main_inventory_controller = inject_safe_call(function()
                return head_updater:call("get_InventoryController()")
            end)
            if main_inventory_controller == nil then
                main_inventory_controller = inject_safe_call(function()
                    return head_updater:call("get_InventoryController")
                end)
            end
            if main_inventory_controller == nil then
                log.info(string.format(
                    "[RE4R AP] %s: case upgrade to size %d SKIPPED, InventoryController missing",
                    route_label, attache_case_size))
            else
                main_inventory_controller = inject_try_add_ref(main_inventory_controller)
                -- changeSize hands back nothing worth trusting, so the size is
                -- read again afterwards and the before/after pair is what
                -- proves it took. Believing a return value is exactly what hid
                -- the stand-in sweep failing for a week.
                local function read_case_size()
                    local raw = inject_safe_call(function()
                        return main_inventory_controller:call("get_CurrInventorySize()")
                    end)
                    if raw == nil then
                        raw = inject_safe_call(function()
                            return main_inventory_controller:call("get_CurrInventorySize")
                        end)
                    end
                    return tonumber(raw)
                end
                local before = read_case_size()
                if before ~= nil and before >= attache_case_size then
                    log.info(string.format(
                        "[RE4R AP] %s: case already at size %d, upgrade to %d is a no-op",
                        route_label, before, attache_case_size))
                else
                    inject_safe_call(function()
                        return main_inventory_controller:call("changeSize", attache_case_size, false)
                    end)
                    inject_safe_call(function()
                        return main_inventory_controller:call("changeSize(System.Int32, System.Boolean)", attache_case_size, false)
                    end)
                    local after = read_case_size()
                    if after ~= nil and after >= attache_case_size then
                        log.info(string.format(
                            "[RE4R AP] %s: case resized %s -> %d",
                            route_label, before ~= nil and tostring(before) or "?", after))
                    else
                        log.info(string.format(
                            "[RE4R AP] %s: case resize to %d FAILED, size still reads %s",
                            route_label, attache_case_size,
                            after ~= nil and tostring(after) or "unreadable"))
                    end
                end
            end
        end

        return string.format(
            "%s added %d x%d (%s)",
            route_label,
            normalized_item_id,
            normalized_count,
            inject_value_to_string(add_result)
        )
    end

    local function inject_write_currency(inventory_manager, normalized_item_id, normalized_count, route_label)
        -- Currency routing based on chenstack's item_adder.lua special-case manager calls.
        if inject_is_ptas_item(normalized_item_id) then
            local ok = pcall(function()
                inventory_manager:call("addPTAS", normalized_count, false)
            end)
            if not ok then
                ok = pcall(function()
                    inventory_manager:call("addPTAS(System.Int32, System.Boolean)", normalized_count, false)
                end)
            end
            if ok then
                return string.format("%s added %d PTAS", route_label, normalized_count)
            end
            return string.format("%s inject failed: addPTAS unavailable", route_label)
        end

        if inject_is_spinel_item(normalized_item_id) then
            local shop_manager = sdk.get_managed_singleton("chainsaw.InGameShopManager")
            if shop_manager ~= nil then
                shop_manager = inject_try_add_ref(shop_manager)
            end
            if shop_manager == nil then
                return string.format("%s inject failed: InGameShopManager singleton missing", route_label)
            end

            local ok = pcall(function()
                shop_manager:call("addSpinelCount", normalized_count)
            end)
            if not ok then
                ok = pcall(function()
                    shop_manager:call("addSpinelCount(System.Int32)", normalized_count)
                end)
            end
            if ok then
                return string.format("%s added %d Spinel", route_label, normalized_count)
            end
            return string.format("%s inject failed: addSpinelCount unavailable", route_label)
        end

        return string.format("%s inject failed: unknown currency item", route_label)
    end

    -- [Stack-aware delivery] Top up existing same-item stacks before opening a
    -- new one. Playtest report 2026-08-05: every injected ammo arrived as its
    -- own one-slot stack because this route only ever targeted an EMPTY slot
    -- with forceSetItem. Names verified against il2cpp_dump.json:
    -- CsInventory._InventoryItems is List<CsInventoryItem>; the wrapper's
    -- <Item>/<SlotIndex>/<CurrSlotType> backing fields hold the payload and
    -- its grid position; chainsaw.Item carries _ItemId/_CurrentItemCount;
    -- ItemDefiniition._StackMax bounds a stack; CsInventory.stackAdd(item,
    -- slotType, slotIndex) merges into the stack AT that slot and returns
    -- AddItemResult{AddCount}. Every engine effect is verified by re-reading
    -- state (REFramework returns nil without throwing on signature misses);
    -- any surprise stops the merge loop and leaves the remainder to the
    -- legacy empty-slot path, so delivery can never fall below the old route.
    local function inject_address_of(value)
        local managed = inject_get_managed(value)
        if managed == nil then
            return nil
        end
        return inject_safe_call(function()
            return managed:get_address()
        end)
    end

    local function inject_read_item_count(item_value)
        local managed = inject_get_managed(item_value)
        if managed == nil then
            return nil
        end
        return tonumber(inject_safe_call(function()
            return managed:get_field("_CurrentItemCount")
        end))
    end

    local function inject_set_item_count(item_value, new_count)
        local managed = inject_get_managed(item_value)
        if managed == nil then
            return false
        end
        inject_safe_call(function()
            managed:set_field("_CurrentItemCount", new_count)
        end)
        return inject_read_item_count(item_value) == new_count
    end

    local function inject_collect_partial_stacks(cs_inventory, normalized_item_id, exclude_address)
        local partials = {}
        local managed = inject_get_managed(cs_inventory)
        if managed == nil then
            return partials
        end
        local items_list = inject_safe_call(function()
            return managed:get_field("_InventoryItems")
        end)
        local total = inject_get_collection_count(items_list)
        if type(total) ~= "number" then
            return partials
        end
        for index = 0, math.min(total, 200) - 1 do
            local wrapper = inject_get_collection_item(items_list, index)
            local wrapper_managed = inject_get_managed(wrapper)
            if wrapper_managed ~= nil then
                local wrapped_item = inject_safe_call(function()
                    return wrapper_managed:get_field("<Item>k__BackingField")
                end)
                local wrapped_managed = inject_get_managed(wrapped_item)
                if wrapped_managed ~= nil
                    and (exclude_address == nil or inject_address_of(wrapped_item) ~= exclude_address) then
                    local wrapped_id = tonumber(inject_safe_call(function()
                        return wrapped_managed:get_field("_ItemId")
                    end))
                    if wrapped_id == normalized_item_id then
                        local current = inject_read_item_count(wrapped_item)
                        local define = inject_safe_call(function()
                            return wrapped_managed:get_field("<_ItemDefine>k__BackingField")
                        end)
                        local define_managed = inject_get_managed(define)
                        local stack_max = define_managed ~= nil and tonumber(inject_safe_call(function()
                            return define_managed:get_field("_StackMax")
                        end)) or nil
                        if type(current) == "number" and type(stack_max) == "number"
                            and stack_max > current then
                            table.insert(partials, {
                                wrapper = wrapper_managed,
                                item = wrapped_item,
                                slot_type = inject_safe_call(function()
                                    return wrapper_managed:get_field("<CurrSlotType>k__BackingField")
                                end),
                                slot_index = inject_safe_call(function()
                                    return wrapper_managed:get_field("<SlotIndex>k__BackingField")
                                end),
                            })
                        end
                    end
                end
            end
        end
        return partials
    end

    -- Returns how many of the item's units were absorbed into existing stacks
    -- and how many remain on the item instance afterwards.
    local function inject_try_stack_delivery(cs_inventory, item, normalized_item_id, normalized_count, route_label)
        local remaining = normalized_count
        local absorbed = 0
        local cs_type = inject_get_value_type(cs_inventory)
        local stack_add = inject_find_method(cs_type, "stackAdd", 3)
        if stack_add == nil then
            return absorbed, remaining
        end
        local partials = inject_collect_partial_stacks(
            cs_inventory, normalized_item_id, inject_address_of(item))
        if #partials == 0 then
            return absorbed, remaining
        end

        local cs_managed = inject_get_managed(cs_inventory)
        for _, entry in ipairs(partials) do
            if remaining <= 0 then
                break
            end
            if entry.slot_type == nil or entry.slot_index == nil then
                break
            end
            local before = inject_read_item_count(entry.item)
            local result = inject_safe_call(function()
                return stack_add:call(cs_managed, item, entry.slot_type, entry.slot_index)
            end)
            local after = inject_read_item_count(entry.item)
            local gained = (type(before) == "number" and type(after) == "number")
                and (after - before) or 0
            if gained <= 0 then
                log.info(string.format(
                    "[RE4R AP] %s: stackAdd made no progress (result=%s), leaving %d for slot placement",
                    route_label, inject_value_to_string(result), remaining))
                break
            end
            absorbed = absorbed + gained
            remaining = math.max(0, remaining - gained)
            log.info(string.format(
                "[RE4R AP] %s: stacked %d into an existing stack (%d -> %d), %d remaining",
                route_label, gained, before, after, remaining))
            -- Commit-hook suppression matches on EXACT count, and the engine
            -- reports injected writes through the same hook as world pickups:
            -- record the actual merged amount so a partial stackAdd commit
            -- cannot dodge apclient's full-count record. Extra unconsumed
            -- entries expire with the suppression window, same as today.
            record_local_injection_suppression(normalized_item_id, gained)
            -- Keep the source item's own count truthful for whatever happens
            -- next (slot placement, storage overflow, or nothing).
            if inject_read_item_count(item) ~= remaining then
                inject_set_item_count(item, remaining)
            end
        end
        return absorbed, remaining
    end

    -- The engine marks forceSetItem inserts with the wrapper's IsForceGet
    -- flag; organic pickups carry false. Live evidence says the flag does not
    -- block merging, but clear it so an injected stack is indistinguishable
    -- from an organic one. Best effort: failure changes nothing.
    local function inject_clear_force_get(cs_inventory, placed_item)
        local placed_address = inject_address_of(placed_item)
        if placed_address == nil then
            return
        end
        local managed = inject_get_managed(cs_inventory)
        if managed == nil then
            return
        end
        local items_list = inject_safe_call(function()
            return managed:get_field("_InventoryItems")
        end)
        local total = inject_get_collection_count(items_list)
        if type(total) ~= "number" then
            return
        end
        for index = 0, math.min(total, 200) - 1 do
            local wrapper = inject_get_collection_item(items_list, index)
            local wrapper_managed = inject_get_managed(wrapper)
            if wrapper_managed ~= nil then
                local wrapped_item = inject_safe_call(function()
                    return wrapper_managed:get_field("<Item>k__BackingField")
                end)
                if inject_address_of(wrapped_item) == placed_address then
                    inject_safe_call(function()
                        wrapper_managed:call("set_IsForceGet", false)
                    end)
                    return
                end
            end
        end
    end

    local function inject_write_main_inventory(controller_table, item, normalized_item_id, normalized_count, route_label)
        -- "Inventory" without the Key/Treasure/Unique prefix would also match the
        -- specialised controllers, so the type hint is the exact class name.
        local controller, controller_error = inject_resolve_controller(
            -- chainsaw.CsInventoryController is the main-grid controller: it is
            -- what holds the _CsInventory this route writes into. Confirmed from
            -- a live _ControllerTable dump during the Ashley section (2026-07-30),
            -- which registers exactly KeyItem / Cs / Unique / Treasure - there is
            -- no type called "InventoryController".
            controller_table, 4, 2, 0, 4000, { "chainsaw.CsInventoryController" }, route_label)
        if controller == nil then
            return string.format("%s inject failed: %s", route_label, tostring(controller_error))
        end

        local controller_managed = inject_get_managed(controller)
        local cs_inventory = inject_safe_call(function()
            return controller_managed:get_field("<_CsInventory>k__BackingField")
        end)
        if cs_inventory ~= nil then
            cs_inventory = inject_try_add_ref(cs_inventory)
        end
        if cs_inventory == nil then
            return string.format("%s inject failed: CsInventory missing", route_label)
        end

        local cs_type = inject_get_value_type(cs_inventory)
        local get_empty = inject_find_method(cs_type, "getEmptySlotIndexList", 1)
        local force_set = inject_find_method(cs_type, "forceSetItem", 4)
        local stack_add = inject_find_method(cs_type, "stackAdd", 3)
        if get_empty == nil then
            return string.format("%s inject failed: getEmptySlotIndexList missing", route_label)
        end
        if force_set == nil then
            return string.format("%s inject failed: forceSetItem missing", route_label)
        end

        -- Existing stacks with room absorb the delivery first; only the
        -- remainder needs a slot of its own.
        local absorbed, remaining = inject_try_stack_delivery(
            cs_inventory, item, normalized_item_id, normalized_count, route_label)
        if remaining <= 0 then
            return string.format(
                "%s stacked all %d of item %d into existing stacks",
                route_label,
                normalized_count,
                normalized_item_id
            )
        end

        -- Fit-checked placement (playtest report 2026-08-05: injected items
        -- hanging past the case boundary). forceSetItem plants the item's
        -- anchor at the first empty CELL and never asks whether the footprint
        -- fits, so anything larger than 1x1 placed near the edge overhung the
        -- grid. The engine's own answers: enableAddItem(item, AddItemType.Add)
        -- says whether ANY legal spot exists, and add() is the fit-checked
        -- sibling of forceSetItem that refuses an illegal anchor. Signatures
        -- from il2cpp_dump.json; every call is verified by its effects.
        local add_method = inject_find_method(cs_type, "add", 4)
        local enable_add = inject_find_method(cs_type, "enableAddItem", 2)

        local engine_says_fits = nil
        if enable_add ~= nil then
            engine_says_fits = inject_safe_call(function()
                return enable_add:call(inject_get_managed(cs_inventory), item, 0)
            end)
        end
        if engine_says_fits == false then
            -- A case can have free cells and still no legal spot for a tall
            -- item; Storage is the honest destination, not an overhang.
            return inject_write_storage(item, normalized_item_id, remaining, route_label, "no space fits the item")
        end

        local empty_slots = inject_safe_call(function()
            return get_empty:call(inject_get_managed(cs_inventory), 0)
        end)
        local empty_slot_count = inject_get_collection_count(empty_slots)
        if type(empty_slot_count) ~= "number" or empty_slot_count <= 0 then
            return inject_write_storage(item, normalized_item_id, remaining, route_label, "attache case full")
        end

        local placed_suffix = (absorbed > 0)
            and string.format(" (+%d stacked into existing stacks)", absorbed)
            or ""

        if add_method ~= nil then
            for slot_index = 0, empty_slot_count - 1 do
                local candidate = inject_get_collection_item(empty_slots, slot_index)
                if candidate ~= nil then
                    local add_result = inject_safe_call(function()
                        return add_method:call(inject_get_managed(cs_inventory), item, 0, candidate, 0)
                    end)
                    local added = tonumber(inject_safe_call(function()
                        local result_managed = inject_get_managed(add_result)
                        return result_managed ~= nil and result_managed:get_field("AddCount") or nil
                    end))
                    if type(added) == "number" and added > 0 then
                        if absorbed > 0 then
                            record_local_injection_suppression(normalized_item_id, remaining)
                        end
                        local row, column = inject_get_slot_row_column(candidate)
                        return string.format(
                            "%s added %d x%d at slot (%s,%s)%s",
                            route_label,
                            normalized_item_id,
                            remaining,
                            tostring(row or "?"),
                            tostring(column or "?"),
                            placed_suffix
                        )
                    end
                end
            end
            log.info(string.format(
                "[RE4R AP] %s: add() refused every empty slot, falling back to forceSetItem",
                route_label))
        end

        local first_slot = inject_get_collection_item(empty_slots, 0)
        local row, column = inject_get_slot_row_column(first_slot)
        if first_slot == nil then
            return string.format("%s inject failed: first empty slot unavailable", route_label)
        end

        local force_set_result = inject_safe_call(function()
            return force_set:call(inject_get_managed(cs_inventory), item, 0, first_slot, 0)
        end)

        if force_set_result == false and stack_add ~= nil then
            local stack_add_result = inject_safe_call(function()
                return stack_add:call(inject_get_managed(cs_inventory), item, 0, first_slot)
            end)
            return string.format(
                "%s fallback stackAdd result: %s",
                route_label,
                inject_value_to_string(stack_add_result)
            )
        end

        local force_set_bool = coerce_to_bool(force_set_result)
        if force_set_bool or force_set_result == true or force_set_result ~= nil then
            inject_clear_force_get(cs_inventory, item)
            if absorbed > 0 then
                -- The slot placement commits the REMAINDER, not the full
                -- delivery apclient records; add the exact-count entry.
                record_local_injection_suppression(normalized_item_id, remaining)
            end
            return string.format(
                "%s injected %d x%d into slot (%s,%s)%s",
                route_label,
                normalized_item_id,
                remaining,
                tostring(row or "?"),
                tostring(column or "?"),
                placed_suffix
            )
        end

        local empty_slots_after = inject_safe_call(function()
            return get_empty:call(inject_get_managed(cs_inventory), 0)
        end)
        local empty_slot_count_after = inject_get_collection_count(empty_slots_after)
        if type(empty_slot_count_after) == "number" and empty_slot_count_after < empty_slot_count then
            inject_clear_force_get(cs_inventory, item)
            if absorbed > 0 then
                record_local_injection_suppression(normalized_item_id, remaining)
            end
            return string.format(
                "%s injected %d x%d into slot (%s,%s)%s",
                route_label,
                normalized_item_id,
                remaining,
                tostring(row or "?"),
                tostring(column or "?"),
                placed_suffix
            )
        end

        return string.format(
            "%s inject failed: forceSetItem type=%s value=%s empty_slots=%s->%s",
            route_label,
            inject_get_value_type_name(force_set_result),
            inject_value_to_string(force_set_result),
            tostring(empty_slot_count),
            tostring(empty_slot_count_after)
        )
    end

    local function inject_write_key_inventory(controller_table, item, normalized_item_id, normalized_count, route_label)
        local controller, controller_error = inject_resolve_controller(
            controller_table, 4, 2, 1, 4000, { "chainsaw.KeyItemInventoryController" }, route_label)
        if controller == nil then
            return string.format("%s inject failed: %s", route_label, tostring(controller_error))
        end

        local controller_type = inject_get_value_type(controller)
        local controller_managed = inject_get_managed(controller)
        local pickup_method = inject_find_method(controller_type, "pickupItem", 1)
        if pickup_method == nil then
            return string.format("%s inject failed: KeyItemInventoryController pickupItem missing", route_label)
        end

        local ok, pickup_result = pcall(function()
            return pickup_method:call(controller_managed, item)
        end)
        if not ok then
            return string.format("%s inject failed: pickupItem err=%s", route_label, tostring(pickup_result))
        end

        if coerce_to_bool(pickup_result) or pickup_result == true then
            return string.format(
                "%s picked up %d x%d via controller",
                route_label,
                normalized_item_id,
                normalized_count
            )
        end

        return string.format(
            "%s inject failed: pickupItem type=%s value=%s",
            route_label,
            inject_get_value_type_name(pickup_result),
            inject_value_to_string(pickup_result)
        )
    end

    -- The pool's four weapon-with-ammo-count items, mapped to the ammo the
    -- game gives you when the gun is already yours. Kept explicit because the
    -- catalog's `class` column is empty on every weapon and ammo row, and the
    -- engine exposes no weapon-to-ammo lookup to read instead. Any other weapon
    -- stays a weapon: receiving a gun you happen to own is legitimate multiworld
    -- content, and only these four encode an ammo amount.
    local INJECT_WEAPON_AMMO_FALLBACK = {
        [274995456] = 112803200,  -- W-870              -> Shotgun Shells
        [274838656] = 112800000,  -- Red9               -> Handgun Ammo
        [275478656] = 112804800,  -- CQBR Assault Rifle -> Rifle Ammo
        [275158656] = 112806400,  -- LE 5               -> Submachine Gun Ammo
    }

    -- Membership test over the attache grid. inject_collect_partial_stacks only
    -- reports stacks with room left, and a weapon is a full "stack", so
    -- ownership needs its own walk.
    local function inject_case_holds_item(cs_inventory, normalized_item_id)
        local managed = inject_get_managed(cs_inventory)
        if managed == nil then
            return false
        end
        local items_list = inject_safe_call(function()
            return managed:get_field("_InventoryItems")
        end)
        local total = inject_get_collection_count(items_list)
        if type(total) ~= "number" then
            return false
        end
        for index = 0, math.min(total, 200) - 1 do
            local wrapper_managed = inject_get_managed(inject_get_collection_item(items_list, index))
            if wrapper_managed ~= nil then
                local wrapped_managed = inject_get_managed(inject_safe_call(function()
                    return wrapper_managed:get_field("<Item>k__BackingField")
                end))
                if wrapped_managed ~= nil then
                    local wrapped_id = tonumber(inject_safe_call(function()
                        return wrapped_managed:get_field("_ItemId")
                    end))
                    if wrapped_id == normalized_item_id then
                        return true
                    end
                end
            end
        end
        return false
    end

    -- Owned = in Storage OR in the attache case. Storage matters most: injected
    -- weapons land there, so a second copy there is exactly what merges.
    local function inject_player_owns_item(normalized_item_id)
        local armoury_manager = sdk.get_managed_singleton("chainsaw.ArmouryManager")
        if armoury_manager ~= nil then
            armoury_manager = inject_try_add_ref(armoury_manager)
            local stored = inject_safe_call(function()
                return inject_get_managed(armoury_manager):call("existsItem", normalized_item_id)
            end)
            if stored == true then
                return true
            end
        end

        local inventory_manager = sdk.get_managed_singleton("chainsaw.InventoryManager")
        if inventory_manager == nil then
            return false
        end
        inventory_manager = inject_try_add_ref(inventory_manager)
        local controller_table = inject_safe_call(function()
            return inject_get_managed(inventory_manager):get_field("_ControllerTable")
        end)
        if controller_table == nil then
            return false
        end
        local controller = inject_find_controller_by_type(
            controller_table, { "chainsaw.CsInventoryController" })
        if controller == nil then
            return false
        end
        local cs_inventory = inject_safe_call(function()
            return inject_get_managed(controller):get_field("<_CsInventory>k__BackingField")
        end)
        if cs_inventory == nil then
            return false
        end
        return inject_case_holds_item(cs_inventory, normalized_item_id)
    end

    -- Convert only when the placement carries an ammo count AND the gun is
    -- already the player's. Fail-closed: any error reading ownership leaves the
    -- delivery exactly as it was before this fix existed.
    local function inject_weapon_ammo_conversion_applies(normalized_item_id, normalized_count)
        if INJECT_WEAPON_AMMO_FALLBACK[normalized_item_id] == nil or normalized_count <= 1 then
            return false
        end
        local ok, owned = pcall(inject_player_owns_item, normalized_item_id)
        return ok and owned == true
    end

    inject_item_to_inventory = function(item_id, count)
        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        local normalized_count = math.max(1, math.floor(tonumber(count) or 0))
        if normalized_item_id <= 0 then
            return "Inject failed: invalid item id"
        end

        -- [Owned weapon -> ammo] Four pool items are a WEAPON carrying an ammo
        -- count ("W-870 x5", "Red9 x5", "CQBR Assault Rifle x20", "LE 5 x60"):
        -- the count is what the game hands you when you already own that gun.
        -- Delivering the weapon itself to a player who owns one is destructive,
        -- not merely redundant - storage MERGES duplicate weapons and the
        -- merged result keeps the un-upgraded state, silently wiping the
        -- upgrades on the copy the player was carrying (live 2026-08-06).
        if inject_weapon_ammo_conversion_applies(normalized_item_id, normalized_count) then
            local ammo_item_id = INJECT_WEAPON_AMMO_FALLBACK[normalized_item_id]
            log.info(string.format(
                "[RE4R AP] weapon %d already owned; delivering %d of its ammo (%d) instead",
                normalized_item_id, normalized_count, ammo_item_id))
            normalized_item_id = ammo_item_id
        end

        local item_kind = inject_get_item_kind(normalized_item_id)
        local route_label = inject_get_route_label(item_kind, normalized_item_id)

        local inventory_manager = sdk.get_managed_singleton("chainsaw.InventoryManager")
        if inventory_manager ~= nil then
            inventory_manager = inject_try_add_ref(inventory_manager)
        end
        if inventory_manager == nil then
            return "Inject failed: InventoryManager singleton missing"
        end

        if inject_is_currency_item(normalized_item_id) then
            return inject_write_currency(inventory_manager, normalized_item_id, normalized_count, route_label)
        end

        local manager_managed = inject_get_managed(inventory_manager)
        local controller_table = inject_safe_call(function()
            return manager_managed:get_field("_ControllerTable")
        end)
        if controller_table == nil then
            return "Inject failed: _ControllerTable unavailable"
        end

        local generated_count = normalized_count
        if inject_is_weapon_item_kind(item_kind)
            or inject_is_key_item_kind(item_kind)
            or inject_is_unique_item_kind(item_kind)
            or inject_is_treasure_kind(item_kind, normalized_item_id) then
            generated_count = 1
        end

        local item, create_error = inject_generate_item(normalized_item_id, generated_count)
        if item == nil then
            return string.format("Inject failed: %s", tostring(create_error or "item creation failed"))
        end

        if inject_is_weapon_item_kind(item_kind) then
            return inject_write_storage(item, normalized_item_id, 1, route_label, nil)
        end

        if inject_is_key_item_kind(item_kind) then
            return inject_write_key_inventory(controller_table, item, normalized_item_id, 1, route_label)
        end

        if inject_is_unique_item_kind(item_kind) then
            return inject_write_unique_inventory(normalized_item_id, 1, item, route_label)
        end

        if inject_is_treasure_kind(item_kind, normalized_item_id) then
            return inject_write_treasure_inventory(normalized_item_id, 1, item, route_label)
        end

        if inject_is_token_kind(item_kind) then
            return inject_write_key_inventory(
                controller_table,
                item,
                normalized_item_id,
                normalized_count,
                route_label
            )
        end

        return inject_write_main_inventory(controller_table, item, normalized_item_id, normalized_count, route_label)
    end

    -- [A3] The merchant's sell flow classifies each sellable row by source
    -- inventory (chainsaw.gui.shop.SellerType) and removes sold items from
    -- that source. Storage (the Armoury) holds only weapon-class items in
    -- vanilla, so the sale's removal never learned to take a Main-Inventory
    -- class item OUT of it - and AP overflow parks exactly those items there
    -- (inject_write_storage). Live 2026-08: selling such an item from
    -- Storage pays out and leaves the item in place, repeatably. Infinite
    -- money. The money is granted deep inside the game's own transaction,
    -- so the fix is a reconciler around the transaction instead: snapshot
    -- case+storage counts for foreign-class storage residents when the sell
    -- confirm starts, capture what the transaction reports sold
    -- (InGameShopManager.notifySellItems), and afterwards take from Storage
    -- exactly the sold count the game's own removal did not take. It only
    -- ever acts on shortfalls, only on item ids whose designed route is not
    -- Storage (vanilla cannot put those there), and caps at what Storage
    -- still holds - so every vanilla-reachable sale is untouched by
    -- construction.
    local sale_reconciler = {
        armed = false,
        snapshot = {},   -- item_id -> { storage = n, case = n }
        sold = {},       -- item_id -> count the transaction reported sold
    }

    local function inject_resolve_case_inventory()
        local inventory_manager = sdk.get_managed_singleton("chainsaw.InventoryManager")
        if inventory_manager == nil then
            return nil
        end
        inventory_manager = inject_try_add_ref(inventory_manager)
        local controller_table = inject_safe_call(function()
            return inject_get_managed(inventory_manager):get_field("_ControllerTable")
        end)
        if controller_table == nil then
            return nil
        end
        local controller = inject_find_controller_by_type(
            controller_table, { "chainsaw.CsInventoryController" })
        if controller == nil then
            return nil
        end
        return inject_safe_call(function()
            return inject_get_managed(controller):get_field("<_CsInventory>k__BackingField")
        end)
    end

    -- Case copies of the given ids, counted by stack size, in one walk.
    -- Ids absent from the case count as zero.
    local function inject_count_case_items(id_set)
        local counts = {}
        for id in pairs(id_set) do
            counts[id] = 0
        end
        local cs_inventory = inject_resolve_case_inventory()
        if cs_inventory == nil then
            return counts
        end
        local managed = inject_get_managed(cs_inventory)
        if managed == nil then
            return counts
        end
        local items_list = inject_safe_call(function()
            return managed:get_field("_InventoryItems")
        end)
        local total = inject_get_collection_count(items_list)
        if type(total) ~= "number" then
            return counts
        end
        for index = 0, math.min(total, 200) - 1 do
            local wrapper_managed = inject_get_managed(inject_get_collection_item(items_list, index))
            if wrapper_managed ~= nil then
                local wrapped_managed = inject_get_managed(inject_safe_call(function()
                    return wrapper_managed:get_field("<Item>k__BackingField")
                end))
                if wrapped_managed ~= nil then
                    local wrapped_id = tonumber(inject_safe_call(function()
                        return wrapped_managed:get_field("_ItemId")
                    end))
                    if wrapped_id ~= nil and counts[math.floor(wrapped_id)] ~= nil then
                        local stack = tonumber(inject_safe_call(function()
                            return wrapped_managed:get_field("_CurrentItemCount")
                        end)) or 1
                        wrapped_id = math.floor(wrapped_id)
                        counts[wrapped_id] = counts[wrapped_id] + math.max(1, math.floor(stack))
                    end
                end
            end
        end
        return counts
    end

    -- [Stand-in diagnosis 2026-08-17] The merchant's case sweep calls
    -- reduce() straight on the resolved CsInventory and gets nil back every
    -- time, while the walk above reads the same case without trouble. The
    -- difference is the inject_get_managed wrap, so the merchant gets the
    -- proven accessors rather than keeping its own second idea of how this
    -- object works.
    --
    -- Returns an array of { id, count } and no error, or nil plus a reason.
    local function inject_debug_walk_case_items(limit)
        local cs_inventory = inject_resolve_case_inventory()
        if cs_inventory == nil then
            return nil, "case inventory unavailable"
        end
        local managed = inject_get_managed(cs_inventory)
        if managed == nil then
            return nil, "case inventory did not wrap to a managed object"
        end
        local items_list = inject_safe_call(function()
            return managed:get_field("_InventoryItems")
        end)
        local total = inject_get_collection_count(items_list)
        if type(total) ~= "number" then
            return nil, "inventory list count unavailable"
        end
        local found = {}
        for index = 0, math.min(total, limit or 200) - 1 do
            local wrapper_managed = inject_get_managed(inject_get_collection_item(items_list, index))
            if wrapper_managed ~= nil then
                local wrapped_managed = inject_get_managed(inject_safe_call(function()
                    return wrapper_managed:get_field("<Item>k__BackingField")
                end))
                if wrapped_managed ~= nil then
                    local id = tonumber(inject_safe_call(function()
                        return wrapped_managed:get_field("_ItemId")
                    end))
                    if id ~= nil then
                        local stack = tonumber(inject_safe_call(function()
                            return wrapped_managed:get_field("_CurrentItemCount")
                        end)) or 1
                        found[#found + 1] = {
                            id = math.floor(id),
                            count = math.max(1, math.floor(stack)),
                        }
                    end
                end
            end
        end
        return found
    end

    -- Ask the LIVE object what it can actually do. The il2cpp dump advertised
    -- get_U/get_V on via.gui.Texture that the real instance did not have, and
    -- that cost two rounds, so removal methods get read off the instance.
    -- Every accessor is tried by name and the failures are reported rather
    -- than swallowed, because a wrong method name here would otherwise look
    -- exactly like "this object has no methods".
    local function inject_debug_case_methods(name_filter)
        local cs_inventory = inject_resolve_case_inventory()
        if cs_inventory == nil then
            return nil, "case inventory unavailable"
        end
        local managed = inject_get_managed(cs_inventory)
        if managed == nil then
            return nil, "case inventory did not wrap to a managed object"
        end
        local type_def = inject_safe_call(function()
            return managed:get_type_definition()
        end)
        if type_def == nil then
            return nil, "get_type_definition returned nothing"
        end
        local methods = inject_safe_call(function()
            return type_def:get_methods()
        end)
        if methods == nil then
            return nil, "get_methods returned nothing"
        end
        local described = {}
        for _, method in ipairs(methods) do
            local name = inject_safe_call(function() return method:get_name() end)
            if type(name) == "string"
                and (name_filter == nil or name:lower():find(name_filter, 1, true) ~= nil) then
                -- get_num_params, NOT get_params: the wrong one fails silently.
                local param_count = tonumber(inject_safe_call(function()
                    return method:get_num_params()
                end))
                local returns = inject_safe_call(function()
                    local rt = method:get_return_type()
                    return rt ~= nil and rt:get_full_name() or nil
                end)
                described[#described + 1] = string.format(
                    "%s(%s params) -> %s",
                    name,
                    param_count ~= nil and tostring(param_count) or "?",
                    tostring(returns or "?"))
            end
        end
        table.sort(described)
        return described
    end

    -- [Stand-in removal 2026-08-17] reduce(chainsaw.ItemID, Int32, Boolean)
    -- resolves to nothing and hands back nil. Reflecting the live object shows
    -- three reduce overloads, and the arity that matches ours takes different
    -- param types, so the signature never binds. remove() is the better door:
    -- two single-argument Boolean overloads, and the walk already produces the
    -- Item object, which is how reduceArmouryItem is called elsewhere here.
    --
    -- Both a wrapped Item and an instance guid are tried, because the treasure
    -- controller's own remove() takes a guid and the two 1-param overloads are
    -- probably one of each. Success is proven by COUNTING the case before and
    -- after, never by a return value. Returns removed_count, reason.
    local function inject_remove_case_item(item_id)
        item_id = math.floor(tonumber(item_id) or 0)
        local cs_inventory = inject_resolve_case_inventory()
        if cs_inventory == nil then
            return 0, "case inventory unavailable"
        end
        local managed = inject_get_managed(cs_inventory)
        if managed == nil then
            return 0, "case inventory did not wrap to a managed object"
        end

        -- Returns how many copies are present, plus a handle and a guid for
        -- the first one. Re-walked after every attempt so the count is live.
        local function survey()
            local items_list = inject_safe_call(function()
                return managed:get_field("_InventoryItems")
            end)
            local total = inject_get_collection_count(items_list)
            if type(total) ~= "number" then
                return nil, nil, nil
            end
            local seen, handle, guid = 0, nil, nil
            for index = 0, math.min(total, 200) - 1 do
                local wrapper = inject_get_managed(inject_get_collection_item(items_list, index))
                if wrapper ~= nil then
                    local raw_item = inject_safe_call(function()
                        return wrapper:get_field("<Item>k__BackingField")
                    end)
                    local inner = inject_get_managed(raw_item)
                    if inner ~= nil then
                        local id = tonumber(inject_safe_call(function()
                            return inner:get_field("_ItemId")
                        end))
                        if id ~= nil and math.floor(id) == item_id then
                            seen = seen + 1
                            if handle == nil then
                                handle = raw_item
                                for _, field in ipairs({ "_Id", "_ID", "_Guid", "_InventoryItemId" }) do
                                    if guid == nil then
                                        guid = inject_safe_call(function()
                                            return inner:get_field(field)
                                        end)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            return seen, handle, guid
        end

        local before, handle, guid = survey()
        if before == nil then
            return 0, "inventory list unreadable"
        end
        if before == 0 then
            return 0, "not in the case"
        end

        local attempts = {}
        if handle ~= nil then
            attempts[#attempts + 1] = { "remove(item)", function()
                return managed:call("remove", handle)
            end }
            attempts[#attempts + 1] = { "remove(chainsaw.Item)", function()
                return managed:call("remove(chainsaw.Item)", handle)
            end }
        end
        if guid ~= nil then
            attempts[#attempts + 1] = { "remove(guid)", function()
                return managed:call("remove", guid)
            end }
        end
        if #attempts == 0 then
            return 0, "present but neither a handle nor a guid could be read"
        end

        for _, attempt in ipairs(attempts) do
            inject_safe_call(attempt[2])
            local after = survey()
            if type(after) == "number" and after < before then
                return before - after, nil
            end
        end

        local final = survey()
        return 0, string.format(
            "tried %d removal form(s), count still %s (was %d)",
            #attempts, tostring(final), before)
    end

    local function inject_resolve_armoury_manager()
        local armoury_manager = sdk.get_managed_singleton("chainsaw.ArmouryManager")
        if armoury_manager == nil then
            return nil
        end
        return inject_get_managed(inject_try_add_ref(armoury_manager))
    end

    local function inject_get_storage_item_count(armoury_managed, item_id)
        local count = inject_safe_call(function()
            return armoury_managed:call("getItemCountSum", item_id)
        end)
        return math.max(0, math.floor(tonumber(count) or 0))
    end

    -- Storage residents whose designed route is NOT Storage: only AP overflow
    -- puts those there, so they are the only ids the reconciler may touch.
    local function inject_collect_foreign_storage_ids(armoury_managed)
        local ids = {}
        local list = inject_safe_call(function()
            return armoury_managed:call("getArmouryItemList")
        end)
        local total = inject_get_collection_count(list)
        if type(total) ~= "number" then
            return ids
        end
        for index = 0, math.min(total, 400) - 1 do
            local entry = inject_get_managed(inject_get_collection_item(list, index))
            if entry ~= nil then
                local inner = inject_get_managed(inject_safe_call(function()
                    return entry:get_field("_Item")
                end))
                if inner ~= nil then
                    local item_id = tonumber(inject_safe_call(function()
                        return inner:get_field("_ItemId")
                    end))
                    if item_id ~= nil and item_id > 0 then
                        item_id = math.floor(item_id)
                        local kind = inject_get_item_kind(item_id)
                        if inject_get_route_label(kind, item_id) ~= "Storage" then
                            ids[item_id] = true
                        end
                    end
                end
            end
        end
        return ids
    end

    -- Take up to `wanted` of item_id out of Storage through the game's own
    -- reduceArmouryItem, feeding it the stored Item instances. Progress is
    -- measured by the authoritative count so stack semantics cannot loop us;
    -- bounded passes, stop on any pass that makes no progress.
    local function inject_reduce_storage_item(armoury_managed, item_id, wanted)
        local removed_total = 0
        for _ = 1, 8 do
            if removed_total >= wanted then
                break
            end
            local before = inject_get_storage_item_count(armoury_managed, item_id)
            if before <= 0 then
                break
            end
            local target_inner = nil
            local target_stack = 1
            local list = inject_safe_call(function()
                return armoury_managed:call("getArmouryItemList")
            end)
            local total = inject_get_collection_count(list)
            if type(total) ~= "number" then
                break
            end
            for index = 0, math.min(total, 400) - 1 do
                local entry = inject_get_managed(inject_get_collection_item(list, index))
                if entry ~= nil then
                    local inner = inject_get_managed(inject_safe_call(function()
                        return entry:get_field("_Item")
                    end))
                    if inner ~= nil then
                        local entry_id = tonumber(inject_safe_call(function()
                            return inner:get_field("_ItemId")
                        end))
                        if entry_id ~= nil and math.floor(entry_id) == item_id then
                            target_inner = inner
                            target_stack = math.max(1, math.floor(tonumber(inject_safe_call(function()
                                return inner:get_field("_CurrentItemCount")
                            end)) or 1))
                            break
                        end
                    end
                end
            end
            if target_inner == nil then
                break
            end
            local take = math.min(wanted - removed_total, target_stack, before)
            local ok = pcall(function()
                armoury_managed:call("reduceArmouryItem", target_inner, take)
            end)
            if not ok then
                break
            end
            local after = inject_get_storage_item_count(armoury_managed, item_id)
            if after >= before then
                break
            end
            removed_total = removed_total + (before - after)
        end
        return removed_total
    end

    local function sale_reconciler_arm()
        sale_reconciler.armed = false
        sale_reconciler.snapshot = {}
        sale_reconciler.sold = {}
        local armoury_managed = inject_resolve_armoury_manager()
        if armoury_managed == nil then
            return
        end
        local foreign_ids = inject_collect_foreign_storage_ids(armoury_managed)
        if next(foreign_ids) ~= nil then
            local case_counts = inject_count_case_items(foreign_ids)
            for id in pairs(foreign_ids) do
                sale_reconciler.snapshot[id] = {
                    storage = inject_get_storage_item_count(armoury_managed, id),
                    case = case_counts[id] or 0,
                }
            end
        end
        -- Armed with an empty snapshot is fine: the settle pass no-ops.
        sale_reconciler.armed = true
    end

    local function sale_reconciler_capture(sell_list)
        if not sale_reconciler.armed then
            -- A confirm path we did not wrap reached the transaction. Stand
            -- down (guessing mid-transaction risks over-removal) but say so
            -- loudly - this log line is how we learn the path exists.
            log.info("[RE4R AP] storage-sale: transaction with no armed snapshot; reconciler stands down for this sale")
            return
        end
        local total = inject_get_collection_count(sell_list)
        if type(total) ~= "number" then
            return
        end
        for index = 0, total - 1 do
            local entry = inject_get_managed(inject_get_collection_item(sell_list, index))
            if entry ~= nil then
                local inner = inject_get_managed(inject_safe_call(function()
                    return entry:get_field("SellItem")
                end))
                local sold_count = tonumber(inject_safe_call(function()
                    return entry:get_field("SellCount")
                end)) or 0
                local item_id = nil
                if inner ~= nil then
                    item_id = tonumber(inject_safe_call(function()
                        return inner:get_field("_ItemId")
                    end))
                end
                if item_id ~= nil and item_id > 0 and sold_count > 0 then
                    item_id = math.floor(item_id)
                    sale_reconciler.sold[item_id] =
                        (sale_reconciler.sold[item_id] or 0) + math.floor(sold_count)
                end
            end
        end
    end

    local function sale_reconciler_settle()
        if not sale_reconciler.armed then
            return
        end
        sale_reconciler.armed = false
        local sold = sale_reconciler.sold
        local snapshot = sale_reconciler.snapshot
        sale_reconciler.sold = {}
        sale_reconciler.snapshot = {}
        if next(sold) == nil or next(snapshot) == nil then
            return
        end
        local armoury_managed = inject_resolve_armoury_manager()
        if armoury_managed == nil then
            return
        end
        local case_ids = {}
        for id in pairs(snapshot) do
            case_ids[id] = true
        end
        local case_now = inject_count_case_items(case_ids)
        for id, sold_count in pairs(sold) do
            local snap = snapshot[id]
            if snap ~= nil then
                local storage_now = inject_get_storage_item_count(armoury_managed, id)
                local removed = (snap.storage - storage_now) + (snap.case - (case_now[id] or 0))
                local shortfall = sold_count - removed
                if shortfall > 0 then
                    local can_take = math.min(shortfall, storage_now)
                    if can_take > 0 then
                        local took = inject_reduce_storage_item(armoury_managed, id, can_take)
                        log.info(string.format(
                            "[RE4R AP] storage-sale reconciled: item %d sold x%d, game removed %d, took %d from Storage (%d -> %d)",
                            id, sold_count, removed, took, storage_now,
                            inject_get_storage_item_count(armoury_managed, id)))
                    else
                        log.info(string.format(
                            "[RE4R AP] storage-sale shortfall for item %d (sold %d, game removed %d) but Storage holds none",
                            id, sold_count, removed))
                    end
                end
            end
        end
    end

    local function install_storage_sale_reconciler_hook()
        local state_type = sdk.find_type_definition("chainsaw.gui.shop.InGameShopGuiState_SellDefault")
        local shop_manager_type = sdk.find_type_definition("chainsaw.InGameShopManager")
        if state_type == nil or shop_manager_type == nil then
            log.info("[RE4R AP] shop sell types not found -- storage-sale reconciler disabled")
            return
        end
        local gauge_method = state_type:get_method("onHoldGaugeCompleted")
        local notify_method = shop_manager_type:get_method("notifySellItems")
        if gauge_method == nil or notify_method == nil then
            log.info("[RE4R AP] shop sell methods not found -- storage-sale reconciler disabled")
            return
        end
        sdk.hook(
            gauge_method,
            function(args)
                local ok, err = pcall(sale_reconciler_arm)
                if not ok then
                    log.info("[RE4R AP] storage-sale arm error: " .. tostring(err))
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                local ok, err = pcall(sale_reconciler_settle)
                if not ok then
                    log.info("[RE4R AP] storage-sale settle error: " .. tostring(err))
                end
                return retval
            end
        )
        sdk.hook(
            notify_method,
            function(args)
                local ok, err = pcall(function()
                    sale_reconciler_capture(sdk.to_managed_object(args[4]))
                end)
                if not ok then
                    log.info("[RE4R AP] storage-sale capture error: " .. tostring(err))
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                return retval
            end
        )
        log.info("[RE4R AP] storage-sale reconciler installed (sell shortfalls leave Storage)")
    end

    -- [Scatter interlock, 2026-08-16] The Deluxe entitlement grant drops DLC
    -- weapons (Sentinel Nine, Skull Shaker) straight into Storage through
    -- chainsaw.ArmouryManager.addExtraItem. While the merchant's gear is
    -- scattered those guns are multiworld pool items, so the grant is vetoed
    -- for exactly the scattered engine ids; every other extra item
    -- (costumes, charms, non-scattered rooms) flows untouched. If the guns
    -- still appear in Storage on a Deluxe profile, they arrive by a path
    -- this hook never saw - the absence of the veto line in the log says so.
    local function install_extra_item_veto_hook()
        local armoury_type = sdk.find_type_definition("chainsaw.ArmouryManager")
        if armoury_type == nil then
            log.info("[RE4R AP] ArmouryManager type not found -- extra-item veto disabled")
            return
        end
        local add_method = armoury_type:get_method("addExtraItem")
        if add_method == nil then
            log.info("[RE4R AP] ArmouryManager.addExtraItem not found -- extra-item veto disabled")
            return
        end
        sdk.hook(
            add_method,
            function(args)
                local bridge = ctx.bridge
                if bridge == nil or bridge.gear_scattered ~= true then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end
                local scattered = bridge.scattered_item_ids
                if type(scattered) ~= "table" then
                    return sdk.PreHookResult.CALL_ORIGINAL
                end
                local item_id = nil
                pcall(function()
                    item_id = tonumber(sdk.to_int64(args[3]))
                end)
                if item_id ~= nil and scattered[item_id] then
                    log.info(string.format(
                        "[RE4R AP] entitlement grant vetoed: item %d is a multiworld item in this room",
                        item_id))
                    return sdk.PreHookResult.SKIP_ORIGINAL
                end
                return sdk.PreHookResult.CALL_ORIGINAL
            end,
            function(retval)
                return retval
            end
        )
        log.info("[RE4R AP] extra-item grant veto installed (scattered gear stays in the multiworld)")
    end

    -- [D5] Bonus weapons. RE4R validates Extra Content Shop purchases when a
    -- save loads and DELETES un-bought bonus weapons from the inventory -
    -- which is what "bonus weapons disappear after death or reload" was. In
    -- allow-bonus-items rooms the merchant can stock them, so Cam's call
    -- (playtest round 2): force the persistent unlock instead of warning
    -- players away. Per-item on purpose - only the four weapons the BioRand
    -- option can stock are touched, never enableAllBonus, so the rest of the
    -- player's Extra Content stays exactly as they earned it. The recipe per
    -- weapon: ItemID -> ExShopBonusID (getItemIdToBonus), then mark it
    -- unlocked AND bought (the reload validation checks bought), then ask
    -- share.SaveDataManager for a system save so the records persist even if
    -- the player never touches a typewriter. Idempotent: already-bought
    -- weapons are skipped, so this can run on every connect.
    -- Exactly the weapons the game's ExShop conversion table knows
    -- (exshopidconvertuserdata.user.2 carries three weapon entries: bonus 6/7/8
    -- for these ids; verified against every DLC convert file too). The
    -- Infinite Rocket Launcher is deliberately ABSENT: it has no ExShop entry
    -- anywhere - it is a normal merchant purchase, not an Extra Content
    -- unlock - so its lookup returns -1 on every install and there is nothing
    -- to unlock (live 2026-08-15, twelve in-game retries all -1).
    local BONUS_WEAPON_ITEM_IDS = {
        { id = 276445056, name = "Primal Knife" },
        { id = 275157056, name = "Chicago Sweeper" },
        { id = 275638656, name = "Handcannon" },
    }

    local function inject_ensure_bonus_weapons_unlocked()
        local record_manager = sdk.get_managed_singleton("chainsaw.GameRecordManager")
        if record_manager == nil then
            return false, "GameRecordManager singleton missing"
        end
        record_manager = inject_try_add_ref(record_manager)

        local ok_cat, category_weapon = pcall(function()
            return sdk.find_type_definition("chainsaw.ExShopCategory"):get_field("Weapon"):get_data(nil)
        end)
        if not ok_cat or category_weapon == nil then
            return false, "ExShopCategory.Weapon unresolved"
        end

        -- [Scatter interlock, 2026-08-16] While the merchant's gear is
        -- scattered, the Extra Content GUNS are multiworld pool items and the
        -- free unlock would undercut them; only the Primal Knife (a knife,
        -- never scattered) keeps its unlock. Cam: "we want weapons to be
        -- gotten via the multiworld."
        local gear_scattered = ctx.bridge ~= nil and ctx.bridge.gear_scattered == true
        local weapons_to_unlock = BONUS_WEAPON_ITEM_IDS
        if gear_scattered then
            weapons_to_unlock = {}
            for _, weapon in ipairs(BONUS_WEAPON_ITEM_IDS) do
                if weapon.name == "Primal Knife" then
                    weapons_to_unlock[#weapons_to_unlock + 1] = weapon
                else
                    log.info(string.format(
                        "[RE4R AP] bonus unlock suppressed for %s - it is a multiworld item in this room",
                        weapon.name))
                end
            end
        end

        local unlocked = 0
        local unresolved = 0
        local unresolved_names = {}
        for _, weapon in ipairs(weapons_to_unlock) do
            local ok, err = pcall(function()
                local manager = inject_get_managed(record_manager)
                local bonus_id = manager:call("getItemIdToBonus", weapon.id)
                -- -1 is the not-found sentinel. At boot the ExShop records
                -- are not loaded yet and every lookup misses; the old guard
                -- only rejected non-numbers, so all four unlocks wrote to -1
                -- and did nothing (live 2026-08-14). A miss is counted so
                -- the caller can retry once the game is actually loaded.
                if type(bonus_id) ~= "number" or bonus_id < 0 then
                    unresolved = unresolved + 1
                    unresolved_names[#unresolved_names + 1] = weapon.name
                    return
                end
                if manager:call("checkBuyBonus", bonus_id) ~= true then
                    manager:call("setUnlockBonus", bonus_id)
                    manager:call("setBuyBonus", bonus_id, category_weapon)
                    unlocked = unlocked + 1
                    log.info(string.format(
                        "[RE4R AP] force-unlocked bonus weapon: %s (bonus id %s)",
                        weapon.name, tostring(bonus_id)))
                end
            end)
            if not ok then
                log.info(string.format(
                    "[RE4R AP] bonus-weapon unlock failed for %s: %s",
                    weapon.name, tostring(err)))
            end
        end

        if unlocked > 0 then
            -- share.SaveDataManager has no requestSystemSave: that name belongs
            -- to a boot-flow class. The real entry point is
            -- requestSaveSystemData(AppSaveSlot, SystemSaveRequestArgs), which
            -- needs both arguments built properly, so this asks through the
            -- verified helper and reports honestly when it cannot. The unlocks
            -- themselves are already applied in memory either way; what is at
            -- risk is only whether they survive without a normal save.
            local save_manager = sdk.get_managed_singleton("share.SaveDataManager")
            local ok_save, save_detail = inject_call_verified(save_manager, "requestSystemSave")
            if ok_save then
                log.info(string.format(
                    "[RE4R AP] %d bonus weapon(s) force-unlocked; system save requested",
                    unlocked))
            else
                log.warn(string.format(
                    "[RE4R AP] %d bonus weapon(s) force-unlocked but NOT persisted: %s"
                    .. " - they hold until the next normal save",
                    unlocked, tostring(save_detail)))
            end
        end

        if unresolved > 0 then
            -- Named so a single stubborn miss identifies itself: a weapon
            -- still -1 IN-GAME is a wrong item id for its ExShop mapping,
            -- not load timing (live 2026-08-15, one of the four).
            log.info(string.format(
                "[RE4R AP] %d bonus weapon id(s) unresolved (%s); retry pending",
                unresolved, table.concat(unresolved_names, ", ")))
        end

        return true, unlocked, unresolved
    end

    injection.items = injectable_items
    injection.item_names = injectable_item_names
    injection.item_kind_by_id = injectable_item_kind_by_id
    injection.item_class_by_id = injectable_item_class_by_id
    injection.item_stack_by_id = injectable_item_stack_by_id
    injection.ammo_item_id_by_class = injectable_ammo_item_id_by_class
    injection.category_counts = injectable_category_counts
    injection.category_names = injectable_category_names

    ctx.injectable_items = injectable_items
    _G.injectable_items = injectable_items
    ctx.injectable_category_names = injectable_category_names
    _G.injectable_category_names = injectable_category_names

    export("get_injectable_display_category", get_injectable_display_category)
    export("load_injectable_items", load_injectable_items)
    export("prune_local_injection_suppressions", prune_local_injection_suppressions)
    export("record_local_injection_suppression", record_local_injection_suppression)
    export("consume_local_injection_suppression", consume_local_injection_suppression)
    export("select_known_injectable_item", select_known_injectable_item)
    export("find_known_injectable_item_index", find_known_injectable_item_index)
    export("inject_record_recent_item", inject_record_recent_item)
    export("get_injectable_label_for_item_id", get_injectable_label_for_item_id)
    export("inject_status_succeeded", inject_status_succeeded)
    export("build_filtered_injectable_view", build_filtered_injectable_view)
    export("inject_command_succeeded", inject_command_succeeded)
    export("inject_item_to_inventory", inject_item_to_inventory)
    export("inject_resolve_case_inventory", inject_resolve_case_inventory)
    export("inject_debug_walk_case_items", inject_debug_walk_case_items)
    export("inject_debug_case_methods", inject_debug_case_methods)
    export("inject_remove_case_item", inject_remove_case_item)
    export("inject_call_verified", inject_call_verified)
    export("inject_get_item_kind", inject_get_item_kind)
    export("inject_is_weapon_item_kind", inject_is_weapon_item_kind)
    export("inject_is_ptas_item", inject_is_ptas_item)
    export("inject_is_spinel_item", inject_is_spinel_item)
    export("inject_is_currency_item", inject_is_currency_item)
    export("inject_is_key_item_kind", inject_is_key_item_kind)
    export("inject_is_unique_item_kind", inject_is_unique_item_kind)
    export("inject_is_token_kind", inject_is_token_kind)
    export("inject_is_treasure_kind", inject_is_treasure_kind)
    export("inject_get_route_label", inject_get_route_label)
    export("inject_get_route_destination", inject_get_route_destination)
    export("inject_get_expected_commit_count", inject_get_expected_commit_count)
    export("inject_get_route_hint", inject_get_route_hint)
    export("inject_read_key_item_ids", inject_read_key_item_ids)
    export("inject_ensure_bonus_weapons_unlocked", inject_ensure_bonus_weapons_unlocked)
    export("install_storage_sale_reconciler_hook", install_storage_sale_reconciler_hook)
    export("install_extra_item_veto_hook", install_extra_item_veto_hook)

    -- Reads the campaign lead's key-item ids out of InventoryManager's
    -- per-context save-data table. The live controller unregisters while
    -- another character plays, but this table is what the game itself
    -- restores the lead from afterwards, so it survives boots and saves made
    -- INSIDE the section - the exact case the boot snapshot cannot cover
    -- (live log 2026-08-05, three occurrences of "snapshot is empty (no lead
    -- session this boot)": booting into an Ashley save BK'd her on the Bunch
    -- of Keys / Salazar Insignia doors). Per-SAVE truth by construction: the
    -- table is part of the loaded save, so this cannot repeat the retro-heal
    -- mistake a persisted snapshot would risk. Chain verified against
    -- il2cpp_dump.json: _InventorySaveDataTable is Dictionary<ContextID,
    -- InventorySaveDataBase>; the lead's key inventory ContextID is
    -- (4, 2, 1, 4000); KeyItemInventorySaveData.Items[] entries carry .Item
    -- (chainsaw.Item) whose _ItemId is the engine id.
    local function inject_read_lead_key_items_from_savedata()
        local ids = {}
        local inventory_manager = sdk.get_managed_singleton("chainsaw.InventoryManager")
        if inventory_manager == nil then
            return ids
        end
        inventory_manager = inject_try_add_ref(inventory_manager)
        local manager_managed = inject_get_managed(inventory_manager)
        if manager_managed == nil then
            return ids
        end
        local save_table = inject_safe_call(function()
            return manager_managed:get_field("_InventorySaveDataTable")
        end)
        local key = inject_create_context_id(4, 2, 1, 4000)
        if save_table == nil or key == nil then
            return ids
        end
        local save_data = inject_direct_dictionary_lookup(save_table, key)
        local save_managed = inject_get_managed(save_data)
        if save_managed == nil then
            return ids
        end
        local items = inject_safe_call(function()
            return save_managed:get_field("Items")
        end)
        local total = inject_get_collection_count(items)
        if type(total) ~= "number" then
            return ids
        end
        for index = 0, math.min(total, 64) - 1 do
            local entry_managed = inject_get_managed(inject_get_collection_item(items, index))
            if entry_managed ~= nil then
                local item_value = inject_safe_call(function()
                    return entry_managed:get_field("Item")
                end)
                local item_managed = inject_get_managed(item_value)
                local item_id = item_managed ~= nil and tonumber(inject_safe_call(function()
                    return item_managed:get_field("_ItemId")
                end)) or nil
                if type(item_id) == "number" and item_id > 0 then
                    table.insert(ids, item_id)
                end
            end
        end
        return ids
    end

    -- Snapshot while the lead plays; replay into the next character's key
    -- inventory the moment they take over. Throttled - this reads reflection
    -- and must not run every frame. The boot snapshot stays the fast path;
    -- when it is empty (fresh boot straight into the section) the save-data
    -- reader above supplies the same truth.
    local key_mirror_last_clock = 0.0
    local key_mirror_was_default = true
    local key_mirror_pending = {}
    local key_mirror_attempts = 0
    local key_mirror_delivered = 0
    local key_mirror_gave_up = false
    -- The takeover race the retry loop covers resolves in seconds; this is a
    -- backstop against an item that will NEVER land (a torn-down section, a
    -- route that cannot place it) turning into a forever 2s retry storm.
    local KEY_MIRROR_MAX_ATTEMPTS = 60

    re.on_frame(function()
        local now = os.clock()
        if now - key_mirror_last_clock < 2.0 then
            return
        end
        key_mirror_last_clock = now

        -- Gate on the same playability compound the injection path uses. The
        -- mirror must never run at the title screen, mid-load, or - the crash
        -- that motivated this - during end-of-run teardown, when the key
        -- controllers unregister but this loop kept calling into the
        -- torn-down _ControllerTable every 2s until it faulted (Amondo's
        -- ending crash, 2026-08-11). Victory in = nothing left to mirror and
        -- the world is coming down, so stop outright.
        if bridge ~= nil and (bridge.victory_sent == true or bridge.victory_pending == true) then
            return
        end
        local rs_fn = ctx.get_runtime_state or _G.get_runtime_state
        local rs = (type(rs_fn) == "function") and rs_fn() or nil
        if not (rs ~= nil
            and rs.is_in_game
            and rs.player_present
            and rs.is_playable
            and not rs.is_loading
            and not rs.is_cutscene) then
            return
        end

        local ok, err = pcall(function()
            local default_active = inject_is_default_character_active()

            if default_active then
                local ids = inject_read_key_item_ids()
                if type(ids) == "table" then
                    key_item_snapshot = ids
                    if not key_item_snapshot_logged then
                        key_item_snapshot_logged = true
                        log.info(string.format(
                            "[RE4R AP] key-item mirror: snapshot holds %d key item(s)", #ids))
                    end
                end
                key_mirror_was_default = true
                key_mirror_pending = {}
                key_mirror_attempts = 0
                key_mirror_delivered = 0
                key_mirror_gave_up = false
                return
            end

            -- Non-lead character. Build the pending list once per takeover:
            -- the boot snapshot wins when it exists, and the lead's save-data
            -- table covers a boot straight into the section.
            if key_mirror_was_default then
                key_mirror_was_default = false
                key_mirror_attempts = 0
                key_mirror_delivered = 0
                key_mirror_gave_up = false
                key_mirror_pending = {}
                local source = key_item_snapshot
                local origin = "boot snapshot"
                if #source == 0 then
                    source = inject_read_lead_key_items_from_savedata()
                    origin = "lead save data"
                end
                for _, item_id in ipairs(source) do
                    table.insert(key_mirror_pending, item_id)
                end
                if #key_mirror_pending == 0 then
                    log.info("[RE4R AP] key-item mirror: another character took over and no lead key items were found in the snapshot or the save-data table - nothing to mirror")
                    return
                end
                log.info(string.format(
                    "[RE4R AP] key-item mirror: mirroring %d key item(s) from the %s",
                    #key_mirror_pending, origin))
            end

            -- Retry until everything lands. The takeover can be observed
            -- before the new character's controllers finish registering, and
            -- the old fire-once version lost the whole mirror to that race.
            if #key_mirror_pending > 0 then
                if key_mirror_attempts >= KEY_MIRROR_MAX_ATTEMPTS then
                    -- Give up loudly, once, rather than hammer a controller
                    -- that is never going to accept these. Resets on the next
                    -- takeover (was_default block above).
                    if not key_mirror_gave_up then
                        key_mirror_gave_up = true
                        log.info(string.format(
                            "[RE4R AP] key-item mirror: giving up on %d item(s) after %d attempts",
                            #key_mirror_pending, key_mirror_attempts))
                    end
                    return
                end
                key_mirror_attempts = key_mirror_attempts + 1
                local still_pending = {}
                for _, item_id in ipairs(key_mirror_pending) do
                    local status = inject_item_to_inventory(item_id, 1)
                    if inject_status_succeeded(status) then
                        key_mirror_delivered = key_mirror_delivered + 1
                        log.info(string.format(
                            "[RE4R AP] key-item mirror: %d transferred (%s)",
                            item_id, tostring(status)))
                    else
                        table.insert(still_pending, item_id)
                        if key_mirror_attempts == 1 or key_mirror_attempts % 15 == 0 then
                            log.info(string.format(
                                "[RE4R AP] key-item mirror: %d not transferred yet (attempt %d: %s)",
                                item_id, key_mirror_attempts, tostring(status)))
                        end
                    end
                end
                key_mirror_pending = still_pending
                if #key_mirror_pending == 0 then
                    log.info("[RE4R AP] key-item mirror: complete")
                    -- Say it out loud. Key items appearing in another
                    -- character's inventory with no explanation reads as a bug
                    -- (or as cheating) rather than as the thing that keeps her
                    -- doors openable (Cam, live 2026-08-06).
                    local push = ctx.push_info_toast or _G.push_info_toast
                    if type(push) == "function" and key_mirror_delivered > 0 then
                        push("Key items carried over", string.format(
                            "%d key item%s from the campaign lead came with you",
                            key_mirror_delivered,
                            key_mirror_delivered == 1 and "" or "s"))
                    end
                    key_mirror_delivered = 0
                end
            end
        end)
        if not ok then
            log.info(string.format("[RE4R AP] key-item mirror error: %s", tostring(err)))
        end
    end)
end

return install
