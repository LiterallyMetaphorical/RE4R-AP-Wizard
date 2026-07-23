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
                $"{staticData.Counts.NoGuidLocations} no-GUID).");

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
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
