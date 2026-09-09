using System;
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
    /// The difficulty this room was generated for, as the game numbers them:
    /// 10 assisted, 20 standard, 30 hardcore, 40 professional. The merchant's
    /// shelf needs it, because a shop row carries one stock setting and the
    /// game only applies it on a matching difficulty (live 2026-09-06: a shelf
    /// written for Standard holds a single unit of everything on Assisted).
    /// 20 when the room does not say, which is what the patcher always wrote.
    /// </summary>
    public int SlotDifficulty { get; init; } = 20;

    /// <summary>
    /// The apworld's merchant shop checks (D4), already resolved to what fill
    /// put in each slot. Disabled for rooms whose apworld predates the option
    /// or whose shop_checks is 0.
    /// </summary>
    public MerchantShopSlotData MerchantShop { get; init; } = MerchantShopSlotData.Disabled;

    /// <summary>
    /// The Trade-tab checks and exchange economy (Phase 2), resolved from
    /// slot_data. Disabled for rooms whose apworld predates the option or
    /// whose trade_checks is 0 with no shuffled trade stock.
    /// </summary>
    public TradeShopSlotData TradeShop { get; init; } = TradeShopSlotData.Disabled;

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

    /// <summary>
    /// What the slot plays: "campaign", "campaign_and_mercenaries" or
    /// "mercenaries_only" (apworld 0.7.2 included_content). Absent in older
    /// rooms, which are campaign rooms.
    /// </summary>
    public string GameMode { get; init; } = "campaign";

    /// <summary>
    /// slot_data.patched_campaign (apworld 0.7.6): which campaign BioRand has
    /// to patch for this room, named the way the patcher names it, or "" for a
    /// room with no campaign at all. Null when the room did not say, which is
    /// every room made before 0.7.6.
    ///
    /// This is the question the launcher actually needs answered. GameMode is
    /// one string out of a fixed set and an unrecognised value falls back to
    /// "campaign", so a room built on content this launcher does not know
    /// would otherwise be patched as Leon's campaign without a word. The scout
    /// refuses a campaign it cannot patch rather than guessing.
    /// </summary>
    public string? PatchedCampaign { get; init; }

    /// <summary>
    /// What this launcher will actually patch: the room's own answer when it
    /// gave one, otherwise derived from GameMode for rooms older than 0.7.6.
    /// Empty means no campaign patch at all.
    /// </summary>
    public string CampaignPatchTarget =>
        PatchedCampaign ?? (IsMercenariesOnlyGameMode ? string.Empty : "Main Story");

    private bool IsMercenariesOnlyGameMode =>
        string.Equals(GameMode, "mercenaries_only", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// No campaign to patch, so BioRand is skipped and the Lua mod is the
    /// whole install. The only content that patches nothing is The
    /// Mercenaries.
    /// </summary>
    public bool MercenariesOnly => CampaignPatchTarget.Length == 0;

    public bool CampaignIncluded => !MercenariesOnly;

    /// <summary>slot_data.mercenaries: the rank checks this slot carries.</summary>
    public MercenariesSlotData Mercenaries { get; init; } = MercenariesSlotData.Disabled;
}
