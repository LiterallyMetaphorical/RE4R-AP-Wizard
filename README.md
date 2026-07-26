# Resident Evil 4 Remake - Archipelago

Launcher for Resident Evil 4 Remake Archipelago multiworld sessions.

## Linux

The Linux build provides the RE4R Archipelago launcher as a native desktop application.
It accepts Windows, extensionless Linux, and source-tree generators instead of
requiring `ArchipelagoGenerate.exe`.

```bash
dotnet publish src/RE4R.AP.Launcher.Linux/RE4R.AP.Launcher.Linux.csproj \
  -c Release -r linux-x64 --self-contained

./re4r-ap-launcher
```

Command-line operations are also available through
`./re4r-ap-launcher --help`.

This repository holds the Windows launcher that sets up, generates, patches,
and joins a Resident Evil 4 Remake (2023) Archipelago multiworld. It bundles
the world-patching pipeline, the in-game client scripts, and the compiled
Archipelago world, and runs the whole player workflow from one app.

> [!CAUTION]
> This is an early alpha for closed playtesting, not a finished release. It has
> had very little testing, the progression logic is only a coarse first pass,
> and bugs are close to guaranteed. Save often and expect to use the recovery
> tools below. Windows and the Steam release of Resident Evil 4 Remake are the
> only supported targets.

## Read first

- Save often, and save after boss fights and chapter transitions.
- Resident Evil 4 is mostly linear. Some areas may be cut off during parts of the story, so try to save often and collect most item checks as you go.
- REFramework loads the in-game scripts when the game starts. After the
  launcher patches, fully quit and relaunch the game once so the scripts load.
- If you finish one seed and want to start another, restart the game between
  them.
- If something looks wrong, the "Getting unstuck" section below lists the tools
  built in for exactly that.

## Project status

Current closed-playtest scope:

- Content: the full Leon main campaign, Chapters 1 to 16. Around 471 item
  locations, though the exact count depends on your options.
- Goal: complete the campaign. The launcher reports the goal to the
  Archipelago server on completion.
- Progression logic: a coarse first pass. Eight chapter-group milestones are
  each gated on their real key items (Boat Fuel and the Hexagon Pieces for the
  Lake, the Insignia Key for the Church, the Dungeon Key and Lithographic
  Stones for the castle, the animal heads and keycards for the island, and so
  on). Finer location-by-location logic inside each group is not written yet.
  Seeds are built to be completable, but placement inside a chapter group is
  not finely checked.
- Randomization modes: three presets, from a pure multiworld item shuffle up to
  full BioRand item and enemy randomization.
- Multiworld items: other players' items appear in the world as the Archipelago
  logo. Collecting one sends its location check and never enters your inventory.
- DeathLink: supported both ways, gated on the room's setting.
- In-game overlay: location markers, a scrollable message log, received and
  sent notifications on the game's native activity rail, and a goal banner.

## What the launcher does

The launcher covers both roles in a multiworld:

- Organizer: installs the prerequisites, exposes the BioRand options, runs a
  step-by-step generation guide, generates the seed against the bundled
  Archipelago world, and helps you upload it and create a room.
- Joiner: connects to a room, patches your game install for that seed, and
  launches Resident Evil 4 Remake ready to play.

It is one self-contained app. There are no separate Python, randomizer, or
client downloads.

## How it works

Three pieces do the work:

- BioRand world patch. A bundled Resident Evil 4 fork of BioRand rewrites the
  campaign's item placements for your seed and produces one game patch (`.pak`).
  The multiworld's item locations are written on top of that world by explicit
  location, so item-generation options cannot move or corrupt an Archipelago
  check.
- In-game client (REFramework Lua). An autorun script package talks to the
  Archipelago server over the standard network protocol, detects pickups,
  delivers received items, and draws the overlay.
- Archipelago world. The compiled world definition (`RE4R.apworld`) holds the
  item and location IDs, regions, options, and generation logic. It ships
  bundled with the launcher.

Check flow:

```text
in-world pickup (native or Archipelago-logo placeholder)
  -> pickup detected by the in-game client
  -> location check queued
  -> LocationChecks sent to the server
  -> server acknowledges
  -> check kept locally until acknowledged
```

Sent checks are saved and re-sent on reconnect, so a dropped connection does
not lose a check.

## Requirements

- Resident Evil 4 Remake (2023), Steam release, on Windows.
- Archipelago 0.6.7. The launcher can install it for you during setup.
- REFramework for Resident Evil 4 Remake, installed by the launcher.

## Getting started

> [!WARNING]
> Extract each new release into a fresh, empty folder. Do not copy a new
> version on top of an older extracted build.

