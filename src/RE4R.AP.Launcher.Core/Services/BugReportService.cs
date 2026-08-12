using System.IO.Compression;
using System.Text;
using RE4R.AP.Launcher.Core.Utilities;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Bundles the files a crash or bug report needs into one zip the player can
/// attach in Discord, so we stop chasing session records, framework logs, drop
/// audits and crash dumps one message at a time.
///
/// The launcher does NOT start the game (players launch from Steam) and
/// REFramework truncates re2_framework_log.txt at its own init, before our Lua
/// runs - so neither side can snapshot the previous session's log at game
/// start. The pragmatic cover is <see cref="RotateFrameworkLog"/>, called at
/// launcher touchpoints (startup, patch, report): it copies the current
/// framework log to an AppData backup whenever it is newer than the newest
/// backup, so the last session survives the relaunch the player came to the
/// launcher for. The crash dump is a separate file that survives relaunches on
/// its own, so crashes stay recoverable even when the log does not.
/// </summary>
public sealed class BugReportService
{
    private const int MaxFrameworkLogBackups = 5;

    private readonly string _appDataRootPath;

    public BugReportService(string appDataRootPath)
    {
        _appDataRootPath = appDataRootPath;
    }

    public string FrameworkLogBackupDirectoryPath =>
        Path.Combine(_appDataRootPath, "framework-logs");

    public string BugReportDirectoryPath =>
        Path.Combine(_appDataRootPath, "bug-reports");

