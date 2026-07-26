namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// Result of validating a candidate Archipelago install folder for the
/// Generation Guidance screen. An install is usable when
/// a supported Archipelago generator is present; the version is advisory only.
/// </summary>
public sealed class ArchipelagoInstallInspection
{
    public string RootPath { get; init; } = string.Empty;

    public bool RootExists { get; init; }

    public string GeneratorPath { get; init; } = string.Empty;

    public bool GeneratorFound => !string.IsNullOrWhiteSpace(GeneratorPath);

    /// <summary>Compatibility alias retained for the Windows UI.</summary>
    public bool GenerateExeFound => GeneratorFound;

    /// <summary>Generator version, or empty when it cannot be determined.</summary>
    public string DetectedVersion { get; init; } = string.Empty;

    public bool HasVersion => !string.IsNullOrWhiteSpace(DetectedVersion);

    public bool MatchesVersionPin { get; init; }

    public bool IsUsable => RootExists && GeneratorFound;
}
