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

    // Room location counts vary with the world's RandomizeGatedKeys option:
    // OFF rooms create always_locations, ON rooms create locations_total
    // (always + optional_key).
    [JsonPropertyName("always_locations")]
    public int AlwaysLocations { get; set; }

    [JsonPropertyName("optional_key_locations")]
    public int OptionalKeyLocations { get; set; }
}
