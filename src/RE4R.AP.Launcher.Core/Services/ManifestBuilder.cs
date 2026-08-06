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
        var scoutedCount = scoutSession.Locations.Count;
        if (scoutedCount == staticData.Counts.LocationsTotal - removedByEvents
            || (staticData.Counts.AlwaysLocations > 0 && scoutedCount == staticData.Counts.AlwaysLocations - removedByEvents))
        {
            Log(removedByEvents == 0
                ? $"Room has {scoutedCount} RE4R locations."
                : $"Room has {scoutedCount} RE4R locations ({removedByEvents} removed by the Random Events roll).");
        }
        else
        {
            throw new ManifestBuildException(
                $"The AP server returned {scoutedCount} locations, but the bundled RE4R world data expects {staticData.Counts.LocationsTotal - removedByEvents}. The room was probably generated with a different RE4R.apworld version than this launcher bundles.");
        }

        Log($"Building manifest for {scoutSession.Locations.Count} locations using BioRand game-version {gameVersion}.");

        var placements = new SortedDictionary<string, ManifestPlacement>(StringComparer.Ordinal);
        var placeholderCount = 0;
        var realRe4rCount = 0;
        var skippedNoGuidCount = 0;

        foreach (var scoutedLocation in scoutSession.Locations.OrderBy(location => location.LocationId))
        {
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
        // placement or an explicitly counted no-GUID skip; a shortfall means
        // scouted data silently failed to map.
        if (placements.Count + skippedNoGuidCount != scoutSession.Locations.Count)
        {
            throw new ManifestBuildException(
                $"The AP manifest mapped {placements.Count} GUID placements (+{skippedNoGuidCount} no-GUID skips) from {scoutSession.Locations.Count} scouted locations. The bundled world data does not match the room.");
        }

        Log($"{placements.Count} GUID-backed locations mapped into BioRand ap-placements.");
        Log(
            $"{placeholderCount} placeholder items, {realRe4rCount} real RE4R items, " +
            $"{skippedNoGuidCount} no-GUID locations skipped.");
        Log("AP manifest JSON is ready for BioRand generation.");

        var configJson = BuildConfigJson(placements, normalizedOptions, gameVersion, scoutSession.RandomEvents);

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
        RandomEventsSlotData randomEvents)
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

        return root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
        });
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }

    private readonly record struct ManifestPlacement(int ItemId, int Count);
}
