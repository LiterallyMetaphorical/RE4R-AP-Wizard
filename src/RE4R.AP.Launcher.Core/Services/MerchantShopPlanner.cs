using System.Security.Cryptography;
using System.Text;

using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Turns the apworld's shop checks into a patch plan (D4 + rotation).
///
/// Before rotation this was a one-to-one assignment: every check owned a
/// stand-in item id for the whole run, which capped a seed at 20 checks
/// because that is how many usable ids the game has. Now the ids are a pool of
/// ROWS. A room can carry up to 90 checks and the mod decides at runtime which
/// check each row is currently showing, so the launcher's job is to hand both
/// consumers the same three things: the row ids, the full check list, and a
/// stable message GUID per check so the fork can bake its text and the mod can
/// point a row at that text without either side inventing strings.
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

    /// <summary>
    /// How many of the stand-in ids can actually carry a shelf row. The table
    /// holds 24, but only the front 20 are clean: a pak built on all 24 crashes
    /// RE4R at startup, six seconds in, before the mod loads (proven
    /// 2026-08-17). Rotation removed the need for more - one row now carries
    /// several checks - so this number is the DISPLAY window, not a ceiling on
    /// how many checks a seed can hold.
    /// </summary>
    public const int MaxDisplayRows = 20;

    /// <summary>The clean front of the table, in row order.</summary>
    public static readonly IReadOnlyList<int> RowItemIds =
        StandinItemIds.Take(MaxDisplayRows).ToArray();

    public static MerchantShopPlan Plan(MerchantShopSlotData shop)
    {
        ArgumentNullException.ThrowIfNull(shop);
        if (!shop.Enabled || shop.Slots.Count == 0)
        {
            return MerchantShopPlan.Empty;
        }

        var planned = new List<MerchantShopPlannedSlot>(shop.Slots.Count);
        var seenIdentities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var slot in shop.Slots.OrderBy(entry => entry.Index))
        {
            // Identity is what the mod acks against, so a duplicate would make
            // two checks share one acknowledgement and silently lose one.
            if (!seenIdentities.Add(slot.Identity))
            {
                throw new Exceptions.ManifestBuildException(
                    $"Merchant shop check identity '{slot.Identity}' appears twice in the room. "
                    + "Identities must be unique; the apworld derives them per chapter and ordinal.");
            }

            if (!shop.Tiers.TryGetValue(slot.Classification, out var tier))
            {
                throw new Exceptions.ManifestBuildException(
                    $"Merchant shop check '{slot.Identity}' is classified '{slot.Classification}', "
                    + "which the room's tier table does not price.");
            }

            planned.Add(new MerchantShopPlannedSlot(
                slot,
                tier,
                DeriveMessageGuid("name", slot.Identity),
                DeriveMessageGuid("caption", slot.Identity)));
        }

        // Rows the fork actually has to mint. A room with fewer checks than
        // rows does not need the spare ones, and minting them would put empty
        // rows on the shelf.
        var rowCount = Math.Min(MaxDisplayRows, planned.Count);
        return new MerchantShopPlan(planned, AssignRowTiers(planned, rowCount, shop));
    }

    /// <summary>
    /// Give every row a FIXED tier, sized to the room's actual mix of checks.
    ///
    /// A row's price is baked into the pak, and rotation would otherwise need
    /// the runtime <c>registerItemPrice</c> lever, which nobody has proven
    /// works. Fixing the tier per row removes that dependency entirely: the
    /// mod only ever shows a check on a row of its own tier, so the displayed
    /// price is always right without a single runtime price call.
    ///
    /// Rows are allocated by largest remainder, and every classification the
    /// room actually contains is guaranteed at least one row - otherwise its
    /// checks could never be displayed at all.
    /// </summary>
    private static IReadOnlyList<MerchantShopRow> AssignRowTiers(
        IReadOnlyList<MerchantShopPlannedSlot> checks,
        int rowCount,
        MerchantShopSlotData shop)
    {
        var demand = checks
            .GroupBy(c => c.Slot.Classification, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);

        var allocation = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var classification in demand.Keys)
        {
            allocation[classification] = 1;
        }

        var spare = rowCount - allocation.Count;
        if (spare > 0)
        {
            // Largest remainder over what is left after the guaranteed row.
            var shares = demand
                .Select(entry => (entry.Key, Exact: (double)entry.Value / checks.Count * spare))
                .ToList();
            foreach (var share in shares)
            {
                allocation[share.Key] += (int)Math.Floor(share.Exact);
            }
            var placed = allocation.Values.Sum();
            foreach (var share in shares.OrderByDescending(s => s.Exact - Math.Floor(s.Exact)))
            {
                if (placed >= rowCount)
                {
                    break;
                }
                allocation[share.Key]++;
                placed++;
            }
        }

        var rows = new List<MerchantShopRow>(rowCount);
        foreach (var entry in allocation.OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (!shop.Tiers.TryGetValue(entry.Key, out var tier))
            {
                continue;
            }
            for (var i = 0; i < entry.Value && rows.Count < rowCount; i++)
            {
                rows.Add(new MerchantShopRow(RowItemIds[rows.Count], entry.Key, tier));
            }
        }

        return rows;
    }

    /// <summary>
    /// A stable message GUID per check, derived from the check's identity
    /// alone. The fork bakes its name and caption entries at these GUIDs and
    /// the mod points a row at them at runtime, so both sides agree without
    /// the fork ever having to report anything back to the launcher.
    ///
    /// MD5 here is an identifier derivation, not a security boundary - the
    /// same use the apworld makes of it for location codes.
    /// </summary>
    public static Guid DeriveMessageGuid(string kind, string identity)
    {
        var salt = Encoding.UTF8.GetBytes($"re4r:ap-merchant-msg:{kind}:{identity}");
        return new Guid(MD5.HashData(salt));
    }
}

public sealed record MerchantShopPlannedSlot(
    MerchantShopSlot Slot,
    MerchantShopTier Tier,
    Guid NameMsgGuid,
    Guid CaptionMsgGuid);

/// <summary>
/// One shelf row: an engine item id the fork mints a catalog row for, and the
/// FIXED tier it charges. The mod only shows a check on a row of the check's
/// own tier, which is what lets the price live in the pak instead of needing
/// an unproven runtime price call.
/// </summary>
public sealed record MerchantShopRow(int ItemId, string Classification, MerchantShopTier Tier);

/// <summary>
/// The whole shelf plan: every check in the room, plus the rows the fork mints
/// for them. Rows are a display window the mod rotates checks through.
/// </summary>
public sealed record MerchantShopPlan(
    IReadOnlyList<MerchantShopPlannedSlot> Checks,
    IReadOnlyList<MerchantShopRow> Rows)
{
    public static readonly MerchantShopPlan Empty =
        new(Array.Empty<MerchantShopPlannedSlot>(), Array.Empty<MerchantShopRow>());

    public int Count => Checks.Count;

    public IReadOnlyList<int> RowItemIds => Rows.Select(row => row.ItemId).ToArray();
}
