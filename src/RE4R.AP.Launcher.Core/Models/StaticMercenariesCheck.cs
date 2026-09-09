using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// A Mercenaries rank check (apworld 0.7.2). Like the shop slots and trade
/// checks, not a world location: no GUID, no pak spot, and a room carries
/// 32, 64 or 128 of them depending on mercenaries_score_checks. The mod
/// sends them from the mode's result screen; the launcher only needs to
/// recognise the ids so a Mercenaries room does not trip the unknown-id
/// refusal, and to keep them out of the BioRand manifest.
/// </summary>
public sealed class StaticMercenariesCheck
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("character")]
    public string Character { get; set; } = string.Empty;

    [JsonPropertyName("stage")]
    public string Stage { get; set; } = string.Empty;

    [JsonPropertyName("rank")]
    public string Rank { get; set; } = string.Empty;

    [JsonPropertyName("identity")]
    public string Identity { get; set; } = string.Empty;
}
