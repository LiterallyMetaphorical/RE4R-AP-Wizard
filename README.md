# Resident Evil 4 Remake - Archipelago

## What You Need

- Resident Evil 4 Remake (2023) on Steam, including the **Separate Ways** and **Treasure Map: Expansion**
  DLCs.
- Everything else - REFramework, the world patcher, the in-game client - comes with the Wizard and installs itself.
- Hosting a multiworld additionally needs Archipelago 0.6.7.

## Credits

- The Archipelago project and its contributors for the multiworld framework, protocol, and server.
- praydog for REFramework, the in-game scripting foundation this builds on.
- IntelOrca and the BioRand project for the Resident Evil randomizer this project's world patcher is built from.
- black-sliver for the Archipelago client binding (lua-apclientpp).
- @CriminalENT for the in-game repack and model swap that placed the Archipelago logo in the game.
- @snowzzrra for advice, development help, the Linux release, and the entire Mercenaries AP support.
- chenstack for [Item Adder](https://www.nexusmods.com/residentevil42023/mods/896), the foundation for injecting multiworld Items, and [Item indicator](https://www.nexusmods.com/residentevil42023/mods/1063), the foundation for the in-world Markers.
- JumperDenfer for the [RE4 Warp Mod](https://www.nexusmods.com/residentevil42023/mods/5923), the foundation for the Typewriter warp system.
- Additional Resident Evil 4 mod authors whose work informed these systems; specific techniques are credited in the source where they are used.
- The Resident Evil modding community for the tools and knowledge that made the world patches possible.

> [!CAUTION]
> Beta for playtesting. Bugs are likely. Save often, and see
> [Something's Wrong](#somethings-wrong) - the mod ships recovery tools for
> exactly that. Windows and the Steam release of Resident Evil 4 Remake (2023)
> are the supported targets; the Linux build is experimental.

> [!WARNING]
> **You may receive a key item early, but using it early may have unintended side effects, including a softlock.**
> If you're unsure, just proceed through the playthrough in the intended order.
> Using the fuel without ever visiting Fish Farm is fine, but at least walk into the area and check the header to confirm there are no Progression items there. Even so, you may leave behind something useful.

## Starting Arsenal

Unless disabled, you start with 2 random weapons as your Starting Arsenal, drawn from up to 23 guns: the Merchant's original stock, the three guns found in the world, the Deluxe and Separate Ways guns that work in Leon's campaign, and the Bonus Weapons if enabled. The guns you start with leave the AP pool; the rest are scattered amongst the Multiworld. Your starting guns can also spawn with attachments. A scope-supported gun starts with its scope 100% of the time, and every other gun has a 50% chance of one compatible attachment.

Bonus Weapons (Handcannon, Chicago Sweeper, Primal Knife) only enter the pool when your settings file allows them, because owning them writes a permanent unlock to your game profile.

## Item Randomization

- **456 Item Locations** are randomized across the full Leon campaign, including Key Items (with logic to ensure they spawn before you need them). Hardcore and Professional have one fewer, a Bindery stone the game will not hand over on those difficulties.
- Other players' Items appear as Archipelago-logo pickups. Collecting one sends its check and puts nothing in your inventory. Your own Items are collected normally.

Three randomization presets, chosen when you patch. Archipelago's Locations stay pinned in all of them, so world options can never move or corrupt a check:

- **AP Item Randomization Only** - the multiworld shuffles the fixed campaign
  pickups; everything else is vanilla.
- **Full BioRand Item Randomization** - BioRand also re-rolls the world's
  other pickups.
- **Full BioRand Item and Enemy Randomization** - adds enemy randomization.

Changing any single option flips you to a Custom configuration. Options that
would change the set of checks, or create a softlock, are locked out.

## The Merchant

### Buy Tab

- The Merchant deals in Checks now, on both the Buy and Trade tabs.
- With Shuffle Merchant Gear on (the default), everything he sold as gear is in the AP Pool: weapons, attachments, case upgrades, knives, recipes, body armor and his trade stock. What stays on the shelf is the restocked Staples (healing and crafting), tune-ups and selling.
- Buy tab Checks cost 2,500 / 7,500 / 15,000 pesetas by tier. Buying another player's item refunds you 1 / 3 / 6 Spinel, so helping a friend costs money up front and pays back in trade currency. Your own items are normal spending and refund nothing.
- New Checks are unlocked at every Chapter. The Buy tab shows at most 20 unbought Checks at once; the rest sit in a queue until you buy more.
- The shop is restocked every Chapter with "Staples" to aid you with healing and crafting.

### Trade Tab

- Trade tab Checks cost 1 / 3 / 6 Spinel by tier, on seven tiles that rotate as you buy.
- Exchange Velvet Blue at 2 Spinel, as often as you like, and the three gemstones at 3, 4 and 5 Spinel, restocked every Chapter.
- Turn Spinel into money quickly with Velvet Blue, or invest into gems to slot into your Treasures for a larger profit.
- The Multiworld mints exactly enough Spinel to afford every Trade Check, and the Merchant's Requests provide more on top of that, so there's a bit of forgiveness if a Spinel check is left behind.
- A tile with nothing behind it displays the "Claimed" state.
- Trade Checks never refund.

## Receiving Items

- Items arrive while the game is playable, never mid-load or in a cutscene; anything sent while you're not in a playable state is queued until you are.
- Guns, grenades, and knives go to typewriter Storage, never your case.
- Ammo, health, gunpowder and resources go into your case; if it is full, or nothing fits, they go to Storage too.
- Key items, tokens, charms and recipes reach the Key Items tab, treasures the Treasure tab, Pesetas and Spinel your wallet.
- Case upgrades and knives are progressive: each Progressive Attache Case is the next size up from the one you carry, each Progressive Knife the next knife you do not own (the Fighting Knife, then the Primal). Order of arrival never matters.

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

## Typewriters

You're likely familiar with the Typewriters spread out across the world of RE4R, like the one beside the welcome note where you start. They save your game - you're encouraged to save often. AP Items you send out and AP items you receive are saved and mirrored by the AP server, but any "normal" items in RE4R will be lost, just like normal progression.

Typewriters also allow you to Warp back to them once discovered (or from the start, if your settings file unlocked them). Be warned that this should be a last resort, and is known to have issues with unloaded areas, strange lighting, etc.

## REFramework, Menus, & Displays

Press Insert at any time to open the Archipelago window (this is REFramework's toggle key, which will hide/show menus at any time).

The UI Overlay sits in the top right corner and always shows your current Chapter, Area & number of Checks you have found there.

The Checklist tab is your hub for progress across everything in the room: the Main Campaign, The Mercenaries, and (eventually) Separate Ways. The bar at the top counts every Check found against every Check the room holds. Below it, each content has its own section with its own count and bar. Main Campaign lists every Typewriter & the Checks near it. Open a Typewriter to see the Chapters & Areas it covers, and a Warp button. Merchant and Mercenaries each have their own sections as well.

The Guidance tab controls various assistance features that come with RE4R AP. Unchecked AP item locations show a floating [AP] Marker with the distance, the chapter it belongs to, and how far above or below you it is. The Guidance tab allows you to turn Markers on or off, adjust how far away they appear, and make them more or less detailed. You can also reopen the welcome note as a window from the Guidance tab at any time.

The Hints tab spends hint points to learn where an item is. Hints for items in your world will automatically show their [AP] Marker, while Hints about your items in other worlds get pinned on screen under Multiworld Hints. Multiworld Hints can be hidden in the Guidance tab.

Something's Wrong has recovery tools if a Check refuses to send. Force Check counts immediately and clears the spot's marker. And waiting on another player is normal in a Multiworld: your next key item may be in someone else's game.

The Server tab shows connection state, address, slot, and whether the room's seed matches this session. Rooms on archipelago.gg sleep after a couple of hours of inactivity and can wake on a different address - this is where you update it.

The Message Log is a scrollable history of everything that happened, plus a box for chat and any Archipelago server command.

## Keys, Drawers and Ashley

By default, Small Keys stay in your own world, each placed no later than the drawer it opens. A locked drawer is never waiting on another player. If Small Keys get shuffled into other Worlds, it's possible they could get to you after you pass the drawer.

While you play as Ashley, her own keys reach her directly, even mid-section. Everything else waits until you are Leon again.

## Debug Tab & Developer Tools

The Debug tab is hidden by default and nothing in it is needed to play. To show it, open the REFramework menu (Insert), find ArchipelagoRE4R under Script Generated UI, and tick **Developer Tools (Debug tab)**.

The one tool you may need is Item Injection. If an item another player sent you never arrived, first reconnect from the Server tab: the mod re-delivers anything it missed. If it is still not there, open Item Injection. The items you were sent most recently sit under Recent, one button each; anything else you can find by Category and name. Set the Count, press Inject Item, and the Status line tells you where it landed. Only inject what the Multiworld actually sent you.

The rest of the tab is for the people fixing bugs. One warning: the DeathLink simulation really does kill you.

## Your Settings File

The Wizard writes it for you from the Configure Archipelago Settings screen. For hand edits:

- **Included Content** - Main Campaign, The Mercenaries, or both. See [The Mercenaries](#the-mercenaries).
- **Mercenaries Score Checks** - which ranks count as checks: A only, A and S, or every rank.
- **Difficulty** - the difficulty you'll actually play. Hardcore and Professional remove the spot that can't be collected on those difficulties, so it needs to match your save.
- **Merchant Shop Checks per Chapter** and **Merchant Trade Checks per Chapter** - how many checks the Buy tab and the Trade tab release each chapter (3 each by default, 0 turns a tab off).
- **Merchant Checks** - who the Buy tab's rows may hold: Mixed, Local (your own items), or Remote (a trading post; needs another world in the room).
- **Shuffle Merchant Gear** - on by default; everything the merchant sold as gear joins the pool. Starting Arsenal, Bonus Weapons and the Trade tab need it on.
- **Bonus Weapons** - lets the Handcannon, Chicago Sweeper and Primal Knife into the pool (a permanent profile unlock).
- **Starting Arsenal** and **Starting Arsenal Types** - how many guns you start with (0 to 2) and which types the draw may take.
- **Random Weapon Stats** - BioRand's weapon randomization: off, stats only, or full random upgrade trees.
- **Random Events** - experimental; the multiworld chooses the world's random events, and a moved check keeps its name at its new spot.
- **Death Link** - share deaths with the room.
- **Progression Balancing** - how hard the multiworld works to keep your important items early. 50-70 suits RE4R's gated chapters; lower values mean longer waits on other players.
- **Check Guidance** - whether in-game Markers are allowed, and whether they may show rarity colours.
- **Marker Detail** - the level Markers start at (Minimal, Basic, Locate, Identify); the Guidance tab can change it any time.
- **Allow Missable Locations** - off by default, keeping progression items off spots you can permanently lose: ones you can walk past for good, and small-key drawers, since a discarded Small Key can seal one. Turn it on for riskier seeds where both can hold progression.
- **Shuffle Keycards** - off by default; the island keycards stay at their native spots.
- **Minimize Backtracking + Side Areas** - off by default; when on, keeps important checks on the main path.
- **Unlocked Typewriters** - save points you can warp to from the start. Name them by their typewriter name ("Farm Typewriter") or by their stage id (43300); either works.
- **Priority and excluded locations** - the location picker marks spots that must hold an important item, or must not. Marking a whole key-gated region as priority (the Castle, the Island) asks for more than the item pool can deliver, because the items that open that region can never sit inside it: the generator keeps as many of those spots as it can fill and sets the rest back to normal, and its log says how many.

## Install

1. Download the latest release ZIP from the Releases tab and extract it into a **new empty folder**. Never extract on top of an older version, and ideally don't install to your RE4R installation either.
2. Run `RE4R.AP.Launcher.exe`. It opens on Setup Status - let it install
   anything missing.
3. You can then move down either path: Host a Multiworld or Join a Multiworld from someone else who is hosting for you
4. The Wizard will then walk you through the required steps

You only run the Wizard to set up, when the Seed changes, or you're making a bug report. Day to day, just launch the game!

### Joining Someone Else's Multiworld

If you aren't hosting, you do not need an Archipelago install of
your own - the launcher patches your game and talks to the room by itself.

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
then send you the room Address. Enter it in Join a Multiworld with your Slot
name and patch.

## How It Works

- **World patch.** A Resident Evil 4 fork of BioRand rewrites the campaign's item placements for your seed into one `.pak`. Archipelago's locations are written on top by explicit location, so randomization can never move a check.
- **In-game client.** REFramework Lua scripts talk to the Archipelago server, detect pickups, deliver received items, and draw the overlay.
- **Archipelago world.** `RE4R.apworld` holds the item and location IDs, the areas and their logic, and the options. It ships with the Wizard.

A check is only forgotten locally once the server acknowledges it, so a dropped connection never loses one.

## Known Issues

- Using Key Items out of the intended order of progression can and often will have unintended effects on the game, including softlocks
- Some pickups can grant the item and send nothing. The tell is an Archipelago logo left in your inventory. Force Check it in Something's Wrong and report the location in Discord.
- The Buy tab shows at most 20 unbought Checks at once. The rest get queued until you buy more. The Checklist still lists them all.
- Typewriter Warps can land you in an area that has not finished loading, with odd lighting or missing objects. Save first; last resort only.
- An inbound DeathLink shows the game-over screen with no death animation.
- A summoned boat may face an odd direction at its pier.
- The overlay's counters can briefly disagree with the server. The server is the correct one.
- Hardcore and Professional runs have one Check fewer by design (a Lithographic stone). If another stone there refuses to be picked up, report it.
- Random Events are experimental. A moved Check keeps its name but not its old spot; its Marker follows it.

## Something's Wrong

**A check did not send.** Something's Wrong -> pick the Location -> Force Check. Report it with the Location name.

**An Item never arrived.** Reconnect first (Server tab) - the mod re-delivers anything missed. If it still does not appear, Debug has a manual injector.

**Disconnected, or the room fell asleep.** Open your room page in a browser to wake it, then check the Address in the Server tab. The Wizard also has **Fix Address Automatically**.

**Checks you already found look unfound.** The mod re-sends its saved checks on reconnect; give it a few seconds. The server's list is authoritative.

**Items lost after dying or reloading.** They are re-delivered when you load a save. If not, reconnect.

**The game crashes at startup.** Usually REFramework rather than this mod. Rename `dinput8.dll` to launch without it and confirm, then send the log.

**Nothing above helps.** A standard Archipelago text client can share your Slot and use normal server commands. Your host can also hand you a specific Item from the room page console: `/send YourSlotName "Item Name x1"`.

### Reporting A Bug

For every bug or issue, open the RE4R AP Wizard and press Generate Bug Report (bottom right). It packs everything I need into one .zip, which you can send to me in the Archipelago After Dark Discord, in the Resident Evil 4 discussion: https://discord.gg/fqvNCCRsu4

Ideally, do this before you relaunch the game (not viable for a crash, obviously), since RE4R wipes its log file every time it starts. The Wizard keeps a copy of the last log it saw, but the freshest evidence is the log from the run where things went wrong.

## Linux

A Linux Build is included; it cross-compiles
from Windows and runs the Windows patcher through Proton. Windows is the primary supported platform for this playtest.

```bash
dotnet publish src/RE4R.AP.Launcher.Linux/RE4R.AP.Launcher.Linux.csproj \
  -c Release -r linux-x64 --self-contained
./re4r-ap-launcher
```

## Disclosure

Application code is AI-assisted and manually reviewed. All player-facing assets, including art like the Archipelago 3D Model & "AP Wizard Guy" mascot, were human-created.

## License

MIT, the same license BioRand uses. See [LICENSE](LICENSE).

Each release also bundles other people's work, under their own licenses:

- BioRand, by Ted John, MIT. Its notice ships as
  `assets/THIRD-PARTY-NOTICES-BioRand.txt`, and the exact Build bundled is
  recorded in `assets/BIORAND_PROVENANCE.txt`.
- lua-apclientpp, by black-sliver, MIT. Its notice ships as
  `assets/native/THIRD-PARTY-NOTICES-lua-apclientpp.txt`, and its binary
  distribution may include OpenSSL under Apache 2.0.

REFramework is downloaded from its own GitHub releases during setup rather than
bundled here, so it stays under praydog's terms.



