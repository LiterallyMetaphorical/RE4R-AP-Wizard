using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class GameFingerprint
{
    [JsonPropertyName("steam_build_id")]
    public string SteamBuildId { get; set; } = string.Empty;

    [JsonPropertyName("exe_product_version")]
    public string ExeProductVersion { get; set; } = string.Empty;

    [JsonPropertyName("exe_file_version")]
    public string ExeFileVersion { get; set; } = string.Empty;

    [JsonPropertyName("fingerprint_hash")]
    public string FingerprintHash { get; set; } = string.Empty;

    public static GameFingerprint CreateDefault()
    {
        return new GameFingerprint();
    }

    public static GameFingerprint Sanitize(GameFingerprint? fingerprint)
    {
        return fingerprint ?? CreateDefault();
    }
}
