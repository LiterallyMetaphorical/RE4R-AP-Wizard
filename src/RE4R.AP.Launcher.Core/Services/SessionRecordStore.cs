using System.Text.Json;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class SessionRecordStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    public SessionRecordStore(string appDataRootPath)
    {
        AppDataRootPath = appDataRootPath;
        SessionsDirectoryPath = Path.Combine(AppDataRootPath, "sessions");
    }

    public string AppDataRootPath { get; }

    public string SessionsDirectoryPath { get; }

    public event Action<string>? LogMessage;

    /// <summary>
    /// Records the player is still "in": status active or patch_in_progress,
    /// newest first. Under the one-multiworld-at-a-time model there should be
    /// at most one, but the store does not assume it.
    /// </summary>
    public async Task<IReadOnlyList<SessionRecord>> LoadOpenSessionsAsync(
        CancellationToken cancellationToken = default)
    {
        var all = await LoadAllAsync(cancellationToken);
        var open = all
            .Where(record => IsOpenStatus(record.Status))
            .OrderByDescending(record => record.LastOpenedAtUtc)
            .ToList();
        Log($"Found {open.Count} open session record(s) (active or patch-in-progress).");
        return open;
    }

    public async Task<SessionRecord?> TryLoadBySessionKeyAsync(
        string sessionKey,
        CancellationToken cancellationToken = default)
    {
        var sessionPath = GetSessionRecordPath(sessionKey);
        if (!File.Exists(sessionPath))
        {
            return null;
        }

        try
        {
            await using var stream = File.OpenRead(sessionPath);
            return await JsonSerializer.DeserializeAsync<SessionRecord>(stream, SerializerOptions, cancellationToken);
        }
        catch (JsonException)
        {
            Log($"Ignoring malformed session record at {sessionPath}. The file could not be parsed.");
            return null;
        }
        catch (IOException)
        {
            Log($"Ignoring unreadable session record at {sessionPath}. The file could not be opened.");
            return null;
        }
    }

    public async Task SaveAsync(SessionRecord record, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(record);

        Directory.CreateDirectory(SessionsDirectoryPath);
        var sessionPath = GetSessionRecordPath(record.SessionKey);
        Log($"Saving session record {record.SessionKey} for slot {record.SlotName} seed {record.SeedName} to {sessionPath}.");

        await using var stream = File.Create(sessionPath);
        await JsonSerializer.SerializeAsync(stream, record, SerializerOptions, cancellationToken);
        await stream.FlushAsync(cancellationToken);

        Log($"Saved session record to {sessionPath}.");
    }

    public Task DeleteAsync(string sessionKey, CancellationToken cancellationToken = default)
    {
        var sessionPath = GetSessionRecordPath(sessionKey);
        try
        {
            if (File.Exists(sessionPath))
            {
                File.Delete(sessionPath);
                Log($"Deleted session record {sessionKey}.");
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log($"Could not delete session record {sessionKey}: {ex.Message}");
        }

        return Task.CompletedTask;
    }

    /// <summary>
    /// One-multiworld-at-a-time: the RE4R install is physically patched for
    /// exactly one session, so making one current supersedes every other open
    /// record regardless of server or slot.
    /// </summary>
    public async Task SupersedeOtherActiveSessionsAsync(
        string currentSessionKey,
        CancellationToken cancellationToken = default)
    {
        var all = await LoadAllAsync(cancellationToken);
        foreach (var record in all)
        {
            if (!string.Equals(record.SessionKey, currentSessionKey, StringComparison.Ordinal)
                && IsOpenStatus(record.Status))
            {
                record.Status = "superseded";
                Log($"Marking prior open session {record.SessionKey} ({record.SeedName}, slot {record.SlotName}) as superseded.");
                await SaveAsync(record, cancellationToken);
            }
        }
    }

    /// <summary>
    /// Teardown (minimal v1): the player is done with this multiworld; the
    /// record stops surfacing as resumable but stays on disk as history.
    /// </summary>
    public async Task MarkFinishedAsync(string sessionKey, CancellationToken cancellationToken = default)
    {
        var record = await TryLoadBySessionKeyAsync(sessionKey, cancellationToken);
        if (record is null)
        {
            Log($"No session record found to mark finished for key {sessionKey}.");
            return;
        }

        record.Status = "finished";
        await SaveAsync(record, cancellationToken);
        Log($"Marked session {sessionKey} ({record.SeedName}, slot {record.SlotName}) as finished.");
    }

    public async Task<IReadOnlyList<SessionRecord>> LoadAllAsync(CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(SessionsDirectoryPath))
        {
            Log($"No session records directory exists yet at {SessionsDirectoryPath}.");
            return Array.Empty<SessionRecord>();
        }

        var records = new List<SessionRecord>();
        foreach (var filePath in Directory.EnumerateFiles(SessionsDirectoryPath, "*.json", SearchOption.TopDirectoryOnly))
        {
            try
            {
                await using var stream = File.OpenRead(filePath);
                var record = await JsonSerializer.DeserializeAsync<SessionRecord>(stream, SerializerOptions, cancellationToken);
                if (record is not null)
                {
                    records.Add(record);
                }
            }
            catch (JsonException)
            {
                Log($"Ignoring malformed session record at {filePath}. The file could not be parsed.");
            }
            catch (IOException)
            {
                Log($"Ignoring unreadable session record at {filePath}. The file could not be opened.");
            }
        }

        return records;
    }

    private static bool IsOpenStatus(string status)
    {
        return string.Equals(status, "active", StringComparison.OrdinalIgnoreCase)
            || string.Equals(status, "patch_in_progress", StringComparison.OrdinalIgnoreCase);
    }

    private string GetSessionRecordPath(string sessionKey)
    {
        return Path.Combine(SessionsDirectoryPath, $"{sessionKey}.json");
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
