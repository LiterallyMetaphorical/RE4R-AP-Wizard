using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class StaticGameLocation
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("guid")]
    public string? Guid { get; set; }

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
