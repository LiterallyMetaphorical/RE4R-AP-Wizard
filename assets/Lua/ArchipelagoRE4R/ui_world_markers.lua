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
    -- [D8] Rollback re-grabs: white, same as a plain marker - the [RE-GRAB]
    -- prefix is the distinguisher (Cam, live 2026-08-14; the green tried too
    -- hard). Kept as its own constant so the choice stays revisitable.
    local MARKER_COLOR_REGRAB = 0xFFFFFFFF

    -- Text floats a little above the pickup so it reads at eye level.
    local MARKER_Y_OFFSET = 1.4
    -- Height is shown as signed metres once the vertical gap exceeds this.
    local MARKER_HEIGHT_MIN = 1.0
    -- Off-chapter (future/past) markers are muted to this translucent grey so
    -- they read as "not this chapter" without hiding the data.
    local MARKER_COLOR_OFFCHAPTER = 0x99AAAAAA

    -- Enrichment tiers (marker_detail), each a superset of the one before:
    --   minimal   [AP] 9m | +1m
    --   basic     + chapter tag and area name          (the default)
    --   locate    + the vanilla item, its container, and the finding note
    --   identify  + the REAL placement (item + recipient) - a spoiler
    --   developer + the [guid8] code that matches the spoiler log
    -- The player's pick is capped by the host's YAML ceiling
    -- (bridge.marker_detail_ceiling, absent = permissive). Only DEVELOPER is a
    -- debug affordance now: identify used to sit behind Developer Tools too,
    -- which meant no ordinary player could ever reach the top of the ladder
    -- however permissive their room was (Cam, 2026-08-13). Spoiler policy
    -- belongs to the host's ceiling; Developer Tools is for debugging.
    -- A HINTED check always renders identify regardless (you paid to know).
    local DETAIL_TIER = { minimal = 1, basic = 2, locate = 3, identify = 4, developer = 5 }

    local function detail_tier_of(name)
        return DETAIL_TIER[name] or DETAIL_TIER.basic
    end

    local function frame_detail_tier()
        local pick = bridge.world_markers_detail
        if type(pick) ~= "string" then
            pick = (type(_G.WORLD_MARKER_DETAIL) == "string" and _G.WORLD_MARKER_DETAIL) or "basic"
        end
        -- Developer Tools honours the pick outright, ceiling included: the
        -- ceiling ladder cannot even name the developer tier, so capping to
        -- it made tier 5 unreachable in every room. The Guidance picker
        -- offers the same range, so what you pick is what renders.
        if bridge.developer_tools_enabled == true then
            return detail_tier_of(pick)
        end
        -- Absent ceiling = permissive top tier.
        local tier = math.min(detail_tier_of(pick), detail_tier_of(bridge.marker_detail_ceiling or "developer"))
        -- Only the developer tier is a debug affordance.
        if tier >= DETAIL_TIER.developer then
            tier = DETAIL_TIER.identify
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

    -- [Marker position editor] Developer tool. When a marker points at empty
    -- space (the drop audit can't correct these - it reads the DropItem's
    -- logical Transform, which stays at the authored anchor even when the item
    -- is visibly elsewhere), stand in-game, pick the marker, nudge it in world
    -- axes onto the real item, and log a table-ready line for
    -- data_parser._POSITION_OVERRIDES. Overrides are keyed by guid and applied
    -- in build_marker_entry, so the in-world marker moves live as you nudge.
    -- In-session only; nothing writes to game or save data.
    local MARKER_EDIT_FILE = "ArchipelagoRE4R/marker_position_edits.json"
    local marker_edit_overrides = {}
    local marker_edit_selected_guid = nil
    local marker_edit_step = 0.5

    local function marker_edit_invalidate_cache()
        -- Force the next get_marker_entries to rebuild so a nudge shows this
        -- frame instead of waiting out the 1s cache.
        marker_cache.built_at = -math.huge
    end

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
        -- [Marker position editor] Live nudge: a per-guid override moves the
        -- in-world marker as the editor adjusts it. Base xyz kept so the editor
        -- can show the delta and reset.
        local base_x, base_y, base_z = x, y, z
        local override = open_location.guid and marker_edit_overrides[open_location.guid]
        if override ~= nil then
            x, y, z = override.x, override.y, override.z
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
            base_x = base_x,
            base_y = base_y,
            base_z = base_z,
            location_id = location_id,
            hinted = hinted,
            stage = open_location.stage,
            guid = open_location.guid,
            item_name = (display_entry and display_entry.item_name) or "",
            section_name = (display_entry and display_entry.section_name) or "",
            gloss = gloss,
            -- Finding note: authored BioRand prose or the context note
            -- translated from the scene dev names. Identify-tier only.
            note = (display_entry and display_entry.note) or "",
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
        -- [D8] Plus the rollback class: spots this SEED has checked but this
        -- SAVE has not, holding one of our own items. The check stays sent -
        -- these are not reopened locations - but the item is physically back
        -- in the world and nothing else would point at it.
        local collect_regrab = ctx.collect_regrab_family_locations or _G.collect_regrab_family_locations
        if type(collect_regrab) == "function" then
            for _, regrab_location in ipairs(collect_regrab(stage)) do
                local entry = build_marker_entry(regrab_location)
                if entry ~= nil then
                    entry.regrab = true
                    entries[#entries + 1] = entry
                end
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
            elseif entry.regrab then
                -- Same ambient rules as any marker (toggle + distance): this is
                -- guidance, not a paid hint. The tag says what it is - the
                -- check already sent, the item is just lying there again.
                if ambient_enabled and distance <= max_distance then
                    label_prefix = "[RE-GRAB]"
                    color = MARKER_COLOR_REGRAB
                end
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
                -- Fixed reading order (Cam 2026-07-31): tag, chapter, distance,
                -- height, then everything about the item. The chapter used to
                -- be prepended after the fact, which put it BEFORE the [AP]
                -- tag and made the marker read "[Ch1] [AP] ...".
                local parts = { label_prefix }
                -- Basic and up: the chapter tag. Minimal keeps only the
                -- spatial reading (tag, distance, height).
                local head_length = 1
                if eff_tier >= DETAIL_TIER.basic and type(entry.chapter) == "number" then
                    parts[#parts + 1] = "[Ch" .. tostring(entry.chapter) .. "]"
                    head_length = 2
                end
                parts[#parts + 1] = string.format("%dm", math.floor(distance + 0.5))

                -- Every tier carries height; it is spatial, not informational.
                if dy >= MARKER_HEIGHT_MIN then
                    parts[#parts + 1] = string.format("+%dm", math.floor(dy + 0.5))
                elseif dy <= -MARKER_HEIGHT_MIN then
                    parts[#parts + 1] = string.format("-%dm", math.floor((-dy) + 0.5))
                end
                -- Basic and up: the area name.
                if eff_tier >= DETAIL_TIER.basic
                    and type(entry.section_name) == "string" and entry.section_name ~= "" then
                    parts[#parts + 1] = entry.section_name
                end

                -- Locate: what to look for = vanilla item name + container tag,
                -- plus the finding note. The note used to sit at identify, but
                -- it describes how to REACH the thing ("boost Ashley through the
                -- hole above the gate") rather than what the multiworld put
                -- there, so it belongs with the rest of the finding aids
                -- (Cam, 2026-08-13).
                if eff_tier >= DETAIL_TIER.locate then
                    local item_name = tostring(entry.item_name or "")
                    if item_name ~= "" then
                        local tag = ""
                        if type(entry.gloss) == "string" and entry.gloss ~= "" then
                            tag = " (" .. entry.gloss .. ")"
                        end
                        parts[#parts + 1] = '"' .. item_name .. '"' .. tag
                    end
                    local note = tostring(entry.note or "")
                    if note ~= "" then
                        parts[#parts + 1] = note
                    end
                end

                -- The tag and the chapter read as one unit, so they are joined
                -- by spaces; the spatial and item fields stay pipe-separated.
                -- At minimal there is no chapter, so the head is the tag alone
                -- and the distance becomes the first piped field.
                local head_pieces = {}
                for index = 1, head_length do
                    head_pieces[#head_pieces + 1] = parts[index]
                end
                local head = table.concat(head_pieces, " ")
                local rest = {}
                for index = head_length + 1, #parts do
                    rest[#rest + 1] = parts[index]
                end
                local label = head
                if #rest > 0 then
                    label = head .. " " .. table.concat(rest, " | ")
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

    -- [Marker position editor] Record the edited marker's corrected position.
    -- Persists a structured JSON of every edit (guid -> position + label, keyed
    -- by guid so re-editing a spot overwrites cleanly) via the same json file
    -- API the drop audit uses, and ALSO emits the paste-ready
    -- _POSITION_OVERRIDES line to the framework log. Cam sends either.
    local function marker_edit_log_position(entry)
        local label = tostring(entry.section_name or "")
        local item = tostring(entry.item_name or "")
        if item ~= "" then
            label = (label ~= "" and (label .. " - ") or "") .. item
        end
        -- Round to cm - matches the audit's precision and the table's style.
        local rx = math.floor(entry.x * 100 + 0.5) / 100
        local ry = math.floor(entry.y * 100 + 0.5) / 100
        local rz = math.floor(entry.z * 100 + 0.5) / 100
        local line = string.format(
            '        "%s": (%.2f, %.2f, %.2f),  # %s',
            tostring(entry.guid), rx, ry, rz, label)
        log.info("[RE4R AP] marker editor -> " .. line)

        local ok = pcall(function()
            local existing = json.load_file(MARKER_EDIT_FILE)
            if type(existing) ~= "table" then
                existing = { version = 1, edits = {} }
            end
            if type(existing.edits) ~= "table" then
                existing.edits = {}
            end
            existing.edits[tostring(entry.guid)] = {
                x = rx, y = ry, z = rz, label = label,
                stage = entry.stage,
            }
            json.dump_file(MARKER_EDIT_FILE, existing)
        end)
        if ok then
            return string.format("logged %s (%.2f, %.2f, %.2f)",
                tostring(entry.guid):sub(1, 8), rx, ry, rz)
        end
        return "line is in re2_framework_log.txt (file write failed)"
    end

    -- [Marker position editor] Dev-gated window: pick a marker in the current
    -- stage, nudge it in world axes onto the real item, log the corrected
    -- position. Gated on developer_tools_enabled AND its own toggle.
    local function draw_marker_position_editor()
        if bridge.developer_tools_enabled ~= true
            or bridge.marker_editor_window_enabled ~= true then
            return
        end
        local state = bridge.last_state or {}
        if not state.is_playable or type(state.current_stage) ~= "number" then
            return
        end

        imgui.begin_window("AP Marker Position Editor", true)
        imgui.text("Nudge a marker onto the real item, then Log New Position.")
        imgui.text("Send marker_position_edits.log to have it merged.")

        local entries = get_marker_entries(state.current_stage)
        if #entries == 0 then
            imgui.text("No markers in this stage.")
            imgui.end_window()
            return
        end

        -- Marker list as a combo: "section - item [guid8]".
        local labels = {}
        local selected_index = 1
        for i, entry in ipairs(entries) do
            local place = tostring(entry.item_name or "")
            if entry.gloss ~= nil and entry.gloss ~= "" then
                place = place .. " (" .. entry.gloss .. ")"
            end
            labels[i] = string.format("%s - %s [%s]",
                tostring(entry.section_name or "?"),
                place ~= "" and place or "?",
                type(entry.guid) == "string" and entry.guid:sub(1, 8) or "?")
            if entry.guid == marker_edit_selected_guid then
                selected_index = i
            end
        end

        local changed, new_index = imgui.combo("Marker", selected_index, labels)
        if changed and entries[new_index] ~= nil then
            selected_index = new_index
        end
        local selected = entries[selected_index]
        if selected == nil then
            imgui.end_window()
            return
        end
        marker_edit_selected_guid = selected.guid

        imgui.text(string.format("Current: %.2f, %.2f, %.2f", selected.x, selected.y, selected.z))
        imgui.text(string.format("Authored: %.2f, %.2f, %.2f",
            selected.base_x, selected.base_y, selected.base_z))
        local ddx = selected.x - selected.base_x
        local ddy = selected.y - selected.base_y
        local ddz = selected.z - selected.base_z
        imgui.text(string.format("Delta: %.2f, %.2f, %.2f", ddx, ddy, ddz))

        -- Step size selector.
        if imgui.button("step 0.1") then marker_edit_step = 0.1 end
        imgui.same_line()
        if imgui.button("step 0.5") then marker_edit_step = 0.5 end
        imgui.same_line()
        if imgui.button("step 1.0") then marker_edit_step = 1.0 end
        imgui.same_line()
        imgui.text(string.format("(step %.1fm)", marker_edit_step))

        -- Nudge in world axes. N/S move Z, E/W move X, Up/Down move Y. The
        -- absolute mapping does not matter - the editor watches the marker move
        -- and presses whichever direction closes the gap.
        local function nudge(dx, dy, dz)
            local base = marker_edit_overrides[selected.guid]
                or { x = selected.base_x, y = selected.base_y, z = selected.base_z }
            marker_edit_overrides[selected.guid] = {
                x = base.x + dx, y = base.y + dy, z = base.z + dz,
            }
            marker_edit_invalidate_cache()
        end
        local s = marker_edit_step
        if imgui.button("N (+Z)") then nudge(0, 0, s) end
        imgui.same_line()
        if imgui.button("S (-Z)") then nudge(0, 0, -s) end
        imgui.same_line()
        if imgui.button("E (+X)") then nudge(s, 0, 0) end
        imgui.same_line()
        if imgui.button("W (-X)") then nudge(-s, 0, 0) end
        if imgui.button("Up (+Y)") then nudge(0, s, 0) end
        imgui.same_line()
        if imgui.button("Down (-Y)") then nudge(0, -s, 0) end

        if imgui.button("Reset This Marker") then
            marker_edit_overrides[selected.guid] = nil
            marker_edit_invalidate_cache()
        end
        imgui.same_line()
        if imgui.button("Log New Position") then
            bridge.marker_edit_status = marker_edit_log_position(selected)
        end
        if type(bridge.marker_edit_status) == "string" then
            imgui.text(bridge.marker_edit_status)
        end

        imgui.end_window()
    end

    export("draw_world_check_markers", draw_world_check_markers)
    export("dump_world_markers_to_log", dump_world_markers_to_log)
    export("draw_marker_position_editor", draw_marker_position_editor)
end

return install
