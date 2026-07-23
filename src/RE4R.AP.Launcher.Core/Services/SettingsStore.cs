using System.Text.Json;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    public SettingsStore(string? appDataRootPath = null)
    {
        AppDataRootPath = appDataRootPath
            ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "RE4R-AP");
        SettingsFilePath = Path.Combine(AppDataRootPath, "settings.json");
    }

    public string AppDataRootPath { get; }

    public string SettingsFilePath { get; }

    public event Action<string>? LogMessage;

    public async Task<LauncherSettings> LoadAsync(CancellationToken cancellationToken = default)
    {
        Log($"Checking launcher settings at {SettingsFilePath}.");
        if (!File.Exists(SettingsFilePath))
        {
            Log($"No launcher settings file was found at {SettingsFilePath}. The launcher will use default settings until you save new ones.");
            return LauncherSettings.CreateDefault();
        }

        try
        {
            await using var stream = File.OpenRead(SettingsFilePath);
            var loaded = await JsonSerializer.DeserializeAsync<LauncherSettings>(
                stream,
                SerializerOptions,
                cancellationToken);

            Log($"Loaded launcher settings from {SettingsFilePath}.");
            return LauncherSettings.Sanitize(loaded);
        }
        catch (JsonException)
        {
            Log($"Launcher settings at {SettingsFilePath} could not be read because the file is malformed. The launcher will use defaults instead.");
            return LauncherSettings.CreateDefault();
        }
        catch (IOException)
        {
            Log($"Launcher settings at {SettingsFilePath} could not be read. The launcher will use defaults instead.");
            return LauncherSettings.CreateDefault();
        }
        catch (UnauthorizedAccessException)
        {
            Log($"Launcher settings at {SettingsFilePath} are not accessible. The launcher will use defaults instead.");
            return LauncherSettings.CreateDefault();
        }
    }

    public async Task SaveAsync(LauncherSettings settings, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(AppDataRootPath);
        Log($"Saving launcher settings to {SettingsFilePath}.");

        await using var stream = File.Create(SettingsFilePath);
        await JsonSerializer.SerializeAsync(
            stream,
            LauncherSettings.Sanitize(settings),
            SerializerOptions,
            cancellationToken);
        await stream.FlushAsync(cancellationToken);

        Log($"Saved launcher settings to {SettingsFilePath}.");
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
