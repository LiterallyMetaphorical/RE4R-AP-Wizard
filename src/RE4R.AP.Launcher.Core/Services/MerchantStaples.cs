namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// The merchant's baseline consumable supply (Cam, 2026-08-17).
///
/// Turning the buy tab into Archipelago checks took away the place a player
/// bought healing and crafting. Most of that supply moved into the multiworld
/// (the apworld steers every merchant check's filler toward staples), but the
/// pool delivers on the MULTIWORLD's clock, not the player's: a herb that
/// arrives in chapter 14 did nothing for you in chapter 3. So the shelf keeps
/// a small, reliable, priced supply as a safety net against starvation.
///
/// Deliberately modest. The pool carries the volume; this exists so the shelf
/// reads as a shop and so nobody is ever stuck without a heal. A generous
/// shelf here would make the pool's own consumables worthless.
///
/// AMMO IS DELIBERATELY ABSENT. RE4R's loop is that you craft ammo from
/// gunpowder and resources, and the pool now carries finished ammo at volume.
/// Selling ammo directly would devalue every ammo check in the multiworld, so
/// the shelf sells the crafting INPUTS instead, which is what vanilla does.
///
/// Prices here are only used for a staple the shop does not already stock.
/// The fork never overwrites an existing row's price, so vanilla pricing wins
/// wherever vanilla already sells the item.
/// </summary>
public static class MerchantStaples
{
    /// <summary>Chapters that restock, so the fork and the UI agree on totals.</summary>
    public const int RestockChapters = 16;

    public static readonly IReadOnlyList<MerchantStaple> All = new[]
    {
        // Healing: enough that a bad run can always buy its way back up,
        // not enough to replace finding herbs.
        new MerchantStaple(114400000, "Green Herb", 2, 1_000),
        new MerchantStaple(114401600, "Red Herb", 1, 2_000),
        new MerchantStaple(114403200, "Yellow Herb", 1, 4_000),
        new MerchantStaple(114416000, "First Aid Spray", 1, 5_000),

        // Crafting inputs. These carry the ammo economy without selling ammo.
        new MerchantStaple(117606400, "Resources (Small)", 3, 800),
        new MerchantStaple(117601600, "Resource (Large)", 2, 1_600),
        new MerchantStaple(117600000, "Gunpowder", 3, 700),

        // Combat consumables, priced high on purpose: a convenience, not a
        // supply line.
        new MerchantStaple(277075456, "Hand Grenade", 1, 3_000),
        new MerchantStaple(277078656, "Flash Grenade", 1, 2_000),
    };
}

/// <summary>
/// One staple row. <paramref name="PerChapter"/> units are added to the shelf
/// at every chapter waypoint, so the run-long supply is PerChapter x 16.
/// </summary>
public sealed record MerchantStaple(int ItemId, string Name, int PerChapter, int Price);
