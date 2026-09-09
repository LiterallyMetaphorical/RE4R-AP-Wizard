using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// A Trade-tab check (Phase 2 of the Trade takeover). Like the shop slots,
/// not a world location: no GUID, no pak spot, and a room carries between
/// none and all 45 depending on trade_checks - so they live outside the
/// exact-count contracts, and their ids exist here so the scout recognises
/// what a trade room declares (the 2026-08-14 unknown-id lesson).
/// </summary>
public sealed class StaticTradeCheck
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("release_index")]
    public int ReleaseIndex { get; set; }

    [JsonPropertyName("chapter")]
    public int Chapter { get; set; }

    [JsonPropertyName("chapter_ordinal")]
    public int ChapterOrdinal { get; set; }

    [JsonPropertyName("price_spinel")]
    public int PriceSpinel { get; set; }
}
