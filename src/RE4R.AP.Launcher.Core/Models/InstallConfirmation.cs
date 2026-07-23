namespace RE4R.AP.Launcher.Core.Models;

public sealed class InstallConfirmation
{
    public string OperationName { get; init; } = string.Empty;

    public string DestinationRootPath { get; init; } = string.Empty;

    public int TotalFileCount { get; init; }

    public long TotalBytes { get; init; }

    public IReadOnlyList<InstallPlannedFile> Files { get; init; } = Array.Empty<InstallPlannedFile>();
}
