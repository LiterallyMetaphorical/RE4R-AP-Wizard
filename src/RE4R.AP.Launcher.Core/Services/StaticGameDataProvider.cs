using System.Text.Json;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class StaticGameDataProvider
{
    private const string StaticDataFileName = "re4r_ap_static.json";
    private const int ExpectedSchemaVersion = 1;

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public StaticGameDataProvider(string? assetsDataDirectoryPath = null)
    {
        AssetsDataDirectoryPath = assetsDataDirectoryPath
            ?? Path.Combine(AppContext.BaseDirectory, "assets", "Data");
        StaticDataFilePath = Path.Combine(AssetsDataDirectoryPath, StaticDataFileName);
    }

    public string AssetsDataDirectoryPath { get; }

    public string StaticDataFilePath { get; }

    public event Action<string>? LogMessage;

    public async Task<StaticGameData> LoadAsync(CancellationToken cancellationToken = default)
    {
        Log($"Loading bundled RE4R AP world data from {StaticDataFilePath}.");
        if (!File.Exists(StaticDataFilePath))
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data file was not found at {StaticDataFilePath}. " +
                "Copy re4r_ap_static.json into assets/Data before launching.");
        }

        try
        {
            await using var stream = File.OpenRead(StaticDataFilePath);
            var staticData = await JsonSerializer.DeserializeAsync<StaticGameData>(
                stream,
                SerializerOptions,
                cancellationToken);

            if (staticData is null)
            {
                throw new StaticGameDataException($"The bundled RE4R AP world data file at {StaticDataFilePath} was empty.");
            }

            Validate(staticData);

            Log(
                $"Loaded static RE4R AP data from {StaticDataFilePath} " +
                $"({staticData.Counts.LocationsTotal} locations, {staticData.Counts.GuidLocations} GUID-backed, " +
                $"{staticData.Counts.NoGuidLocations} no-GUID, {staticData.ShopSlots.Count} merchant shop slots).");

            return staticData;
        }
        catch (JsonException ex)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data at {StaticDataFilePath} is malformed JSON.",
                ex);
        }
        catch (IOException ex)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data at {StaticDataFilePath} could not be read.",
                ex);
        }
    }

    private static void Validate(StaticGameData staticData)
    {
        if (staticData.SchemaVersion != ExpectedSchemaVersion)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data schema version {staticData.SchemaVersion} is unsupported; expected {ExpectedSchemaVersion}. Rebuild the launcher bundle with matching data.");
        }

        if (string.IsNullOrWhiteSpace(staticData.WorldVersion))
        {
            throw new StaticGameDataException("The bundled RE4R AP world data did not include a world_version.");
        }

        if (staticData.PlaceholderItemId <= 0)
        {
            throw new StaticGameDataException("The bundled RE4R AP world data did not include a valid placeholder_item_id.");
        }

        staticData.Counts ??= new StaticGameDataCounts();
        staticData.LocationCodes ??= new List<long>();
        staticData.Locations ??= new Dictionary<long, StaticGameLocation>();
        staticData.Items ??= new Dictionary<long, StaticGameItem>();
        staticData.ShopSlots ??= new Dictionary<long, StaticShopSlot>();

        var actualGuidCount = staticData.Locations.Values.Count(
            entry => !string.IsNullOrWhiteSpace(entry.Guid));
        var actualNoGuidCount = staticData.Locations.Count - actualGuidCount;

        if (staticData.LocationCodes.Count != staticData.Counts.LocationsTotal)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data location_codes count {staticData.LocationCodes.Count} does not match its declared total {staticData.Counts.LocationsTotal}.");
        }

        if (staticData.Locations.Count != staticData.Counts.LocationsTotal)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data locations count {staticData.Locations.Count} does not match its declared total {staticData.Counts.LocationsTotal}.");
        }

        if (actualGuidCount != staticData.Counts.GuidLocations)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data GUID-backed count {actualGuidCount} does not match its declared count {staticData.Counts.GuidLocations}.");
        }

        if (actualNoGuidCount != staticData.Counts.NoGuidLocations)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data no-GUID count {actualNoGuidCount} does not match its declared count {staticData.Counts.NoGuidLocations}.");
        }

        if (staticData.Items.Count != staticData.Counts.ItemsTotal)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data items count {staticData.Items.Count} does not match its declared count {staticData.Counts.ItemsTotal}.");
        }

        if (staticData.ShopSlots.Count != staticData.Counts.ShopSlots)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data shop slot count {staticData.ShopSlots.Count} does not match its declared count {staticData.Counts.ShopSlots}.");
        }

        // A shop slot code that is also a world location code would make the
        // scout and manifest classify the same id two ways; the apworld seeds
        // its code derivation against the location table, so overlap here
        // means the two halves of the bundle came from different builds.
        var collidingShopSlotIds = staticData.ShopSlots.Keys
            .Where(staticData.Locations.ContainsKey)
            .ToList();
        if (collidingShopSlotIds.Count > 0)
        {
            throw new StaticGameDataException(
                $"The bundled RE4R AP world data has {collidingShopSlotIds.Count} shop slot code(s) colliding with world location codes (first: {collidingShopSlotIds[0]}). Rebuild the launcher bundle from one apworld build.");
        }
    }

    /// <summary>
    /// Best-effort synchronous load for UI that can do without it.
    /// </summary>
    /// <remarks>
    /// The YAML editor's item and location pickers need the bundled group and
    /// name lists, but they are a convenience: a missing, old or malformed
    /// bundle should leave the player with an editor that still writes a valid
    /// YAML, not a launcher that will not open the screen. Every failure
    /// returns null and the pickers render empty.
    ///
    /// Synchronous on purpose. This is a local file read on a user-initiated
    /// screen, and threading it through async construction would buy nothing
    /// but a race between the view appearing and its lists filling in.
    /// </remarks>
    public StaticGameData? TryLoad()
    {
        try
        {
            if (!File.Exists(StaticDataFilePath))
            {
                return null;
            }

            using var stream = File.OpenRead(StaticDataFilePath);
            var staticData = JsonSerializer.Deserialize<StaticGameData>(stream, SerializerOptions);
            if (staticData is null)
            {
                return null;
            }

            staticData.ItemGroups ??= new Dictionary<string, List<string>>();
            staticData.LocationGroups ??= new Dictionary<string, List<string>>();
            staticData.Locations ??= new Dictionary<long, StaticGameLocation>();
            staticData.Items ??= new Dictionary<long, StaticGameItem>();
            staticData.ShopSlots ??= new Dictionary<long, StaticShopSlot>();
            return staticData;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            Log($"Could not read {StaticDataFilePath} for the YAML pickers: {ex.Message}");
            return null;
        }
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
