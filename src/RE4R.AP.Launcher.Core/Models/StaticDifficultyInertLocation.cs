using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// A location the game draws but will not let the player collect on Hardcore or
/// Professional, so those slots never create it.
/// </summary>
/// <remarks>
/// Mirrors the apworld's <c>_HARD_DIFFICULTY_INERT_GUIDS</c>, exported by
/// data_parser so the launcher can tell a legitimately short room from a
/// version mismatch. A Hardcore room scouts one fewer location than the bundle
/// declares, and before this the count check called that a different apworld and
/// refused to patch - which blocked a player for an hour on 2026-08-21.
/// </remarks>
public sealed class StaticDifficultyInertLocation
{
    [JsonPropertyName("guid")]
    public string Guid { get; set; } = string.Empty;

    [JsonPropertyName("code")]
    public long Code { get; set; }

    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("reason")]
    public string Reason { get; set; } = string.Empty;
}
