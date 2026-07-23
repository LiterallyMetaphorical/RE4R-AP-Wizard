namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// Result of validating a candidate Archipelago install folder for the
/// Generation Guidance screen. An install is usable when
/// ArchipelagoGenerate.exe is present; the version is advisory only - the
/// screen warns on a pin mismatch but never blocks (v1 guidance contract).
/// </summary>
public sealed class ArchipelagoInstallInspection
{
    public string RootPath { get; init; } = string.Empty;

    public bool RootExists { get; init; }

    public bool GenerateExeFound { get; init; }

    /// <summary>major.minor.build of ArchipelagoGenerate.exe, or empty when unreadable.</summary>
    public string DetectedVersion { get; init; } = string.Empty;

    public bool HasVersion => !string.IsNullOrWhiteSpace(DetectedVersion);

    public bool MatchesVersionPin { get; init; }

    public bool IsUsable => RootExists && GenerateExeFound;
}
