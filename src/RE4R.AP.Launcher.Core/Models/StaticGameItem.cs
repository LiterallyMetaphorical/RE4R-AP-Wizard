using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class StaticGameItem
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("biorand_item_id")]
    public int BioRandItemId { get; set; }

    // Delivery quantity for world placements. Older static files carry no
    // count field; a lone item id has always meant one, so that is the default.
    [JsonPropertyName("count")]
    public int Count { get; set; } = 1;

    [JsonPropertyName("biorand_name")]
    public string BioRandName { get; set; } = string.Empty;

    [JsonPropertyName("classification")]
    public string Classification { get; set; } = string.Empty;
}
