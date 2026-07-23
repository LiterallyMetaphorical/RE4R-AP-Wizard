namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// Outcome of a lightweight room probe: connect, read the server's unsolicited
/// RoomInfo packet (no authentication), disconnect.
/// </summary>
public sealed class RoomProbeResult
{
    /// <summary>Something accepted the websocket connection at the address.</summary>
    public bool Answered { get; init; }

    /// <summary>
    /// The seed_name from the RoomInfo packet, or empty when the server
    /// answered but never sent a readable RoomInfo (not an AP server, or a
    /// protocol change). An answering port is NOT necessarily your room -
    /// archipelago.gg recycles ports across rooms - so only a matching seed
    /// proves the session is really there.
    /// </summary>
    public string SeedName { get; init; } = string.Empty;

    /// <summary>The candidate address (ws/wss normalized) that answered.</summary>
    public string NormalizedServer { get; init; } = string.Empty;
}
