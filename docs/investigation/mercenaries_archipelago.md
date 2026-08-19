# 1 Executive feasibility verdict

**Verdict: PRODUCTION IMPLEMENTED AND LIVE VALIDATED.**

Archipelago mapping is fully implemented across APWorld, REFramework Lua runtime, and Launcher (Core, Windows WPF, and Linux Avalonia):
- 32 character/stage combinations (8 playable character loadouts x 4 stages).
- 128 Mercenaries locations with configurable score-check density (Rank A Only, Standard [A, S], Full [A, S, S+, S++]).
- Deterministic starting loadout precollection (1 character + 1 stage).
- In-memory virtual selection gating on character and stage select GUIs without mutating vanilla save data.
- Complete domain isolation between campaign and Mercenaries runtimes.
- In-game Mercenaries checklist embedded in REFramework UI (*The Checklist* tab).

**Live Runtime Validation Summary:**
- **Probe 1:** Discovered REFramework concrete types (`chainsaw.MercenariesManager`, `MercenariesModeController`, `Cp1021*` behaviors).
- **Probe 2 & 3:** Confirmed `IsResult` transition boundary, `StageKind` (0..3), `PlayerCharacterWithCostumeKind` (0..7), live score decoding, and restart/quit exclusions.
- **Probe 3.1 & Production:** Continuous result polling from `Cp1021GameClearResultGuiBehavior._OpenParam` proved robust for death and extermination runs.
- **Selection Gating:** Type dumps revealed overloaded `isUnlock` methods on `Cp1021StageSelectGuiBehavior` and `Cp1021CharacterSelectGuiBehavior` plus `onInputCheckEvent`, which are hooked in-memory to enforce Archipelago item ownership.


# 2 Current Mercenaries structure

## Public source-backed roster and maps

The content baseline comprises:

- Characters: Leon (Default), Leon (Pinstripe), Luis, Krauser, HUNK, Ada (Default),
  Ada (Dress), Wesker (8 playable selection entries).
- Maps: Village, Castle, Island, Docks (4 maps).
- Cartesian content: 8 x 4 = **32 character/map pairs**.
- Canonical map identifier: `chainsaw.MercenariesDefine.StageKind`.
- Canonical character/costume identifier: `chainsaw.MercenariesDefine.PlayerCharacterWithCostumeKind`.

Canonical AP names for locations:

`Mercenaries - <Character> - <Stage> - <Rank>`

This report uses `Stage` for canonical map labels even where game UI says “map”.

## Ranks and thresholds

| Rank | Engine ScoreRank enum | Score threshold | AP display name | AP interpretation |
|---|---|---:|---|---|
| C | `C = 0` | 0 | C | Baseline / threshold entry (not default check) |
| B | `B = 1` | 50,000 | B | Optional low-threshold profile |
| A | `A = 2` | 100,000 | A | Recommended baseline |
| S | `S = 3` | 200,000 | S | Recommended strong-run threshold |
| S+ | `SS = 4` | 500,000 | S+ | Full profile (engine calls this SS) |
| S++ | `SSS = 5` | 1,000,000 | S++ | Expert profile (engine calls this SSS) |

Note on internal naming: RE Engine enums use `SS` for S+ and `SSS` for S++. Display
and AP naming will map `SS -> S+` and `SSS -> S++` while preserving internal enum values.

## Canonical Stage Mapping

The authoritative engine enum is `chainsaw.MercenariesDefine.StageKind`:

- `StageKind.Invalid = -1`
- `StageKind.MerStage_00 = 0` -> **Village** (raw CurrentStageID = 40200)
- `StageKind.MerStage_01 = 1` -> **Castle** (raw CurrentStageID = 50300, 50301)
- `StageKind.MerStage_02 = 2` -> **Island** (raw CurrentStageID = 66102)
- `StageKind.MerStage_03 = 3` -> **Docks** (raw CurrentStageID = 69900)

Raw `CurrentStageID` changes mid-run (e.g. Castle 50300 -> 50301 -> 50300) and is
retained solely as a diagnostic sanity check. `StageKind` is the canonical identity.

## Canonical Character and Loadout Representation

The engine distinguishes:

