namespace RE4R.AP.Launcher.Models;

/// <summary>
/// The newest release found on GitHub, and whether it beats what is running.
/// </summary>
public sealed class LauncherUpdateInfo
{
    public string TagName { get; init; } = string.Empty;

    /// <summary>Release title, or the tag when GitHub has no name set.</summary>
    public string DisplayName { get; init; } = string.Empty;

    public string ReleaseUrl { get; init; } = string.Empty;

    public string RunningVersion { get; init; } = string.Empty;

    public bool IsNewer { get; init; }
}
