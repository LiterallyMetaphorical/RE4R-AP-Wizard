# Resident Evil 4 Remake - Archipelago

## Credits

- The Archipelago project and its contributors for the multiworld framework, protocol, and server.
- praydog for REFramework, the in-game scripting foundation this builds on.
- IntelOrca and the BioRand project for the Resident Evil randomizer this project's world patcher is built from.
- black-sliver for the Archipelago client binding (lua-apclientpp).
- @CriminalENT for the in-game repack and model swap that placed the Archipelago logo in the game.
- @snowzzrra for the Linux Release
- chenstack for [Item Adder](https://www.nexusmods.com/residentevil42023/mods/896), the foundation for injecting multiworld items, and [Item indicator](https://www.nexusmods.com/residentevil42023/mods/1063), the foundation for the in-world Markers.
- JumperDenfer for the [RE4 Warp Mod](https://www.nexusmods.com/residentevil42023/mods/5923), the foundation for the typewriter warp system.
- Additional Resident Evil 4 mod authors whose work informed these systems; specific techniques are credited in the source where they are used.
- The Resident Evil modding community for the tools and knowledge that made the world patches possible.

> [!CAUTION]
> Early alpha for playtesting. Bugs are likely. Save often, and see
> [When something goes wrong](#when-something-goes-wrong) - the mod ships
> recovery tools for exactly that. Windows and the Steam release of Resident
> Evil 4 Remake (2023) are the only supported targets.

## What gets randomized

- **474 item locations** across the full Leon campaign, chapters 1 to 16. Includes Key Items with logic to ensure they spawn before you need them.
- Other players' items appear as Archipelago-logo pickups. Collecting one sends its check and puts nothing in your inventory. Your own items are collected normally.
- Locations that cannot be collected in game are excluded from the pool, so nothing gets stranded on them.

Three randomization presets, chosen when you patch. Archipelago's locations stay pinned in all of them, so world options can never move or corrupt a check:

- **AP Item Randomization Only** - the multiworld shuffles the fixed campaign
  pickups; everything else is vanilla.
- **Full BioRand Item Randomization** - BioRand also re-rolls the world's
  other pickups.
- **Full BioRand Item and Enemy Randomization** - adds enemy randomization.

Changing any single option flips you to a Custom configuration. Options that
would change the set of checks, or create a softlock, are locked out.

> [!WARNING]
> **Leave Random Events off.** It reshapes the world - locked doors, removed
> ladders and walls, relocated key items - and the logic is not yet equipped to
> handle any of it. A seed may become unfinishable. It is off by default, and
> turning it on asks you to confirm first, the full randomization preset
> included.

## What You Need

- Resident Evil 4 Remake (2023) on Steam, including the **Separate Ways** and **Treasure Map: Expansion**
  DLCs.
- Everything else - REFramework, the world patcher, the in-game client - comes with the Wizard and installs itself.
- Hosting a multiworld additionally needs Archipelago 0.6.7.

## Install

1. Download the latest release ZIP from the Releases tab and extract it into a **new empty folder**. Never extract on top of an older version.
2. Run `RE4R.AP.Launcher.exe`. It opens on Setup Status - let it install
   anything missing.
3. You can then move down either path: Host a Multiworld or Join a Multiworld from someone else who is hosting for you
4. The Wizard will then walk you through the required steps

You only run the Wizard to set up or when the seed changes. Day to day, just launch the game!

### Joining someone else's multiworld

Someone else hosts; you just play. You do not need an Archipelago install of
your own - the launcher patches your game and talks to the room by itself -
and the launcher folder can live anywhere, never inside the game's folder.

Since you are not hosting, your host needs two files from you before a room
can exist. Configure Archipelago Settings lists both when you make your
settings, with a button that opens the folder holding the apworld:

- **RE4R.apworld** goes in their Archipelago folder, under `custom_worlds`
- **RE4R_YourSlotName.yaml** goes in the `Players` folder next to it

They then generate with `Generate.py` in an Archipelago 0.6.7 install (only
that version is supported right now). The archipelago.gg website cannot
generate community games, so it has to be done on their PC.

Hosting is normal after that: generating writes an `AP_*.zip` into their
output folder, they upload it to archipelago.gg/uploads and create the room,
then send you the room address. Enter it in Join a Multiworld with your slot
name and patch.

### Your settings file

- **Difficulty** - the game's own difficulty.
- **Death Link** - share deaths with the room.
- **Progression Balancing** - how hard the multiworld works to keep your important items early. 50-70 suits RE4R's gated chapters; lower values mean longer waits on other players.
- **Check Guidance** - the ceiling for in-game Markers.
- **Allow Missable Locations** - off by default, keeping progression items off spots you can permanently lose: ones you can walk past for good, and small-key drawers, since a discarded Small Key can seal one. Turn it on for riskier seeds where both can hold progression.
- **Shuffle Keycards** - off by default; the island keycards stay at their native spots.
- **Minimize Backtracking + Side Areas** - off by default; when on, keeps important checks on the main path.
- **Unlocked Typewriters** - save points you can warp to from the start.

## How it works

- **World patch.** A Resident Evil 4 fork of BioRand rewrites the campaign's item placements for your seed into one `.pak`. Archipelago's locations are written on top by explicit location, so randomization can never move a check.
- **In-game client.** REFramework Lua scripts talk to the Archipelago server, detect pickups, deliver received items, and draw the overlay.
- **Archipelago world.** `RE4R.apworld` holds the item and location IDs, the areas and their logic, and the options. It ships with the Wizard.

A check is only forgotten locally once the server acknowledges it, so a dropped connection never loses one.

## Known issues

- An inbound DeathLink shows the game-over screen with no death animation.
- Some overlay counters can briefly disagree with the server
- RE4R AP has recently still struggled with missing item placements if you find one, please send a screenshot of the item (With Developer type Markers enabled, ideally) and describe where you are.
- If a Marker points at nothing, please also report that in the same way.

## In-Game

Press **Insert** to open the Archipelago window while in-game. On your first chapter a short getting-started guide appears by itself; you can reopen it any time from the Guidance tab.

### The Checklist

The home tab, and the answer to "where do I go next". Every typewriter save point is listed with how many checks are found near it, out of how many. Expand one to see the areas it covers with their own counts, and warp straight there. Typewriter warps unlock once you have found that typewriter in game.

### Guidance

Unchecked spots show a floating **[AP]** Marker reading, in order: the tag, the chapter it belongs to, the distance, the height difference, then the area and item detail. This tab turns Markers on and off, sets how far away they appear, and controls how much they say:

- **Basic** - distance, height, area.
- **Locate** - adds what the item looked like in the vanilla game, and whether
  it is in a container or hanging (shoot it down).
- **Identify** - adds the real item and who it belongs to. Full spoilers, so
  it requires Developer Tools.

Markers from another chapter are dimmed and tagged, because RE4R reuses areas between chapters; there is a toggle to hide them. Locations you have bought a hint for show a magenta **[HINT]** Marker anywhere in the area.

### Hints

Spends Archipelago hint points two ways: buy a hint for one of your own items, or for an unchecked location near you. Hints you already own are listed with where they point.

### Something's Wrong

The recovery tab.

- **Force Check** marks a location complete and releases the item it held. Use it when a check refuses to send - and please report it!
- **Release / Collect** unlocks after you reach your goal: send your remaining items to their owners, or pull your own items home.

### Server

Connection state, address, slot, and whether the room's seed matches this session. Rooms on archipelago.gg sleep after a couple of hours of inactivity and can wake on a different address - this is where you update it.

### Message Log

A scrollable history of everything that happened, plus a box for chat and any Archipelago server command.

### Debug (Developer Tools only)

Enable **Developer Tools** in REFramework's script menu. **Diagnostics** at the top gathers your build, seed, slot, connection and counts into one block you can copy straight into a bug report. Below that: the pickup probe, manual item injection, harmless simulations, and authoring tools.

## When something goes wrong

**A check did not send.** Something's Wrong -> pick the location -> Force Check. Report it with the location name.

**An item never arrived.** Reconnect first (Server tab) - the mod re-delivers anything missed. If it still does not appear, Debug has a manual injector.

**Disconnected, or the room fell asleep.** Open your room page in a browser to wake it, then check the address in the Server tab. The Wizard also has **Fix Address Automatically**.

**Checks you already found look unfound.** The mod re-sends its saved checks on reconnect; give it a few seconds. The server's list is authoritative.

**Items lost after dying or reloading.** They are re-delivered when you load a save. If not, reconnect.

**The game crashes at startup.** Usually REFramework rather than this mod. Rename `dinput8.dll` to launch without it and confirm, then send the log.

**Nothing above helps.** A standard Archipelago text client can share your slot and use normal server commands. Your host can also hand you a specific item from the room page console: `/send YourSlotName "Item Name x1"`.

### Reporting a bug

Copy the Diagnostics block from the Debug tab, say what you were doing, and
attach:

- `re2_framework_log.txt` from your RE4R folder. Mod lines are tagged
  `[RE4R AP]`. **The game truncates this on restart** - grab it first.
- `%APPDATA%\RE4R-AP\logs\` for Wizard problems.
- If asked, `reframework\data\ArchipelagoRE4R\drop_audit.json`, which records which item spots the game actually spawned during your run.

Reports go to the Archipelago After Dark Discord, in the Resident Evil 4 discussion: https://discord.gg/fqvNCCRsu4

## Linux (experimental)

A Linux build is included: it cross-compiles
from Windows and runs the Windows patcher through Proton. Windows is the primary supported platform for this playtest.

```bash
dotnet publish src/RE4R.AP.Launcher.Linux/RE4R.AP.Launcher.Linux.csproj \
  -c Release -r linux-x64 --self-contained
./re4r-ap-launcher
```

## License

MIT, the same license BioRand uses. See [LICENSE](LICENSE).

Each release also bundles other people's work, under their own licenses:

- BioRand, by Ted John, MIT. Its notice ships as
  `assets/THIRD-PARTY-NOTICES-BioRand.txt`, and the exact build bundled is
  recorded in `assets/BIORAND_PROVENANCE.txt`.
- lua-apclientpp, by black-sliver, MIT. Its notice ships as
  `assets/native/THIRD-PARTY-NOTICES-lua-apclientpp.txt`, and its binary
  distribution may include OpenSSL under Apache 2.0.

REFramework is downloaded from its own GitHub releases during setup rather than
bundled here, so it stays under praydog's terms.