1. Base character: `chainsaw.MercenariesDefine.PlayerCharacterKind` (6 entries):
   - `Chi0 = 0` -> Leon
   - `Chi1 = 1` -> Luis
   - `Chi2 = 2` -> Krauser
   - `Chi3 = 3` -> HUNK
   - `Chi4 = 4` -> Ada
   - `Chi5 = 5` -> Wesker

2. Selectable character + costume: `chainsaw.MercenariesDefine.PlayerCharacterWithCostumeKind` (8 entries):
   - `Chi0_0 = 0` -> Leon (Default)
   - `Chi0_1 = 1` -> Leon (Pinstripe)
   - `Chi1_0 = 2` -> Luis
   - `Chi2_0 = 3` -> Krauser
   - `Chi3_0 = 4` -> HUNK
   - `Chi4_0 = 5` -> Ada (Default)
   - `Chi4_1 = 6` -> Ada (Dress)
   - `Chi5_0 = 7` -> Wesker

Live correlations confirmed:
- `ch6i0z0_body` = Leon base character (`costume_id = 0` Default, `costume_id = 1` Pinstripe)
- `ch6i2z0_body` = Krauser
- `ch6i3z0_body` = HUNK
- `ch6i5z0_body` = Wesker

Production AP design treats the eight selectable character+costume entries as distinct
AP unlock items, not merely the six base bodies.

# 3 Runtime discoveries

## Investigation Evidence Categorization

### CONFIRMED TYPE METADATA

The RE Engine TypeDB confirms the following Mercenaries types, fields, and methods:

1. **`chainsaw.MercenariesModeController`**:
   - Fields:
     - `_StageKind` (`chainsaw.MercenariesDefine.StageKind`)
     - `_ScoreCounter` (`chainsaw.MercenariesScoreCounter`)
     - `_PlayerCharacterKind` (`chainsaw.MercenariesDefine.PlayerCharacterKind`)
     - `_PlayerCharacterCostumeId` (`System.Int32`)
     - `_EndGameType` (`chainsaw.MercenariesDefine.EndGameType`)
     - `_ResultEnemyKilledCount` (`System.Int32`)
     - `_ResultScore` (`chainsaw.SimpleAntiMemoryCheatInteger`)
     - `_ResultHighScore` (`System.Int32`)
     - `_ResultMaxComboCount` (`System.Int32`)
     - `_ResultScoreRank` (`chainsaw.MercenariesDefine.ScoreRank`)
     - `_ClearNextState` (`chainsaw.Cp1021GameClearResultGuiBehavior.NextKind`)
     - `_bGameOver` (`System.Boolean`)
     - `_MerGameRankUserData` (`chainsaw.MercenariesGameRankUserData`)
   - Methods:
     - `get_StageKind()`, `get_Routine()`, `get_IsGameActive()`
     - `updateGame()`, `updateGameOver()`, `updateResult()`, `openGuiResult()`, `updateEnd()`
     - `shiftResult()`, `requestInGameQuit()`, `startGame()`, `startResult()`, `onDecidedResult(...)`

2. **`chainsaw.MercenariesManager`**:
   - Singleton wrapper (`AppSingleton`)
   - Getters: `get_IsGameEnd()`, `get_IsResult()`

3. **`chainsaw.MercenariesScoreCounter`**:
   - Getters: `get_Score()`, `get_TotalScore()`, `get_Combo()`, `get_ComboCount()`, `get_KillCount()`
   - Method: `AddScore(System.Int32)`

4. **`chainsaw.Cp1021GameClearResultGuiBehavior`**:
   - Field: `_OpenParam` (`chainsaw.Cp1021GameClearResultGuiBehavior.OpenParam`)
   - Enums: `Step`, `NextKind`, `MainPlayState`

5. **`chainsaw.Cp1021GameClearResultGuiBehavior.OpenParam`**:
   - Fields: `OnDecided`, `KillCount`, `ComboCount`, `Timer`, `TimeBonusBaseScore`, `TimeBonusScore`, `GameScore`, `TotalScore` (`SimpleAntiMemoryCheatInteger`), `HighScore`, `Rank` (`ScoreRank`), `Stage` (`StageKind`), `PlChara` (`PlayerCharacterKind`), `PlCostumeId` (`System.Int32`)

