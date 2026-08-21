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

    // Custom apworld option: minimal / basic / locate / identify / developer
    // (default locate). The tier markers actually start at, not a cap; the
    // in-game Guidance tab can move it either way from there.
    public string MarkerDetail { get; set; } = "locate";

    public bool DeathLink { get; set; }

    public bool AllowMissableLocations { get; set; }

    // Shuffle the Level 1/2/3 Keycards into the multiworld instead of
    // leaving them at their native island spots (apworld 0.6.0).
    public bool ShuffleKeycards { get; set; }

    public bool ShuffleMerchantGear { get; set; }

    /// <summary>Random pool weapons precollected at connect (0-3); requires the gear shuffle.</summary>
    public int StartingArsenal { get; set; }

    // Trimmed Starting Arsenal type keys. Empty means every type is allowed
    // and the YAML key is omitted (the apworld default already covers it).
    public IReadOnlyList<string> StartingArsenalTypes { get; set; } = [];

    // Who the merchant's check rows may hold: mixed, local_only, remote_only.
    public string MerchantChecks { get; set; } = "mixed";

    public bool RandomWeaponStats { get; set; }

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

    // How many Archipelago checks the merchant releases per chapter (D4 +
    // rotation). 0 turns the feature off entirely; each check adds one filler
    // to the pool, so this also grows the item count. The seed total is this
    // times the campaign's 15 releasing chapters.
    public int MerchantChecksPerChapter { get; set; }

    public IReadOnlyCollection<string> UnlockedTypewriterStageIds { get; set; } = Array.Empty<string>();

    // Archipelago's per-game item/location options (Amondo's request, 2026-08).
    // Each is emitted only when non-empty, so a player who touches none of them
    // gets byte-identical YAML to before. Entries may be group names (Key
    // Items, Chests, ...) or individual names; AP expands groups itself.
    //
    // The UI models these as two tri-state lists rather than four independent
    // ones, which is why nothing here has to guard against the same name
    // appearing in both directions - it cannot be expressed.
    public IReadOnlyCollection<string> LocalItems { get; set; } = Array.Empty<string>();

    public IReadOnlyCollection<string> NonLocalItems { get; set; } = Array.Empty<string>();

    public IReadOnlyCollection<string> ExcludeLocations { get; set; } = Array.Empty<string>();

    public IReadOnlyCollection<string> PriorityLocations { get; set; } = Array.Empty<string>();
}
