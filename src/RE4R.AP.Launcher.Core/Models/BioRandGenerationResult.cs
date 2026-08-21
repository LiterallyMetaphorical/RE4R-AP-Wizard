namespace RE4R.AP.Launcher.Core.Models;

public sealed class BioRandGenerationResult
{
    public bool Success { get; init; }

    public int ExitCode { get; init; }

    public string BioRandVersionDescriptor { get; init; } = string.Empty;

    public string ErrorMessage { get; init; } = string.Empty;

    public string ConfigFilePath { get; init; } = string.Empty;

    public string StagingDirectoryPath { get; init; } = string.Empty;

    /// <summary>Raw ap_enemy_gates.json emitted by the generator, empty when gates were not in play.</summary>
    public string EnemyGatesJson { get; init; } = string.Empty;

    public IReadOnlyList<StagedFileEntry> StagedFiles { get; init; } = Array.Empty<StagedFileEntry>();

    public IReadOnlyList<string> StandardOutputLines { get; init; } = Array.Empty<string>();

    public IReadOnlyList<string> StandardErrorLines { get; init; } = Array.Empty<string>();
}
