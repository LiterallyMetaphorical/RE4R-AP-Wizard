namespace RE4R.AP.Launcher.Core.Utilities;

/// <summary>
/// Best-effort persistent launcher log under %APPDATA%\RE4R-AP\logs.
/// Failures diagnosed from the in-memory transparency log alone are lost on
/// close or crash; this tee survives both. Diagnostics must never take the
/// launcher down, so every failure here is swallowed.
///
/// The writer is held open and flushed on a timer rather than reopened per
/// line: BioRand emits ~74k lines during a full setup harvest, and a
/// CreateDirectory + open/write/close cycle per line (on the same producer
/// thread that drains BioRand's stdout pipe) stalled the pipe and starved the
/// UI on slower disks (papercut #0). Buffered writes make the tee ~free; a 1 s
/// flush plus the crash-guard/close flush bound how much a hard crash can lose.
/// </summary>
public static class LauncherFileLog
{
    private static readonly object SyncRoot = new();
    private static readonly System.Threading.Timer FlushTimer =
        new(_ => Flush(), null, FlushIntervalMs, FlushIntervalMs);
    private const int FlushIntervalMs = 1000;

    private static StreamWriter? _writer;
    private static string? _writerDateStamp;

    public static string LogDirectoryPath { get; } = ResolveLogDirectoryPath();

    private static string ResolveLogDirectoryPath()
    {
        // Runs at type-init, outside Append's try/catch - it must not throw
        // either, or the first log call would surface a
        // TypeInitializationException inside a crash-guard handler.
        try
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "RE4R-AP",
                "logs");
        }
        catch
        {
            return "logs";
        }
    }

    public static void Append(string message)
    {
        try
        {
            var now = DateTime.Now;
            var stamp = now.ToString("yyyyMMdd");
            var line = $"[{now:HH:mm:ss}] {message}";
            lock (SyncRoot)
            {
                var writer = EnsureWriter(stamp);
                writer?.WriteLine(line);
            }
        }
        catch
        {
            // Never throw from logging.
        }
    }

    /// <summary>Flush buffered lines to disk. Safe to call anytime.</summary>
    public static void Flush()
    {
        try
        {
            lock (SyncRoot)
            {
                _writer?.Flush();
            }
        }
        catch
        {
            // Never throw from logging.
        }
    }

    /// <summary>Flush and release the file. Call on launcher shutdown.</summary>
    public static void Close()
    {
        try
        {
            lock (SyncRoot)
            {
                _writer?.Flush();
                _writer?.Dispose();
                _writer = null;
                _writerDateStamp = null;
            }
        }
        catch
        {
            // Never throw from logging.
        }
    }

    // Caller holds SyncRoot. Opens (or rolls over to) the day's log file.
    private static StreamWriter? EnsureWriter(string stamp)
    {
        if (_writer is not null && _writerDateStamp == stamp)
        {
            return _writer;
        }

        _writer?.Flush();
        _writer?.Dispose();
        _writer = null;

        Directory.CreateDirectory(LogDirectoryPath);
        // FileShare.ReadWrite so the user can open the log (or "Open Log
        // Folder" tooling can read it) while the launcher is still writing.
        var stream = new FileStream(
            Path.Combine(LogDirectoryPath, $"launcher-{stamp}.log"),
            FileMode.Append,
            FileAccess.Write,
            FileShare.ReadWrite);
        _writer = new StreamWriter(stream) { AutoFlush = false };
        _writerDateStamp = stamp;
        return _writer;
    }
}