1. Download the latest release ZIP from the Releases page and extract it into a
   new empty folder.
2. Run `RE4R.AP.Launcher.exe`.
3. On the Setup screen, let the launcher install any missing prerequisites
   (Archipelago and REFramework).
4. To join a game: enter the room address and your slot name, review the
   options the organizer chose, and let the launcher patch and launch. Then
   fully quit and relaunch the game once so the in-game scripts load.
5. To organize a game: follow the generation guide, which walks you through the
   options, generating the seed, uploading it, and creating a room.

The launcher remembers your session, so re-patching or reconnecting later does
not start over.

## Modes

Three presets set how much of the world is randomized. Archipelago's item
locations stay pinned in every mode.

- AP Item Randomization Only: the multiworld shuffles the fixed campaign
  pickups. Everything else is vanilla.
- Full BioRand Item Randomization: BioRand also re-rolls the world's non-check
  pickups. The Archipelago locations stay pinned.
- Full BioRand Item and Enemy Randomization: adds enemy randomization on top.

Changing any single option flips the preset to a Custom configuration. Options
that would change the set of check locations, or that could create a
progression softlock, are locked in Archipelago mode.

## Multiworld items

At every location that holds another player's item, the world spawns an
Archipelago-logo pickup. Collecting it sends that location's check and puts
nothing in your inventory. Your own items appear and are collected normally.

## Getting unstuck

Because this build is experimental, it ships with tools to recover from a bad
spot:

- Item markers. Unchecked locations show a floating marker. A Status-window
  toggle turns on the item identity on each marker (the vanilla item name, a
  container note, and a short id), which helps you find what a floating tag is
  pointing at and name it in a bug report.
- Debug tools. With developer tools enabled, a Debug tab exposes a manual item
  injection window (deliver a received item by hand if one failed to arrive), a
  progression-warning preview, a DeathLink simulate button, and log views.
- Archipelago commands. Connect a standard Archipelago text client to the same
  slot to use the normal server commands, for example `!hint` to locate a
  needed item, `!release` to send out your remaining items, and `!collect` to
  pull in your items after you finish. Two clients can share one slot.
- Typewriter warp. An in-game warp menu teleports you between typewriters and
  save points you have unlocked, which is useful for backtracking.
- Re-patch and reconnect. The launcher can re-patch the current session, and
  the in-game client re-sends any saved checks when it reconnects.

## Known issues

- On an inbound DeathLink the game shows its game-over screen and reloads the
  last checkpoint. The character does not play a death animation.
- Location markers for some hanging or elevated pickups can appear below the
  item's real position.
- Native-rail notifications show the item name, but the full sender and
  source-location history still needs the Archipelago client.
- Some pause-map or overlay counters can briefly disagree with the server. The
  server's `checked_locations` is authoritative.
- The progression logic is coarse (see Project status), so unusual option
  combinations can produce awkward placements. If you get stuck, see "Getting
  unstuck" above.

## Feedback

Bug reports and feedback are welcome. This project lives in the Archipelago
After Dark Discord; look for the Resident Evil 4 discussion there. https://discord.gg/fqvNCCRsu4

## Roadmap

- Closed alpha, in progress. Prove the full Leon campaign end to end: patching,
  item delivery, location checks, DeathLink, and reconnect behavior, with real
  multiworld traffic.
- Location-level logic. Replace the coarse milestone gates with finer per-area
  access rules.
- Open playtest. Broaden testing, polish the overlay and guidance, and
  stabilize the generated world and options.
- Release. Public documentation, packaging, and an Archipelago community
  release.

## Credits

- The Archipelago project and its contributors for the multiworld framework,
  protocol, and server.
- praydog for REFramework, the in-game scripting foundation this project builds
  on.
- IntelOrca and the BioRand project for the Resident Evil randomizer this
  project's world patcher is built from.
- black-sliver for the Archipelago client binding (lua-apclientpp) used by the
  in-game scripts.
- CriminalENT for the in-game repack and model swap that placed the Archipelago
  logo in the game.
- chenstack for
  [Item Adder](https://www.nexusmods.com/residentevil42023/mods/896), the
  foundation for injecting multiworld items, and
  [Item indicator](https://www.nexusmods.com/residentevil42023/mods/1063), the
  foundation for the in-world Archipelago item markers.
- JumperDenfer for the
  [RE4 Warp Mod](https://www.nexusmods.com/residentevil42023/mods/5923), the
  foundation for the typewriter warp system.
- Additional Resident Evil 4 mod authors whose work informed these systems.
  Specific techniques are credited in the source where they are used.
- The Resident Evil modding community for the tools and knowledge that made the
  world patches possible.
