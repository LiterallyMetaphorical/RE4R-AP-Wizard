using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Utilities;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class BioRandProcessRunner
{
    private const string Re4rSteamAppId = "2050650";

    public delegate Task<int> ProcessExecutor(
        ProcessStartInfo startInfo,
        Action<string> onStdOut,
        Action<string> onStdErr,
        CancellationToken cancellationToken);

    private readonly SettingsStore _settingsStore;
    private readonly ProcessExecutor _processExecutor;
    private readonly Func<DateTimeOffset> _utcNow;

    public BioRandProcessRunner(
        SettingsStore? settingsStore = null,
        string? appDataRootPath = null,
        string? tempRootPath = null,
        string? assetsBioRandDirectoryPath = null,
        ProcessExecutor? processExecutor = null,
        Func<DateTimeOffset>? utcNow = null,
        string? localAppDataRootPath = null)
    {
        _settingsStore = settingsStore ?? new SettingsStore(appDataRootPath);
        _processExecutor = processExecutor ?? RunProcessAsync;
        _utcNow = utcNow ?? (() => DateTimeOffset.UtcNow);

        AppDataRootPath = appDataRootPath
            ?? _settingsStore.AppDataRootPath;
        // The BioRand cache is a large (~850 MB) rebuildable harvest of game
        // files - it must NOT live in roaming AppData (profile sync would drag
        // it around, and players never chose to store a gig there). Keep it in
        // LocalAppData. When a caller pins a custom appDataRootPath (isolation),
        // honour it so the cache stays contained under that root.
        LocalAppDataRootPath = localAppDataRootPath
            ?? (appDataRootPath is not null
                ? appDataRootPath
                : Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "RE4R-AP"));
        TempRootPath = tempRootPath
            ?? Path.Combine(Path.GetTempPath(), "RE4R-AP");
        AssetsBioRandDirectoryPath = assetsBioRandDirectoryPath
            ?? Path.Combine(AppContext.BaseDirectory, "assets", "BioRand");
        BioRandCacheDirectoryPath = Path.Combine(LocalAppDataRootPath, "biorand-cache");
        // Pre-2026-07-12 location (roaming AppData). Migrated out on demand.
        LegacyBioRandCacheDirectoryPath = Path.Combine(AppDataRootPath, "biorand-cache");
        StagingRootPath = Path.Combine(TempRootPath, "staging");
        ConfigRootPath = Path.Combine(TempRootPath, "configs");
    }

    public string AppDataRootPath { get; }

    public string LocalAppDataRootPath { get; }

    public string TempRootPath { get; }

    public string AssetsBioRandDirectoryPath { get; }

    public string BioRandCacheDirectoryPath { get; }

    public string LegacyBioRandCacheDirectoryPath { get; }

    public string StagingRootPath { get; }

    public string ConfigRootPath { get; }

    public event Action<string>? LogMessage;

    public string GetBioRandVersionDescriptor()
    {
        return ResolveBioRandCommand().VersionDescriptor;
    }

    public async Task<BioRandSetupResult> RunSetupAsync(
        BioRandSetupRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (string.IsNullOrWhiteSpace(request.Re4rInstallPath))
        {
            throw new BioRandProcessException("BioRand setup could not start because the RE4R install path is missing.");
        }

        var command = ResolveBioRandCommand();
        MigrateLegacyCacheIfNeeded();
        Directory.CreateDirectory(BioRandCacheDirectoryPath);

        var stdoutLines = new List<string>();
        var stderrLines = new List<string>();

        Log($"Running BioRand setup for {request.Re4rInstallPath}");

        var startInfo = CreateProcessStartInfo(command, BioRandCacheDirectoryPath, request.Re4rInstallPath);
        // --full is the fork's default since 2026-07-12, but stay explicit so a
        // future upstream rebase that flips the default back cannot silently
        // reintroduce the missing-file crash class (step-0 lights-scene crash).
        AppendCommandArguments(
            startInfo,
            command,
            "setup",
            "--full",
            "-i",
            request.Re4rInstallPath,
            "-o",
            BioRandCacheDirectoryPath);
        Log($"BioRand setup cache directory: {BioRandCacheDirectoryPath}");
        Log($"BioRand setup command: {FormatCommandLine(startInfo)}");

        // The harvest snapshots the game folder as "vanilla", but it reads the
        // whole pak stack - an installed AP patch pak would be baked into the
        // cache and every later generation would crash on already-patched
        // scenes (2026-07-21: "Unable to find door to replace"). Set our own
        // paks aside for the duration of the harvest.
        RestoreLeftoverPakStashes(request.Re4rInstallPath);
        var protonRecordedPatchFileNames = await CollectProtonRecordedPatchFileNamesAsync(
            request.Re4rInstallPath,
            cancellationToken);
        var knownPatchFileNames = request.ApPatchFileNames
            .Concat(protonRecordedPatchFileNames)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        var stashedPaks = StashApPatchPaks(request.Re4rInstallPath, knownPatchFileNames);

        int exitCode;
        try
        {
            try
            {
                exitCode = await _processExecutor(
                    startInfo,
                    line =>
                    {
                        stdoutLines.Add(line);
                        Log($"[BioRand] {line}");
                    },
                    line =>
                    {
                        stderrLines.Add(line);
                        Log($"[BioRand][stderr] {line}");
                    },
                    cancellationToken);
            }
            catch (Exception ex) when (ex is not BioRandProcessException)
            {
                throw new BioRandProcessException("BioRand setup could not start or complete. Check that the bundled BioRand files are present and try again.", ex);
            }
        }
        finally
        {
            RestorePakStashes(stashedPaks);
        }

        if (exitCode != 0)
        {
            var errorMessage = $"BioRand setup failed with exit code {exitCode}. Check the [BioRand] log lines above for the first error and then try setup again.";
            Log(errorMessage);
            return new BioRandSetupResult
            {
                Success = false,
                ExitCode = exitCode,
                BioRandVersionDescriptor = command.VersionDescriptor,
                ErrorMessage = errorMessage,
                CacheDirectoryPath = BioRandCacheDirectoryPath,
                StandardOutputLines = stdoutLines,
                StandardErrorLines = stderrLines,
            };
        }

        var harvestPoisonedMessage = VerifyHarvestIsVanilla(request.Re4rInstallPath);
        if (harvestPoisonedMessage is not null)
        {
            Log(harvestPoisonedMessage);
            return new BioRandSetupResult
            {
                Success = false,
                ExitCode = exitCode,
                BioRandVersionDescriptor = command.VersionDescriptor,
                ErrorMessage = harvestPoisonedMessage,
                CacheDirectoryPath = BioRandCacheDirectoryPath,
                StandardOutputLines = stdoutLines,
                StandardErrorLines = stderrLines,
            };
        }

        var settings = await _settingsStore.LoadAsync(cancellationToken);
        settings.CurrentGameFingerprint = GameFingerprint.Sanitize(request.GameFingerprint);
        settings.SetupGameFingerprint = settings.CurrentGameFingerprint.FingerprintHash;
        settings.SetupCompletedAtUtc = _utcNow();
        settings.SetupBioRandVersion = command.VersionDescriptor;
        await _settingsStore.SaveAsync(settings, cancellationToken);

        Log($"BioRand setup completed successfully. Cache is ready at {BioRandCacheDirectoryPath} ({FormatSize(GetCacheSizeBytes())}). You can clear it any time from Setup Status.");

        return new BioRandSetupResult
        {
            Success = true,
            ExitCode = exitCode,
            BioRandVersionDescriptor = command.VersionDescriptor,
            CacheDirectoryPath = BioRandCacheDirectoryPath,
            StandardOutputLines = stdoutLines,
            StandardErrorLines = stderrLines,
        };
    }

    private const string PakStashSuffix = ".ap-setup-stash";

    // Sentinel for a clean harvest: SkipFirstCabinDoorPatch's target door in
    // this scene. Every BioRand-generated patch pak ships the scene with that
    // door already replaced, so a freshly harvested "vanilla" copy that lacks
    // the GUID was read through a BioRand pak still installed in the game
    // folder - generation would later die with "Unable to find door to
    // replace". Guid.ToByteArray() matches the RSZ on-disk GUID layout.
    // One sentinel is not coverage. The original single st40 check is late-game,
    // so a mod that rewrites the OPENING of the game passed it silently and the
    // clean bill of health actively misled the diagnosis (live 2026-08-02).
    // These are the scenes BioRand's own start-up patches read, so a harvest that
    // fails any of them is guaranteed to crash generation later. Every GUID here
    // was verified present in a known-good harvest.
    private sealed record HarvestSentinel(string Area, string RelativePath, Guid ObjectGuid);

    private static readonly IReadOnlyList<HarvestSentinel> HarvestSentinels = new[]
    {
        new HarvestSentinel(
            "the Chapter 1 opening",
            Path.Combine("natives", "stm", "_chainsaw", "leveldesign", "chapter", "cp10_chp1_1", "level_cp10_chp1_1_010.scn.20"),
            new Guid("9fc712ca-478c-45b5-be12-5233edf4fe95")),
        new HarvestSentinel(
            "the cabin",
            Path.Combine("natives", "stm", "_chainsaw", "environment", "scene", "gimmick", "st43", "gimmick_st43_900.scn.20"),
            new Guid("7a2d6128-79f7-0a71-388f-0ea0a80ce6e7")),
        new HarvestSentinel(
            "the cabin approach",
            Path.Combine("natives", "stm", "_chainsaw", "environment", "scene", "gimmick", "st43", "gimmick_st43_301_p000.scn.20"),
            new Guid("3e5c7e73-fd33-49b6-b4ac-bba642abb1fc")),
        new HarvestSentinel(
            "the castle",
            Path.Combine("natives", "stm", "_chainsaw", "environment", "scene", "gimmick", "st40", "gimmick_st40_903_p000.scn.20"),
            new Guid("9a8b310d-6521-4905-bf55-fd1aeefbf2a3")),
    };

    // Vanilla RE4R's pak stack, per supported game version. The engine loads
    // re_chunk_000.pak.patch_NNN.pak in ascending order with later paks
    // overriding earlier ones, so ANY extra pak silently rewrites the game the
    // harvest is about to snapshot. Versions absent from this table are not
    // checked at all: guessing a maximum and blocking someone on a game build we
    // do not recognise is worse than missing the warning.
    private static readonly Dictionary<string, int> VanillaMaxPatchPakIndex =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["4 Mar 2025"] = 6,
            ["3 Feb 2026"] = 6,
            ["31 Mar 2026"] = 6,
        };

    /// <summary>
    /// Patch paks in the game folder that are neither vanilla nor ours. Steam's
    /// "verify integrity" does NOT delete files it does not know about, so a mod
    /// uninstalled months ago still overrides the game and poisons the harvest
    /// (live 2026-08-02: a Berserker mod left patch_007 to 011 behind, and four
    /// hours went into a crash that was really "your game is modded").
    /// Returns an empty list when the game version is unknown.
    /// </summary>
    public IReadOnlyList<string> FindForeignPatchPaks(
        string installPath,
        string? detectedGameVersion,
        IReadOnlyList<string> ourPatchFileNames)
    {
        if (string.IsNullOrWhiteSpace(installPath)
            || !Directory.Exists(installPath)
            || string.IsNullOrWhiteSpace(detectedGameVersion)
            || !VanillaMaxPatchPakIndex.TryGetValue(detectedGameVersion, out var vanillaMax))
        {
            return Array.Empty<string>();
        }

        var ours = new HashSet<string>(ourPatchFileNames, StringComparer.OrdinalIgnoreCase);
        var foreign = new List<string>();

        foreach (var path in Directory.EnumerateFiles(installPath, "re_chunk_000.pak.patch_*.pak", SearchOption.TopDirectoryOnly))
        {
            var fileName = Path.GetFileName(path);
            if (ours.Contains(fileName))
            {
                continue;
            }

            var match = Regex.Match(fileName, @"patch_(\d+)\.pak$", RegexOptions.IgnoreCase);
            if (!match.Success || !int.TryParse(match.Groups[1].Value, out var index))
            {
                continue;
            }

            if (index > vanillaMax)
            {
                foreign.Add(fileName);
            }
        }

        foreign.Sort(StringComparer.OrdinalIgnoreCase);
        return foreign;
    }

    private List<(string StashPath, string OriginalPath)> StashApPatchPaks(
        string installPath,
        IReadOnlyList<string> patchFileNames)
    {
        var stashed = new List<(string, string)>();
        foreach (var fileName in patchFileNames.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var originalPath = Path.Combine(installPath, fileName);
            if (!File.Exists(originalPath))
            {
                continue;
            }

            var stashPath = originalPath + PakStashSuffix;
            try
            {
                File.Move(originalPath, stashPath, overwrite: true);
                stashed.Add((stashPath, originalPath));
                Log($"Set {fileName} aside so setup snapshots the vanilla game, not the AP-patched one. It is restored right after.");
            }
            catch (Exception ex)
            {
                Log($"Could not set {fileName} aside for setup: {ex.Message}. The harvest check below will catch it if the cache came out non-vanilla.");
            }
        }

        return stashed;
    }

    private async Task<IReadOnlyList<string>> CollectProtonRecordedPatchFileNamesAsync(
        string installPath,
        CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsLinux())
        {
            return Array.Empty<string>();
        }

        var steamAppsPath = FindSteamAppsPath(installPath);
        if (steamAppsPath is null)
        {
            return Array.Empty<string>();
        }

        var usersPath = Path.Combine(
            steamAppsPath,
            "compatdata",
            Re4rSteamAppId,
            "pfx",
            "drive_c",
            "users");
        if (!Directory.Exists(usersPath))
        {
            return Array.Empty<string>();
        }

        var patchFileNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var userPath in Directory.EnumerateDirectories(usersPath))
        {
            var protonAppDataRoot = Path.Combine(userPath, "AppData", "Roaming", "RE4R-AP");
            if (!Directory.Exists(protonAppDataRoot))
            {
                continue;
            }

            var protonSessionStore = new SessionRecordStore(protonAppDataRoot);
            var records = await protonSessionStore.LoadAllAsync(cancellationToken);
            foreach (var fileName in records
                         .SelectMany(record => record.BioRandPatchFiles)
                         .Select(file => Path.GetFileName(file.RelativePath))
                         .Where(fileName => !string.IsNullOrWhiteSpace(fileName)))
            {
                patchFileNames.Add(fileName!);
            }
        }

        if (patchFileNames.Count > 0)
        {
            Log(
                $"Found {patchFileNames.Count} BioRand patch file name(s) in the RE4R Proton prefix; "
                + "they will be set aside while setup harvests the vanilla game.");
        }

        return patchFileNames.ToList();
    }

    private void RestorePakStashes(List<(string StashPath, string OriginalPath)> stashedPaks)
    {
        foreach (var (stashPath, originalPath) in stashedPaks)
        {
            try
            {
                if (File.Exists(originalPath))
                {
                    Log($"Not restoring {Path.GetFileName(originalPath)}: a new file with that name appeared during setup. The set-aside copy stays at {stashPath}.");
                    continue;
                }

                File.Move(stashPath, originalPath);
                Log($"Restored {Path.GetFileName(originalPath)} after setup.");
            }
            catch (Exception ex)
            {
                Log($"Failed to restore {Path.GetFileName(originalPath)} from {stashPath}: {ex.Message}. Move it back manually (remove the {PakStashSuffix} suffix) before launching RE4R.");
            }
        }
    }

    /// <summary>
    /// Self-heal from a crash mid-setup: any *.ap-setup-stash left in the game
    /// folder is a pak we set aside and never got to restore.
    /// </summary>
    private void RestoreLeftoverPakStashes(string installPath)
    {
        try
        {
            foreach (var stashPath in Directory.EnumerateFiles(installPath, "*" + PakStashSuffix, SearchOption.TopDirectoryOnly))
            {
                var originalPath = stashPath[..^PakStashSuffix.Length];
                if (File.Exists(originalPath))
                {
                    Log($"Leaving leftover {Path.GetFileName(stashPath)} in place: {Path.GetFileName(originalPath)} exists again (probably re-patched since).");
                    continue;
                }

                File.Move(stashPath, originalPath);
                Log($"Restored {Path.GetFileName(originalPath)} that an interrupted earlier setup had set aside.");
            }
        }
        catch (Exception ex)
        {
            Log($"Skipped the leftover set-aside sweep: {ex.Message}");
        }
    }

    /// <summary>
    /// Returns an error message when the harvested cache was read through a
    /// BioRand patch pak (see the sentinel note above), else null. Public so
    /// the workflow can also re-check an EXISTING "current" cache - a cache
    /// poisoned by a pre-shield launcher would otherwise never be examined
    /// again.
    /// </summary>
    public string? VerifyHarvestIsVanilla(string installPath)
    {
        var missingFiles = new List<string>();
        var modifiedAreas = new List<string>();

        foreach (var sentinel in HarvestSentinels)
        {
            var sentinelPath = Path.Combine(BioRandCacheDirectoryPath, sentinel.RelativePath);
            if (!File.Exists(sentinelPath))
            {
                missingFiles.Add(sentinel.Area);
                continue;
            }

            var bytes = File.ReadAllBytes(sentinelPath);
            if (bytes.AsSpan().IndexOf(sentinel.ObjectGuid.ToByteArray()) < 0)
            {
                modifiedAreas.Add(sentinel.Area);
            }
        }

        if (missingFiles.Count > 0)
        {
            return $"The BioRand cache is incomplete: it is missing the scene for {FormatList(missingFiles)}. "
                + "Clear the BioRand cache from Setup Status and run setup again.";
        }

        if (modifiedAreas.Count == 0)
        {
            return null;
        }

        var patchPaks = Directory.EnumerateFiles(installPath, "re_chunk_000.pak.patch_*.pak", SearchOption.TopDirectoryOnly)
            .Select(Path.GetFileName)
            .ToList();
        var pakListSuffix = patchPaks.Count > 0
            ? $" Patch paks currently in the game folder: {string.Join(", ", patchPaks)}."
            : string.Empty;

        return $"The BioRand cache was built from a MODIFIED game, not a clean one. {FormatList(modifiedAreas)} "
            + (modifiedAreas.Count == 1 ? "does" : "do")
            + " not match the real game, so generation will crash on those scenes."
            + pakListSuffix
            + " Vanilla ends at patch_006, so anything above that is a mod, even one you have already uninstalled:"
            + " Steam's Verify Integrity does not delete files it did not install."
            + " Delete the extra paks, then clear the BioRand cache in Setup Status and run setup again.";
    }

    private static string FormatList(IReadOnlyList<string> items)
    {
        return items.Count switch
        {
            0 => string.Empty,
            1 => items[0],
            2 => $"{items[0]} and {items[1]}",
            _ => $"{string.Join(", ", items.Take(items.Count - 1))} and {items[^1]}",
        };
    }

    /// <summary>
    /// Moves a pre-2026-07-12 cache out of roaming AppData into LocalAppData.
    /// The cache is a large rebuildable harvest, so a lost migration is not
    /// fatal - it simply rebuilds in the new location on the next setup. Always
    /// best-effort; never throws.
    /// </summary>
    public void MigrateLegacyCacheIfNeeded()
    {
        try
        {
            if (PathsEqual(LegacyBioRandCacheDirectoryPath, BioRandCacheDirectoryPath))
                return; // custom/isolated root: legacy and current are the same place
            if (!Directory.Exists(LegacyBioRandCacheDirectoryPath))
                return;

            if (Directory.Exists(BioRandCacheDirectoryPath))
            {
                // New location already populated - just drop the stale roaming copy.
                if (TryDeleteDirectory(LegacyBioRandCacheDirectoryPath))
                    Log($"Removed the old roaming BioRand cache at {LegacyBioRandCacheDirectoryPath} (a LocalAppData cache already exists).");
                return;
            }

            Directory.CreateDirectory(LocalAppDataRootPath);
            Directory.Move(LegacyBioRandCacheDirectoryPath, BioRandCacheDirectoryPath);
            Log($"Moved the BioRand cache out of roaming AppData into {BioRandCacheDirectoryPath} - a rebuildable ~850 MB harvest does not belong in a roaming profile.");
        }
        catch (Exception ex)
        {
            // Cross-volume move or a locked/owned file: clear the roaming copy so
            // it stops wasting profile space; setup rebuilds fresh in LocalAppData.
            Log($"Could not move the old BioRand cache automatically ({ex.Message}); it will be rebuilt in {BioRandCacheDirectoryPath}.");
            TryDeleteDirectory(LegacyBioRandCacheDirectoryPath);
        }
    }

    /// <summary>Total size of the current cache in bytes (0 if absent/unreadable).</summary>
    public long GetCacheSizeBytes()
    {
        try
        {
            return DirectorySizeBytes(BioRandCacheDirectoryPath);
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>
    /// Removes staging/config directories left by previous generations. Each
    /// generate run writes a fresh timestamped runId directory and the patch pak
    /// is copied into the game during install, so once a new run starts every
    /// prior run directory in %TEMP% is dead weight. Best-effort; never throws.
    /// </summary>
    private void PruneOldRunDirectories()
    {
        var reclaimed = 0L;
        var removed = 0;
        foreach (var root in new[] { StagingRootPath, ConfigRootPath })
        {
            if (!Directory.Exists(root))
                continue;
            foreach (var dir in Directory.EnumerateDirectories(root))
            {
                try
                {
                    reclaimed += DirectorySizeBytes(dir);
                }
                catch
                {
                    // Size is best-effort; still attempt the delete below.
                }
                if (TryDeleteDirectory(dir))
                    removed++;
            }
        }
        if (removed > 0)
            Log($"Cleaned up {removed} leftover BioRand staging/config folder(s) from previous patches ({FormatSize(reclaimed)} reclaimed).");
    }

    private static long DirectorySizeBytes(string path)
    {
        var dir = new DirectoryInfo(path);
        if (!dir.Exists)
            return 0;
        return dir.EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length);
    }

    /// <summary>
    /// Deletes the BioRand cache (both current and any lingering roaming copy).
    /// The next patch re-runs setup (~1 min) to rebuild it. Returns false if the
    /// current cache could not be fully removed.
    /// </summary>
    public bool ClearCache()
    {
        var currentRemoved = TryDeleteDirectory(BioRandCacheDirectoryPath);
        TryDeleteDirectory(LegacyBioRandCacheDirectoryPath);
        if (currentRemoved)
            Log("Cleared the BioRand cache. The next patch will re-run setup (about a minute) to rebuild it.");
        else
            Log($"Could not fully clear the BioRand cache at {BioRandCacheDirectoryPath}. If the launcher was ever run as administrator, some files may be owned by Administrators - delete the folder from an elevated File Explorer, and avoid running the launcher elevated in future.");
        return currentRemoved;
    }

    private static bool PathsEqual(string a, string b)
    {
        return string.Equals(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)),
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)),
            StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryDeleteDirectory(string path)
    {
        try
        {
            if (!Directory.Exists(path))
                return true;

            // Harvested game files can carry the read-only attribute, which makes
            // Directory.Delete throw UnauthorizedAccessException; clear it first.
            var dir = new DirectoryInfo(path);
            foreach (var info in dir.EnumerateFileSystemInfos("*", SearchOption.AllDirectories))
            {
                if ((info.Attributes & FileAttributes.ReadOnly) != 0)
                    info.Attributes &= ~FileAttributes.ReadOnly;
            }
            Directory.Delete(path, recursive: true);
            return true;
        }
        catch
        {
            return false;
        }
    }

    public async Task<BioRandGenerationResult> RunGenerationAsync(
        BioRandGenerationRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (string.IsNullOrWhiteSpace(request.ConfigJson))
        {
            throw new BioRandProcessException("BioRand generation could not start because the AP config JSON was empty.");
        }

        if (!Directory.Exists(BioRandCacheDirectoryPath))
        {
            throw new BioRandProcessException(
                $"BioRand generation could not start because the BioRand cache directory was not found at {BioRandCacheDirectoryPath}. Run setup first.");
        }

        var command = ResolveBioRandCommand();
        Directory.CreateDirectory(StagingRootPath);
        Directory.CreateDirectory(ConfigRootPath);
        // Prior runs' staging/config dirs are dead once we start a new run (the
        // pak was already copied into the game at install time). Clear them so
        // %TEMP% doesn't accumulate a staging dir per patch.
        PruneOldRunDirectories();

        var runId = $"{_utcNow():yyyyMMddHHmmss}-{Guid.NewGuid():N}";
        var stagingDirectoryPath = Path.Combine(StagingRootPath, runId);
        var configDirectoryPath = Path.Combine(ConfigRootPath, runId);
        var configFilePath = Path.Combine(configDirectoryPath, "ap_config.json");

        Directory.CreateDirectory(stagingDirectoryPath);
        Directory.CreateDirectory(configDirectoryPath);

        await File.WriteAllTextAsync(configFilePath, request.ConfigJson, cancellationToken);
        Log($"Writing BioRand config to {configFilePath}");
        Log($"BioRand generation started with seed {request.Seed}");

        var stdoutLines = new List<string>();
        var stderrLines = new List<string>();

        var startInfo = CreateProcessStartInfo(command, stagingDirectoryPath, request.Re4rInstallPath);
        AppendCommandArguments(
            startInfo,
            command,
            "generate",
            "-i",
            BioRandCacheDirectoryPath,
            "-o",
            stagingDirectoryPath,
            "--seed",
            request.Seed.ToString(),
            "--config",
            configFilePath);
        Log($"BioRand staging directory: {stagingDirectoryPath}");
        Log($"BioRand generation command: {FormatCommandLine(startInfo)}");

        int exitCode;
        try
        {
            exitCode = await _processExecutor(
                startInfo,
                line =>
                {
                    stdoutLines.Add(line);
                    Log($"[BioRand] {line}");
                },
                line =>
                {
                    stderrLines.Add(line);
                    Log($"[BioRand][stderr] {line}");
                },
                cancellationToken);
        }
        catch (Exception ex) when (ex is not BioRandProcessException)
        {
            throw new BioRandProcessException("BioRand generation could not start or complete. Check the bundled BioRand files and the [BioRand] log lines, then try again.", ex);
        }

        if (exitCode != 0)
        {
            var errorMessage = DescribeGenerationFailure(exitCode, stdoutLines, stderrLines);
            Log(errorMessage);
            return new BioRandGenerationResult
            {
                Success = false,
                ExitCode = exitCode,
                BioRandVersionDescriptor = command.VersionDescriptor,
                ErrorMessage = errorMessage,
                ConfigFilePath = configFilePath,
                StagingDirectoryPath = stagingDirectoryPath,
                StandardOutputLines = stdoutLines,
                StandardErrorLines = stderrLines,
            };
        }

        var stagedFiles = await EnumerateStagedFilesAsync(stagingDirectoryPath, cancellationToken);
        var stagedBytes = stagedFiles.Sum(file => file.Size);
        Log($"BioRand generation complete. {stagedFiles.Count} files were staged in {stagingDirectoryPath} ({FormatSize(stagedBytes)} total).");
        LogStagedFileSummary(stagedFiles);

        // The generator's spawn-gate echo (ap-enemy-gates in the config ->
        // ap_enemy_gates.json beside the logs). Absent whenever gates were not
        // requested or the build predates them; the room file then carries no
        // enemy_gates section and the mod gates nothing.
        var enemyGatesJson = string.Empty;
        var enemyGatesPath = Path.Combine(stagingDirectoryPath, "ap_enemy_gates.json");
        if (File.Exists(enemyGatesPath))
        {
            enemyGatesJson = await File.ReadAllTextAsync(enemyGatesPath, cancellationToken);
            Log("BioRand emitted the enemy spawn-gate manifest (ap_enemy_gates.json).");
        }

        return new BioRandGenerationResult
        {
            Success = true,
            ExitCode = exitCode,
            BioRandVersionDescriptor = command.VersionDescriptor,
            ConfigFilePath = configFilePath,
            StagingDirectoryPath = stagingDirectoryPath,
            StagedFiles = stagedFiles,
            StandardOutputLines = stdoutLines,
            StandardErrorLines = stderrLines,
            EnemyGatesJson = enemyGatesJson,
        };
    }

    private async Task<IReadOnlyList<StagedFileEntry>> EnumerateStagedFilesAsync(
        string stagingDirectoryPath,
        CancellationToken cancellationToken)
    {
        // RE Engine only loads the BioRand patch as a numbered pak next to
        // re_chunk_000.pak in the game root; loose natives/ files are ignored
        // by the game, so they are never staged or installed.
        var pakFilePaths = Directory.EnumerateFiles(
                stagingDirectoryPath, "re_chunk_000.pak.patch_*.pak", SearchOption.TopDirectoryOnly)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (pakFilePaths.Count == 0)
        {
            throw new BioRandProcessException(
                $"BioRand finished but did not produce a patch pak file in {stagingDirectoryPath}. " +
                "The bundled BioRand build may be older than this launcher expects. Reinstall or rebuild the launcher bundle, then try again.");
        }

        if (pakFilePaths.Count > 1)
        {
            throw new BioRandProcessException(
                $"BioRand produced {pakFilePaths.Count} patch pak files in {stagingDirectoryPath}, but exactly one was expected. " +
                "Delete the staging folder and try again.");
        }

        var stagedFiles = new List<StagedFileEntry>();
        foreach (var filePath in pakFilePaths)
        {
            var relativePath = Path.GetRelativePath(stagingDirectoryPath, filePath)
                .Replace('\\', '/');
            stagedFiles.Add(
                new StagedFileEntry
                {
                    RelativePath = relativePath,
                    Sha256 = await HashingUtilities.ComputeSha256HexAsync(filePath, cancellationToken),
                    Size = new FileInfo(filePath).Length,
                });
        }

        return stagedFiles;
    }

    private ResolvedBioRandCommand ResolveBioRandCommand()
    {
        if (!Directory.Exists(AssetsBioRandDirectoryPath))
        {
            throw new BioRandProcessException(
                $"The launcher could not find its bundled BioRand files at {AssetsBioRandDirectoryPath}. Reinstall or rebuild the launcher bundle and try again.");
        }

        var directCandidates = new[]
        {
            "biorand-re4r.exe",
            "biorand-re4r",
        }
        .Select(fileName => Path.Combine(AssetsBioRandDirectoryPath, fileName))
        .FirstOrDefault(File.Exists);

        if (directCandidates is not null)
        {
            return new ResolvedBioRandCommand(
                directCandidates,
                UseDotNetHost: false,
                VersionDescriptor: DescribeBioRandVersion(directCandidates));
        }

        var dllCandidate = new[]
        {
            Path.Combine(AssetsBioRandDirectoryPath, "biorand-re4r.dll"),
        }
        .Concat(Directory.EnumerateFiles(AssetsBioRandDirectoryPath, "biorand-re4r*.dll", SearchOption.TopDirectoryOnly))
        .FirstOrDefault(File.Exists);

        if (dllCandidate is not null)
        {
            return new ResolvedBioRandCommand(
                dllCandidate,
                UseDotNetHost: true,
                VersionDescriptor: DescribeBioRandVersion(dllCandidate));
        }

        throw new BioRandProcessException(
            $"The launcher could not find a BioRand executable in {AssetsBioRandDirectoryPath}. " +
            "Expected biorand-re4r.exe, biorand-re4r, or biorand-re4r.dll.");
    }

    private static string DescribeBioRandVersion(string executablePath)
    {
        try
        {
            var fileVersion = FileVersionInfo.GetVersionInfo(executablePath);
            if (!string.IsNullOrWhiteSpace(fileVersion.ProductVersion))
            {
                return $"{Path.GetFileName(executablePath)} ({fileVersion.ProductVersion})";
            }
        }
        catch
        {
        }

        return Path.GetFileName(executablePath);
    }

    private static ProcessStartInfo CreateProcessStartInfo(
        ResolvedBioRandCommand command,
        string workingDirectory,
        string re4rInstallPath)
    {
        if (OperatingSystem.IsLinux()
            && string.Equals(Path.GetExtension(command.ExecutablePath), ".exe", StringComparison.OrdinalIgnoreCase))
        {
            var proton = ResolveProtonRuntime(re4rInstallPath);
            var protonStartInfo = CreateBaseProcessStartInfo(proton.ProtonPath, workingDirectory);
            protonStartInfo.ArgumentList.Add("run");
            protonStartInfo.ArgumentList.Add(command.ExecutablePath);
            protonStartInfo.Environment["STEAM_COMPAT_DATA_PATH"] = proton.CompatDataPath;
            protonStartInfo.Environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"] = proton.SteamClientInstallPath;
            return protonStartInfo;
        }

        return CreateBaseProcessStartInfo(
            command.UseDotNetHost ? "dotnet" : command.ExecutablePath,
            workingDirectory);
    }

    private static ProcessStartInfo CreateBaseProcessStartInfo(string fileName, string workingDirectory) =>
        new()
        {
            FileName = fileName,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };

    private static void AppendCommandArguments(
        ProcessStartInfo startInfo,
        ResolvedBioRandCommand command,
        params string[] arguments)
    {
        if (command.UseDotNetHost)
        {
            startInfo.ArgumentList.Add(command.ExecutablePath);
        }

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(
                OperatingSystem.IsLinux()
                    && string.Equals(Path.GetExtension(command.ExecutablePath), ".exe", StringComparison.OrdinalIgnoreCase)
                    ? ConvertUnixPathForWine(argument)
                    : argument);
        }
    }

    private static string ConvertUnixPathForWine(string argument)
    {
        if (!Path.IsPathRooted(argument))
        {
            return argument;
        }

        return $"Z:{argument.Replace('/', '\\')}";
    }

    private static ProtonRuntime ResolveProtonRuntime(string re4rInstallPath)
    {
        if (string.IsNullOrWhiteSpace(re4rInstallPath) || !Directory.Exists(re4rInstallPath))
        {
            throw new BioRandProcessException(
                "BioRand needs the selected RE4R Steam install path to locate its Proton prefix.");
        }

        var steamAppsPath = FindSteamAppsPath(re4rInstallPath);
        if (steamAppsPath is null)
        {
            throw new BioRandProcessException(
                $"Could not locate the steamapps folder above the selected RE4R install at {re4rInstallPath}.");
        }

        var compatDataPath = Path.Combine(steamAppsPath, "compatdata", Re4rSteamAppId);
        if (!Directory.Exists(compatDataPath))
        {
            throw new BioRandProcessException(
                $"The RE4R Proton prefix was not found at {compatDataPath}. Launch the game through Steam once, then try again.");
        }

        var configuredProtonPath = Environment.GetEnvironmentVariable("RE4R_AP_PROTON_PATH");
        var protonPath = !string.IsNullOrWhiteSpace(configuredProtonPath) && File.Exists(configuredProtonPath)
            ? configuredProtonPath
            : FindProtonPath(steamAppsPath);
        if (protonPath is null)
        {
            throw new BioRandProcessException(
                $"No Steam Proton runtime was found in {Path.Combine(steamAppsPath, "common")}. "
                + "Install Proton for this Steam library or set RE4R_AP_PROTON_PATH.");
        }

        var defaultSteamClientPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".local",
            "share",
            "Steam");
        var steamClientInstallPath = Directory.Exists(defaultSteamClientPath)
            ? defaultSteamClientPath
            : Directory.GetParent(steamAppsPath)?.FullName ?? steamAppsPath;

        return new ProtonRuntime(protonPath, compatDataPath, steamClientInstallPath);
    }

    private static string? FindSteamAppsPath(string installPath)
    {
        var current = new DirectoryInfo(Path.GetFullPath(installPath));
        while (current is not null)
        {
            if (string.Equals(current.Name, "steamapps", StringComparison.OrdinalIgnoreCase))
            {
                return current.FullName;
            }

            current = current.Parent;
        }

        return null;
    }

    private static string? FindProtonPath(string steamAppsPath)
    {
        var commonPath = Path.Combine(steamAppsPath, "common");
        if (!Directory.Exists(commonPath))
        {
            return null;
        }

        return Directory.EnumerateDirectories(commonPath, "Proton*", SearchOption.TopDirectoryOnly)
            .OrderByDescending(
                path => string.Equals(
                    Path.GetFileName(path),
                    "Proton - Experimental",
                    StringComparison.OrdinalIgnoreCase))
            .ThenByDescending(Path.GetFileName, StringComparer.OrdinalIgnoreCase)
            .Select(path => Path.Combine(path, "proton"))
            .FirstOrDefault(File.Exists);
    }

    private static async Task<int> RunProcessAsync(
        ProcessStartInfo startInfo,
        Action<string> onStdOut,
        Action<string> onStdErr,
        CancellationToken cancellationToken)
    {
        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var exited = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);

        process.OutputDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                onStdOut(args.Data);
            }
        };
        process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data))
            {
                onStdErr(args.Data);
            }
        };
        process.Exited += (_, _) => exited.TrySetResult(process.ExitCode);

        try
        {
            if (!process.Start())
            {
                throw new BioRandProcessException($"Failed to start process {startInfo.FileName}.");
            }
        }
        catch (Exception ex) when (ex is not BioRandProcessException)
        {
            throw new BioRandProcessException($"Failed to start process {startInfo.FileName}.", ex);
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var registration = cancellationToken.Register(
            () =>
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch
                {
                }
            });

        return await exited.Task.WaitAsync(cancellationToken);
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }

    private void LogStagedFileSummary(IReadOnlyList<StagedFileEntry> stagedFiles)
    {
        if (stagedFiles.Count == 0)
        {
            Log("No staged patch files were produced.");
            return;
        }

        var previewCount = Math.Min(10, stagedFiles.Count);
        Log($"Staged patch file summary ({previewCount} shown):");
        foreach (var stagedFile in stagedFiles.Take(previewCount))
        {
            Log($"  {stagedFile.RelativePath} ({FormatSize(stagedFile.Size)})");
        }

        if (stagedFiles.Count > previewCount)
        {
            Log($"  ... and {stagedFiles.Count - previewCount} more staged files.");
        }
    }

    /// <summary>
    /// Turns BioRand's exit code and captured output into something a player can
    /// act on. Input evidence is checked FIRST: the fork's CLI runs with
    /// PropagateExceptions and no top-level catch, so even a friendly
    /// RandomizerUserException ("The cache is incomplete...") prints as
    /// "Unhandled exception. ...Exception: ..." - generic exception text must
    /// not outrank the specific input markers inside it, or exactly the
    /// failures the repair steps were written for get told "internal error"
    /// instead. A NEGATIVE exit code is a Windows crash status; every crash of
    /// that class this project has diagnosed (access violations, the live
    /// 2026-08-02 stack overflow) came from parsing damaged or leftover-pak
    /// game/cache input, and a hard crash prints no evidence at all - so it is
    /// classified as input on the exit code alone.
    /// </summary>
    private static string DescribeGenerationFailure(
        int exitCode,
        IReadOnlyList<string> stdoutLines,
        IReadOnlyList<string> stderrLines)
    {
        var outputLines = stdoutLines.Concat(stderrLines);

        if (ContainsRecognizedInputEvidence(outputLines))
        {
            return $"BioRand found recognized damaged or mismatched game/cache input (exit code {exitCode}). The captured [BioRand] output is available in the launcher log; please provide that log if repair steps do not resolve this failure.";
        }

        if (exitCode < 0 && !ContainsInternalExceptionEvidence(outputLines))
        {
            return $"BioRand crashed (exit code {exitCode}), which in this project has always meant damaged or mismatched game/cache input rather than anything set wrong. The captured [BioRand] output is available in the launcher log; please provide that log if repair steps do not resolve this failure.";
        }

        if (ContainsInternalExceptionEvidence(outputLines))
        {
            return $"BioRand failed internally (exit code {exitCode}). The captured [BioRand] output is available in the launcher log; please provide that log when reporting this failure.";
        }

        return $"BioRand failed with exit code {exitCode}. No recognized game/cache input problem was identified. The captured [BioRand] output is available in the launcher log; please provide that log when reporting this failure.";
    }

    private static bool ContainsInternalExceptionEvidence(IEnumerable<string> outputLines)
    {
        return outputLines.Any(line =>
            line.Contains("Unhandled exception", StringComparison.OrdinalIgnoreCase)
            || Regex.IsMatch(line, @"\b(?:System\.)?[A-Za-z_][\w.]*Exception\b", RegexOptions.IgnoreCase));
    }

    private static bool ContainsRecognizedInputEvidence(IEnumerable<string> outputLines)
    {
        var markers = new[]
        {
            "Unable to find lights scene",
            "Unable to find door to replace",
            "cache is incomplete",
            "cache was built from a MODIFIED game",
            "does not match the real game",
            "checksum mismatch",
            "corrupt game file",
            "corrupted game file",
        };

        return outputLines.Any(line => markers.Any(marker =>
            line.Contains(marker, StringComparison.OrdinalIgnoreCase)));
    }

    private static string FormatCommandLine(ProcessStartInfo startInfo)
    {
        var arguments = startInfo.ArgumentList.Count > 0
            ? string.Join(" ", startInfo.ArgumentList.Select(QuoteArgument))
            : startInfo.Arguments;
        return string.IsNullOrWhiteSpace(arguments)
            ? QuoteArgument(startInfo.FileName)
            : $"{QuoteArgument(startInfo.FileName)} {arguments}";
    }

    private static string QuoteArgument(string value)
    {
        return value.IndexOfAny([' ', '\t', '"']) >= 0
            ? $"\"{value.Replace("\"", "\\\"")}\""
            : value;
    }

    public static string FormatSize(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB"];
        var value = Math.Abs((double)bytes);
        var unitIndex = 0;
        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }

        return string.Format(CultureInfo.InvariantCulture, "{0:0.##} {1}", value, units[unitIndex]);
    }

    private sealed record ResolvedBioRandCommand(
        string ExecutablePath,
        bool UseDotNetHost,
        string VersionDescriptor);

    private sealed record ProtonRuntime(
        string ProtonPath,
        string CompatDataPath,
        string SteamClientInstallPath);
}
