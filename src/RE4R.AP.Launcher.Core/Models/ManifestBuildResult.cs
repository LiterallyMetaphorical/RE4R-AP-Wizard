namespace RE4R.AP.Launcher.Core.Models;

public sealed class ManifestBuildResult
{
    public string ConfigJson { get; init; } = string.Empty;

    public int GuidPlacementCount { get; init; }

    public int PlaceholderItemCount { get; init; }

    public int RealRe4rItemCount { get; init; }

    public int SkippedNoGuidLocationCount { get; init; }
}
