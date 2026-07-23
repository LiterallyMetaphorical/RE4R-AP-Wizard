using System.Text.Json;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class PendingSessionDraftStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    public PendingSessionDraftStore(string appDataRootPath)
    {
        DraftFilePath = Path.Combine(appDataRootPath, "pending_session.json");
    }

    public string DraftFilePath { get; }

    public event Action<string>? LogMessage;

    public async Task<PendingSessionDraft?> TryLoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(DraftFilePath))
        {
            return null;
        }

        try
        {
            await using var stream = File.OpenRead(DraftFilePath);
            var draft = await JsonSerializer.DeserializeAsync<PendingSessionDraft>(stream, SerializerOptions, cancellationToken);
            if (draft is not null)
            {
                Log($"Loaded the pending session draft for slot {draft.SlotName} (saved {draft.SavedAtUtc.ToLocalTime():yyyy-MM-dd HH:mm}).");
            }

            return draft;
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            Log($"Ignoring the pending session draft at {DraftFilePath}: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Loads the current draft (or starts a fresh one), applies the caller's
    /// changes, and saves. The Configure screen and the Generation Guidance
    /// screen both write to the same draft file - each must mutate only its
    /// own fields instead of serializing a from-scratch object, or a joiner
    /// save would silently wipe the organizer's checklist progress.
    /// </summary>
    public async Task<PendingSessionDraft> UpdateAsync(
        Action<PendingSessionDraft> mutate,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(mutate);

        var draft = await TryLoadAsync(cancellationToken) ?? new PendingSessionDraft();
        mutate(draft);
        draft.SchemaVersion = 2;
        draft.SavedAtUtc = DateTimeOffset.UtcNow;
        await SaveAsync(draft, cancellationToken);
        return draft;
    }

    public async Task SaveAsync(PendingSessionDraft draft, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(draft);

        Directory.CreateDirectory(Path.GetDirectoryName(DraftFilePath)!);
        await using var stream = File.Create(DraftFilePath);
        await JsonSerializer.SerializeAsync(stream, draft, SerializerOptions, cancellationToken);
        await stream.FlushAsync(cancellationToken);
        Log($"Saved the pending session draft for slot {draft.SlotName}.");
    }

    public Task DeleteAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            if (File.Exists(DraftFilePath))
            {
                File.Delete(DraftFilePath);
                Log("Removed the pending session draft (its session is now patched).");
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log($"Could not remove the pending session draft: {ex.Message}");
        }

        return Task.CompletedTask;
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
