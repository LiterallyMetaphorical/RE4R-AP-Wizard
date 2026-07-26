using System.Diagnostics;
using System.IO.Compression;
using System.Text.Json;
using System.Text.RegularExpressions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Utilities;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// File-system support for the Generation Guidance screen: detect/validate a
/// player-owned Archipelago install, copy the bundled RE4R.apworld into it,
/// stage collected player YAMLs into its Players folder, and find the
/// generated AP_*.zip. Guidance-only contract: this service never runs the
/// AP installer or ArchipelagoGenerate itself.
/// </summary>
public sealed class ArchipelagoInstallationService
{
    /// <summary>
    /// The Archipelago version this launcher's RE4R.apworld targets. Keep in
    /// sync with minimum/maximum_ap_version in the ArchipelagoRE4R repo's
    /// archipelago.json (and the provenance note in assets/Data).
    /// </summary>
    public const string ApVersionPin = "0.6.7";

    public const string ApReleasePageUrl = "https://github.com/ArchipelagoMW/Archipelago/releases/tag/" + ApVersionPin;

    public const string UploadsPageUrl = "https://archipelago.gg/uploads";

    public const string GenerateExeName = "ArchipelagoGenerate.exe";

    public static IReadOnlyList<string> GeneratorFileNames { get; } =
        new[] { GenerateExeName, "ArchipelagoGenerate", "Generate.py" };

    private const string CollectedYamlCacheDirectoryName = "collected_yamls";

    public ArchipelagoInstallationService(string appDataRootPath, string? apworldSourcePath = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(appDataRootPath);
        CollectedYamlCachePath = Path.Combine(appDataRootPath, CollectedYamlCacheDirectoryName);
        ApworldSourcePath = apworldSourcePath
            ?? Path.Combine(AppContext.BaseDirectory, "assets", "Data", "RE4R.apworld");
    }

    public string CollectedYamlCachePath { get; }

    public string ApworldSourcePath { get; }

    public static string DefaultInstallPath => OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Archipelago")
        : Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Archipelago");

    public static string GetCustomWorldsPath(string apRootPath) => Path.Combine(apRootPath, "custom_worlds");

    public static string GetPlayersPath(string apRootPath) => Path.Combine(apRootPath, "Players");

    public static string GetOutputPath(string apRootPath) => Path.Combine(apRootPath, "output");

    /// <summary>
    /// Inspects a candidate Archipelago folder. Usable = the folder exists
    /// and contains a Windows executable, extensionless Linux executable, or
    /// source-tree Generate.py; a readable file version is compared against
    /// <see cref="ApVersionPin"/> so the
    /// screen can warn - never block - on a mismatch.
    /// </summary>
    public ArchipelagoInstallInspection Inspect(string? apRootPath)
    {
        var trimmed = apRootPath?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(trimmed) || !Directory.Exists(trimmed))
        {
            return new ArchipelagoInstallInspection { RootPath = trimmed, RootExists = false };
        }

        var generatorPath = GeneratorFileNames
            .Select(fileName => Path.Combine(trimmed, fileName))
            .FirstOrDefault(File.Exists);
        if (generatorPath is null)
        {
            return new ArchipelagoInstallInspection { RootPath = trimmed, RootExists = true };
        }

