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

    // The tier markers start at. Defaults to the apworld's own default so
    // drafts saved before this option existed generate the same seed.
    [JsonPropertyName("marker_detail")]
    public string MarkerDetail { get; set; } = "locate";

    [JsonPropertyName("death_link")]
    public bool DeathLink { get; set; }

    [JsonPropertyName("allow_missable_locations")]
    public bool AllowMissableLocations { get; set; }

    // Replaces the retired randomize_gated_keys flag; unknown fields in older
    // drafts are ignored on load and these default to off.
    [JsonPropertyName("shuffle_keycards")]
    public bool ShuffleKeycards { get; set; }

    [JsonPropertyName("shuffle_merchant_gear")]
    public bool ShuffleMerchantGear { get; set; }

    [JsonPropertyName("starting_arsenal")]
    public int StartingArsenal { get; set; }

    // Trimmed Starting Arsenal type keys; null/absent means every type
    // (drafts from before the option existed load as the full set).
    [JsonPropertyName("starting_arsenal_types")]
    public List<string>? StartingArsenalTypes { get; set; }

    // Merchant check locality; null/absent in older drafts means mixed.
    [JsonPropertyName("merchant_checks")]
    public string? MerchantChecks { get; set; }

    [JsonPropertyName("random_weapon_stats")]
    public bool RandomWeaponStats { get; set; }

    [JsonPropertyName("minimize_backtracking")]
    public bool MinimizeBacktracking { get; set; }

    // EXPERIMENTAL apworld option; off by default, and absent in older drafts.
    [JsonPropertyName("random_events")]
    public bool RandomEvents { get; set; }

    // How many AP checks the merchant releases each chapter. The key changed
    // with rotation, and deliberately so: a draft saved before it holds a
    // TOTAL (up to 20), and reading that as a per-chapter rate would silently
    // multiply the shelf. An old draft falls back to the current default.
    [JsonPropertyName("merchant_checks_per_chapter")]
    public int MerchantChecksPerChapter { get; set; }

    // Default TRUE so drafts saved before this option existed keep the guide
    // on, matching the apworld default.
    [JsonPropertyName("tutorial")]
    public bool Tutorial { get; set; } = true;

    [JsonPropertyName("unlocked_typewriter_stage_ids")]
    public List<string> UnlockedTypewriterStageIds { get; set; } = new();

    // The AP item/location picks, stored in their collapsed form (group names
    // where a group is whole) so the draft reads the same as the YAML it
    // produced. Restoring expands groups back to members, so a bundle whose
    // groups changed between sessions still restores every name it can.
    public List<string> LocalItems { get; set; } = new();

    public List<string> NonLocalItems { get; set; } = new();

    public List<string> ExcludeLocations { get; set; } = new();

    public List<string> PriorityLocations { get; set; } = new();

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
