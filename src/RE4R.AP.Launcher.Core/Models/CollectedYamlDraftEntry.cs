using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// One player YAML the organizer collected for generation. The file is
/// copied into the launcher's own cache folder the moment it is added, so
/// the checklist survives the source file being moved or deleted between
/// launcher sessions (the review doc's "collected-YAML copies").
/// </summary>
public sealed class CollectedYamlDraftEntry
{
    [JsonPropertyName("file_name")]
    public string FileName { get; set; } = string.Empty;

    [JsonPropertyName("cache_path")]
    public string CachePath { get; set; } = string.Empty;

    [JsonPropertyName("source_path")]
    public string SourcePath { get; set; } = string.Empty;

    [JsonPropertyName("added_at_utc")]
    public DateTimeOffset AddedAtUtc { get; set; }
}
