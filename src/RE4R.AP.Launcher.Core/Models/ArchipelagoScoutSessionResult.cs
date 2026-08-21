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
    /// The apworld's merchant shop checks (D4), already resolved to what fill
    /// put in each slot. Disabled for rooms whose apworld predates the option
    /// or whose shop_checks is 0.
    /// </summary>
    public MerchantShopSlotData MerchantShop { get; init; } = MerchantShopSlotData.Disabled;

    /// <summary>
    /// The YAML's Random Weapon Stats choice: the multiworld holds the
    /// weapons, so their character rides with them and BioRand's own switch
    /// is pinned to this at patch time. Null for rooms whose apworld
    /// predates the key - those leave the switch player-controlled.
    /// </summary>
    public bool? RandomWeaponStats { get; init; }
}
