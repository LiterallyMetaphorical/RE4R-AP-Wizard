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

    /// <summary>
    /// The AP-authored Random Events choice from slot_data. Disabled for
    /// rooms whose apworld predates the option.
    /// </summary>
    public RandomEventsSlotData RandomEvents { get; init; } = RandomEventsSlotData.Disabled;

    /// <summary>
    /// Game mode: campaign, campaign_and_mercenaries, mercenaries_only (apworld 0.8.0).
    /// </summary>
    public string GameMode { get; init; } = "campaign";
}

