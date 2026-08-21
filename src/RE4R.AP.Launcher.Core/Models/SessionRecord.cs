using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

public sealed class SessionRecord
{
    // Schema 2 (redesign step 2): keyed on seed+slot (server_slot_key removed;
    // the server address is mutable metadata), adds room_url, biorand_seed,
    // and the "patch_in_progress"/"finished" statuses.
    [JsonPropertyName("schema_version")]
    public int SchemaVersion { get; set; } = 2;

    [JsonPropertyName("session_key")]
    public string SessionKey { get; set; } = string.Empty;

    // Mutable metadata: the address the room was last seen at. Never part of
    // the session identity - archipelago.gg rooms can move ports on restart.
    [JsonPropertyName("normalized_server")]
    public string NormalizedServer { get; set; } = string.Empty;

    // Optional durable pointer to the archipelago.gg room page (decision #1);
    // captured when the player provides it, empty otherwise.
    [JsonPropertyName("room_url")]
    public string RoomUrl { get; set; } = string.Empty;

    [JsonPropertyName("is_hosted_session")]
    public bool IsHostedSession { get; set; }

    [JsonPropertyName("hosted_port")]
    public int? HostedPort { get; set; }

    [JsonPropertyName("slot_name")]
    public string SlotName { get; set; } = string.Empty;

    [JsonPropertyName("seed_name")]
    public string SeedName { get; set; } = string.Empty;

    // One of: "patch_in_progress" (breadcrumb written before game files are
    // touched; survives a crash mid-patch), "active", "superseded", "finished".
    [JsonPropertyName("status")]
    public string Status { get; set; } = "active";

    [JsonPropertyName("created_at_utc")]
    public DateTimeOffset CreatedAtUtc { get; set; }

    [JsonPropertyName("last_opened_at_utc")]
    public DateTimeOffset LastOpenedAtUtc { get; set; }

    [JsonPropertyName("patched_at_utc")]
    public DateTimeOffset PatchedAtUtc { get; set; }

    [JsonPropertyName("world_version")]
    public string WorldVersion { get; set; } = string.Empty;

    [JsonPropertyName("static_data_hash")]
    public string StaticDataHash { get; set; } = string.Empty;

    [JsonPropertyName("install_path_at_patch")]
    public string InstallPathAtPatch { get; set; } = string.Empty;

    [JsonPropertyName("game_fingerprint_at_patch")]
    public GameFingerprint GameFingerprintAtPatch { get; set; } = GameFingerprint.CreateDefault();

    [JsonPropertyName("biorand_version_at_patch")]
    public string BioRandVersionAtPatch { get; set; } = string.Empty;

    [JsonPropertyName("biorand_game_version_at_patch")]
    public string BioRandGameVersionAtPatch { get; set; } = string.Empty;

    [JsonPropertyName("setup_game_fingerprint_at_patch")]
    public string SetupGameFingerprintAtPatch { get; set; } = string.Empty;

    [JsonPropertyName("setup_completed_at_utc")]
    public DateTimeOffset? SetupCompletedAtUtc { get; set; }

    [JsonPropertyName("setup_biorand_version_at_patch")]
    public string SetupBioRandVersionAtPatch { get; set; } = string.Empty;

    [JsonPropertyName("placeholder_item_id")]
    public int PlaceholderItemId { get; set; }

    [JsonPropertyName("scouted_location_count")]
    public int ScoutedLocationCount { get; set; }

    [JsonPropertyName("guid_manifest_location_count")]
    public int GuidManifestLocationCount { get; set; }

    [JsonPropertyName("noguid_skipped_location_count")]
    public int NoGuidSkippedLocationCount { get; set; }

    // The deterministic BioRand seed and the exact options used at first
    // patch. Re-patching the same session reuses BOTH verbatim so the world
    // is reproduced identically (prerequisite for mode 2, step 4b).
    [JsonPropertyName("biorand_seed")]
    public int? BioRandSeed { get; set; }

    [JsonPropertyName("biorand_options")]
    public BioRandOptions BioRandOptions { get; set; } = BioRandOptions.CreateDefault();

    [JsonPropertyName("biorand_patch_files")]
    public List<StagedFileEntry> BioRandPatchFiles { get; set; } = new();

    [JsonPropertyName("lua_copy_files")]
    public List<StagedFileEntry> LuaCopyFiles { get; set; } = new();

    // The generator's spawn-gate echo for this patch (raw ap_enemy_gates.json).
    // Persisted so a relaunch or re-patch that skips generation still hands the
    // mod the same gate identities the installed pak was rolled with.
    [JsonPropertyName("enemy_gates_json")]
    public string EnemyGatesJson { get; set; } = string.Empty;
}
