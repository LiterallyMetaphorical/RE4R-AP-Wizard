namespace RE4R.AP.Launcher.Core.Models;

public sealed class ArchipelagoScoutSessionResult
{
    public string NormalizedServer { get; init; } = string.Empty;

    public string SeedName { get; init; } = string.Empty;

    public int Team { get; init; }

    public int ConnectedPlayerSlot { get; init; }

    /// <summary>
    /// The slot name this session connected as. Forced into the BioRand
    /// config as "username", which is how the patch addresses its player
    /// (the welcome note's salutation, ${user.name} in randomized
    /// messages); without it the fork falls back to "player".
    /// </summary>
    public string SlotName { get; init; } = string.Empty;

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
    /// The YAML's weapon-randomization choice, stats half: the multiworld
    /// holds the weapons, so their character rides with them and BioRand's
    /// own switch is pinned to this at patch time. Null for rooms whose
    /// apworld predates the key - those leave the switch player-controlled.
    /// </summary>
    public bool? RandomWeaponStats { get; init; }

    /// <summary>
    /// The upgrades half of the same choice (off / stats_only / full in the
    /// YAML, carried as two booleans so old launchers keep reading the one
    /// they know). Null for rooms whose apworld predates the three-way -
    /// the manifest then falls back to forcing upgrades off whenever stats
    /// is off, which is the pair's only invalid shape.
    /// </summary>
    public bool? RandomWeaponUpgrades { get; init; }

    /// <summary>
    /// [Bonus Weapons] The YAML's consent to the permanent profile unlock
    /// the Extra Content trio (Handcannon, Chicago Sweeper, Primal Knife)
    /// needs while scattered. Carried into the room file to arm the mod's
    /// force-unlock for exactly those three; false for older rooms and
    /// non-consenting slots.
    /// </summary>
    public bool BonusWeaponsConsented { get; init; }
}
