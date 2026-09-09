using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// The identity slice of PAYLOAD_STAMP.json, written by tools/stage_payload.py
/// and riding every payload - bundled in assets or installed into the app-data
/// payload store by an update. Which mod build this is (mod_version) and which
/// world data it belongs to (world_version) is everything the update path
/// needs; provenance fields in the same file are for humans and stay unread.
/// </summary>
public sealed class PayloadStampFile
{
    [JsonPropertyName("staged_at_utc")]
    public string StagedAtUtc { get; set; } = string.Empty;

    [JsonPropertyName("payload")]
    public PayloadStampPayload Payload { get; set; } = new();
}

public sealed class PayloadStampPayload
{
    [JsonPropertyName("mod_version")]
    public string ModVersion { get; set; } = string.Empty;

    [JsonPropertyName("world_version")]
    public string WorldVersion { get; set; } = string.Empty;
}
