local function install(ctx)
    local config = {
        -- Logged at boot next to the launcher's install stamp so a player's
        -- re2_framework_log.txt identifies the exact deployed build. Bump on
        -- every Lua change that ships (date.rev).
        MOD_VERSION = "2026.07.27-1",
        DATA_DIR = "ArchipelagoRE4R",
        WRITE_INTERVAL_SECONDS = 0.25,
        SCAN_INTERVAL_SECONDS = 1 / 30,
        HOLDER_HIT_GUID_WINDOW_MS = 500,
        PENDING_PICKUP_ACCEPT_WINDOW_MS = 5000,
        -- Tracked accepts (the interacted DropItem's GUID IS an AP check) wait
        -- much longer for their inventory commit: weapon pickups park in the
        -- full-screen acquisition UI until the player closes it, so the commit
        -- can arrive minutes after the accept. The 5s window above starved
        -- EVERY multiworld placeholder (they are all the SW Blast Crossbow -
        -- live find, Cam 2026-07-21: 14s gap -> "pickup_commit unmatched",
        -- check never sent). Blind fallback probes keep the tight window.
        PENDING_TRACKED_ACCEPT_WINDOW_MS = 600000,
        -- The multiworld placeholder is SW - Glasses (a Separate Ways
        -- treasure with no main-campaign presence). It replaced the SW Blast
        -- Crossbow after live fire proved the engine refuses to instantiate
        -- a weapon drop the player already owns (the first collected weapon
        -- placeholder suppressed every later spawn - Cam, 2026-07-22).
        -- Treasures have no ownership rule, so spawning is data-correct on
        -- its own; the accept-hook INTERCEPTION stays on as the delivery
        -- mechanism (send the check, despawn the drop, keep the case clean).
        -- Id must match placeholder_item_id in the launcher's
        -- re4r_ap_static.json.
        PLACEHOLDER_ITEM_ID = 120486400,
        PLACEHOLDER_INTERCEPT = true,
        LOCAL_INJECTION_SUPPRESSION_WINDOW_MS = 5000,
        LOCAL_INJECTION_ACCEPT_SUPPRESSION_WINDOW_MS = 250,
        SAFE_WARP_PRELOAD_DELAY_SECONDS = 1.0,
        CHECK_NOTIFICATION_DURATION_MS = 4500,
        CHECK_NOTIFICATION_MAX_VISIBLE = 4,
        -- When a burst of this many or more received items lands at once (the
        -- reconnect catch-up resend replays the whole item stream), collapse them
        -- into a single rolling "Synced N items" toast instead of N toasts.
        CHECK_SYNC_COALESCE_THRESHOLD = 4,
        -- [Native rail spike] Where transient toasts render (native_log.lua):
        --   "native"  - the game's own bottom-right activity-log rail; the imgui
        --               toast is skipped once the Message Log captured it. Local
        --               in-world pickups push NOTHING (the game's organic pickup
        --               toast already shows the item - that was the double-toast).
        --   "overlay" - legacy imgui toasts only, byte-identical old behaviour.
        --   "both"    - render both surfaces at once (A/B comparison).
        -- Live-tunable in the Debug tab; this is only the boot default. The
        -- imgui rail code is fully intact regardless of mode.
        NATIVE_TOAST_MODE = "native",
        -- Native rail only: filler items are WHITE on the imgui overlay, but on
        -- the rail white is the connective colour - item names tagged
        -- entity="item" that would render white get this parchment tint
        -- instead so the thing-being-named still stands out. "" disables.
        NATIVE_ITEM_FALLBACK_HEX = "E8DCC0",
        -- [Native rail] Glyph prefixes for NATIVE lines only. The rail renders
        -- with the real game font - full Unicode verified live 2026-07-23
        -- (Å ★ → all drew correctly). The imgui overlay + Message Log keep the
        -- ASCII CHECK_OVERLAY_* prefixes below: REFramework's imgui font still
        -- draws these glyphs as boxes. Same two-axis rules as the imgui
        -- prefixes: meta events (hint/goal/death) kind glyph only, item events
        -- kind + rarity, kindless probes rarity only.
        NATIVE_GLYPHS_ENABLED = true,
        NATIVE_GLYPH_KIND_RECEIVED = "←",
        NATIVE_GLYPH_KIND_SENT = "→",
        NATIVE_GLYPH_KIND_HINT = "?",
        NATIVE_GLYPH_KIND_GOAL = "★",
        -- U+2620 skull drew as a box live (Cam 2026-07-23) despite the other
        -- glyphs rendering; dagger is the death mark instead. If † ever boxes
        -- too, "×" (U+00D7, Latin-1) is the safe fallback.
        NATIVE_GLYPH_KIND_DEATH = "†",
        NATIVE_GLYPH_RARITY_PROGRESSION = "★",
        NATIVE_GLYPH_RARITY_USEFUL = "◆",
        NATIVE_GLYPH_RARITY_FILLER = "•",
        -- [Native rail] Panel style for our free-text notices. Organic item
        -- toasts draw a backing banner; NoticeLogRequest entries come out
        -- plainer. Each request type picks its visual via getTextPanelState()
        -- - a runtime-only string. When this is non-empty, a post-hook makes
        -- NoticeLogRequest report THIS state instead, so our lines adopt the
        -- item-style banner. Discover the right value with the Debug tab's
        -- "Install panel-state hooks" (it auto-captures what organic ItemGet
        -- toasts return, shown in the Debug tab + re2 log). Empty = game
        -- default (no override hook installed at boot).
        -- "DEFAULT" = the state organic ItemGet toasts report (captured live
        -- 2026-07-23); with it our notices draw the same backing plate as the
        -- game's own pickup toasts (Cam: "we want the backing plate").
        NATIVE_TOAST_PANEL_STATE = "DEFAULT",
        -- [World markers] Default detail tier for marker labels (marker_detail
        -- ladder): "basic" (distance / direction / height / area), "locate"
        -- (+ what to look for: vanilla item + container), or "identify" (+ the
        -- actual AP item and recipient -- a spoiler gated behind Developer Tools).
        -- The Status-window picker overrides at runtime, capped by the YAML host
        -- ceiling (marker_detail_ceiling). Guidance default says WHERE, not WHAT.
        WORLD_MARKER_DETAIL = "basic",
        -- Developer pickup-probe telemetry (GUID / stage / ctx / "Not in dataset" /
        -- "No accept hook") in the header overlay. OFF for players; flip to true to
        -- diagnose detection during testing.
        SHOW_DEBUG_PROBE_OVERLAY = false,
        -- Importance prefix shown before every toast title, alongside the colour, so
        -- importance reads without relying on colour (a11y).
        -- ASCII ONLY. REFramework's imgui font has NO coverage for the nicer glyphs:
        -- star/circle/middle-dot/arrows/skull ALL rendered as boxes in-game (confirmed
        -- live, Cam 2026-07-16). Do NOT "upgrade" these back to Unicode without
        -- verifying in-game first.
        CHECK_OVERLAY_PREFIX_PROGRESSION = "* ",
        CHECK_OVERLAY_PREFIX_USEFUL = "+ ",
        CHECK_OVERLAY_PREFIX_FILLER = ". ",
        -- Event-KIND glyphs -- a SECOND axis alongside the rarity prefix above:
        -- WHAT happened (received/sent/hint/goal/death), not how important. The
        -- overlay shows "<kind> <rarity> Title" for item toasts and "<kind> Title"
        -- for meta events (hint/goal/death). Bare glyph, no trailing space (the
        -- renderer spaces them). ASCII only -- see the font note above.
        CHECK_OVERLAY_KIND_PREFIX_RECEIVED = "<-",
        CHECK_OVERLAY_KIND_PREFIX_SENT = "->",
        CHECK_OVERLAY_KIND_PREFIX_HINT = "?",
        CHECK_OVERLAY_KIND_PREFIX_GOAL = "*",
        CHECK_OVERLAY_KIND_PREFIX_DEATH = "X",
        CHECK_OVERLAY_MARGIN_X = 28,
        CHECK_OVERLAY_MARGIN_Y = 28,
        CHECK_OVERLAY_GAP_Y = 10,
        CHECK_OVERLAY_HEADER_WIDTH = 640,
        CHECK_OVERLAY_TOAST_WIDTH = 460,
        CHECK_OVERLAY_HEADER_HEIGHT = 38,
        CHECK_OVERLAY_TOAST_HEIGHT = 58,
        CHECK_OVERLAY_HEADER_MAIN_Y_OFFSET = 18,
        CHECK_OVERLAY_HEADER_MIN_WIDTH = 320,
        CHECK_OVERLAY_HEADER_PADDING_X = 20,
        CHECK_OVERLAY_TOAST_MIN_WIDTH = 260,
        CHECK_OVERLAY_TOAST_PADDING_X = 18,
        CHECK_OVERLAY_WINDOW_FLAGS = 43 + 256 + 786944 + 4096 + 8192,
        CHECK_OVERLAY_TEXT_COLOR_FILLER = { 1.0, 1.0, 1.0, 1.0 },
        CHECK_OVERLAY_TEXT_COLOR_PROGRESS = { 0.878, 0.698, 0.290, 1.0 },
        CHECK_OVERLAY_TEXT_COLOR_USEFUL = { 0.427, 0.545, 0.910, 1.0 },
        -- Player names in toast titles ("Sent <item> to <player>") get their own colour
        -- so the ITEM and the WHO read as distinct entities at a glance. The item keeps
        -- its classification colour; connective words stay white.
        CHECK_OVERLAY_TEXT_COLOR_PLAYER = { 0.45, 0.78, 0.96, 1.0 },
        CHECK_OVERLAY_TEXT_COLOR_CONNECTED = { 0.45, 0.85, 0.45, 1.0 },
        CHECK_OVERLAY_TEXT_COLOR_ERROR = { 0.92, 0.42, 0.42, 1.0 },
        CHECK_OVERLAY_TEXT_COLOR_DETAIL = { 1.0, 1.0, 1.0, 1.0 },
        CHECK_OVERLAY_TEXT_COLOR_PROBE_DETAIL = { 0.7, 0.7, 0.7, 1.0 },
        CHECK_OVERLAY_TEXT_COLOR_SHADOW = { 0.0, 0.0, 0.0, 0.75 },
        -- [Celebration] Center-screen banner for once-per-seed moments (currently just
        -- the goal). Loud on purpose: it fires rarely, so it can afford the screen.
        -- NOTE: timing uses os.clock() (monotonic, sub-second). now_unix_ms() is
        -- os.time()*1000 -- WHOLE-SECOND granular -- and cannot animate a fade at all.
        CELEBRATION_DURATION_MS = 9000,
        CELEBRATION_FADE_IN_MS = 400,
        CELEBRATION_FADE_OUT_MS = 1400,
        CELEBRATION_PULSE_PERIOD_MS = 1800, -- slow alpha "breathe"; 0 disables
        CELEBRATION_BANNER = "* * * * * * * * * * * * * * * *", -- ASCII: the font has no glyph coverage
        CELEBRATION_WIDTH = 720,
        CELEBRATION_LINE_HEIGHT = 30,
        CELEBRATION_FONT_SCALE = 1.6, -- via set_window_font_scale; silently ignored if unsupported
        CELEBRATION_TEXT_COLOR = { 1.0, 0.84, 0.35, 1.0 }, -- gold
    }

    -- REFramework's Lua sandbox removes os.getenv (it does os["getenv"]=nil),
    -- so calling it crashes the mod on load. Guard it: when APPDATA is
    -- unavailable the mod relies on game-relative paths (resolved under
    -- reframework/data) instead of %APPDATA%.
    local function safe_getenv(name)
        local getenv = rawget(os, "getenv")
        if type(getenv) == "function" then
            local ok, value = pcall(getenv, name)
            if ok and type(value) == "string" then
                return value
            end
        end
        return nil
    end

    config.APPDATA_DIR = safe_getenv("APPDATA") or ""
    config.LAUNCHER_DATA_DIR = config.APPDATA_DIR .. "\\RE4R-AP"
    -- Session watermark/checked-set store. Game-relative (resolved by
    -- REFramework's json API under reframework/data/), same mechanism as
    -- warp_unlocks. It used to derive from APPDATA_DIR, which REFramework
    -- always nils -> "\RE4R-AP\bridge" = the GAME DRIVE'S ROOT (shipped that
    -- way through 2026-07-23; functional but a wart, and on a stranger's PC a
    -- mystery folder). LEGACY_BRIDGE_DIR is that old shape, kept ONLY so
    -- load_session_state can migrate existing stores forward.
    config.BRIDGE_DIR = config.DATA_DIR .. "\\bridge"
    config.LEGACY_BRIDGE_DIR = "\\RE4R-AP\\bridge"
    -- Written by the launcher at patch time (launcher version + payload id);
    -- the mod logs it at boot for support triage. Absent = pre-stamp install.
    config.VERSION_STAMP_FILE = config.DATA_DIR .. "\\version_stamp.json"
    -- Game-relative (reframework/data/ArchipelagoRE4R/ap_connection.json) so the
    -- mod reads connection info without os.getenv; the launcher writes it here.
    config.CONNECTION_INFO_FILE = config.DATA_DIR .. "\\ap_connection.json"
    config.STAGE_CHAPTER_MAP_FILE = config.DATA_DIR .. "\\stage_chapter_map.json"
    config.LOCATION_GUID_MAP_FILE = config.DATA_DIR .. "\\location_guid_map.json"
    config.LOCATION_DISPLAY_MAP_FILE = config.DATA_DIR .. "\\location_display_map.json"
    config.MAP_LABELS_FILE = config.DATA_DIR .. "\\map_labels.json"
    config.INJECTABLE_ITEMS_FILE = config.DATA_DIR .. "\\injectable_items.json"
    config.WARP_POINTS_FILE = config.DATA_DIR .. "\\warp.csv"
    config.WARP_UNLOCKS_DIR = config.DATA_DIR .. "\\warp_unlocks"
    config.CHECK_OVERLAY_HEADER_RESERVED_HEIGHT =
        config.CHECK_OVERLAY_HEADER_HEIGHT + config.CHECK_OVERLAY_HEADER_MAIN_Y_OFFSET

    ctx.config = config

    for key, value in pairs(config) do
        _G[key] = value
    end
end

return install
