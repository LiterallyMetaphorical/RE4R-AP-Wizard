namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// Outcome of retiring a session. When the player opts to restore vanilla, the
/// BioRand patch files are removed from the game folder; these counts let the UI
/// report honestly (including a partial failure, e.g. a pak locked because RE4R
/// is still running).
/// </summary>
public sealed class SessionRetireResult
{
    /// <summary>True if the player asked to remove the BioRand patch.</summary>
    public bool RestoreVanillaRequested { get; init; }

    /// <summary>Patch files successfully deleted from the game folder.</summary>
    public int PatchFilesRemoved { get; init; }

    /// <summary>Patch files that could not be deleted (e.g. locked/missing).</summary>
    public int PatchFilesFailed { get; init; }

    /// <summary>True when a restore was requested and every patch file is gone.</summary>
    public bool VanillaRestored => RestoreVanillaRequested && PatchFilesFailed == 0;
}
