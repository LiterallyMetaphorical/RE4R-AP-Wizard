namespace RE4R.AP.Launcher.Core.Models;

public sealed class LaunchWorkflowResult
{
    public bool Success { get; init; }

    public bool Cancelled { get; init; }

    public WorkflowStep? CancelledAtStep { get; init; }

    public bool ResumedExistingSession { get; init; }

    public string NormalizedServer { get; init; } = string.Empty;

    public string SeedName { get; init; } = string.Empty;

    public BioRandSetupResult? SetupResult { get; init; }

    public ArchipelagoScoutSessionResult? ScoutResult { get; init; }

    public ManifestBuildResult? ManifestResult { get; init; }

    public BioRandGenerationResult? GenerationResult { get; init; }

    public InstallResult? PatchInstallResult { get; init; }

    public InstallResult? LuaInstallResult { get; init; }

    public ConnectionInfoWriteResult? ConnectionInfoResult { get; init; }

    public SessionRecord? SessionRecord { get; init; }

    public string FinalMessage { get; init; } = string.Empty;
}