6. **`chainsaw.SimpleAntiMemoryCheatInteger`**:
   - Field: `_Value` (`System.Int64`)
   - Getter: `get_Value() -> System.Int32`

7. **`chainsaw.MercenariesDefine.EndGameType`**:
   - `Invalid = -1`, `TimeOut = 0`, `Dead = 1`, `Exterminated = 2`

8. **`chainsaw.MercenariesModeController.RoutineType`**:
   - `Init = 0`, `Wait = 1`, `GUI_START = 2`, `Game = 3`, `GUI_CLEAR = 4`, `GameOver = 5`, `Result = 6`, `End = 7`

### CONFIRMED LIVE (Probes 1, 2 & 3)

From controlled live sessions:

1. **Live Score Observation Confirmed**:
   - `MercenariesScoreCounter.get_Score()` reads live integer score smoothly (e.g. HUNK/Village: 0 -> 500 -> 1000 -> 1500 -> 2000; Wesker/Castle: ~118k and ~329k).

2. **Character & Costume Disambiguation Confirmed**:
   - Leon Default = `PlayerCharacterKind = 0`, `costume_id = 0`.
   - Leon Pinstripe = `PlayerCharacterKind = 0`, `costume_id = 1`.

3. **Lifecycle States Confirmed**:
   - Death transitions cleanly: `Game(3) -> GameOver(5) -> Result(6) -> End(7)` with `EndGameType = Dead(1)`.
   - Restart cleanly increments controller generation without triggering `IsResult`.
   - Quit cleanly destroys controller without triggering `IsResult`.

4. **Result Commit Boundary vs Payload Readiness**:
   - `MercenariesManager.get_IsResult()` `false -> true` is the authoritative **Result Pipeline Entry** (`RESULT_PIPELINE_ENTERED`).
   - Taking a one-time snapshot of `_Result*` and `_OpenParam` at the exact entry frame was proven **too early** (Wesker death runs produced live scores ~118k [visual Rank A] and ~329k [visual Rank S], but snapshot captured initial default zeros).
   - Payload population occurs later during `RoutineType.Result (6)`.

### PROBE 3.1 ARCHITECTURE

Probe 3.1 implements a 3-phase result model:
1. **`RESULT_PIPELINE_ENTERED`**: Triggered when `MercenariesManager.get_IsResult()` flips `false -> true`. Captures entry state, stage, character, costume, EndGameType, and last live score.
2. **Continuous Result Data Polling**: Continuously polls `Cp1021GameClearResultGuiBehavior._OpenParam` and controller `_Result*` fields through `RoutineType.Result (6)` and `RoutineType.End (7)`. Logs on content fingerprint change.
3. **`RESULT_PAYLOAD_READY`**: Fired when `_OpenParam` contains populated identity (`Stage != -1` and `PlChara != -1`). Logs complete OpenParam payload alongside Controller snapshot.

# 4 Score-check mechanism

## Authoritative Event Model

```
[MercenariesModeController Appearance]
       |
       v (assign controller_generation = N)
[Active Gameplay: live score updates via ScoreCounter.get_Score()]
       |
       +---> [Restart] ---> Controller destroyed (IsResult remains false) -> NO CHECK
       |
       +---> [Quit]    ---> Controller destroyed (IsResult remains false) -> NO CHECK
       |
       +---> [Clear / Death]
                 |
                 v
       [MercenariesManager.get_IsResult() false -> true]
                 |
                 v (RESULT_PIPELINE_ENTERED)
       [Continuous Polling in Routine 6 (Result) & 7 (End)]
                 |
                 v (OpenParam Stage != -1, PlChara != -1)
       [RESULT_PAYLOAD_READY Event (generation N, deduplicated)]
                 |
                 +--> Decoded Final Score (SimpleAntiMemoryCheatInteger.get_Value())
                 |    Authoritative ScoreRank, StageKind, CharacterKind, CostumeId
                 v
       [Monotonic AP Location Check Evaluation]
```

## Check Semantics

Recommended Standard profile exposes rank A and S for each pair:
- A: 100,000
- S: 200,000
- 32 pairs x 2 thresholds = **64 locations**

