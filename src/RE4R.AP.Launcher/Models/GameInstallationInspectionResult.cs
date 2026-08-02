using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Models;

public sealed class GameInstallationInspectionResult
{
    public string InstallPath { get; init; } = string.Empty;

    public bool InstallPathExists { get; init; }

    public bool ExecutableFound { get; init; }

    public string ExecutablePath { get; init; } = string.Empty;

    public string SteamAppsPath { get; init; } = string.Empty;

    public bool ReFrameworkDirectoryFound { get; init; }

    public bool ReFrameworkDllFound { get; init; }

    public string ReFrameworkDirectoryPath { get; init; } = string.Empty;

    public string ReFrameworkDllPath { get; init; } = string.Empty;

    public bool ArchipelagoLuaRootScriptFound { get; init; }

    public bool ArchipelagoLuaDirectoryFound { get; init; }

    public string ArchipelagoLuaRootScriptPath { get; init; } = string.Empty;

    public string ArchipelagoLuaDirectoryPath { get; init; } = string.Empty;

    public bool SeparateWaysDetected { get; init; }

    public string SeparateWaysManifestPath { get; init; } = string.Empty;

    public bool TreasureMapDetected { get; init; }

    public string TreasureMapManifestPath { get; init; } = string.Empty;

    public GameFingerprint Fingerprint { get; init; } = GameFingerprint.CreateDefault();

    public string DetectedBioRandGameVersion { get; init; } = string.Empty;

    public string DetectionSummary { get; init; } = string.Empty;

    public string FingerprintSummary { get; init; } = string.Empty;

    public bool ReFrameworkDetected => ReFrameworkDirectoryFound && ReFrameworkDllFound;

    public bool ArchipelagoLuaModDetected => ArchipelagoLuaRootScriptFound && ArchipelagoLuaDirectoryFound;

    public bool CanLaunch => InstallPathExists && ExecutableFound && !string.IsNullOrWhiteSpace(Fingerprint.FingerprintHash);

    public static GameInstallationInspectionResult CreateDefault()
    {
        return new GameInstallationInspectionResult
        {
            DetectionSummary = "Select your RE4R install path to detect the game version.",
            FingerprintSummary = "No RE4R install inspected yet.",
        };
    }
}
