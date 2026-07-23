using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class StaticGameData
{
    [JsonPropertyName("schema_version")]
    public int SchemaVersion { get; set; }

    [JsonPropertyName("generated_at_utc")]
    public string GeneratedAtUtc { get; set; } = string.Empty;

    [JsonPropertyName("game")]
    public string Game { get; set; } = string.Empty;

    [JsonPropertyName("world_version")]
    public string WorldVersion { get; set; } = string.Empty;

    [JsonPropertyName("placeholder_item_id")]
    public int PlaceholderItemId { get; set; }

    [JsonPropertyName("counts")]
    public StaticGameDataCounts Counts { get; set; } = new();

    [JsonPropertyName("location_codes")]
    public List<long> LocationCodes { get; set; } = new();

    [JsonPropertyName("locations")]
    public Dictionary<long, StaticGameLocation> Locations { get; set; } = new();

    [JsonPropertyName("items")]
    public Dictionary<long, StaticGameItem> Items { get; set; } = new();
}
