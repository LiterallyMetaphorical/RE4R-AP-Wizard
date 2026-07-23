namespace RE4R.AP.Launcher.Core.Models;

public sealed class ArchipelagoScoutSessionResult
{
    public string NormalizedServer { get; init; } = string.Empty;

    public string SeedName { get; init; } = string.Empty;

    public int Team { get; init; }

    public int ConnectedPlayerSlot { get; init; }

    public IReadOnlyList<ScoutLocationResult> Locations { get; init; } = Array.Empty<ScoutLocationResult>();

    /// <summary>
    /// The room's exact location-id set for this slot (missing + checked from
    /// the Connected packet). Written into the game data folder at patch time
    /// so the in-game client never scouts ids the room does not have.
    /// </summary>
    public IReadOnlyList<long> RoomLocationIds { get; init; } = Array.Empty<long>();
}
