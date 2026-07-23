namespace RE4R.AP.Launcher.Core.Models;

public sealed class ExistingSessionConflictPrompt
{
    public string NormalizedServer { get; init; } = string.Empty;

    public string SlotName { get; init; } = string.Empty;

    public string ExistingSeedName { get; init; } = string.Empty;

    public string IncomingSeedName { get; init; } = string.Empty;

    public DateTimeOffset? ExistingPatchedAtUtc { get; init; }
}
