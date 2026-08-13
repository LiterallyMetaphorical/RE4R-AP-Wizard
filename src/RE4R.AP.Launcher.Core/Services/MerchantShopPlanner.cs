using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Turns the apworld's shop slots into a patch plan (D4): every slot gets a
/// stand-in engine item id, and the pool's unique buyable items get named for
/// exclusion. The launcher owns this assignment because both downstream
/// consumers must agree on it - the fork writes catalog rows keyed on these
/// ids, and the mod recognises purchases by them.
/// </summary>
public static class MerchantShopPlanner
{
    /// <summary>
    /// Cut item ids the ItemID enum knows and neither campaign uses, so a
    /// shop row can adopt one without colliding with real content. The fork
    /// mints each into a working item by copying the AP placeholder's
    /// definition/messages/GUI resources onto it, which is also why order
    /// matters: the front of the table is entirely clean, while the last four
    /// already carry vanilla catalog rows the fork leaves alone.
    /// </summary>
    public static readonly IReadOnlyList<int> StandinItemIds = new[]
    {
        120481600, 120960000, 118880000, 118881600, 118883200, 118884800,
        118886400, 118892800, 118894400, 118896000, 118897600, 118899200,
        118900800, 118902400, 118908800, 118910400, 118918400, 123689600,
        123691200, 123692800, 112809600, 112811200, 112812800, 119291200,
    };

    /// <summary>
    /// Pool items the merchant must never SELL. These are the unique,
    /// upgradeable items that exist both in the multiworld pool and in the
    /// merchant's buyable catalog: selling one lets a player buy the very
    /// thing the multiworld placed (anticlimax) and, worse, own two copies of
    /// an upgradeable weapon - RE4R merges duplicate weapons to the
    /// un-upgraded state and silently wipes the upgrades. Consumables that
    /// overlap the pool (First Aid Spray, Resources) are deliberately NOT
    /// here: they are multi-source filler and removing them would just make
    /// the shop worse.
    ///
    /// Red9 is deliberately absent: its only world spot is an excluded
    /// possession-conditional one, so it is merchant-only for AP players and
    /// excluding it would delete the gun from the seed entirely.
    /// </summary>
    public static readonly IReadOnlyList<int> PoolUniqueBuyableItemIds = new[]
    {
        274995456, // W-870
        275158656, // LE 5
        275478656, // CQBR Assault Rifle
        116004800, // Biosensor Scope
    };

    public static IReadOnlyList<MerchantShopPlannedSlot> Plan(MerchantShopSlotData shop)
    {
        ArgumentNullException.ThrowIfNull(shop);
        if (!shop.Enabled || shop.Slots.Count == 0)
        {
            return Array.Empty<MerchantShopPlannedSlot>();
        }

        if (shop.Slots.Count > StandinItemIds.Count)
        {
            throw new Exceptions.ManifestBuildException(
                $"The room has {shop.Slots.Count} merchant shop checks but the launcher only knows "
                + $"{StandinItemIds.Count} stand-in item ids. Update the stand-in table to match the apworld.");
        }

        var planned = new List<MerchantShopPlannedSlot>(shop.Slots.Count);
        var used = new HashSet<int>();
        foreach (var slot in shop.Slots.OrderBy(entry => entry.Index))
        {
            // Stand-ins are assigned by slot ORDER, not slot index, so a room
            // with sparse indices still uses the clean front of the table.
            var standinItemId = StandinItemIds[planned.Count];
            if (!used.Add(standinItemId))
            {
                throw new Exceptions.ManifestBuildException(
                    $"Merchant shop stand-in item id {standinItemId} was assigned twice.");
            }

            if (!shop.Tiers.TryGetValue(slot.Classification, out var tier))
            {
                throw new Exceptions.ManifestBuildException(
                    $"Merchant shop slot {slot.Index} is classified '{slot.Classification}', "
                    + "which the room's tier table does not price.");
            }

            planned.Add(new MerchantShopPlannedSlot(slot, standinItemId, tier));
        }

        return planned;
    }
}

public sealed record MerchantShopPlannedSlot(
    MerchantShopSlot Slot,
    int StandinItemId,
    MerchantShopTier Tier);