Monotonic algorithm:
1. Deduplicate by `controller_generation`.
2. Extract decoded integer score, ScoreRank, StageKind, and Character+Costume at `RESULT_PAYLOAD_READY`.
3. If run reached valid result payload, evaluate against configured thresholds.
4. Emit checks monotonically: once a threshold is satisfied, lower subsequent runs do not uncheck it.

# 5 Unlock mechanism

Do not modify persistent vanilla save unlock flags.

## Preferred Strategy: AP Virtual Selection Gating (Implemented)

Live investigation and type dumps of `chainsaw.Cp1021StageSelectGuiBehavior` and `chainsaw.Cp1021CharacterSelectGuiBehavior` established the complete selection architecture:

- **`Cp1021StageSelectGuiBehavior`:**
  - Has two overloaded `isUnlock` methods:
    1. `isUnlock(StageKind)`: checks stage availability (0=Village, 1=Castle, 2=Island, 3=Docks).
    2. `isUnlock(PlayerCharacterWithCostumeKind)`: checks character availability (0..7).
  - Exposes `onInputCheckEvent(1 params) -> bool`: validates player confirmation on selection.
  - Exposes `getKindId()`: queries current stage or character kind ID.
- **`Cp1021CharacterSelectGuiBehavior`:**
  - Exposes `isUnlock(PlayerCharacterWithCostumeKind) -> bool`.
  - Exposes `onInputCheckEvent(1 params) -> bool`.
  - Exposes `getCharacterKind()`: queries active character kind.
- **`Cp1021UnlockSettingsUserData`:**
  - Provides the underlying vanilla unlock requirements (`StageSetting` and `CharacterSetting`).

**Runtime Hooking Implementation (`mercenaries.lua`):**
1. Hooks **all overloads** of `isUnlock` on `Cp1021StageSelectGuiBehavior` and `Cp1021CharacterSelectGuiBehavior`.
2. In pre-hooks, converts argument pointers (`args[2]`) or invokes `getKindId`/`getCharacterKind` on the behavior instance (`args[1]`).
3. In post-hooks, checks if `ownership.initialized` is true and whether the queried stage/character is in the player's received Archipelago item set:
   - If owned: returns `sdk.to_ptr(1)` (unlocked).
   - If not owned: returns `sdk.to_ptr(0)` (locked).
4. Hooks `onInputCheckEvent` on both selection GUIs to block confirmation inputs for locked stages/characters.
5. In vanilla mode (or when Mercenaries is not enabled in `slot_data`), all hooks pass through unchanged without modifying vanilla behavior.


# 6 Scoresanity design

- **Model A (Recommended):** Pair plus rank thresholds (Standard = A + S: 64 locations; Full = A + S + S+ + S++: 128 locations; Expert = S++: 32 locations).
- **Model B:** Best rank per pair (32 locations).
- **Model C:** Milestone locations.

Model A (Standard default) is recommended.

# 7 APWorld mode architecture

## Modes
1. **Campaign** — unchanged.
2. **Combined** — campaign + Mercenaries (isolated runtime domains).
3. **Merc-only** — 32 pairs, 8 character items, 4 map items, no campaign items.

## Items (8 Characters + 4 Maps = 12 Items)
- **Characters (8):** Leon (Default), Leon (Pinstripe), Luis, Krauser, HUNK, Ada (Default), Ada (Dress), Wesker.
- **Maps (4):** Village, Castle, Island, Docks.

# 8 Starting inventory and logic

`Character item AND Map item -> Pair Access`

Two starting items (1 local character + 1 local map) are precollected. Remaining 10 items are placed in the progression pool, with safe filler populating the remaining locations.

# 9 Item/location counts

| Profile | Locations | Character/Map Items | Start Items Precollected | Active Progression Items | Filler Locations |
|---|---:|---:|---:|---:|---:|
| Standard (A, S) | **64** | 12 | 2 | 10 | 54 |
| Full (A, S, S+, S++) | **128** | 12 | 2 | 10 | 118 |
| Expert (S++) | **32** | 12 | 2 | 10 | 22 |

# 10 Goal recommendation

