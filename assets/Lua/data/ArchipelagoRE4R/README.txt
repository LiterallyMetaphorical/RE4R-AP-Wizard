Copy this `ArchipelagoRE4R` folder into the game's `reframework\\data` directory.

The Step 1 bridge writes:
- `bridge_state.json`: live game-state snapshot from REFramework
- `bridge_command.json`: command file written by the Python client
- `stage_chapter_map.json`: stage-to-chapter lookup used by the in-game status panel

The matching Lua script lives at:
- `reframework\\autorun\\ArchipelagoRE4R.lua`
