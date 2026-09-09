using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class StaticGameLocation
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("guid")]
    public string? Guid { get; set; }

    /// <summary>
    /// Which campaign this check belongs to: "leon" or "separate_ways". Absent
    /// on a world older than 0.8.0, where every check was Leon's.
    /// </summary>
    [JsonPropertyName("campaign")]
    public string Campaign { get; set; } = "leon";

    /// <summary>Ada's, rather than Leon's.</summary>
    [JsonIgnore]
    public bool IsSeparateWays =>
        string.Equals(Campaign, "separate_ways", StringComparison.OrdinalIgnoreCase);

    [JsonPropertyName("identity_kind")]
    public string IdentityKind { get; set; } = string.Empty;

    [JsonPropertyName("chapter")]
    public int Chapter { get; set; }

    [JsonPropertyName("stage")]
    public int Stage { get; set; }

    [JsonPropertyName("region")]
    public string Region { get; set; } = string.Empty;

    [JsonPropertyName("source_item_name")]
    public string SourceItemName { get; set; } = string.Empty;
}
