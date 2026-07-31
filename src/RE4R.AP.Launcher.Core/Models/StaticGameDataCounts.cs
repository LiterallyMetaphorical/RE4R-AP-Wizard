using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class StaticGameDataCounts
{
    [JsonPropertyName("locations_total")]
    public int LocationsTotal { get; set; }

    [JsonPropertyName("guid_locations")]
    public int GuidLocations { get; set; }

    [JsonPropertyName("noguid_locations")]
    public int NoGuidLocations { get; set; }

    [JsonPropertyName("items_total")]
    public int ItemsTotal { get; set; }

    // Since apworld 0.6.0 every location is unconditional, so
    // always_locations == locations_total and optional_key_locations is 0.
    // Both keys stay in the schema so older static data still parses.
    [JsonPropertyName("always_locations")]
    public int AlwaysLocations { get; set; }

    [JsonPropertyName("optional_key_locations")]
    public int OptionalKeyLocations { get; set; }
}
