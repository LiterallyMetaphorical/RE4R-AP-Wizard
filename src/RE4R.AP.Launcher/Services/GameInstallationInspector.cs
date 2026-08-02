using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Models;

namespace RE4R.AP.Launcher.Services;

public sealed class GameInstallationInspector
{
    private const string Re4rExecutableName = "re4.exe";
    private const string SteamAppManifestName = "appmanifest_2050650.acf";
    private const string SeparateWaysAppManifestName = "appmanifest_2109300.acf";
    private const string SeparateWaysDlcAppId = "2109300";

    // Treasure Map: Expansion. It does not just reveal treasures on the map, it
    // ADDS spawns that do not otherwise exist, and 36 of our check locations sit
    // on them (every "dlc"-tagged placement in the fork's items.csv is one of
    // these treasures). Without the DLC those 36 checks cannot be collected at
    // all, so a seed that puts progression behind one is unfinishable.
    private const string TreasureMapAppManifestName = "appmanifest_2109301.acf";
    private const string TreasureMapDlcAppId = "2109301";
    private const string ReFrameworkDirectoryName = "reframework";
    private const string ReFrameworkDllName = "dinput8.dll";

    private static readonly Dictionary<string, string> KnownSteamBuildToBioRandVersion =
        new(StringComparer.Ordinal)
        {
            ["22377325"] = "31 Mar 2026",
        };

