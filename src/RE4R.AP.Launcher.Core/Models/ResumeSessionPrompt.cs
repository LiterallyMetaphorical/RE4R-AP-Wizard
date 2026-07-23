namespace RE4R.AP.Launcher.Core.Models;

public sealed class ResumeSessionPrompt
{
    public string NormalizedServer { get; init; } = string.Empty;

    public string SlotName { get; init; } = string.Empty;

    public string SeedName { get; init; } = string.Empty;

    public DateTimeOffset? PatchedAtUtc { get; init; }
}
