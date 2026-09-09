# Resident Evil 4 Remake - Archipelago

## Credits

- The Archipelago project and its contributors for the multiworld framework, protocol, and server.
- praydog for REFramework, the in-game scripting foundation this builds on.
- IntelOrca and the BioRand project for the Resident Evil randomizer this project's world patcher is built from.
- black-sliver for the Archipelago client binding (lua-apclientpp).
- @CriminalENT for the in-game repack and model swap that placed the Archipelago logo in the game.
- @snowzzrra for the Linux Release and for The Mercenaries support
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

- **456 item locations** across the full Leon campaign, chapters 1 to 16. Includes Key Items with logic to ensure they spawn before you need them.
- **The merchant sells multiworld checks** on both his tabs: the shop for pesetas and the trade tab for spinel, each on by default at 3 a chapter (45 a seed each). See [The merchant](#the-merchant).
- **The Mercenaries can be part of the room, or the whole room.** Rank checks for every character and stage pair, with the characters and stages as the items. See [The Mercenaries](#the-mercenaries).
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
> **Random Events is experimental and multiworld-authored.** Enable its Boolean
> YAML setting only when you want it: generation picks the event set, models its
> room changes in logic, and the launcher applies that authoritative roll when
> patching. It requires item and enemy randomization, so both are forced on.

## The merchant

The merchant is a second source of checks, and by default he is part of the run
rather than an option you go looking for. Both of his tabs hold checks now: the
shop, paid in pesetas, and the trade tab, paid in spinel.

**Merchant Shop Checks.** His buy tab holds Archipelago checks. Three a chapter
by default, forty-five a seed, up to ninety at the cap. His shelf shows thirteen
at a time and the rest queue behind them, moving up as you buy, so a check is
never lost. Each row names what it really is and who it belongs to, then reads
SOLD OUT once bought.

Prices are fixed by tier - 2,500 filler, 7,500 useful, 15,000 progression - and
buying another player's item refunds spinel at the trade tab's own tiers: 1, 3
or 6. You need the pesetas up front, and you get trade currency back (about
half the price in money terms, through the exchange). Your own items are normal
spending and refund nothing.

You can set who the rows may hold: **Mixed** lets the multiworld decide,
**Local** keeps your own items on the shelf, and **Remote** turns the shop into
a trading post where every row belongs to somebody else.

**Merchant Trade Checks.** His trade tab holds checks too, bought with spinel
instead of pesetas. Three a chapter by default, forty-five a seed. Seven slots
show at once, and a claimed slot rotates to the next check straight away, so the
tab keeps offering something as long as checks remain.

Spinel prices are fixed by tier as well - 1 filler, 3 useful, 6 progression -
and the item pool mints exactly enough spinel to pay for every trade check in
the seed, so the tab is always affordable. The nineteen Merchant Requests still
pay their spinel on top of that.

Two things work differently here. Trade checks never refund, and the owners
setting does not apply to them, so the trade tab is always mixed no matter what
you chose for the shelf.

The currency exchange is there whatever rate you set, zero included: Velvet Blue
always available at 2 spinel, and the three gemstones at 3, 4 and 5, restocking
every chapter. Leftover spinel still turns into money.

One caution before you cash out: the logic that paces trade checks counts
only the spinel the multiworld minted, and spinel you spend on gemstones or
Gold Tokens is invisible to it. Keep enough back for the trade checks still
on the tab, or only the merchant's own request rewards can make it up.

**Merchant Gear.** On by default. His weapons, attachments, case sizes,
knives and crafting recipes leave the buy tab and join the multiworld, the
Deluxe and Separate Ways guns included. Your next gun is a check somewhere out
there, possibly in another player's world. Expect a different power curve. Gear
never gates logic, so a seed can always be finished with what the world hands
you.

The case sizes and the knives are progressive: each Progressive Attache Case
you receive is the next size up from the one you carry, and each Progressive
Knife is the next knife you do not own, the Fighting Knife first and then the
Primal (which only enters the pool with Bonus Weapons on). Order of arrival
never matters, and none of them is ever wasted.

Consumable supplies stay: herbs, first aid, resources, gunpowder and grenades
restock at every chapter. Ammo deliberately does not, because you craft it and
the multiworld now carries it.

**Starting Arsenal.** Two pool weapons in your case from the campaign's first
moment, with ammo to match. Each one leaves the pool, so nobody finds a second
copy. Set it to zero if you would rather start with nothing.

## The Mercenaries

**Included Content**, at the top of your settings, picks what the multiworld
covers: Main Campaign, The Mercenaries, or both. Separate Ways is listed and
greyed out as coming soon.

With The Mercenaries included, every character and stage pair has rank checks.
**Mercenaries Score Checks** decides which ranks count: A only (32 checks), A
and S (64, the default), or every rank up to S++ (128). Only Rank A can hold
progression, so no seed ever depends on a top score.

The characters and stages are the items. One of each starts with you; the rest
stay locked in the mode's menus until their item arrives, with a toast when it
does. A campaign item received while a Mercenaries run is in progress waits
until you are back in the campaign.

A room that includes only The Mercenaries needs no campaign patch: the launcher
skips BioRand and installs the in-game mod alone, and Rank A on every unlocked
pair is the goal. The Checklist has a Mercenaries section with the stages side
by side and each character's rank marks.

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

Clicking Join a Multiworld opens Configure Archipelago Settings first, because
your settings file has to exist before your host can generate anything. That
screen lists the two files your host needs, with a button for each:

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

- **Included Content** - Main Campaign, The Mercenaries, or both. See [The Mercenaries](#the-mercenaries).
- **Mercenaries Score Checks** - which ranks count as checks: A only, A and S, or every rank.
- **Difficulty** - the difficulty you'll actually play. Hardcore and Professional remove the few spots that can't be collected on those difficulties, so it needs to match your save.
- **Death Link** - share deaths with the room.
- **Progression Balancing** - how hard the multiworld works to keep your important items early. 50-70 suits RE4R's gated chapters; lower values mean longer waits on other players.
- **Check Guidance** - the ceiling for in-game Markers.
- **Allow Missable Locations** - off by default, keeping progression items off spots you can permanently lose: ones you can walk past for good, and small-key drawers, since a discarded Small Key can seal one. Turn it on for riskier seeds where both can hold progression.
- **Shuffle Keycards** - off by default; the island keycards stay at their native spots.
- **Minimize Backtracking + Side Areas** - off by default; when on, keeps important checks on the main path.
- **Unlocked Typewriters** - save points you can warp to from the start. In a hand-written settings file, name them by their typewriter name ("Farm Typewriter") or by their stage id (43300); either works.
- **Priority and excluded locations** - the location picker marks spots that must hold an important item, or must not. Marking a whole key-gated region as priority (the Castle, the Island) asks for more than the item pool can deliver, because the items that open that region can never sit inside it: the generator keeps as many of those spots as it can fill and sets the rest back to normal, and its log says how many.

## How it works

- **World patch.** A Resident Evil 4 fork of BioRand rewrites the campaign's item placements for your seed into one `.pak`. Archipelago's locations are written on top by explicit location, so randomization can never move a check.
- **In-game client.** REFramework Lua scripts talk to the Archipelago server, detect pickups, deliver received items, and draw the overlay.
- **Archipelago world.** `RE4R.apworld` holds the item and location IDs, the areas and their logic, and the options. It ships with the Wizard.

A check is only forgotten locally once the server acknowledges it, so a dropped connection never loses one.

## Known issues

**Some pickups can grant the item and send nothing.** The main cause found so
far is fixed in this build (a pickup taken with a full case, or as a weapon or
key item, now sends), but the report is still worth making because a miss is
silent. **The tell: if an Archipelago-logo placeholder lands in your inventory,
that check did not send** - a placeholder is meant to vanish on pickup. Nothing
is permanently lost. **Force Check** in the Something's Wrong tab sends it, one
location at a time. If it happens, please send `re2_framework_log.txt` grabbed
WITHOUT relaunching the game, since it is overwritten every launch.

Smaller things:

- The merchant backlog is only in the log, not on screen.
- A summoned boat may face an odd direction at its pier.
- An inbound DeathLink shows the game-over screen with no death animation.
- Some overlay counters can briefly disagree with the server.
- If a Marker points at nothing, please report it with a screenshot (Developer
  marker detail enabled, ideally) and where you were standing.

## In-Game

Press **Insert** to open the Archipelago window while in-game. A welcome note waits for you in the Hunter's Lodge at the start; the Guidance tab can show the same getting-started guide again any time.

### The Checklist

The home tab, and the answer to "where do I go next". It has a section for each kind of content the room includes, each with its own count and progress bar:

- **Main Campaign** lists every typewriter save point with how many checks are found near it, out of how many. Expand one to see the areas it covers with their own counts, and warp straight there. Typewriter warps unlock once you have found that typewriter in game.
- **Merchant** lists the shop's checks and the trade tab's by chapter, marks the bought ones, and says which chapters have not released yet.
- **Mercenaries** shows the stages side by side with each character's rank marks.

### Guidance

Unchecked spots show a floating **[AP]** Marker reading, in order: the tag, the chapter it belongs to, the distance, the height difference, then the area and item detail. This tab turns Markers on and off, sets how far away they appear, and controls how much they say:

- **Minimal** - distance and height only.
- **Basic** - adds the chapter and the area.
- **Locate** - adds what the item looked like in the vanilla game, and whether
  it is in a container or hanging (shoot it down).
- **Identify** - adds the real item and who it belongs to. A spoiler, and the
  level a bought hint always shows.

Your settings file picks the level you start at; this tab can change it any
time, and the choice sticks for that seed.

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
