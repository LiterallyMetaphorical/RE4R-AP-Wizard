using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// A merchant shop check slot (D4). Not a world location: no GUID, no pak
/// spot, and a room carries between none and all of them depending on
/// shop_checks - so they live outside the exact-count contracts the world
/// location table is validated against.
/// </summary>
public sealed class StaticShopSlot
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("slot")]
    public int Slot { get; set; }

    [JsonPropertyName("physical_chapter")]
    public int PhysicalChapter { get; set; }

    [JsonPropertyName("logical_chapter")]
    public int LogicalChapter { get; set; }
}