Default Merc-only goal: Complete all 32 character/map pairs at rank A or higher in Standard profile (server-evaluated).

# 11 Campaign interoperability

Combined mode maintains strict runtime domain separation:
- In Mercenaries: Disable campaign pickup detector, key-item sync, and inventory injection.
- In Campaign: Disable Mercenaries result evaluation and selection gating.
- Mode gate: Driven by `chainsaw.MercenariesManager` / `chainsaw.MercenariesModeController` presence.

# 12 Launcher changes

- **Campaign:** BioRand patch + manifest generation.
- **Merc-only:** Direct launch with Lua client; bypass BioRand manifest, generation, and patching.
- **Combined:** BioRand campaign patch + Mercenaries static data.

# 13 Save-data safety

- Historical vanilla high scores are ignored for AP checks.
- Checks are scoped to `server seed + slot + content revision`.
- No persistent vanilla unlock flags or save structures are mutated.

# 14 Technical risks

| Area | Status | Mitigation / Findings |
|---|---|---|
| Mode Identification | **CONFIRMED** | `chainsaw.MercenariesManager` & `MercenariesModeController` |
| Stage Identity | **CONFIRMED** | `StageKind` enum (0..3) is canonical; raw stage ID is diagnostic only |
| Character Identity | **CONFIRMED** | 8-entry `PlayerCharacterWithCostumeKind` matches playable selection |
| Result Commit Signal | **CONFIRMED** | `MercenariesManager.get_IsResult()` false -> true |
| Score Extraction | **CONFIRMED** | Continuous fingerprint polling in Routine 6/7 via `_OpenParam` |
| Restart / Quit Safety | **CONFIRMED** | `IsResult` remains false; controller destroyed; no false checks |
| GUI Hook Overhead | **RESOLVED** | Broad hooks eliminated; non-invasive polling used |
| AP Selection Gating | **IMPLEMENTED** | Multi-overload `isUnlock` + `onInputCheckEvent` hooks in `mercenaries.lua` |
| In-Game Checklist | **IMPLEMENTED** | Integrated into *The Checklist* tab in `ui_checks.lua` |

# 15 Probe history and Production Certification

## Probe History
- **Probe v1 (completed):** Generic scene/flow, character body strings, raw stage IDs, MainFlowManager limitations.
- **Probe v2 (completed):** TypeDB structures, `StageKind`, `PlayerCharacterWithCostumeKind`, `IsResult` transition, Restart/Quit exclusion, broad GUI hook diagnosis.
- **Probe v3 (completed):** Verified live score reading, costume ID disambiguation, `EndGameType`, `RoutineType`, `IsResult` commit boundary. Discovered early snapshot timing issue on result payload.
- **Probe v3.1 (completed):** Validated `RESULT_PIPELINE_ENTERED` -> continuous result polling -> `RESULT_PAYLOAD_READY`.
- **Production Integration (completed):** Implemented in `mercenaries.lua`, `ui_checks.lua`, `apworld_src/RE4R`, and Launcher. Type dumps confirmed `Cp1021StageSelectGuiBehavior` and `Cp1021CharacterSelectGuiBehavior` overload signatures, hooking them in-memory to enforce item progression.

# 16 Production Verification Criteria

The Mercenaries runtime pipeline is certified **PRODUCTION-READY**:
1. `StageKind` is read reliably (0=Village, 1=Castle, 2=Island, 3=Docks).
2. `PlayerCharacterKind` + costume ID are read reliably (8 selectable loadouts).
3. Live score is read as a normal integer during gameplay.
4. `RESULT_PIPELINE_ENTERED` is emitted upon `IsResult` transition.
5. Final result payload becomes ready in Routine 6/7.
6. Final numeric score matches the result UI.
7. Final rank matches the result UI across distinct ranks (A, S, S+, S++).
8. Death results work and produce populated score/rank checks.
9. Normal completion results work and include any end-of-run bonus.
10. Restart/Quit remain excluded by the lifecycle behavior.
11. One logical result generates exactly one check evaluation pass without duplicate emissions.
12. Starting loadouts (1 char + 1 stage) are precollected and correctly unlocked in-memory on session connect.
13. In-game Checklist reflects live check completions per stage and character.

