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

    // Custom apworld option: minimal / basic / locate / identify (default
    // locate). Ceiling on how much the in-game markers may say; players still
    // pick their own level below it.
    public string MarkerDetail { get; set; } = "locate";

    public bool DeathLink { get; set; }

    public bool AllowMissableLocations { get; set; }

    // Shuffle the Level 1/2/3 Keycards into the multiworld instead of
    // leaving them at their native island spots (apworld 0.6.0).
    public bool ShuffleKeycards { get; set; }

    // Keep important checks along the main path: hard hexagon deadline plus
    // filler-only side excursions (apworld 0.6.0).
    public bool MinimizeBacktracking { get; set; }

    // The in-game first-run guide (apworld 0.6.3). On by default; players who
    // know the ropes can turn it off for every seed they generate.
    public bool Tutorial { get; set; } = true;

    // EXPERIMENTAL: the multiworld authors BioRand's Random Events at
    // generation time and the logic reacts to them (apworld 0.7.0). Off by
    // default; the launcher pins the rolled set into BioRand at patch time.
    public bool RandomEvents { get; set; }

    public IReadOnlyCollection<string> UnlockedTypewriterStageIds { get; set; } = Array.Empty<string>();
}
