namespace RE4R.AP.Launcher.Core.Models;

public sealed class Re4rYamlRequest
{
    public string SlotName { get; set; } = string.Empty;

    public string Difficulty { get; set; } = "standard";

    // Stock Archipelago ProgressionBalancing (0-99). The apworld inherits it
    // via PerGameCommonOptions; the launcher default (70) is higher than AP's
    // stock 50 because RE4R's long gated chapters strand players otherwise.
    public int ProgressionBalancing { get; set; } = 70;

    // Custom apworld option: off / markers / markers_rarity (default markers).
    // Permission ceiling for the in-game world markers.
    public string CheckGuidance { get; set; } = "markers";

    public bool DeathLink { get; set; }

    public bool AllowMissableLocations { get; set; }

    public bool RandomizeGatedKeys { get; set; }

    public IReadOnlyCollection<string> UnlockedTypewriterStageIds { get; set; } = Array.Empty<string>();
}
