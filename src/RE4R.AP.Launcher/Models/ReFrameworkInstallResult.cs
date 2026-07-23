namespace RE4R.AP.Launcher.Models;

public sealed class ReFrameworkInstallResult
{
    public bool Success { get; init; }

    public string ReleaseTag { get; init; } = string.Empty;

    public string AssetName { get; init; } = string.Empty;

    public int FilesWrittenCount { get; init; }
}
