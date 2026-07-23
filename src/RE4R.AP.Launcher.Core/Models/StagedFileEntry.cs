namespace RE4R.AP.Launcher.Core.Models;

public sealed class StagedFileEntry
{
    public string RelativePath { get; init; } = string.Empty;

    public string Sha256 { get; init; } = string.Empty;

    public long Size { get; init; }
}
