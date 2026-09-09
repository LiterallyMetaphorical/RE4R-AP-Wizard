using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class LauncherSettings
{
    [JsonPropertyName("re4r_install_path")]
    public string Re4rInstallPath { get; set; } = string.Empty;

    // "dark" or "light". Dark is the default, so an absent or unreadable value
    // lands on it without needing a migration.
    [JsonPropertyName("theme")]
    public string Theme { get; set; } = "dark";

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

    // Startup update check against the project's GitHub releases. On by
    // default; false is the opt-out for people who want their tools silent.
    [JsonPropertyName("check_for_updates")]
    public bool CheckForUpdates { get; set; } = true;

    // "Not now" on the update banner remembers the version it dismissed, so
    // the same release never nags twice but the next one still shows.
    [JsonPropertyName("dismissed_payload_update")]
    public string DismissedPayloadUpdate { get; set; } = string.Empty;

    [JsonPropertyName("dismissed_launcher_update")]
    public string DismissedLauncherUpdate { get; set; } = string.Empty;

    /// <summary>
    /// Lets the settings screen offer Separate Ways, which is HELD OUT of this
    /// release. Off unless someone has hand-edited this file, which is the
    /// point. Ada's campaign generates, patches and plays as of 2026-09-07,
    /// but she has no typewriter warps and no merchant, so it is not shipped.
    /// The apworld refuses the content as well: generating from a yaml this
    /// flag produced needs RE4R_AP_ALLOW_SEPARATE_WAYS set in the environment.
    ///
    /// A flag rather than a hidden key sequence, so that it shows up in this
    /// file and in the launcher log. A room built with it on has to be
    /// identifiable from a bug report, or it looks like an ordinary fault
    /// (Cam, 2026-09-06).
    /// </summary>
    [JsonPropertyName("unlock_separate_ways")]
    public bool UnlockSeparateWays { get; set; }

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
        settings.DismissedPayloadUpdate ??= string.Empty;
        settings.DismissedLauncherUpdate ??= string.Empty;
        // Anything that is not an explicit "light" is dark, so a hand-edited or
        // truncated settings file cannot leave the launcher themeless.
        settings.Theme = string.Equals(settings.Theme?.Trim(), "light", StringComparison.OrdinalIgnoreCase)
            ? "light"
            : "dark";
        return settings;
    }
}
