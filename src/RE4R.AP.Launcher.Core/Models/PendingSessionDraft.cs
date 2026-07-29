using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// The async-gap bridge (redesign step 2): a joiner configures + sends their
/// YAML, closes the launcher, and returns days later with a room address.
/// This draft persists everything they chose so the landing can greet them
/// with "got your room address?" instead of a blank Configure screen
/// (review: async-gap-no-draft).
/// Schema 2 (redesign step 4) adds the organizer side: role, chosen AP
/// install path, collected-YAML copies, and the pasted-back room details, so
/// the Generation Guidance checklist survives a launcher restart mid-setup.
/// Schema-1 drafts load fine - the organizer fields just default to empty.
/// </summary>
public sealed class PendingSessionDraft
{
    public const string JoinerRole = "joiner";

    public const string OrganizerRole = "organizer";

    [JsonPropertyName("schema_version")]
    public int SchemaVersion { get; set; } = 2;

    [JsonPropertyName("slot_name")]
    public string SlotName { get; set; } = string.Empty;

    [JsonPropertyName("difficulty")]
    public string Difficulty { get; set; } = "Standard";

    // Defaults live on the property so a schema-1/legacy draft that predates
    // these keys deserializes to the intended values (70 / markers) instead of
    // int-zero / null - System.Text.Json leaves an absent key at its initializer.
    [JsonPropertyName("progression_balancing")]
    public int ProgressionBalancing { get; set; } = 70;

    [JsonPropertyName("check_guidance")]
    public string CheckGuidance { get; set; } = "markers";

    [JsonPropertyName("death_link")]
    public bool DeathLink { get; set; }

    [JsonPropertyName("allow_missable_locations")]
    public bool AllowMissableLocations { get; set; }

    [JsonPropertyName("randomize_gated_keys")]
    public bool RandomizeGatedKeys { get; set; }

    [JsonPropertyName("unlocked_typewriter_stage_ids")]
    public List<string> UnlockedTypewriterStageIds { get; set; } = new();

    [JsonPropertyName("yaml_text")]
    public string YamlText { get; set; } = string.Empty;

    [JsonPropertyName("saved_at_utc")]
    public DateTimeOffset SavedAtUtc { get; set; }

    [JsonPropertyName("role")]
    public string Role { get; set; } = JoinerRole;

    [JsonPropertyName("ap_install_path")]
    public string ApInstallPath { get; set; } = string.Empty;

    [JsonPropertyName("collected_yamls")]
    public List<CollectedYamlDraftEntry> CollectedYamls { get; set; } = new();

    [JsonPropertyName("room_address")]
    public string RoomAddress { get; set; } = string.Empty;

    [JsonPropertyName("guidance_step")]
    public int GuidanceStep { get; set; }

    [JsonPropertyName("room_url")]
    public string RoomUrl { get; set; } = string.Empty;

    public bool IsOrganizer => string.Equals(Role, OrganizerRole, StringComparison.OrdinalIgnoreCase);
}