    private static readonly Dictionary<string, string> KnownExeVersionToBioRandVersion =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["1.5.9.0"] = "31 Mar 2026",
        };

    public static IReadOnlyList<string> SupportedBioRandGameVersions { get; } =
        new[] { "4 Mar 2025", "3 Feb 2026", "31 Mar 2026" };

    public GameInstallationInspectionResult Inspect(string? installPath)
    {
        if (string.IsNullOrWhiteSpace(installPath))
        {
            return GameInstallationInspectionResult.CreateDefault();
        }

        var trimmedPath = installPath.Trim();
        if (!Directory.Exists(trimmedPath))
        {
            return new GameInstallationInspectionResult
            {
                InstallPath = trimmedPath,
                DetectionSummary = "The selected RE4R install path does not exist.",
                FingerprintSummary = "No valid RE4R install found yet.",
            };
        }

        var executablePath = Path.Combine(trimmedPath, Re4rExecutableName);
        var executableFound = File.Exists(executablePath);
        var steamAppsDirectory = FindSteamAppsDirectory(trimmedPath);
        var buildId = TryReadSteamBuildId(steamAppsDirectory);
        var reFrameworkDirectoryPath = Path.Combine(trimmedPath, ReFrameworkDirectoryName);
        var reFrameworkDllPath = Path.Combine(trimmedPath, ReFrameworkDllName);
        var archipelagoLuaRootScriptPath = Path.Combine(trimmedPath, "reframework", "autorun", "ArchipelagoRE4R.lua");
        var archipelagoLuaDirectoryPath = Path.Combine(trimmedPath, "reframework", "autorun", "ArchipelagoRE4R");
        var gameManifestPath = string.IsNullOrWhiteSpace(steamAppsDirectory)
            ? string.Empty
            : Path.Combine(steamAppsDirectory, SteamAppManifestName);
        var separateWaysManifestPath = string.IsNullOrWhiteSpace(steamAppsDirectory)
            ? string.Empty
            : Path.Combine(steamAppsDirectory, SeparateWaysAppManifestName);
        var separateWaysDetected = IsDlcDetected(gameManifestPath, separateWaysManifestPath, SeparateWaysDlcAppId);
        var treasureMapManifestPath = string.IsNullOrWhiteSpace(steamAppsDirectory)
            ? string.Empty
            : Path.Combine(steamAppsDirectory, TreasureMapAppManifestName);
        var treasureMapDetected = IsDlcDetected(gameManifestPath, treasureMapManifestPath, TreasureMapDlcAppId);
        var fileVersionInfo = executableFound ? FileVersionInfo.GetVersionInfo(executablePath) : null;
        var productVersion = fileVersionInfo?.ProductVersion ?? string.Empty;
        var fileVersion = fileVersionInfo?.FileVersion ?? string.Empty;
        var fingerprintHash = ComputeFingerprintHash(buildId, productVersion, fileVersion);
        var detectedVersion = DetectBioRandGameVersion(buildId, productVersion, fileVersion);

        var fingerprint = new GameFingerprint
        {
            SteamBuildId = buildId,
            ExeProductVersion = productVersion,
            ExeFileVersion = fileVersion,
            FingerprintHash = fingerprintHash,
        };

        var fingerprintSummary = BuildFingerprintSummary(buildId, productVersion, fileVersion, executableFound);
        var detectionSummary = string.IsNullOrWhiteSpace(detectedVersion)
            ? "Detected the RE4R install fingerprint. Choose a BioRand game version manually if needed."
            : $"Detected BioRand game version {detectedVersion}.";

        return new GameInstallationInspectionResult
        {
            InstallPath = trimmedPath,
            InstallPathExists = true,
            ExecutableFound = executableFound,
            ExecutablePath = executablePath,
            SteamAppsPath = steamAppsDirectory,
            ReFrameworkDirectoryFound = Directory.Exists(reFrameworkDirectoryPath),
            ReFrameworkDllFound = File.Exists(reFrameworkDllPath),
            ReFrameworkDirectoryPath = reFrameworkDirectoryPath,
            ReFrameworkDllPath = reFrameworkDllPath,
            ArchipelagoLuaRootScriptFound = File.Exists(archipelagoLuaRootScriptPath),
            ArchipelagoLuaDirectoryFound = Directory.Exists(archipelagoLuaDirectoryPath),
            ArchipelagoLuaRootScriptPath = archipelagoLuaRootScriptPath,
            ArchipelagoLuaDirectoryPath = archipelagoLuaDirectoryPath,
            SeparateWaysDetected = separateWaysDetected,
            SeparateWaysManifestPath = separateWaysManifestPath,
            TreasureMapDetected = treasureMapDetected,
            TreasureMapManifestPath = treasureMapManifestPath,
            Fingerprint = fingerprint,
            DetectedBioRandGameVersion = detectedVersion,
            DetectionSummary = detectionSummary,
            FingerprintSummary = fingerprintSummary,
        };
    }

    private static string TryReadSteamBuildId(string steamAppsDirectory)
    {
        if (string.IsNullOrWhiteSpace(steamAppsDirectory))
        {
            return string.Empty;
        }

        var manifestPath = Path.Combine(steamAppsDirectory, SteamAppManifestName);
        if (!File.Exists(manifestPath))
        {
            return string.Empty;
        }

        try
        {
            var text = File.ReadAllText(manifestPath);
            var match = Regex.Match(text, "\"buildid\"\\s+\"(?<value>[^\"]+)\"", RegexOptions.IgnoreCase);
            return match.Success ? match.Groups["value"].Value.Trim() : string.Empty;
        }
        catch (IOException)
        {
            return string.Empty;
        }
        catch (UnauthorizedAccessException)
        {
            return string.Empty;
        }
    }

    /// <summary>
    /// A DLC counts as present if Steam wrote its own appmanifest, or if the
    /// base game's manifest lists it under "dlcappid" (how Steam records DLC
    /// that ships inside the base depots).
    /// </summary>
    private static bool IsDlcDetected(string gameManifestPath, string dlcManifestPath, string dlcAppId)
    {
        if (!string.IsNullOrWhiteSpace(dlcManifestPath) && File.Exists(dlcManifestPath))
        {
            return true;
        }

        if (string.IsNullOrWhiteSpace(gameManifestPath) || !File.Exists(gameManifestPath))
        {
            return false;
        }

        try
        {
            var text = File.ReadAllText(gameManifestPath);
            return Regex.IsMatch(
                text,
                "\"dlcappid\"\\s+\"" + Regex.Escape(SeparateWaysDlcAppId) + "\"",
                RegexOptions.IgnoreCase);
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static string FindSteamAppsDirectory(string installPath)
    {
        var current = new DirectoryInfo(installPath);
        while (current is not null)
        {
            if (string.Equals(current.Name, "steamapps", StringComparison.OrdinalIgnoreCase))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        return string.Empty;
    }

    private static string DetectBioRandGameVersion(
        string steamBuildId,
        string productVersion,
        string fileVersion)
    {
        if (!string.IsNullOrWhiteSpace(steamBuildId)
            && KnownSteamBuildToBioRandVersion.TryGetValue(steamBuildId, out var mappedFromBuild))
        {
            return mappedFromBuild;
        }

        if (!string.IsNullOrWhiteSpace(productVersion)
            && KnownExeVersionToBioRandVersion.TryGetValue(productVersion, out var mappedFromProduct))
        {
            return mappedFromProduct;
        }

        if (!string.IsNullOrWhiteSpace(fileVersion)
            && KnownExeVersionToBioRandVersion.TryGetValue(fileVersion, out var mappedFromFile))
        {
            return mappedFromFile;
        }

        return string.Empty;
    }

    private static string BuildFingerprintSummary(
        string steamBuildId,
        string productVersion,
        string fileVersion,
        bool executableFound)
    {
        if (!executableFound)
        {
            return "The selected install path exists, but re4.exe was not found.";
        }

        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(steamBuildId))
        {
            parts.Add($"Steam build {steamBuildId}");
        }

        if (!string.IsNullOrWhiteSpace(productVersion))
        {
            parts.Add($"ProductVersion {productVersion}");
        }

        if (!string.IsNullOrWhiteSpace(fileVersion))
        {
            parts.Add($"FileVersion {fileVersion}");
        }

        return parts.Count > 0
            ? string.Join(" | ", parts)
            : "re4.exe was found, but no version metadata could be read.";
    }

    private static string ComputeFingerprintHash(
        string steamBuildId,
        string productVersion,
        string fileVersion)
    {
        if (string.IsNullOrWhiteSpace(steamBuildId)
            && string.IsNullOrWhiteSpace(productVersion)
            && string.IsNullOrWhiteSpace(fileVersion))
        {
            return string.Empty;
        }

        var payload = $"{steamBuildId}\n{productVersion}\n{fileVersion}";
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(payload)));
    }
}
