using System.Text.Json;
using System.Text.Json.Nodes;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class ManifestBuilder
{
    private readonly StaticGameDataProvider _staticGameDataProvider;

    public ManifestBuilder(StaticGameDataProvider? staticGameDataProvider = null)
    {
        _staticGameDataProvider = staticGameDataProvider ?? new StaticGameDataProvider();
    }

    public event Action<string>? LogMessage;

    public async Task<ManifestBuildResult> BuildAsync(
        ArchipelagoScoutSessionResult scoutSession,
        BioRandOptions? options,
        string gameVersion,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(scoutSession);

        if (string.IsNullOrWhiteSpace(gameVersion))
        {
            throw new ManifestBuildException("The AP manifest could not be built because the BioRand game-version is missing.");
        }

        var staticData = await _staticGameDataProvider.LoadAsync(cancellationToken);
        var normalizedOptions = BioRandOptions.Sanitize(options);

        // Since apworld 0.6.0 every location is unconditional, so a healthy
        // room scouts exactly the bundled count. The always/total split is
        // kept for older static data where an optional tier existed. An
        // AP-authored Random Events roll can delete checks outright (the
        // removekey events); slot_data says how many, so the expectation
        // shrinks by exactly that count and anything else still fails.
        var removedByEvents = scoutSession.RandomEvents.Enabled
            ? scoutSession.RandomEvents.RemovedLocationCodes.Count
            : 0;

        // Shop slots (D4) are counted apart from the world total: how many a
        // room carries varies with shop_checks, and the slot_data block is
        // the authority on that number. A mismatch between the room's shop
        // location ids and its slot data means the shop rows cannot all be
        // built, so it fails loudly here rather than quietly downstream.
        var scoutedShopSlotCount = scoutSession.Locations.Count(
            location => staticData.ShopSlots.ContainsKey(location.LocationId));
        var declaredShopSlotCount = scoutSession.MerchantShop.Enabled
            ? scoutSession.MerchantShop.Slots.Count
            : 0;
        if (scoutedShopSlotCount != declaredShopSlotCount)
        {
            throw new ManifestBuildException(
                $"The room carries {scoutedShopSlotCount} merchant shop location(s) but its slot data describes {declaredShopSlotCount}. The room's shop data does not match its location list.");
        }

        var scoutedCount = scoutSession.Locations.Count - scoutedShopSlotCount;
        if (scoutedCount == staticData.Counts.LocationsTotal - removedByEvents
            || (staticData.Counts.AlwaysLocations > 0 && scoutedCount == staticData.Counts.AlwaysLocations - removedByEvents))
        {
            var shopSuffix = scoutedShopSlotCount > 0
                ? $" Plus {scoutedShopSlotCount} merchant shop check(s)."
                : string.Empty;
            Log((removedByEvents == 0
                ? $"Room has {scoutedCount} RE4R locations."
                : $"Room has {scoutedCount} RE4R locations ({removedByEvents} removed by the Random Events roll).") + shopSuffix);
        }
        else
        {
            throw new ManifestBuildException(
                $"The AP server returned {scoutedCount} world locations, but the bundled RE4R world data expects {staticData.Counts.LocationsTotal - removedByEvents}. The room was probably generated with a different RE4R.apworld version than this launcher bundles.");
        }

        Log($"Building manifest for {scoutSession.Locations.Count} locations using BioRand game-version {gameVersion}.");

        var placements = new SortedDictionary<string, ManifestPlacement>(StringComparer.Ordinal);
        var placeholderCount = 0;
        var realRe4rCount = 0;
        var skippedNoGuidCount = 0;
        var shopSlotSkippedCount = 0;

        foreach (var scoutedLocation in scoutSession.Locations.OrderBy(location => location.LocationId))
        {
            // Shop slots never enter ap-placements: they have no world spot.
            // The shop plan below carries them into the manifest instead.
            if (staticData.ShopSlots.ContainsKey(scoutedLocation.LocationId))
            {
                shopSlotSkippedCount++;
                continue;
            }

            if (!staticData.Locations.TryGetValue(scoutedLocation.LocationId, out var staticLocation))
            {
                throw new ManifestBuildException(
                    $"The bundled RE4R world data did not contain AP location id {scoutedLocation.LocationId} returned by LocationScouts.");
            }

            if (string.IsNullOrWhiteSpace(staticLocation.Guid))
            {
                skippedNoGuidCount++;
                continue;
            }

            var manifestPlacement = ResolveManifestPlacement(staticData, scoutSession, scoutedLocation);

            if (!placements.TryAdd(staticLocation.Guid, manifestPlacement))
            {
                throw new ManifestBuildException(
                    $"The AP manifest encountered duplicate GUID {staticLocation.Guid}. The bundled world data needs to be regenerated.");
            }

            if (manifestPlacement.ItemId == staticData.PlaceholderItemId)
            {
                placeholderCount++;
            }
            else
            {
                realRe4rCount++;
            }
        }

        // Every scouted location must land in the manifest either as a GUID
        // placement, an explicitly counted no-GUID skip, or a shop slot the
        // shop plan owns; a shortfall means scouted data silently failed to
        // map.
        if (placements.Count + skippedNoGuidCount + shopSlotSkippedCount != scoutSession.Locations.Count)
        {
            throw new ManifestBuildException(
                $"The AP manifest mapped {placements.Count} GUID placements (+{skippedNoGuidCount} no-GUID skips, +{shopSlotSkippedCount} shop slots) from {scoutSession.Locations.Count} scouted locations. The bundled world data does not match the room.");
        }

        Log($"{placements.Count} GUID-backed locations mapped into BioRand ap-placements.");
        Log(
            $"{placeholderCount} placeholder items, {realRe4rCount} real RE4R items, " +
            $"{skippedNoGuidCount} no-GUID locations skipped, {shopSlotSkippedCount} shop slot(s) left to the shop plan.");
        Log("AP manifest JSON is ready for BioRand generation.");

        var plannedShopSlots = MerchantShopPlanner.Plan(scoutSession.MerchantShop);
        if (plannedShopSlots.Count > 0)
        {
            Log($"Merchant sells {plannedShopSlots.Count} AP check(s); "
                + $"{MerchantShopPlanner.PoolUniqueBuyableItemIds.Count} pool item(s) barred from his stock.");
        }

        var configJson = BuildConfigJson(
            placements, normalizedOptions, gameVersion, scoutSession.RandomEvents, plannedShopSlots,
            scoutSession.MerchantShop.ScatteredItemIds, scoutSession.RandomWeaponStats);
        if (scoutSession.RandomWeaponStats is bool yamlWeaponStats)
        {
            Log($"Random Weapon Stats rides the YAML: {(yamlWeaponStats ? "on" : "off")} for every patch of this room.");
        }
        if (scoutSession.MerchantShop.ScatteredItemIds.Count > 0)
        {
            Log($"{scoutSession.MerchantShop.ScatteredItemIds.Count} piece(s) of merchant gear are scattered into the multiworld; the shelf loses them.");
        }

        return new ManifestBuildResult
        {
            ConfigJson = configJson,
            GuidPlacementCount = placements.Count,
            PlaceholderItemCount = placeholderCount,
            RealRe4rItemCount = realRe4rCount,
            SkippedNoGuidLocationCount = skippedNoGuidCount,
        };
    }

    private static ManifestPlacement ResolveManifestPlacement(
        StaticGameData staticData,
        ArchipelagoScoutSessionResult scoutSession,
        ScoutLocationResult scoutedLocation)
    {
        if (scoutedLocation.OwningPlayerSlot != scoutSession.ConnectedPlayerSlot)
        {
            return new ManifestPlacement(staticData.PlaceholderItemId, 1);
        }

        if (!staticData.Items.TryGetValue(scoutedLocation.ItemId, out var staticItem))
        {
            throw new ManifestBuildException(
                $"The bundled RE4R world data did not contain AP item id {scoutedLocation.ItemId} for scouted location {scoutedLocation.LocationId}.");
        }

        if (staticItem.BioRandItemId <= 0)
        {
            throw new ManifestBuildException(
                $"AP item {scoutedLocation.ItemId} ({staticItem.Name}) did not have a valid BioRand item id in the bundled world data.");
        }

        // The engine id alone cannot express the quantity (Rifle Ammo x4 and
        // x5 share one id), so the manifest carries the same delivery count
        // the received-item path uses: a world pickup of your own item must
        // match what the multiworld says it is.
        return new ManifestPlacement(staticItem.BioRandItemId, Math.Max(1, staticItem.Count));
    }

    private string BuildConfigJson(
        IReadOnlyDictionary<string, ManifestPlacement> placements,
        BioRandOptions options,
        string gameVersion,
        RandomEventsSlotData randomEvents,
        IReadOnlyList<MerchantShopPlannedSlot> shopSlots,
        IReadOnlyList<int> scatteredItemIds,
        bool? randomWeaponStats)
    {
        var placementObject = new JsonObject();
        foreach (var placement in placements)
        {
            placementObject[placement.Key] = new JsonObject
            {
                ["item"] = placement.Value.ItemId,
                ["count"] = placement.Value.Count,
            };
        }

        var normalized = BioRandOptions.Sanitize(options);
        var values = new Dictionary<string, JsonNode?>(normalized.Values, StringComparer.Ordinal);

        // 1. Emit EVERY catalog key explicitly, INCLUDING random-items / random-enemies, which are
        //    now ordinary player-facing toggles rather than mode-forced axes. Omitting a key makes
        //    BioRand fall back to its own default - and many default to true (extra-merchants,
        //    extra-hiding-lockers, random-inventory, randomized-messages, ...). That leak is exactly
        //    what produced the phantom merchants and enemy spawns in a "vanilla" mode-1 run.
        var root = new JsonObject();
        foreach (var pair in values)
        {
            root[pair.Key] = pair.Value?.DeepClone();
        }

        // 2. AP locks LAST, so no preset and no player tweak can smuggle in a scope change that
        //    removes or strands AP checks. (Item-generation options cannot corrupt a check - AP
        //    placements are written by explicit id and merged last - so these are the only genuine
        //    AP-breakers. Note BioRand defaults skip-ashley-section to TRUE, which would delete a
        //    whole segment and its checks.)
        root["game-version"] = gameVersion;
        root["campaign"] = "Main Story";
        root["start-chapter"] = 1;
        root["skip-ashley-section"] = false;
        root["ap-mode"] = true;
        root["ap-placements"] = placementObject;

        // 3. Random Events is AP-locked too: the multiworld already rolled the event set at
        //    generation time (or declined to), so the room decides, never this machine. When the
        //    roll is present it is pinned into the fork as the complete forced set, together with
        //    the hash of the event data it was rolled against - a drifted events.csv fails the
        //    patch instead of quietly desyncing the world from the logic. EventModifier requires
        //    random-items and random-enemies for random-events, so those are forced on with it.
        if (randomEvents.Enabled)
        {
            root[BioRandOptionCatalog.RandomEventsKey] = true;
            root[BioRandOptionCatalog.RandomItemsKey] = true;
            root[BioRandOptionCatalog.RandomEnemiesKey] = true;
            var forcedEvents = new JsonArray();
            foreach (var eventName in randomEvents.ChosenEvents)
            {
                forcedEvents.Add(JsonValue.Create(eventName));
            }

            root["ap-forced-events"] = forcedEvents;
            if (!string.IsNullOrWhiteSpace(randomEvents.EventDataHash))
            {
                root["ap-event-data-hash"] = randomEvents.EventDataHash;
            }

            Log($"AP-authored Random Events: pinning {randomEvents.ChosenEvents.Count} events into BioRand "
                + "(random-items and random-enemies forced on with them).");
        }
        else
        {
            root[BioRandOptionCatalog.RandomEventsKey] = false;
        }

        // 4. The AP-aware merchant (D4/D10). Present when the room has shop
        //    checks OR scattered gear: the fork's post-pass no-ops without
        //    this section, so rooms from older apworlds keep the shop they
        //    always had. The exclusion list rides along because it is the
        //    same conversation - the merchant stops selling what the
        //    multiworld holds, whether that is a placed pool item or his own
        //    scattered arsenal.
        //
        //    Two owners cannot stock one shop: BioRand's own merchant reroll
        //    restocks weapons the multiworld just claimed (its added arsenal
        //    is not pool-excludable), so it is forced off whenever the AP
        //    merchant is on. The options screen shows the same forcing.
        if (shopSlots.Count > 0 || scatteredItemIds.Count > 0)
        {
            root[BioRandOptionCatalog.RandomMerchantKey] = false;
            root[BioRandOptionCatalog.RandomMerchantPricesKey] = false;
            Log("AP merchant active: BioRand's own merchant randomization (stock and prices) is forced off.");

            var excludedIds = new SortedSet<int>(MerchantShopPlanner.PoolUniqueBuyableItemIds);
            foreach (var itemId in scatteredItemIds)
            {
                excludedIds.Add(itemId);
            }

            var excluded = new JsonArray();
            foreach (var itemId in excludedIds)
            {
                excluded.Add(JsonValue.Create(itemId));
            }

            var tiers = new JsonObject();
            var slotsArray = new JsonArray();
            foreach (var planned in shopSlots)
            {
                tiers[planned.Slot.Classification] = new JsonObject
                {
                    ["price"] = planned.Tier.Price,
                };
                slotsArray.Add(new JsonObject
                {
                    ["index"] = planned.Slot.Index,
                    ["location-code"] = planned.Slot.LocationCode,
                    ["unlock-chapter"] = planned.Slot.UnlockChapter,
                    ["standin-item-id"] = planned.StandinItemId,
                    ["display-name"] = BuildShopRowName(planned.Slot),
                    ["player-name"] = planned.Slot.PlayerName,
                    ["classification"] = planned.Slot.Classification,
                    ["remote"] = planned.Slot.Remote,
                });
            }

            root["ap-merchant-shop"] = new JsonObject
            {
                ["excluded-item-ids"] = excluded,
                ["tiers"] = tiers,
                ["slots"] = slotsArray,
            };
        }

        // 4b. Weapon character rides with the multiworld's weapons: the
        //     YAML's Random Weapon Stats pins BioRand's switch, identically
        //     on every patch. Rooms from older apworlds carry no key and
        //     leave the switch player-controlled.
        if (randomWeaponStats is bool weaponStats)
        {
            root[BioRandOptionCatalog.RandomWeaponStatsKey] = weaponStats;
        }

        // 4c. Possession-keyed spawn gates (ENEMY_CLASS_DESIGN.md). The fork
        //     echoes each enabled gate back with the spawn identities it rolled
        //     into that class; the mod vetoes those spawns until the item is
        //     possessed. Only item gates ship enabled today (Dread on the
        //     Biosensor Scope); the arsenal gates stay data-scaffolded off.
        var enabledItemGates = EnemyConfigurationPresets.Gates
            .Where(gate => gate is { Enabled: true, Type: "item" } && gate.ItemEngineId > 0)
            .ToList();
        var randomEnemiesOn = root[BioRandOptionCatalog.RandomEnemiesKey] is JsonValue randomEnemiesValue
            && randomEnemiesValue.TryGetValue<bool>(out var randomEnemiesFlag)
            && randomEnemiesFlag;
        if (enabledItemGates.Count > 0 && randomEnemiesOn)
        {
            var gatesObject = new JsonObject();
            foreach (var gate in enabledItemGates)
            {
                var members = new JsonArray();
                foreach (var member in gate.Members)
                {
                    members.Add(JsonValue.Create(member));
                }

                gatesObject[gate.ClassKey] = new JsonObject
                {
                    ["members"] = members,
                    ["item-id"] = gate.ItemEngineId,
                    ["item-name"] = gate.Item,
                };
            }

            root["ap-enemy-gates"] = gatesObject;
            Log($"Enemy spawn gates: {enabledItemGates.Count} class gate(s) sent to the generator.");
        }

        // 4d. The class lock (Cam, 2026-08-16): at locked roster steps each
        //     spawn may only reroll within its vanilla occupant's class, so
        //     the threat map stays the designed campaign's while identity
        //     shuffles. Exempt classes stay eligible everywhere (the
        //     wandering cow rule). The lock is part of a NAMED step's
        //     promise: the step is detected from the composed values, so
        //     hand-tuned Custom states never emit it.
        if (randomEnemiesOn)
        {
            var rosterStep = EnemyConfigurationPresets.DetectRosterStep(key => root[key]);
            if (rosterStep is { ClassLock: true })
            {
                var lockClasses = new JsonObject();
                foreach (var (classKey, members) in EnemyConfigurationPresets.ClassMembers)
                {
                    var memberArray = new JsonArray();
                    foreach (var member in members)
                    {
                        memberArray.Add(JsonValue.Create(member));
                    }

                    lockClasses[classKey] = memberArray;
                }

                var exempt = new JsonArray();
                foreach (var exemptClass in EnemyConfigurationPresets.ClassLockExemptClasses)
                {
                    exempt.Add(JsonValue.Create(exemptClass));
                }

                root["ap-class-lock"] = new JsonObject
                {
                    ["classes"] = lockClasses,
                    ["exempt"] = exempt,
                };
                Log($"Class lock active ({rosterStep.Label}): spawns reroll within their vanilla class.");
            }
        }

        return root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
        });
    }

    /// <summary>
    /// What the shop row is called on the shelf. A remote item names its owner
    /// (that is the whole point of seeing it there); your own reads plainly.
    /// The name is baked into the game's message files at patch time, so it is
    /// kept short enough to sit in a shop row.
    /// </summary>
    private static string BuildShopRowName(MerchantShopSlot slot)
    {
        var itemName = string.IsNullOrWhiteSpace(slot.DisplayName)
            ? "Archipelago Item"
            : slot.DisplayName.Trim();
        if (!slot.Remote || string.IsNullOrWhiteSpace(slot.PlayerName))
        {
            return itemName;
        }

        return $"{slot.PlayerName.Trim()}'s {itemName}";
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }

    private readonly record struct ManifestPlacement(int ItemId, int Count);
}
