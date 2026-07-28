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
    local INJECT_ATTACHE_CASE_SIZE_BY_ITEM_ID = {
        [119455200] = 1,
        [119456800] = 2,
        [119458400] = 3,
        [119460000] = 4,
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
            if main_inventory_controller ~= nil then
                main_inventory_controller = inject_try_add_ref(main_inventory_controller)
                local current_size = inject_safe_call(function()
                    return main_inventory_controller:call("get_CurrInventorySize()")
                end)
                if current_size == nil then
                    current_size = inject_safe_call(function()
                        return main_inventory_controller:call("get_CurrInventorySize")
                    end)
                end
                local current_size_number = tonumber(current_size)
                if current_size_number == nil or current_size_number < attache_case_size then
                    inject_safe_call(function()
                        return main_inventory_controller:call("changeSize", attache_case_size, false)
                    end)
                    inject_safe_call(function()
                        return main_inventory_controller:call("changeSize(System.Int32, System.Boolean)", attache_case_size, false)
                    end)
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

    local function inject_write_main_inventory(controller_table, item, normalized_item_id, normalized_count, route_label)
        local controller, controller_error = inject_lookup_controller(controller_table, 4, 2, 0, 4000)
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

        local empty_slots = inject_safe_call(function()
            return get_empty:call(inject_get_managed(cs_inventory), 0)
        end)
        local empty_slot_count = inject_get_collection_count(empty_slots)
        if type(empty_slot_count) ~= "number" or empty_slot_count <= 0 then
            return inject_write_storage(item, normalized_item_id, normalized_count, route_label, "attache case full")
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
            return string.format(
                "%s injected %d x%d into slot (%s,%s)",
                route_label,
                normalized_item_id,
                normalized_count,
                tostring(row or "?"),
                tostring(column or "?")
            )
        end

        local empty_slots_after = inject_safe_call(function()
            return get_empty:call(inject_get_managed(cs_inventory), 0)
        end)
        local empty_slot_count_after = inject_get_collection_count(empty_slots_after)
        if type(empty_slot_count_after) == "number" and empty_slot_count_after < empty_slot_count then
            return string.format(
                "%s injected %d x%d into slot (%s,%s)",
                route_label,
                normalized_item_id,
                normalized_count,
                tostring(row or "?"),
                tostring(column or "?")
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
        local controller, controller_error = inject_lookup_controller(controller_table, 4, 2, 1, 4000)
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

    inject_item_to_inventory = function(item_id, count)
        local normalized_item_id = math.floor(tonumber(item_id) or 0)
        local normalized_count = math.max(1, math.floor(tonumber(count) or 0))
        if normalized_item_id <= 0 then
            return "Inject failed: invalid item id"
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
end

return install