        var version = TryReadExecutableVersion(generatorPath);
        return new ArchipelagoInstallInspection
        {
            RootPath = trimmed,
            RootExists = true,
            GeneratorPath = generatorPath,
            DetectedVersion = version,
            MatchesVersionPin = string.Equals(version, ApVersionPin, StringComparison.Ordinal),
        };
    }

    /// <summary>Returns the default-location install if it is usable, otherwise null.</summary>
    public ArchipelagoInstallInspection? TryDetectDefaultInstall()
    {
        var inspection = Inspect(DefaultInstallPath);
        return inspection.IsUsable ? inspection : null;
    }

    /// <summary>
    /// Reads world_version out of an apworld's archipelago.json manifest.
    /// Mirrors AP's own lookup: the zip root first, then any entry ending
    /// with archipelago.json. Returns empty when unreadable.
    /// </summary>
    public async Task<string> ReadApworldWorldVersionAsync(string apworldPath, CancellationToken cancellationToken = default)
    {
        try
        {
            return await Task.Run(
                () =>
                {
                    using var archive = ZipFile.OpenRead(apworldPath);
                    var manifestEntry = archive.GetEntry("archipelago.json")
                        ?? archive.Entries.FirstOrDefault(entry =>
                            entry.FullName.EndsWith("archipelago.json", StringComparison.OrdinalIgnoreCase));
                    if (manifestEntry is null)
                    {
                        return string.Empty;
                    }

                    using var stream = manifestEntry.Open();
                    using var document = JsonDocument.Parse(stream);
                    return document.RootElement.TryGetProperty("world_version", out var versionElement)
                        ? versionElement.GetString() ?? string.Empty
                        : string.Empty;
                },
                cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or JsonException or UnauthorizedAccessException)
        {
            return string.Empty;
        }
    }

    public enum ApworldCopyState
    {
        NotCopied,
        Outdated,
        UpToDate,
    }

    /// <summary>SHA-compares the bundled apworld against the copy in custom_worlds.</summary>
    public async Task<ApworldCopyState> GetApworldCopyStateAsync(string apRootPath, CancellationToken cancellationToken = default)
    {
        var destinationPath = GetApworldDestinationPath(apRootPath);
        if (!File.Exists(destinationPath))
        {
            return ApworldCopyState.NotCopied;
        }

        var sourceHash = await HashingUtilities.ComputeSha256HexAsync(ApworldSourcePath, cancellationToken).ConfigureAwait(false);
        var destinationHash = await HashingUtilities.ComputeSha256HexAsync(destinationPath, cancellationToken).ConfigureAwait(false);
        return string.Equals(sourceHash, destinationHash, StringComparison.OrdinalIgnoreCase)
            ? ApworldCopyState.UpToDate
            : ApworldCopyState.Outdated;
    }

    public string GetApworldDestinationPath(string apRootPath)
    {
        return Path.Combine(GetCustomWorldsPath(apRootPath), Path.GetFileName(ApworldSourcePath));
    }

    /// <summary>Copies the bundled RE4R.apworld into &lt;AP&gt;\custom_worlds (overwrites).</summary>
    public async Task<string> CopyApworldAsync(string apRootPath, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(ApworldSourcePath))
        {
            throw new FileNotFoundException(
                $"The bundled RE4R.apworld is missing at {ApworldSourcePath}. Re-install the launcher.",
                ApworldSourcePath);
        }

        var destinationPath = GetApworldDestinationPath(apRootPath);
        await Task.Run(
            () =>
            {
                Directory.CreateDirectory(GetCustomWorldsPath(apRootPath));
                File.Copy(ApworldSourcePath, destinationPath, overwrite: true);
            },
            cancellationToken).ConfigureAwait(false);
        return destinationPath;
    }

    /// <summary>
    /// Copies a player's YAML into the launcher's own cache the moment it is
    /// added, so the organizer's collection survives moved/deleted source
    /// files and launcher restarts. Same-name-different-content collisions
    /// get a numbered suffix; adding a byte-identical duplicate returns the
    /// existing cache entry with <c>isDuplicate</c> = true.
    /// </summary>
    public async Task<(string CachePath, string FileName, bool IsDuplicate)> CacheCollectedYamlAsync(
        string sourcePath,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(CollectedYamlCachePath);
        var sourceHash = await HashingUtilities.ComputeSha256HexAsync(sourcePath, cancellationToken).ConfigureAwait(false);

        var baseName = Path.GetFileNameWithoutExtension(sourcePath);
        var extension = Path.GetExtension(sourcePath);
        for (var attempt = 0; attempt < 100; attempt++)
        {
            var candidateName = attempt == 0 ? $"{baseName}{extension}" : $"{baseName} ({attempt + 1}){extension}";
            var candidatePath = Path.Combine(CollectedYamlCachePath, candidateName);
            if (File.Exists(candidatePath))
            {
                var existingHash = await HashingUtilities.ComputeSha256HexAsync(candidatePath, cancellationToken).ConfigureAwait(false);
                if (string.Equals(existingHash, sourceHash, StringComparison.OrdinalIgnoreCase))
                {
                    return (candidatePath, candidateName, IsDuplicate: true);
                }

                continue;
            }

            await Task.Run(() => File.Copy(sourcePath, candidatePath), cancellationToken).ConfigureAwait(false);
            return (candidatePath, candidateName, IsDuplicate: false);
        }

        throw new IOException($"Too many cached settings files share the name {baseName}{extension}. Clear {CollectedYamlCachePath}.");
    }

    /// <summary>Writes YAML text (the organizer's own Configure draft) into the cache under the given file name.</summary>
    public async Task<(string CachePath, string FileName)> CacheYamlTextAsync(
        string fileName,
        string yamlText,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(CollectedYamlCachePath);
        var cachePath = Path.Combine(CollectedYamlCachePath, fileName);
        await File.WriteAllTextAsync(cachePath, yamlText, cancellationToken).ConfigureAwait(false);
        return (cachePath, fileName);
    }

    public void RemoveCachedYaml(string cachePath)
    {
        // Only ever delete inside our own cache folder - a stale draft could
        // otherwise point Remove at an arbitrary file.
        var fullPath = Path.GetFullPath(cachePath);
        var cacheRoot = Path.GetFullPath(CollectedYamlCachePath);
        if (!fullPath.StartsWith(cacheRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        if (File.Exists(fullPath))
        {
            File.Delete(fullPath);
        }
    }

    /// <summary>Copies every cached YAML into &lt;AP&gt;\Players (overwrites same-name files).</summary>
    public async Task<int> CopyCachedYamlsToPlayersAsync(
        IReadOnlyList<CollectedYamlDraftEntry> entries,
        string apRootPath,
        CancellationToken cancellationToken = default)
    {
        var playersPath = GetPlayersPath(apRootPath);
        return await Task.Run(
            () =>
            {
                Directory.CreateDirectory(playersPath);
                var copied = 0;
                foreach (var entry in entries)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (!File.Exists(entry.CachePath))
                    {
                        continue;
                    }

                    File.Copy(entry.CachePath, Path.Combine(playersPath, entry.FileName), overwrite: true);
                    copied++;
                }

                return copied;
            },
            cancellationToken).ConfigureAwait(false);
    }

    public sealed class PlayersFolderState
    {
        public bool AllCollectedPresent { get; init; }

        public IReadOnlyList<string> ExtraYamlNames { get; init; } = Array.Empty<string>();
    }

    /// <summary>
    /// Checks whether every collected YAML is present (byte-identical) in
    /// &lt;AP&gt;\Players, and which OTHER yaml files sit there - generation
    /// reads every file in Players, so leftovers from an earlier multiworld
    /// silently join the new one.
    /// </summary>
    public async Task<PlayersFolderState> CheckPlayersFolderAsync(
        IReadOnlyList<CollectedYamlDraftEntry> entries,
        string apRootPath,
        CancellationToken cancellationToken = default)
    {
        var playersPath = GetPlayersPath(apRootPath);
        if (!Directory.Exists(playersPath))
        {
            return new PlayersFolderState { AllCollectedPresent = false };
        }

        var collectedNames = new HashSet<string>(entries.Select(entry => entry.FileName), StringComparer.OrdinalIgnoreCase);
        var allPresent = entries.Count > 0;
        foreach (var entry in entries)
        {
            var candidate = Path.Combine(playersPath, entry.FileName);
            if (!File.Exists(candidate) || !File.Exists(entry.CachePath))
            {
                allPresent = false;
                continue;
            }

            var cacheHash = await HashingUtilities.ComputeSha256HexAsync(entry.CachePath, cancellationToken).ConfigureAwait(false);
            var playerHash = await HashingUtilities.ComputeSha256HexAsync(candidate, cancellationToken).ConfigureAwait(false);
            if (!string.Equals(cacheHash, playerHash, StringComparison.OrdinalIgnoreCase))
            {
                allPresent = false;
            }
        }

        var extras = Directory.EnumerateFiles(playersPath)
            .Where(path =>
            {
                var extension = Path.GetExtension(path);
                return string.Equals(extension, ".yaml", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(extension, ".yml", StringComparison.OrdinalIgnoreCase);
            })
            .Select(Path.GetFileName)
            .Where(name => name is not null && !collectedNames.Contains(name))
            .Select(name => name!)
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new PlayersFolderState
        {
            AllCollectedPresent = allPresent,
            ExtraYamlNames = extras,
        };
    }

    /// <summary>Newest AP_*.zip in &lt;AP&gt;\output, or null.</summary>
    public FileInfo? FindNewestOutputZip(string apRootPath)
    {
        var outputPath = GetOutputPath(apRootPath);
        if (!Directory.Exists(outputPath))
        {
            return null;
        }

        return new DirectoryInfo(outputPath)
            .EnumerateFiles("AP_*.zip", SearchOption.TopDirectoryOnly)
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .FirstOrDefault();
    }

    public sealed class InstalledWorldsCatalog
    {
        public HashSet<string> GameNames { get; } = new(StringComparer.OrdinalIgnoreCase);

        public HashSet<string> NormalizedStems { get; } = new(StringComparer.Ordinal);
    }

    /// <summary>
    /// Builds a best-effort catalog of the worlds an AP install can generate
    /// for: apworld manifests carry exact game names; bare folders and
    /// manifest-less apworlds fall back to a normalized-stem heuristic. Used
    /// to softly flag collected YAMLs whose game has no installed world.
    /// </summary>
    public async Task<InstalledWorldsCatalog> LoadInstalledWorldsCatalogAsync(
        string apRootPath,
        CancellationToken cancellationToken = default)
    {
        return await Task.Run(
            () =>
            {
                var catalog = new InstalledWorldsCatalog();
                var worldDirectories = new[]
                {
                    Path.Combine(apRootPath, "lib", "worlds"),
                    GetCustomWorldsPath(apRootPath),
                    Path.Combine(apRootPath, "worlds"),
                };

                foreach (var directory in worldDirectories)
                {
                    if (!Directory.Exists(directory))
                    {
                        continue;
                    }

                    foreach (var apworldPath in Directory.EnumerateFiles(directory, "*.apworld", SearchOption.TopDirectoryOnly))
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        catalog.NormalizedStems.Add(NormalizeWorldName(Path.GetFileNameWithoutExtension(apworldPath)));
                        var gameName = TryReadApworldGameName(apworldPath);
                        if (!string.IsNullOrWhiteSpace(gameName))
                        {
                            catalog.GameNames.Add(gameName);
                        }
                    }

                    foreach (var worldDirectory in Directory.EnumerateDirectories(directory))
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        catalog.NormalizedStems.Add(NormalizeWorldName(Path.GetFileName(worldDirectory)));
                        var manifestPath = Path.Combine(worldDirectory, "archipelago.json");
                        if (File.Exists(manifestPath))
                        {
                            var gameName = TryReadManifestGameName(manifestPath);
                            if (!string.IsNullOrWhiteSpace(gameName))
                            {
                                catalog.GameNames.Add(gameName);
                            }
                        }
                    }
                }

                return catalog;
            },
            cancellationToken).ConfigureAwait(false);
    }

    public static bool IsGameSatisfied(InstalledWorldsCatalog catalog, string gameName)
    {
        if (string.IsNullOrWhiteSpace(gameName))
        {
            return false;
        }

        if (catalog.GameNames.Contains(gameName))
        {
            return true;
        }

        var normalized = NormalizeWorldName(gameName);
        return catalog.NormalizedStems.Any(stem =>
            stem.Length > 0
            && (string.Equals(stem, normalized, StringComparison.Ordinal)
                || normalized.Contains(stem, StringComparison.Ordinal)
                || stem.Contains(normalized, StringComparison.Ordinal)));
    }

    private static string TryReadApworldGameName(string apworldPath)
    {
        try
        {
            using var archive = ZipFile.OpenRead(apworldPath);
            var manifestEntry = archive.GetEntry("archipelago.json")
                ?? archive.Entries.FirstOrDefault(entry =>
                    entry.FullName.EndsWith("archipelago.json", StringComparison.OrdinalIgnoreCase));
            if (manifestEntry is null)
            {
                return string.Empty;
            }

            using var stream = manifestEntry.Open();
            using var document = JsonDocument.Parse(stream);
            return document.RootElement.TryGetProperty("game", out var gameElement)
                ? gameElement.GetString() ?? string.Empty
                : string.Empty;
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or JsonException or UnauthorizedAccessException)
        {
            return string.Empty;
        }
    }

    private static string TryReadManifestGameName(string manifestPath)
    {
        try
        {
            using var stream = File.OpenRead(manifestPath);
            using var document = JsonDocument.Parse(stream);
            return document.RootElement.TryGetProperty("game", out var gameElement)
                ? gameElement.GetString() ?? string.Empty
                : string.Empty;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return string.Empty;
        }
    }

    private static string NormalizeWorldName(string value)
    {
        return new string(value.Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();
    }

    private static string TryReadExecutableVersion(string executablePath)
    {
        try
        {
            var info = FileVersionInfo.GetVersionInfo(executablePath);
            var raw = !string.IsNullOrWhiteSpace(info.ProductVersion) ? info.ProductVersion : info.FileVersion;
            if (string.IsNullOrWhiteSpace(raw))
            {
                return string.Empty;
            }

            // "0.6.7.0" / "0.6.7+build" -> "0.6.7" (major.minor.build, the
            // shape AP's own version_tuple uses).
            var match = Regex.Match(raw, @"\d+\.\d+(\.\d+)?");
            if (!match.Success)
            {
                return string.Empty;
            }

            var parts = match.Value.Split('.');
            return parts.Length >= 3 ? $"{parts[0]}.{parts[1]}.{parts[2]}" : match.Value;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return string.Empty;
        }
    }
}
