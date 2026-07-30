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
    -- Height is shown as signed metres once the vertical gap exceeds this.
    local MARKER_HEIGHT_MIN = 1.0
    -- Off-chapter (future/past) markers are muted to this translucent grey so
    -- they read as "not this chapter" without hiding the data.
    local MARKER_COLOR_OFFCHAPTER = 0x99AAAAAA

    -- Enrichment ladder (marker_detail): basic < locate < identify < developer
    -- (developer = identify + the [guid8] location code, the one token that
    -- correlates a marker with its spoiler-log line - Cam 2026-07-29), each tier a
    -- superset of the prior. The player's client pick is capped by the YAML host
    -- ceiling (bridge.marker_detail_ceiling, absent = permissive "identify"), and
    -- identify additionally needs Developer Tools (a self-spoiler gate). A HINTED
    -- check always renders identify regardless (you paid to know).
    local DETAIL_TIER = { basic = 1, locate = 2, identify = 3, developer = 4 }

    local function detail_tier_of(name)
        return DETAIL_TIER[name] or 1
    end

    local function frame_detail_tier()
        local pick = bridge.world_markers_detail
        if type(pick) ~= "string" then
            pick = (type(_G.WORLD_MARKER_DETAIL) == "string" and _G.WORLD_MARKER_DETAIL) or "basic"
        end
        -- Absent ceiling = permissive top tier. identify AND developer both
        -- sit behind the Developer Tools gate (the >= check covers them).
        local tier = math.min(detail_tier_of(pick), detail_tier_of(bridge.marker_detail_ceiling or "developer"))
        if tier >= DETAIL_TIER.identify and bridge.developer_tools_enabled ~= true then
            tier = DETAIL_TIER.locate
        end
        return tier
    end

    -- identify: the ACTUAL AP placement here (real item + recipient) from the
    -- LocationScouts data. Foreign item names degrade to "Player N's item" until
    -- that game's data package resolves. Mirrors detector.lua's resolution.
    local function identify_suffix(entry)
        local loc = entry.location_id
        if loc == nil then
            return nil
        end
        local key = tostring(math.floor(loc))
        local owner = (type(bridge.location_scout_player) == "table") and tonumber(bridge.location_scout_player[key]) or nil
        local item_id = (type(bridge.location_scout_item) == "table") and tonumber(bridge.location_scout_item[key]) or nil
        if item_id == nil then
            return nil
        end
        local resolve_item = ctx.ap_item_name or _G.ap_item_name
        local item_name = (type(resolve_item) == "function") and resolve_item(item_id, owner) or nil
        if type(item_name) ~= "string" or item_name == "" then
            return nil
        end
        local me = tonumber(bridge.ap_numeric_slot)
        if owner ~= nil and me ~= nil and owner == me then
            return "-> your " .. item_name
        end
        if owner ~= nil then
            local resolve_player = ctx.ap_player_name or _G.ap_player_name
            local who = (type(resolve_player) == "function" and resolve_player(owner)) or ("Player " .. tostring(owner))
            return "-> " .. tostring(who) .. ": " .. item_name
        end
        return "-> " .. item_name
    end

    local marker_cache = {
        family = nil,
        built_at = -math.huge,
        entries = {},
    }

    -- Presentation-only projection: membership + family iteration live in
    -- data.lua's collect_open_family_locations (shared with the Actions-tab
    -- nearby list and the header progression notice), so an eligibility rule
    -- edit there lands here automatically. This function only turns each open
    -- location into a drawable marker entry.
    local function build_marker_entry(open_location)
        local display_entry = open_location.entry
        local x = display_entry and tonumber(display_entry.x)
        local y = display_entry and tonumber(display_entry.y)
        local z = display_entry and tonumber(display_entry.z)
        -- 0,0,0 means "no extracted position" (should not happen for
        -- current data); skip rather than draw a marker at the origin.
        if x == nil or y == nil or z == nil
            or (x == 0.0 and y == 0.0 and z == 0.0) then
            return nil
        end
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
        return {
            x = x,
            y = y,
            z = z,
            location_id = location_id,
            hinted = hinted,
            stage = open_location.stage,
            guid = open_location.guid,
            item_name = (display_entry and display_entry.item_name) or "",
            section_name = (display_entry and display_entry.section_name) or "",
            gloss = gloss,
            chapter = display_entry and tonumber(display_entry.chapter),
        }
    end

    -- Markers draw for the whole stage FAMILY (floor/100 = one map chunk, one
    -- shared coordinate space), not just the exact current sub-stage. Keying
    -- by sub-stage hid markers the player was standing next to: the Village
    -- Square Hand Grenade (36416bae) is keyed under 40211 ("grenade house"),
    -- so from 40200 - two metres outside the door - it never drew (Cam's
    -- footage, 2026-07-23). The 40m distance cap still bounds what shows.
    local function rebuild_marker_entries(stage)
        local entries = {}
        local collect = ctx.collect_open_family_locations or _G.collect_open_family_locations
        if type(collect) ~= "function" then
            return entries
        end
        for _, open_location in ipairs(collect(stage)) do
            local entry = build_marker_entry(open_location)
            if entry ~= nil then
                entries[#entries + 1] = entry
            end
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

    -- The set of currently dispatched (loaded) stages, from DropItemManager. A
    -- marker whose stage is not in this set points at a pickup that has not
    -- spawned in the loaded scene yet -- unlike the item's data chapter, this is
    -- the honest "is it grabbable now" signal.
    local function get_dispatched_stages()
        local manager = sdk.get_managed_singleton("chainsaw.DropItemManager")
        if manager == nil then
            return nil
        end
        local ok, dict = pcall(function() return manager:get_field("_DispatchedStage") end)
        if ok and dict ~= nil then
            return dict
        end
        return nil
    end

    local function stage_loaded(dispatched, stage)
        if dispatched == nil or type(stage) ~= "number" then
            return true -- no data -> fail safe, do not dim
        end
        local ok, contained = pcall(function() return dispatched:call("ContainsKey", stage) end)
        if not ok then
            return true -- lookup failed -> fail safe
        end
        return contained == true
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

        local frame_tier = frame_detail_tier()
        -- Availability dimming: a marker whose stage is not currently dispatched
        -- (loaded) is a pickup that has not spawned yet, so mute or hide it. This
        -- replaces the old chapter comparison, which was unreliable because an
        -- item's data chapter is its area's canonical chapter, not when it is
        -- grabbable. Failure to read the set fails safe (dim nothing).
        local dispatched = get_dispatched_stages()
        local hide_unavailable = bridge.world_markers_hide_offchapter == true

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

            -- Availability: mute (or hide) a marker whose stage is not loaded --
            -- its pickup has not spawned, so it is not grabbable from here yet.
            -- The [Ch N] tag still shows the item's canonical chapter regardless.
            local unavailable = not stage_loaded(dispatched, entry.stage)
            if unavailable then
                if hide_unavailable then
                    label_prefix = nil
                else
                    color = MARKER_COLOR_OFFCHAPTER
                end
            end

            if label_prefix ~= nil then
                -- Hinted checks always render identify (paid to know); everything
                -- else uses this frame's allowed tier (client pick, capped).
                local eff_tier = entry.hinted and DETAIL_TIER.identify or frame_tier
                local parts = { string.format("%s %dm", label_prefix, math.floor(distance + 0.5)) }

                -- Basic: height (signed metres) + area.
                if dy >= MARKER_HEIGHT_MIN then
                    parts[#parts + 1] = string.format("+%dm", math.floor(dy + 0.5))
                elseif dy <= -MARKER_HEIGHT_MIN then
                    parts[#parts + 1] = string.format("-%dm", math.floor((-dy) + 0.5))
                end
                if type(entry.section_name) == "string" and entry.section_name ~= "" then
                    parts[#parts + 1] = entry.section_name
                end

                -- Locate: what to look for = vanilla item name + container tag.
                if eff_tier >= DETAIL_TIER.locate then
                    local item_name = tostring(entry.item_name or "")
                    if item_name ~= "" then
                        local tag = ""
                        if type(entry.gloss) == "string" and entry.gloss ~= "" then
                            tag = " (" .. entry.gloss .. ")"
                        end
                        parts[#parts + 1] = '"' .. item_name .. '"' .. tag
                    end
                end

                local label = table.concat(parts, " | ")
                -- Every marker leads with its chapter (off-chapter ones are also
                -- muted grey to stand out), so a leaked future check reads as
                -- "[Ch5] ... not now" and same-chapter checks confirm the chapter.
                if type(entry.chapter) == "number" then
                    label = "[Ch" .. tostring(entry.chapter) .. "] " .. label
                end

                -- Identify: the real AP placement, appended after the spatial line.
                if eff_tier >= DETAIL_TIER.identify then
                    local id = identify_suffix(entry)
                    if id ~= nil then
                        label = label .. "  " .. id
                    end
                end

                -- Developer: the [guid8] location code - matches the token in
                -- the AP location name and the spoiler log, so a marker can be
                -- correlated line-for-line with generation output.
                if eff_tier >= DETAIL_TIER.developer
                    and type(entry.guid) == "string" and #entry.guid >= 8 then
                    label = label .. "  [" .. entry.guid:sub(1, 8) .. "]"
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

        local dispatched = get_dispatched_stages()
        local dispatched_count = "?"
        if dispatched ~= nil then
            local ok, c = pcall(function() return dispatched:call("get_Count") end)
            if ok then dispatched_count = tostring(c) end
        end
        log.info(string.format(
            "[RE4R AP] marker dump: stage=%s family=%s unchecked=%d dispatched_stages=%s",
            tostring(state.current_stage),
            tostring(math.floor(state.current_stage / 100)),
            #rows,
            dispatched_count
        ))
        for _, row in ipairs(rows) do
            local entry = row.entry
            local place = tostring(entry.item_name or "")
            if entry.gloss ~= nil and entry.gloss ~= "" then
                place = place .. " (" .. entry.gloss .. ")"
            end
            log.info(string.format(
                "[RE4R AP]   marker stage=%s loaded=%s guid=%s dist=%s item='%s' loc_id=%s section='%s' pos=(%.1f,%.1f,%.1f)%s",
                tostring(entry.stage),
                tostring(stage_loaded(dispatched, entry.stage)),
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
