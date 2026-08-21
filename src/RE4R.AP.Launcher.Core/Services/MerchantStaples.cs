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

        // Crafting inputs. These carry the ammo economy without selling ammo,
        // so they are the one place on this shelf that is deliberately NOT
        // modest (Cam, 2026-08-21).
        //
        // Gunpowder was 3 a chapter, which is 48 for a whole run. Rifle ammo
        // alone costs 12 gunpowder for 7 bullets, so the entire run's supply
        // was about 28 rifle rounds if you spent every grain on one gun. The
        // shelf stopped selling ammo on the premise that you would craft it,
        // and 48 gunpowder did not fund that premise.
        //
        // Worth remembering WHY this is our number to pick: vanilla carries
        // gunpowder as a SELL-ONLY row, so the merchant never sold it at all.
        // RestockStaples creates the purchasable row and turns stock limiting
        // on for it, so the cap is entirely ours, not something vanilla chose.
        //
        // Resources go up alongside it on purpose. Gunpowder is one input of
        // two; raising it alone would not open the bottleneck, it would just
        // move it onto Resources.
        new MerchantStaple(117606400, "Resources (Small)", 6, 800),
        new MerchantStaple(117601600, "Resource (Large)", 4, 1_600),
        new MerchantStaple(117600000, "Gunpowder", 24, 700),

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
