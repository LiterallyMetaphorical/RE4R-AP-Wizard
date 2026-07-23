using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class LauncherSettings
{
    [JsonPropertyName("re4r_install_path")]
    public string Re4rInstallPath { get; set; } = string.Empty;

    [JsonPropertyName("last_server_address")]
    public string LastServerAddress { get; set; } = string.Empty;

    [JsonPropertyName("last_slot_name")]
    public string LastSlotName { get; set; } = string.Empty;

    [JsonPropertyName("last_biorand_options")]
    public BioRandOptions LastBioRandOptions { get; set; } = BioRandOptions.CreateDefault();

    [JsonPropertyName("current_game_fingerprint")]
    public GameFingerprint CurrentGameFingerprint { get; set; } = GameFingerprint.CreateDefault();

    [JsonPropertyName("setup_game_fingerprint")]
    public string SetupGameFingerprint { get; set; } = string.Empty;

    [JsonPropertyName("setup_completed_at_utc")]
    public DateTimeOffset? SetupCompletedAtUtc { get; set; }

    [JsonPropertyName("setup_biorand_version")]
    public string SetupBioRandVersion { get; set; } = string.Empty;

    public static LauncherSettings CreateDefault()
    {
        return new LauncherSettings();
    }

    public static LauncherSettings Sanitize(LauncherSettings? settings)
    {
        settings ??= CreateDefault();
        settings.LastBioRandOptions = BioRandOptions.Sanitize(settings.LastBioRandOptions);
        settings.CurrentGameFingerprint = GameFingerprint.Sanitize(settings.CurrentGameFingerprint);
        settings.Re4rInstallPath ??= string.Empty;
        settings.LastServerAddress ??= string.Empty;
        settings.LastSlotName ??= string.Empty;
        settings.SetupGameFingerprint ??= string.Empty;
        settings.SetupBioRandVersion ??= string.Empty;
        return settings;
    }
}
