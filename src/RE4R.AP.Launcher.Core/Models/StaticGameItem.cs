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

    /// <summary>
    /// Item kind, when the export names one. Mercenaries unlocks carry
    /// "merc_character", "merc_stage" or "merc_filler" and have no engine
    /// item: found in a campaign spot they show the Archipelago logo.
    /// </summary>
    [JsonPropertyName("kind")]
    public string? Kind { get; set; }
}
