namespace RE4R.AP.Launcher.Core.Models;

public sealed class BioRandSetupRequest
{
    public string Re4rInstallPath { get; set; } = string.Empty;

    public GameFingerprint GameFingerprint { get; set; } = GameFingerprint.CreateDefault();

    /// <summary>
    /// File names (not paths) of patch paks the launcher itself has installed
    /// into the game folder - collected from session records. Setup moves them
    /// aside for the duration of the harvest: the cache must snapshot the
    /// VANILLA game, and a re-patch runs setup while the previous session's
    /// pak is still installed.
    /// </summary>
    public IReadOnlyList<string> ApPatchFileNames { get; set; } = Array.Empty<string>();
}