    /// <summary>
    /// Preserve the current framework log if it is newer than the newest backup
    /// we hold. Best-effort: a diagnostic aid must never take the launcher down
    /// or block a workflow, so every failure is swallowed. Safe to call often -
    /// it no-ops when the log has not changed since the last backup.
    /// </summary>
    public void RotateFrameworkLog(string installPath)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(installPath))
            {
                return;
            }
            var currentLog = Path.Combine(installPath, "re2_framework_log.txt");
            if (!File.Exists(currentLog))
            {
                return;
            }

            Directory.CreateDirectory(FrameworkLogBackupDirectoryPath);
            var currentWriteUtc = File.GetLastWriteTimeUtc(currentLog);
            var backups = new DirectoryInfo(FrameworkLogBackupDirectoryPath)
                .GetFiles("re2_framework_log_*.txt");

            // Skip if we already hold a backup at least as fresh as this log:
            // repeated touchpoints in one session must not clone the same log.
            var newestBackupUtc = backups.Length == 0
                ? DateTime.MinValue
                : backups.Max(file => file.LastWriteTimeUtc);
            if (currentWriteUtc <= newestBackupUtc)
            {
                return;
            }

            var stamp = currentWriteUtc.ToLocalTime().ToString("yyyyMMdd_HHmmss");
            var destination = Path.Combine(
                FrameworkLogBackupDirectoryPath, $"re2_framework_log_{stamp}.txt");
            File.Copy(currentLog, destination, overwrite: true);
            // Preserve the source mtime so the freshness comparison above holds.
            File.SetLastWriteTimeUtc(destination, currentWriteUtc);

            PruneFrameworkLogBackups();
        }
        catch
        {
            // Never throw from a diagnostic aid.
        }
    }

    private void PruneFrameworkLogBackups()
    {
        try
        {
            var backups = new DirectoryInfo(FrameworkLogBackupDirectoryPath)
                .GetFiles("re2_framework_log_*.txt")
                .OrderByDescending(file => file.LastWriteTimeUtc)
                .Skip(MaxFrameworkLogBackups)
                .ToList();
            foreach (var stale in backups)
            {
                stale.Delete();
            }
        }
        catch
        {
            // Best-effort pruning only.
        }
    }

    /// <summary>
    /// Assemble the bug-report zip. Returns the zip path on success, or null if
    /// even the archive could not be written. Individual missing pieces are
    /// noted in the manifest rather than failing the whole report.
    /// </summary>
    public string? CreateBugReport(string installPath, string slotName, string launcherVersion)
    {
        try
        {
            // Capture the current framework log before anything else can move on.
            RotateFrameworkLog(installPath);
            LauncherFileLog.Flush();

            Directory.CreateDirectory(BugReportDirectoryPath);
            var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
            var safeSlot = SanitizeForFileName(string.IsNullOrWhiteSpace(slotName) ? "unknown" : slotName);
            var zipPath = Path.Combine(BugReportDirectoryPath, $"RE4R-bugreport-{safeSlot}-{stamp}.zip");

            var included = new List<string>();
            var missing = new List<string>();

            using (var archive = ZipFile.Open(zipPath, ZipArchiveMode.Create))
            {
                void TryAdd(string sourcePath, string entryName)
                {
                    try
                    {
                        if (File.Exists(sourcePath))
                        {
                            // Copy through a shared-read stream: the framework
                            // log and launcher log may be open for writing.
                            var entry = archive.CreateEntry(entryName, CompressionLevel.Optimal);
                            using var entryStream = entry.Open();
                            using var source = new FileStream(
                                sourcePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                            source.CopyTo(entryStream);
                            included.Add(entryName);
                        }
                        else
                        {
                            missing.Add(entryName);
                        }
                    }
                    catch (Exception ex)
                    {
                        missing.Add($"{entryName} (error: {ex.Message})");
                    }
                }

                // Launcher-side: newest session record and launcher log.
                var sessionRecord = NewestFile(Path.Combine(_appDataRootPath, "sessions"), "*.json");
                if (sessionRecord != null)
                {
                    TryAdd(sessionRecord, $"session/{Path.GetFileName(sessionRecord)}");
                }
                else
                {
                    missing.Add("session/<record>.json");
                }

                var launcherLog = NewestFile(LauncherFileLog.LogDirectoryPath, "launcher-*.log");
                if (launcherLog != null)
                {
                    TryAdd(launcherLog, $"launcher/{Path.GetFileName(launcherLog)}");
                }
                else
                {
                    missing.Add("launcher/launcher-<date>.log");
                }

                // Game-side: framework log (current + preserved backups), crash
                // dump, drop audit, marker edits.
                if (!string.IsNullOrWhiteSpace(installPath))
                {
                    TryAdd(Path.Combine(installPath, "re2_framework_log.txt"),
                        "framework/re2_framework_log.txt");
                    TryAdd(Path.Combine(installPath, "reframework_crash.dmp"),
                        "framework/reframework_crash.dmp");
                    var dataDir = Path.Combine(installPath, "reframework", "data", "ArchipelagoRE4R");
                    TryAdd(Path.Combine(dataDir, "drop_audit.json"),
                        "framework/drop_audit.json");
                    TryAdd(Path.Combine(dataDir, "marker_position_edits.json"),
                        "framework/marker_position_edits.json");
                }

                if (Directory.Exists(FrameworkLogBackupDirectoryPath))
                {
                    foreach (var backup in new DirectoryInfo(FrameworkLogBackupDirectoryPath)
                        .GetFiles("re2_framework_log_*.txt")
                        .OrderByDescending(file => file.LastWriteTimeUtc))
                    {
                        TryAdd(backup.FullName, $"framework-history/{backup.Name}");
                    }
                }

                // Manifest last, so it can report what landed.
                var manifest = BuildManifest(installPath, slotName, launcherVersion, included, missing);
                var manifestEntry = archive.CreateEntry("manifest.txt", CompressionLevel.Optimal);
                using var manifestStream = manifestEntry.Open();
                using var writer = new StreamWriter(manifestStream, new UTF8Encoding(false));
                writer.Write(manifest);
            }

            LauncherFileLog.Append($"Bug report written to {zipPath}");
            return zipPath;
        }
        catch (Exception ex)
        {
            LauncherFileLog.Append($"Bug report failed: {ex.Message}");
            return null;
        }
    }

    private static string BuildManifest(
        string installPath,
        string slotName,
        string launcherVersion,
        IReadOnlyList<string> included,
        IReadOnlyList<string> missing)
    {
        var sb = new StringBuilder();
        sb.AppendLine("RE4R AP bug report");
        sb.AppendLine("==================");
        sb.AppendLine($"Generated: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        sb.AppendLine($"Launcher version: {launcherVersion}");
        sb.AppendLine($"Slot name: {slotName}");
        sb.AppendLine($"Install path: {installPath}");
        sb.AppendLine();

        // The stale-patch check that was diagnostic gold for Dizzy: a BioRand
        // patch built against game files Steam later refreshed crashes on
        // content load. Flag it here so nobody has to eyeball timestamps.
        try
        {
            var exe = Path.Combine(installPath, "re4.exe");
            var patch = Path.Combine(installPath, "re_chunk_000.pak.patch_007.pak");
            if (File.Exists(exe) && File.Exists(patch))
            {
                var exeTime = File.GetLastWriteTime(exe);
                var patchTime = File.GetLastWriteTime(patch);
                sb.AppendLine("Patch freshness:");
                sb.AppendLine($"  re4.exe               last written {exeTime:yyyy-MM-dd HH:mm}");
                sb.AppendLine($"  ...patch_007.pak (AP) last written {patchTime:yyyy-MM-dd HH:mm}");
                if (patchTime < exeTime)
                {
                    sb.AppendLine("  WARNING: the AP patch is OLDER than the game files. Steam likely "
                        + "refreshed the game after patching - re-patch (verify + clear cache first).");
                }
                else
                {
                    sb.AppendLine("  OK: the AP patch is newer than the game files.");
                }
                sb.AppendLine();
            }
        }
        catch
        {
            // Freshness check is a nicety; skip on any error.
        }

        sb.AppendLine("Included:");
        foreach (var entry in included)
        {
            sb.AppendLine($"  + {entry}");
        }
        if (missing.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("Not found (may be normal - e.g. no crash dump if the game did not crash):");
            foreach (var entry in missing)
            {
                sb.AppendLine($"  - {entry}");
            }
        }
        return sb.ToString();
    }

    private static string? NewestFile(string directory, string pattern)
    {
        try
        {
            if (!Directory.Exists(directory))
            {
                return null;
            }
            return new DirectoryInfo(directory)
                .GetFiles(pattern)
                .OrderByDescending(file => file.LastWriteTimeUtc)
                .FirstOrDefault()?.FullName;
        }
        catch
        {
            return null;
        }
    }

    private static string SanitizeForFileName(string value)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var sb = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            sb.Append(Array.IndexOf(invalid, ch) >= 0 ? '_' : ch);
        }
        return sb.ToString();
    }
}
