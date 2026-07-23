namespace RE4R.AP.Launcher.Core.Models;

public sealed class InstallPlannedFile
{
    public string RelativePath { get; init; } = string.Empty;

    public string SourcePath { get; init; } = string.Empty;

    public string DestinationPath { get; init; } = string.Empty;

    public long Size { get; init; }

    public string ExpectedSha256 { get; init; } = string.Empty;
}
