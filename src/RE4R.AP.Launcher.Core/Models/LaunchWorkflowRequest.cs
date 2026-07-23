namespace RE4R.AP.Launcher.Core.Models;

public sealed class LaunchWorkflowRequest
{
    public string Re4rInstallPath { get; set; } = string.Empty;

    public string ServerAddress { get; set; } = string.Empty;

    // Optional archipelago.gg room-page URL; stored on the session record as
    // the durable pointer (rooms sleep and can change ports).
    public string RoomUrl { get; set; } = string.Empty;

    public string SlotName { get; set; } = string.Empty;

    public string? Password { get; set; }

    public string GameVersion { get; set; } = string.Empty;

    public GameFingerprint CurrentGameFingerprint { get; set; } = GameFingerprint.CreateDefault();

    public BioRandOptions BioRandOptions { get; set; } = BioRandOptions.CreateDefault();

    /// <summary>
    /// Re-patching an already-patched room normally REPLAYS the options recorded at the first
    /// patch, so the world is reproduced identically. Set this when the player has explicitly
    /// chosen to change their options anyway (they were warned that the non-check world re-rolls
    /// and that they should start a new game). AP checks are pinned by GUID either way, so the
    /// multiworld cannot desync - only the world around the checks changes.
    /// </summary>
    public bool OverrideRecordedOptions { get; set; }

    public bool IsHostedSession { get; set; }

    public Func<string, Task>? NotifyAsync { get; set; }

    public Func<ExistingSessionConflictPrompt, Task<bool>>? ConfirmOverwriteDifferentSeedAsync { get; set; }

    public Func<ResumeSessionPrompt, Task<ResumeSessionDecision>>? ChooseResumeActionAsync { get; set; }

    public Func<InstallConfirmation, Task<bool>>? ConfirmPatchInstallAsync { get; set; }

    public Func<InstallConfirmation, Task<bool>>? ConfirmLuaInstallAsync { get; set; }

    /// <summary>
    /// Invoked when a workflow stage begins, so the UI can render a live
    /// phase checklist instead of a raw log (field note: patch progress).
    /// Exceptions are swallowed; the callback must marshal its own threading.
    /// </summary>
    public Action<WorkflowStep>? OnStepStarting { get; set; }
}
