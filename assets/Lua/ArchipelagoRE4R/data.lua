local function install(ctx)
    ctx.data = ctx.data or {}

    local stage_chapter_map = {
        exact = {},
        exact_candidates = {},
        family = {},
        family_candidates = {},
    }
    local stage_location_guid_map = {}
    local stage_location_display_map = {}

    ctx.data.stage_chapter_map = stage_chapter_map
    ctx.data.stage_location_guid_map = stage_location_guid_map
    ctx.data.stage_location_display_map = stage_location_display_map

    local function clear_table(values)
        for key, _ in pairs(values or {}) do
            values[key] = nil
        end
    end

    local function join_numbers(values)
        if type(values) ~= "table" then
            return nil
        end

        local result = {}
        for _, value in ipairs(values) do
            table.insert(result, tostring(value))
        end
        return table.concat(result, "/")
    end

    local function trim_string(value)
        if type(value) ~= "string" then
            return ""
        end

        return value:match("^%s*(.-)%s*$")
    end

    local function sanitize_session_component(value)
        local trimmed = trim_string(value)
        if trimmed == "" then
            return "unknown"
        end

        local sanitized = trimmed:gsub("[^A-Za-z0-9._-]+", "_")
        sanitized = sanitized:gsub("^[._]+", "")
        sanitized = sanitized:gsub("[._]+$", "")
        if sanitized == "" then
            return "unknown"
        end
        return sanitized
    end

    local function normalize_guid(value)
        if type(value) ~= "string" then
            return nil
        end

        local normalized = string.lower(value)
        if normalized == "" then
            return nil
        end
        return normalized
    end

    local function normalize_stage_id(value)
        local numeric_value = tonumber(value)
        if type(numeric_value) ~= "number" then
            return nil
        end
        return math.floor(numeric_value + 0.5)
    end

    local function make_stage_guid_key(stage, guid)
        if type(stage) ~= "number" then
            return nil
        end

        local normalized_guid = normalize_guid(guid)
        if normalized_guid == nil then
            return nil
        end

        return string.format("%s|%s", tostring(stage), normalized_guid)
    end

    local function is_guid_acknowledged(stage, guid)
        local key = make_stage_guid_key(stage, guid)
        return key ~= nil and ctx.bridge.acknowledged_guid_keys[key] == true
    end

    local function rebuild_progression_warning_chapter_maps()
        ctx.bridge.progression_warning_chapter_stage_map = {}
        ctx.bridge.progression_warning_stage_chapter_membership = {}

        for stage_key, stage_entries in pairs(stage_location_display_map or {}) do
            if type(stage_entries) == "table" then
                for _, display_entry in pairs(stage_entries) do
                    local chapter = tonumber(display_entry and display_entry.chapter)
                    if chapter ~= nil then
                        if type(ctx.bridge.progression_warning_chapter_stage_map[chapter]) ~= "table" then
                            ctx.bridge.progression_warning_chapter_stage_map[chapter] = {}
                        end
                        ctx.bridge.progression_warning_chapter_stage_map[chapter][tostring(stage_key)] = true

                        if type(ctx.bridge.progression_warning_stage_chapter_membership[tostring(stage_key)]) ~= "table" then
                            ctx.bridge.progression_warning_stage_chapter_membership[tostring(stage_key)] = {}
                        end
                        ctx.bridge.progression_warning_stage_chapter_membership[tostring(stage_key)][chapter] = true
                    end
                end
            end
        end
    end

    local function load_stage_chapter_map()
        local payload = json.load_file(STAGE_CHAPTER_MAP_FILE)
        if type(payload) ~= "table" then
            return
        end

        stage_chapter_map.exact = payload.exact or {}
        stage_chapter_map.exact_candidates = payload.exact_candidates or {}
        stage_chapter_map.family = payload.family or {}
        stage_chapter_map.family_candidates = payload.family_candidates or {}
    end

    -- [Stage canonicalization] guid -> dataset stage, built alongside the
    -- per-stage watch map. GUIDs are globally unique in the dataset, so this
    -- lets pickup hooks resolve a drop's TRUE stage instead of trusting the
    -- player's current stage volume (sub-stages overlap in the world - live
    -- miss 2026-07-23: Abandoned Factory drops filed under 44210 were grabbed
    -- while the runtime reported 44200 -> "not_in_dataset", checks lost).
    local guid_stage_index = {}

    local function load_location_guid_map()
        local payload = json.load_file(LOCATION_GUID_MAP_FILE)
        if type(payload) ~= "table" then
            return
        end

        clear_table(stage_location_guid_map)
        clear_table(guid_stage_index)
        local raw_stages = payload.stages or {}
        if type(raw_stages) ~= "table" then
            return
        end

        for stage_key, stage_entry in pairs(raw_stages) do
            local guid_lookup = {}
            local item_id_lookup = {}
            local stage_number = tonumber(stage_key)

            if type(stage_entry) == "table" and stage_entry.guids ~= nil then
                for _, guid in ipairs(stage_entry.guids) do
                    if type(guid) == "string" and guid ~= "" then
                        guid_lookup[string.lower(guid)] = true
                        if stage_number ~= nil then
                            guid_stage_index[string.lower(guid)] = stage_number
                        end
                    end
                end

                local raw_item_ids = stage_entry.item_ids or {}
                if type(raw_item_ids) == "table" then
                    for item_id_key, item_guid_list in pairs(raw_item_ids) do
                        local normalized_guids = {}
                        if type(item_guid_list) == "table" then
                            for _, item_guid in ipairs(item_guid_list) do
                                if type(item_guid) == "string" and item_guid ~= "" then
                                    table.insert(normalized_guids, string.lower(item_guid))
                                end
                            end
                        end
                        item_id_lookup[tostring(item_id_key)] = normalized_guids
                    end
                end
            elseif type(stage_entry) == "table" then
                for _, guid in ipairs(stage_entry) do
                    if type(guid) == "string" and guid ~= "" then
                        guid_lookup[string.lower(guid)] = true
                        if stage_number ~= nil then
                            guid_stage_index[string.lower(guid)] = stage_number
                        end
                    end
                end
            end

            stage_location_guid_map[tostring(stage_key)] = {
                guids = guid_lookup,
                item_ids = item_id_lookup,
            }
        end
    end

    -- [Hints] Forward declaration. load_location_display_map (immediately below)
    -- invalidates the location_id -> entry reverse index, but that index and its
    -- invalidator live ~140 lines further down, beside the lazy builder that owns
    -- them. Without this forward local the call resolves to a nil GLOBAL and throws
    -- on the very first display-map load (live crash 2026-07-19). Keep this in sync
    -- if either piece moves.
    local invalidate_location_id_reverse_index

    local function load_location_display_map()
        local payload = json.load_file(LOCATION_DISPLAY_MAP_FILE)
        clear_table(stage_location_display_map)
        if type(payload) ~= "table" then
            return
        end

        local raw_stages = payload.stages or {}
        if type(raw_stages) ~= "table" then
            return
        end

        local function normalize_display_guid(value)
            if type(value) ~= "string" then
                return nil
            end
            local normalized = string.lower(value)
            if normalized == "" then
                return nil
            end
            return normalized
        end

        local function trim_display_text(value)
            if type(value) ~= "string" then
                return ""
            end
            return value:match("^%s*(.-)%s*$")
        end

        for stage_key, raw_entries in pairs(raw_stages) do
            if type(raw_entries) == "table" then
                local stage_entries = {}
                for guid, raw_entry in pairs(raw_entries) do
                    local normalized_guid = normalize_display_guid(guid)
                    if normalized_guid ~= nil and type(raw_entry) == "table" then
                        stage_entries[normalized_guid] = {
                            location_id = tonumber(raw_entry.location_id),
                            location_name = trim_display_text(raw_entry.location_name),
                            toast_title = trim_display_text(raw_entry.toast_title),
                            item_name = trim_display_text(raw_entry.item_name),
                            classification = trim_display_text(raw_entry.classification),
                            chapter = tonumber(raw_entry.chapter),
                            stage_name = trim_display_text(raw_entry.stage_name),
                            -- Pause-map area name + world position (section-scoped
                            -- header counts now; world markers later).
                            section_name = trim_display_text(raw_entry.section_name),
                            -- container/note ride the JSON but were never
                            -- extracted - the hints window's container gloss
                            -- read entry.container as nil-always (latent).
                            container = trim_display_text(raw_entry.container),
                            note = trim_display_text(raw_entry.note),
                            x = tonumber(raw_entry.x),
                            y = tonumber(raw_entry.y),
                            z = tonumber(raw_entry.z),
                        }
                    end
                end

                stage_location_display_map[tostring(stage_key)] = stage_entries
            end
        end

        rebuild_progression_warning_chapter_maps()
        invalidate_location_id_reverse_index()
    end

    -- Pause-map label data (map_labels.json): the literal area names the player
    -- sees on the in-game map, plus chapter/stage -> map-scene tables. Powers the
    -- section-scoped overlay header. Stages stay internal; sections are the
    -- player-facing place vocabulary (see PLAYER_GUIDANCE_DESIGN.md).
    local map_labels = {
        scenes = {},        -- scene id (number) -> zone display name ("Village")
        chapter_scene = {}, -- chapter (number) -> scene id
        stage_scene = {},   -- stage id (number) -> scene id
        labels = {},        -- array of { scene, stage, x, z, name }
    }
    ctx.data.map_labels = map_labels

    local function load_map_labels()
        map_labels.scenes = {}
        map_labels.chapter_scene = {}
        map_labels.stage_scene = {}
        map_labels.labels = {}

        local payload = json.load_file(MAP_LABELS_FILE)
        if type(payload) ~= "table" then
            return
        end

        for scene_key, zone_name in pairs(payload.scenes or {}) do
            local scene_id = tonumber(scene_key)
            if scene_id ~= nil and type(zone_name) == "string" and zone_name ~= "" then
                map_labels.scenes[scene_id] = zone_name
            end
        end
        for chapter_key, scene_id in pairs(payload.chapter_scene or {}) do
            local chapter = tonumber(chapter_key)
            local scene = tonumber(scene_id)
            if chapter ~= nil and scene ~= nil then
                map_labels.chapter_scene[chapter] = scene
            end
        end
        for stage_key, scene_id in pairs(payload.stage_scene or {}) do
            local stage = tonumber(stage_key)
            local scene = tonumber(scene_id)
            if stage ~= nil and scene ~= nil then
                map_labels.stage_scene[stage] = scene
            end
        end
        for _, raw_label in ipairs(payload.labels or {}) do
            if type(raw_label) == "table" then
                local scene = tonumber(raw_label.scene)
                local stage = tonumber(raw_label.stage)
                local x = tonumber(raw_label.x)
                local z = tonumber(raw_label.z)
                local name = trim_string(raw_label.name)
                if scene ~= nil and stage ~= nil and x ~= nil and z ~= nil and name ~= "" then
                    table.insert(map_labels.labels, { scene = scene, stage = stage, x = x, z = z, name = name })
                end
            end
        end
    end

    -- Stage-digit families as the last-resort scene fallback (a few 59xxx stages
    -- sit on the Island map, but stage_scene/chapter_scene cover those first).
    local STAGE_FAMILY_SCENE = { [4] = 10000, [5] = 20000, [6] = 30000 }

    local function get_map_scene(stage, chapter)
        local numeric_stage = tonumber(stage)
        if numeric_stage ~= nil then
            local scene = map_labels.stage_scene[math.floor(numeric_stage)]
            if scene ~= nil then
                return scene
            end
        end
        local numeric_chapter = tonumber(chapter)
        if numeric_chapter ~= nil then
            local scene = map_labels.chapter_scene[math.floor(numeric_chapter)]
            if scene ~= nil then
                return scene
            end
        end
        if numeric_stage ~= nil then
            return STAGE_FAMILY_SCENE[math.floor(numeric_stage / 10000)]
        end
        return nil
    end

    local function get_zone_name(stage, chapter)
        local scene = get_map_scene(stage, chapter)
        if scene == nil then
            return nil
        end
        return map_labels.scenes[scene]
    end

    -- Nearest pause-map area label: same-stage labels win, else scene-wide
    -- Voronoi by XZ distance. Mirror of data_parser.py's _resolve_section_name -
    -- both sides must assign identical names or section counts drift.
    local function get_section_for_position(stage, chapter, x, z)
        local numeric_stage = tonumber(stage)
        local numeric_x = tonumber(x)
        local numeric_z = tonumber(z)
        if numeric_stage == nil or numeric_x == nil or numeric_z == nil then
            return nil
        end

        local scene = get_map_scene(numeric_stage, chapter)
        if scene == nil then
            return nil
        end

        local best_name = nil
        local best_distance = nil
        local restrict_stage = false
        for _, label in ipairs(map_labels.labels) do
            if label.scene == scene then
                local stage_matches = label.stage == math.floor(numeric_stage)
                if stage_matches and not restrict_stage then
                    restrict_stage = true
                    best_name = nil
                    best_distance = nil
                end
                if stage_matches or not restrict_stage then
                    local dx = label.x - numeric_x
                    local dz = label.z - numeric_z
                    local distance = (dx * dx) + (dz * dz)
                    if best_distance == nil or distance < best_distance then
                        best_distance = distance
                        best_name = label.name
                    end
                end
            end
        end
        return best_name
    end

    -- [Hints] location_id -> {stage, guid, entry} reverse index over the display
    -- map, built lazily (display map loads before AP data arrives) and dropped on
    -- display-map reload. Powers hint markers/toasts and the AP Actions pickers.
    local location_id_reverse_index = nil

    -- NOTE: deliberately NOT `local function` -- this fills the forward-declared local
    -- above (see load_location_display_map). Re-adding `local` here would create a new
    -- shadowing local, leaving the forward one nil and restoring the crash.
    function invalidate_location_id_reverse_index()
        location_id_reverse_index = nil
    end

    local function get_display_entry_by_location_id(location_id)
        local numeric_id = tonumber(location_id)
        if numeric_id == nil then
            return nil
        end

        if location_id_reverse_index == nil then
            location_id_reverse_index = {}
            for stage_key, stage_entries in pairs(stage_location_display_map) do
                local stage_id = tonumber(stage_key)
                if stage_id ~= nil and type(stage_entries) == "table" then
                    for guid, display_entry in pairs(stage_entries) do
                        local entry_location_id = tonumber(display_entry and display_entry.location_id)
                        if entry_location_id ~= nil then
                            location_id_reverse_index[math.floor(entry_location_id)] = {
                                stage = stage_id,
                                guid = guid,
                                entry = display_entry,
                            }
                        end
                    end
                end
            end
        end

        return location_id_reverse_index[math.floor(numeric_id)]
    end

    -- Section-scoped check progress: counts every display entry whose
    -- section_name matches, across all stages (a named place can span several
    -- stages and chapter revisits). Rebuilt at most once a second.
    local section_progress_cache = { built_at = -math.huge, counts = {} }

    local function get_section_progress(section_name)
        local normalized = trim_string(section_name)
        if normalized == "" then
            return 0, 0
        end

        local now = os.clock()
        if now - section_progress_cache.built_at > 1.0 then
            local counts = {}
            for stage_key, stage_entries in pairs(stage_location_display_map) do
                local stage_id = tonumber(stage_key)
                if stage_id ~= nil and type(stage_entries) == "table" then
                    for guid, display_entry in pairs(stage_entries) do
                        local entry_section = display_entry and display_entry.section_name
                        if type(entry_section) == "string" and entry_section ~= "" then
                            local bucket = counts[entry_section]
                            if bucket == nil then
                                bucket = { checked = 0, total = 0 }
                                counts[entry_section] = bucket
                            end
                            bucket.total = bucket.total + 1
                            local key = make_stage_guid_key(stage_id, guid)
                            if key ~= nil
                                and (ctx.bridge.acknowledged_guid_keys[key] or ctx.bridge.pending_check_keys[key]) then
                                bucket.checked = bucket.checked + 1
                            end
                        end
                    end
                end
            end
            section_progress_cache.counts = counts
            section_progress_cache.built_at = now
        end

        local bucket = section_progress_cache.counts[normalized]
        if bucket == nil then
            return 0, 0
        end
        return bucket.checked, bucket.total
    end

    local function resolve_chapter_for_ui(stage_id)
        if type(stage_id) ~= "number" then
            return nil, "(unknown)", nil
        end

        local exact_key = tostring(stage_id)
        local exact_chapter = stage_chapter_map.exact[exact_key]
        if type(exact_chapter) == "number" then
            return exact_chapter, tostring(exact_chapter), "exact"
        end

        local exact_candidates = stage_chapter_map.exact_candidates[exact_key]
        if type(exact_candidates) == "table" and #exact_candidates > 0 then
            return nil, join_numbers(exact_candidates), "ambiguous_stage"
        end

        local family_key = tostring(math.floor(stage_id / 100))
        local family_chapter = stage_chapter_map.family[family_key]
        if type(family_chapter) == "number" then
            return family_chapter, tostring(family_chapter), "family"
        end

        local family_candidates = stage_chapter_map.family_candidates[family_key]
        if type(family_candidates) == "table" and #family_candidates > 0 then
            return nil, join_numbers(family_candidates), "ambiguous_family"
        end

        return nil, "(unknown)", nil
    end

    local function get_stage_watch_entry(stage)
        if type(stage) ~= "number" then
            return nil
        end

        return stage_location_guid_map[tostring(stage)]
    end

    -- All tracked stages sharing floor(stage/100) with the given stage, sorted.
    -- A "family" is Capcom's map chunk (402xx = village + its interiors, ...):
    -- sub-stages of one family share a world coordinate space, so world-space
    -- UI (markers) can safely draw a neighbour sub-stage's entries. Verified
    -- against the display map 2026-07-23: every multi-stage family's coordinate
    -- ranges are mutually consistent; cross-FAMILY spaces are NOT (village
    -- 402xx and island 601xx overlap numerically), so never widen past /100.
    local function get_stage_family_stages(stage)
        if type(stage) ~= "number" then
            return {}
        end

        local family = math.floor(stage / 100)
        local stages = {}
        for stage_key, _ in pairs(stage_location_guid_map) do
            local stage_number = tonumber(stage_key)
            if stage_number ~= nil and math.floor(stage_number / 100) == family then
                table.insert(stages, stage_number)
            end
        end
        table.sort(stages)
        return stages
    end

    local function is_stage_guid_tracked(stage, guid)
        local stage_entry = get_stage_watch_entry(stage)
        local normalized_guid = normalize_guid(guid)
        return stage_entry ~= nil and normalized_guid ~= nil and type(stage_entry.guids) == "table"
            and stage_entry.guids[normalized_guid] == true
    end

    -- The stage the DATASET files this guid under, or nil for untracked guids.
    -- Pickup hooks prefer this over the runtime stage: membership and the
    -- ack/pending keys must never depend on which overlapping stage volume the
    -- player happens to stand in when grabbing the drop.
    local function resolve_tracked_stage(guid)
        local normalized_guid = normalize_guid(guid)
        if normalized_guid == nil then
            return nil
        end
        return guid_stage_index[normalized_guid]
    end

    local function count_lookup_entries(values)
        local count = 0
        for _, _ in pairs(values or {}) do
            count = count + 1
        end
        return count
    end

    local function list_lookup_keys(values)
        local result = {}
        for key, _ in pairs(values or {}) do
            table.insert(result, key)
        end
        table.sort(result)
        return result
    end

    local function get_location_display_entry(stage, guid)
        local normalized_guid = normalize_guid(guid)
        if type(stage) ~= "number" or normalized_guid == nil then
            return nil
        end

        local stage_entries = stage_location_display_map[tostring(stage)]
        if type(stage_entries) ~= "table" then
            return nil
        end

        return stage_entries[normalized_guid]
    end

    local function get_stage_progress(stage)
        local stage_entry = get_stage_watch_entry(stage)
        if stage_entry == nil or type(stage_entry.guids) ~= "table" then
            return 0, 0, 0
        end

        local total_count = 0
        local remaining_count = 0
        for guid, _ in pairs(stage_entry.guids) do
            total_count = total_count + 1
            local key = make_stage_guid_key(stage, guid)
            if key ~= nil and not ctx.bridge.acknowledged_guid_keys[key] and not ctx.bridge.pending_check_keys[key] then
                remaining_count = remaining_count + 1
            end
        end

        return total_count - remaining_count, total_count, remaining_count
    end

    -- Remaining-checks label for toast detail lines. Section-scoped when the
    -- checked location knows its pause-map area ("2 left in Village Square");
    -- the stage-scoped "nearby" wording survives only as the no-section fallback.
    local function build_nearby_remaining_label(remaining_count, section_name)
        local normalized_section = trim_string(section_name)
        if normalized_section ~= "" then
            if remaining_count <= 0 then
                return string.format("%s clear", normalized_section)
            end
            if remaining_count == 1 then
                return string.format("1 left in %s", normalized_section)
            end
            return string.format("%d left in %s", remaining_count, normalized_section)
        end

        if remaining_count <= 0 then
            return "All locations checked in this stage"
        end
        if remaining_count == 1 then
            return "1 remains nearby"
        end
        return string.format("%d remain nearby", remaining_count)
    end

    -- Player-facing gloss for items.csv Container values. Mirror of
    -- data_parser._CONTAINER_GLOSS - keep the two in sync. "hanging" is
    -- synthesized by the parser from the scene dev-note name (shoot-to-drop
    -- treasures); every other key is a raw BioRand items.csv Container value.
    local CONTAINER_GLOSS = {
        chest = "chest",
        long = "long chest",
        key = "locked cache",
        smallkey = "small-key drawer",
        multikey = "multi-key cache",
        boss = "boss drop",
        ashley = "Ashley section",
        display = "wall display",
        bawk = "nest",
        hanging = "hanging",
    }

    local function get_container_gloss(container)
        local normalized = string.lower(trim_string(container))
        if normalized == "" then
            return ""
        end
        return CONTAINER_GLOSS[normalized] or ""
    end

    -- Clamp a string to a maximum on-screen length, appending "..." when cut.
    -- Shared by the detector.lua and apclient.lua toast builders (promoted to a
    -- global via the exports table below, like the other overlay helpers) so the
    -- identical helper is not defined twice.
    local function truncate_overlay_text(value, maximum_length)
        local text = tostring(value or "")
        maximum_length = math.max(8, math.floor(tonumber(maximum_length) or 60))
        if #text <= maximum_length then
            return text
        end
        return text:sub(1, maximum_length - 3) .. "..."
    end

    local function get_check_overlay_classification_color(classification)
        local normalized_classification = string.upper(trim_string(classification))
        if normalized_classification == "PROGRESSION" then
            return CHECK_OVERLAY_TEXT_COLOR_PROGRESS
        end
        if normalized_classification == "USEFUL" then
            return CHECK_OVERLAY_TEXT_COLOR_USEFUL
        end
        return CHECK_OVERLAY_TEXT_COLOR_FILLER
    end

    -- Importance prefix glyph for a toast title, keyed on the same classification
    -- string as the colour. Pairs with get_check_overlay_classification_color so
    -- importance is conveyed by symbol AND colour, not colour alone.
    local function get_check_overlay_classification_prefix(classification)
        local normalized_classification = string.upper(trim_string(classification))
        if normalized_classification == "PROGRESSION" then
            return CHECK_OVERLAY_PREFIX_PROGRESSION or ""
        end
        if normalized_classification == "USEFUL" then
            return CHECK_OVERLAY_PREFIX_USEFUL or ""
        end
        return CHECK_OVERLAY_PREFIX_FILLER or ""
    end

    -- Event-KIND glyph for a toast title -- a SECOND axis alongside the rarity
    -- prefix: WHAT happened (received/sent/hint/goal/death), not how important.
    -- Bare glyph (no trailing space); the renderer handles spacing. An unknown or
    -- absent kind returns "" so untagged toasts render exactly as before.
    local function get_check_overlay_kind_prefix(kind)
        local normalized_kind = string.lower(trim_string(kind))
        if normalized_kind == "received" then return CHECK_OVERLAY_KIND_PREFIX_RECEIVED or "" end
        if normalized_kind == "sent" then return CHECK_OVERLAY_KIND_PREFIX_SENT or "" end
        if normalized_kind == "hint" then return CHECK_OVERLAY_KIND_PREFIX_HINT or "" end
        if normalized_kind == "goal" then return CHECK_OVERLAY_KIND_PREFIX_GOAL or "" end
        if normalized_kind == "death" then return CHECK_OVERLAY_KIND_PREFIX_DEATH or "" end
        return ""
    end

    -- Combined two-axis toast prefix, shared by the HUD overlay and the Message Log
    -- so both render identically: "<kind> <rarity> " for item events; "<kind> " for
    -- meta events (hint/goal/death -- always progression, so the rarity glyph adds
    -- nothing); or the rarity prefix alone when no kind is set (untagged toasts).
    local function get_check_overlay_combined_prefix(kind, classification)
        local kind_glyph = get_check_overlay_kind_prefix(kind)
        local rarity_prefix = get_check_overlay_classification_prefix(classification)
        local normalized_kind = string.lower(trim_string(kind))
        if normalized_kind == "hint" or normalized_kind == "goal" or normalized_kind == "death" then
            return (kind_glyph ~= "") and (kind_glyph .. " ") or rarity_prefix
        end
        if kind_glyph ~= "" then
            return kind_glyph .. " " .. rarity_prefix
        end
        return rarity_prefix
    end

    local function get_stage_has_unchecked_progression(stage)
        if type(stage) ~= "number" or type(ctx.bridge.location_classifications) ~= "table" then
            return false
        end
        if next(ctx.bridge.location_classifications) == nil then
            return false
        end

        local stage_entry = get_stage_watch_entry(stage)
        if stage_entry == nil or type(stage_entry.guids) ~= "table" then
            return false
        end

        for guid, _ in pairs(stage_entry.guids) do
            local key = make_stage_guid_key(stage, guid)
            if key ~= nil and not ctx.bridge.acknowledged_guid_keys[key] and not ctx.bridge.pending_check_keys[key] then
                local display_entry = get_location_display_entry(stage, guid)
                local location_id = display_entry and tonumber(display_entry.location_id) or nil
                if location_id ~= nil then
                    local classification = ctx.bridge.location_classifications[tostring(math.floor(location_id))]
                    if classification == "PROGRESSION" then
                        return true
                    end
                end
            end
        end

        return false
    end

    local function get_unchecked_progression_locations_for_chapter(chapter)
        local normalized_chapter = math.floor(tonumber(chapter) or 0)
        local results = {}
        if normalized_chapter <= 0 or type(ctx.bridge.location_classifications) ~= "table" then
            return results
        end
        if next(ctx.bridge.location_classifications) == nil then
            return results
        end

        local stage_lookup = ctx.bridge.progression_warning_chapter_stage_map[normalized_chapter]
        if type(stage_lookup) ~= "table" then
            return results
        end

        for stage_key, _ in pairs(stage_lookup) do
            local stage_id = tonumber(stage_key)
            local stage_entries = stage_location_display_map[tostring(stage_key)]
            if stage_id ~= nil and type(stage_entries) == "table" then
                for guid, display_entry in pairs(stage_entries) do
                    if tonumber(display_entry and display_entry.chapter) == normalized_chapter then
                        local key = make_stage_guid_key(stage_id, guid)
                        if key ~= nil and not ctx.bridge.acknowledged_guid_keys[key] and not ctx.bridge.pending_check_keys[key] then
                            local location_id = tonumber(display_entry.location_id)
                            local classification = location_id ~= nil
                                    and ctx.bridge.location_classifications[tostring(math.floor(location_id))]
                                or nil
                            if classification == "PROGRESSION" then
                                local item_name = trim_string(display_entry.item_name)
                                if item_name == "" then
                                    item_name = trim_string(display_entry.toast_title)
                                end
                                if item_name == "" then
                                    item_name = trim_string(display_entry.location_name)
                                end
                                if item_name == "" then
                                    item_name = "Unknown progression item"
                                end

                                local stage_name = trim_string(display_entry.stage_name)
                                if stage_name == "" then
                                    stage_name = string.format("Stage %s", tostring(stage_id))
                                elseif not string.find(stage_name, tostring(stage_id), 1, true) then
                                    stage_name = string.format("%s (Stage %s)", stage_name, tostring(stage_id))
                                end

                                -- Player-facing place: pause-map section first, internal
                                -- stage note only as fallback (stage_name stays for debug).
                                local section_name = trim_string(display_entry.section_name)
                                local place = (section_name ~= "") and section_name or stage_name

                                table.insert(results, {
                                    chapter = normalized_chapter,
                                    stage = stage_id,
                                    stage_name = stage_name,
                                    section_name = section_name,
                                    place = place,
                                    guid = guid,
                                    item_name = item_name,
                                    location_id = location_id,
                                })
                            end
                        end
                    end
                end
            end
        end

        table.sort(results, function(left, right)
            local left_place = tostring(left.place or "")
            local right_place = tostring(right.place or "")
            if left_place ~= right_place then
                return left_place < right_place
            end
            return tostring(left.item_name) < tostring(right.item_name)
        end)
        return results
    end

    local exports = {
        trim_string = trim_string,
        sanitize_session_component = sanitize_session_component,
        normalize_guid = normalize_guid,
        normalize_stage_id = normalize_stage_id,
        make_stage_guid_key = make_stage_guid_key,
        is_guid_acknowledged = is_guid_acknowledged,
        load_stage_chapter_map = load_stage_chapter_map,
        load_location_guid_map = load_location_guid_map,
        load_location_display_map = load_location_display_map,
        load_map_labels = load_map_labels,
        get_map_scene = get_map_scene,
        get_zone_name = get_zone_name,
        get_section_for_position = get_section_for_position,
        get_section_progress = get_section_progress,
        get_display_entry_by_location_id = get_display_entry_by_location_id,
        get_container_gloss = get_container_gloss,
        resolve_chapter_for_ui = resolve_chapter_for_ui,
        get_stage_watch_entry = get_stage_watch_entry,
        get_stage_family_stages = get_stage_family_stages,
        is_stage_guid_tracked = is_stage_guid_tracked,
        count_lookup_entries = count_lookup_entries,
        list_lookup_keys = list_lookup_keys,
        get_location_display_entry = get_location_display_entry,
        get_stage_progress = get_stage_progress,
        build_nearby_remaining_label = build_nearby_remaining_label,
        truncate_overlay_text = truncate_overlay_text,
        get_check_overlay_classification_color = get_check_overlay_classification_color,
        get_check_overlay_classification_prefix = get_check_overlay_classification_prefix,
        get_check_overlay_kind_prefix = get_check_overlay_kind_prefix,
        get_check_overlay_combined_prefix = get_check_overlay_combined_prefix,
        get_stage_has_unchecked_progression = get_stage_has_unchecked_progression,
        get_unchecked_progression_locations_for_chapter = get_unchecked_progression_locations_for_chapter,
        resolve_tracked_stage = resolve_tracked_stage,
    }

    for key, value in pairs(exports) do
        ctx[key] = value
        _G[key] = value
    end
end

return install
