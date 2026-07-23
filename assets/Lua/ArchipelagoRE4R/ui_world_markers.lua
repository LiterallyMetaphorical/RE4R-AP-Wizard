-- World markers for unchecked AP locations (PLAYER_GUIDANCE_DESIGN.md section 5.1).
-- Draws a floating "[AP]" tag at every tracked-but-unsent check in the current
-- stage within a distance cap, using the world positions the data pipeline
-- extracted from the scene files (display map x/y/z). Guidance says WHERE, never
-- WHAT: markers are neutral white unless the player explicitly opts in to
-- scouted-importance colours.
local function install(ctx)
    ctx.ui_world_markers = ctx.ui_world_markers or {}
    local bridge = ctx.bridge

    local function export(name, value)
        ctx.ui_world_markers[name] = value
        ctx[name] = value
        _G[name] = value
    end

    -- Packed ABGR for draw.world_text. Colour values match the toast palette
    -- (PROGRESSION #E0B24A, USEFUL #6D8BE8, filler white). The hint colour is
    -- deliberately OUTSIDE the rarity palette (magenta #E88BD0) so a hinted
    -- marker cannot be mistaken for opt-in rarity colouring.
    local MARKER_COLOR_NEUTRAL = 0xFFFFFFFF
    local MARKER_COLOR_PROGRESSION = 0xFF4AB2E0
    local MARKER_COLOR_USEFUL = 0xFFE88B6D
    local MARKER_COLOR_HINT = 0xFFD08BE8

    -- Text floats a little above the pickup so it reads at eye level.
    local MARKER_Y_OFFSET = 1.4
    -- Beyond this vertical gap the label gets an above/below hint glyph.
    local MARKER_ELEVATION_HINT = 3.0

    local marker_cache = {
        family = nil,
        built_at = -math.huge,
        entries = {},
    }

    local function collect_stage_marker_entries(stage, entries)
        local stage_entry = get_stage_watch_entry(stage)
        if stage_entry == nil or type(stage_entry.guids) ~= "table" then
            return
        end

        for guid, _ in pairs(stage_entry.guids) do
            local key = make_stage_guid_key(stage, guid)
            if key ~= nil
                and not bridge.acknowledged_guid_keys[key]
                and not bridge.pending_check_keys[key] then
                local display_entry = get_location_display_entry(stage, guid)
                local x = display_entry and tonumber(display_entry.x)
                local y = display_entry and tonumber(display_entry.y)
                local z = display_entry and tonumber(display_entry.z)
                -- 0,0,0 means "no extracted position" (should not happen for
                -- current data); skip rather than draw a marker at the origin.
                if x ~= nil and y ~= nil and z ~= nil
                    and not (x == 0.0 and y == 0.0 and z == 0.0) then
                    local location_id = display_entry and tonumber(display_entry.location_id)
                    -- [Hints] An unfound hint on this location upgrades the
                    -- marker: [HINT] label, hint colour, whole-stage range.
                    local hinted = false
                    if location_id ~= nil and type(bridge.hints_on_my_world) == "table" then
                        hinted = bridge.hints_on_my_world[tostring(math.floor(location_id))] ~= nil
                    end
                    -- [Debug identity] what the spot IS: vanilla item name +
                    -- container gloss ("crate", "barrel"...) so the label can
                    -- say what to look for, and the log dump can name checks.
                    local gloss_fn = ctx.get_container_gloss or _G.get_container_gloss
                    local gloss = ""
                    if type(gloss_fn) == "function" and display_entry ~= nil then
                        gloss = tostring(gloss_fn(display_entry.container) or "")
                    end
                    table.insert(entries, {
                        x = x,
                        y = y,
                        z = z,
                        location_id = location_id,
                        hinted = hinted,
                        stage = stage,
                        guid = guid,
                        item_name = (display_entry and display_entry.item_name) or "",
                        section_name = (display_entry and display_entry.section_name) or "",
                        gloss = gloss,
                    })
                end
            end
        end
    end

    -- Markers draw for the whole stage FAMILY (floor/100 = one map chunk, one
    -- shared coordinate space), not just the exact current sub-stage. Keying
    -- by sub-stage hid markers the player was standing next to: the Village
    -- Square Hand Grenade (36416bae) is keyed under 40211 ("grenade house"),
    -- so from 40200 - two metres outside the door - it never drew (Cam's
    -- footage, 2026-07-23). The 40m distance cap still bounds what shows.
    local function rebuild_marker_entries(stage)
        local entries = {}
        for _, family_stage in ipairs(get_stage_family_stages(stage)) do
            collect_stage_marker_entries(family_stage, entries)
        end
        return entries
    end

    local function get_marker_entries(stage)
        local now = os.clock()
        local family = math.floor(stage / 100)
        if marker_cache.family ~= family or now - marker_cache.built_at > 1.0 then
            marker_cache.family = family
            marker_cache.built_at = now
            marker_cache.entries = rebuild_marker_entries(stage)
        end
        return marker_cache.entries
    end

    local function get_marker_color(location_id)
        -- Rarity colours need BOTH the YAML ceiling and the player opt-in.
        if bridge.check_guidance_ceiling ~= "markers_rarity"
            or not bridge.world_markers_importance_colors then
            return MARKER_COLOR_NEUTRAL
        end
        if location_id == nil or type(bridge.location_classifications) ~= "table" then
            return MARKER_COLOR_NEUTRAL
        end

        local classification = bridge.location_classifications[tostring(math.floor(location_id))]
        if classification == "PROGRESSION" then
            return MARKER_COLOR_PROGRESSION
        end
        if classification == "USEFUL" then
            return MARKER_COLOR_USEFUL
        end
        return MARKER_COLOR_NEUTRAL
    end

    local function draw_world_check_markers()
        -- YAML ceiling: check_guidance "off" disables ALL world guidance,
        -- including hinted markers (the ceiling is absolute).
        if bridge.check_guidance_ceiling == "off" then
            return
        end
        -- Ambient [AP] markers and purchased [HINT] markers gate separately:
        -- a player who opted out of ambient guidance still sees hints they
        -- (or teammates) explicitly bought, unless they turn those off too.
        local ambient_enabled = bridge.world_markers_enabled == true
        local hints_enabled = bridge.world_markers_show_hints ~= false
        if not ambient_enabled and not hints_enabled then
            return
        end

        local state = bridge.last_state or {}
        if not state.is_playable or type(state.current_stage) ~= "number" then
            return
        end

        local position_getter = ctx.get_player_position or _G.get_player_position
        if type(position_getter) ~= "function" then
            return
        end
        local ok_position, player_position = pcall(position_getter)
        if not ok_position or player_position == nil then
            return
        end

        local max_distance = tonumber(bridge.world_markers_max_distance) or 40.0
        local entries = get_marker_entries(state.current_stage)
        for _, entry in ipairs(entries) do
            local dx = entry.x - player_position.x
            local dy = entry.y - player_position.y
            local dz = entry.z - player_position.z
            local distance = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))

            -- Hinted markers ignore the distance cap (whole-stage: the player
            -- is actively hunting a bought hint). A hinted entry with the hint
            -- toggle off falls back to ordinary ambient treatment.
            local label_prefix, color = nil, nil
            if entry.hinted and hints_enabled then
                label_prefix = "[HINT]"
                color = MARKER_COLOR_HINT
            elseif ambient_enabled and distance <= max_distance then
                label_prefix = "[AP]"
                color = get_marker_color(entry.location_id)
            end

            if label_prefix ~= nil then
                local label = label_prefix
                -- [Debug identity] "[AP] Sapphire x1 (crate) [768028fb] 4m":
                -- playtest aid (config default) - a bare tag over rubble is
                -- unfindable and unreportable. Checkbox lives in the Status
                -- window next to the other marker toggles.
                local debug_identity = bridge.world_markers_debug_identity
                if debug_identity == nil then
                    debug_identity = (WORLD_MARKER_DEBUG_IDENTITY == true)
                end
                if debug_identity then
                    local item_name = tostring(entry.item_name or "")
                    if item_name ~= "" then
                        label = label .. " " .. item_name
                    end
                    if entry.gloss ~= nil and entry.gloss ~= "" then
                        label = label .. " (" .. entry.gloss .. ")"
                    end
                    if type(entry.guid) == "string" and #entry.guid >= 8 then
                        label = label .. " [" .. entry.guid:sub(1, 8) .. "]"
                    end
                end
                if bridge.world_markers_show_distance then
                    label = string.format("%s %dm", label, math.floor(distance + 0.5))
                end
                if dy > MARKER_ELEVATION_HINT then
                    label = label .. " ^"
                elseif dy < -MARKER_ELEVATION_HINT then
                    label = label .. " v"
                end

                local ok_draw = pcall(
                    draw.world_text,
                    label,
                    Vector3f.new(entry.x, entry.y + MARKER_Y_OFFSET, entry.z),
                    color
                )
                if not ok_draw then
                    -- draw module unavailable (no camera yet): bail this frame.
                    return
                end
            end
        end
    end

    -- Debug-tab dump: every unchecked marker in the current stage FAMILY with
    -- full identity + distance, nearest first, to the re2 log. Pairs with the
    -- in-world identity labels: the label answers "what is this one", the dump
    -- answers "what is around me / what did the family collect".
    local function dump_world_markers_to_log()
        local state = bridge.last_state or {}
        if not state.is_playable or type(state.current_stage) ~= "number" then
            return "not in gameplay - no dump"
        end

        local player_position = nil
        local position_getter = ctx.get_player_position or _G.get_player_position
        if type(position_getter) == "function" then
            local ok_position, value = pcall(position_getter)
            if ok_position then
                player_position = value
            end
        end

        local entries = rebuild_marker_entries(state.current_stage)
        local rows = {}
        for _, entry in ipairs(entries) do
            local distance = nil
            if player_position ~= nil then
                local dx = entry.x - player_position.x
                local dy = entry.y - player_position.y
                local dz = entry.z - player_position.z
                distance = math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
            end
            table.insert(rows, { entry = entry, distance = distance })
        end
        table.sort(rows, function(left, right)
            return (left.distance or math.huge) < (right.distance or math.huge)
        end)

        log.info(string.format(
            "[RE4R AP] marker dump: stage=%s family=%s unchecked=%d",
            tostring(state.current_stage),
            tostring(math.floor(state.current_stage / 100)),
            #rows
        ))
        for _, row in ipairs(rows) do
            local entry = row.entry
            local place = tostring(entry.item_name or "")
            if entry.gloss ~= nil and entry.gloss ~= "" then
                place = place .. " (" .. entry.gloss .. ")"
            end
            log.info(string.format(
                "[RE4R AP]   marker stage=%s guid=%s dist=%s item='%s' loc_id=%s section='%s' pos=(%.1f,%.1f,%.1f)%s",
                tostring(entry.stage),
                tostring(entry.guid),
                row.distance ~= nil and string.format("%dm", math.floor(row.distance + 0.5)) or "?",
                place,
                tostring(entry.location_id),
                tostring(entry.section_name or ""),
                entry.x, entry.y, entry.z,
                entry.hinted and " HINTED" or ""
            ))
        end
        return string.format("dumped %d unchecked marker(s) to log", #rows)
    end

    export("draw_world_check_markers", draw_world_check_markers)
    export("dump_world_markers_to_log", dump_world_markers_to_log)
end

return install
