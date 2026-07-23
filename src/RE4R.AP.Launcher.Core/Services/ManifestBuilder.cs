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

        // Rooms carry either the always-set (RandomizeGatedKeys off) or the
        // full set (on). Anything else means the room's RE4R.apworld does not
        // match this launcher's bundled world data.
        var scoutedCount = scoutSession.Locations.Count;
        if (staticData.Counts.AlwaysLocations > 0 && scoutedCount == staticData.Counts.AlwaysLocations)
        {
            Log($"Room has {scoutedCount} RE4R locations - gated keys stay vanilla in this multiworld (RandomizeGatedKeys off).");
        }
        else if (scoutedCount == staticData.Counts.LocationsTotal)
        {
            Log(staticData.Counts.OptionalKeyLocations > 0
                ? $"Room has {scoutedCount} RE4R locations - gated keys are shuffled in this multiworld (RandomizeGatedKeys on)."
                : $"Room has {scoutedCount} RE4R locations.");
        }
        else
        {
            throw new ManifestBuildException(
                $"The AP server returned {scoutedCount} locations, but the bundled RE4R world data expects {staticData.Counts.AlwaysLocations} (gated keys vanilla) or {staticData.Counts.LocationsTotal} (gated keys shuffled). The room was probably generated with a different RE4R.apworld version than this launcher bundles.");
        }

        Log($"Building manifest for {scoutSession.Locations.Count} locations using BioRand game-version {gameVersion}.");

        var placements = new SortedDictionary<string, int>(StringComparer.Ordinal);
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

            var manifestItemId = ResolveManifestItemId(staticData, scoutSession, scoutedLocation);

            if (!placements.TryAdd(staticLocation.Guid, manifestItemId))
            {
                throw new ManifestBuildException(
                    $"The AP manifest encountered duplicate GUID {staticLocation.Guid}. The bundled world data needs to be regenerated.");
            }

            if (manifestItemId == staticData.PlaceholderItemId)
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

        var configJson = BuildConfigJson(placements, normalizedOptions, gameVersion);

        return new ManifestBuildResult
        {
            ConfigJson = configJson,
            GuidPlacementCount = placements.Count,
            PlaceholderItemCount = placeholderCount,
            RealRe4rItemCount = realRe4rCount,
            SkippedNoGuidLocationCount = skippedNoGuidCount,
        };
    }

    private static int ResolveManifestItemId(
        StaticGameData staticData,
        ArchipelagoScoutSessionResult scoutSession,
        ScoutLocationResult scoutedLocation)
    {
        if (scoutedLocation.OwningPlayerSlot != scoutSession.ConnectedPlayerSlot)
        {
            return staticData.PlaceholderItemId;
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

        return staticItem.BioRandItemId;
    }

    private string BuildConfigJson(
        IReadOnlyDictionary<string, int> placements,
        BioRandOptions options,
        string gameVersion)
    {
        var placementObject = new JsonObject();
        foreach (var placement in placements)
        {
            placementObject[placement.Key] = placement.Value;
        }

        var normalized = BioRandOptions.Sanitize(options);
        var values = new Dictionary<string, JsonNode?>(normalized.Values, StringComparer.Ordinal);

        // 1. Random Events REQUIRES Random Items AND Random Enemies - EventModifier.Apply THROWS
        //    otherwise, which would fail the whole patch. Players can now toggle those two freely
        //    (any tweak flips the mode to Custom), so enforce the dependency rather than letting
        //    them build a config that crashes. The UI surfaces this too, but this is the backstop.
        if (BioRandOptionCatalog.ApplyRandomEventsDependency(values))
        {
            Log("Random Events needs both Random Items and Random Enemies, so it has been switched off for this patch.");
        }

        // 2. Emit EVERY catalog key explicitly, INCLUDING random-items / random-enemies, which are
        //    now ordinary player-facing toggles rather than mode-forced axes. Omitting a key makes
        //    BioRand fall back to its own default - and many default to true (extra-merchants,
        //    extra-hiding-lockers, random-inventory, randomized-messages, ...). That leak is exactly
        //    what produced the phantom merchants and enemy spawns in a "vanilla" mode-1 run.
        var root = new JsonObject();
        foreach (var pair in values)
        {
            root[pair.Key] = pair.Value?.DeepClone();
        }

        // 3. AP locks LAST, so no preset and no player tweak can smuggle in a scope change that
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

        return root.ToJsonString(new JsonSerializerOptions
        {
            WriteIndented = true,
        });
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
