using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// Authoritative JSON schema for the shared AP connection file written to
/// <c>%APPDATA%\RE4R-AP\ap_connection.json</c>.
/// </summary>
/// <remarks>
/// This file is the launcher-owned contract shared by three components:
/// the launcher, the Python AP client, and the future in-game Lua
/// connection window. All three should read the same field names and
/// semantics from this model.
/// </remarks>
public sealed class ApConnectionInfo
{
    /// <summary>
    /// Canonical AP websocket server address, for example
    /// <c>ws://archipelago.gg:38281</c>.
    /// </summary>
    [JsonPropertyName("server_address")]
    public string ServerAddress { get; set; } = string.Empty;

    /// <summary>
    /// AP slot name used to authenticate the RE4R player.
    /// </summary>
    [JsonPropertyName("slot_name")]
    public string SlotName { get; set; } = string.Empty;

    /// <summary>
    /// Optional AP password. Empty string means no password.
    /// </summary>
    [JsonPropertyName("password")]
    public string Password { get; set; } = string.Empty;

    /// <summary>
    /// The room's page on the Archipelago host, when the player supplied one.
    /// The in-game port-recovery dialog shows it so a player whose room port
    /// moved can find the new port without alt-tabbing to the launcher; the
    /// mod cannot fetch web pages itself, so this is the pointer, not a fix.
    /// Empty string means the session was set up without a room URL.
    /// </summary>
    [JsonPropertyName("room_url")]
    public string RoomUrl { get; set; } = string.Empty;
}
