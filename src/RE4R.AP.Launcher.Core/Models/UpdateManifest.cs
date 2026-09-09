using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// update-manifest.json, published as an asset on each GitHub release by
/// tools/build_update_assets.py. It describes the Lua-only payload that
/// release carries; the "is there a newer launcher" question is answered by
/// the release listing itself and needs no manifest.
/// </summary>
public sealed class UpdateManifest
{
    [JsonPropertyName("schema_version")]
    public int SchemaVersion { get; set; }

    [JsonPropertyName("payload")]
    public UpdateManifestPayload? Payload { get; set; }
}

public sealed class UpdateManifestPayload
{
    [JsonPropertyName("mod_version")]
    public string ModVersion { get; set; } = string.Empty;

    [JsonPropertyName("world_version")]
    public string WorldVersion { get; set; } = string.Empty;

    [JsonPropertyName("sha256")]
    public string Sha256 { get; set; } = string.Empty;

    [JsonPropertyName("url")]
    public string Url { get; set; } = string.Empty;

    [JsonPropertyName("notes")]
    public string Notes { get; set; } = string.Empty;
}
