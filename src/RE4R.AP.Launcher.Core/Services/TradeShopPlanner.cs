using System.Security.Cryptography;
using System.Text;

using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Turns the apworld's Trade-tab checks into a patch plan (Trade takeover,
/// Phase 2). The buy-tab twin is <see cref="MerchantShopPlanner"/> and this
/// deliberately mirrors it, because the two tabs pose the same problem: many
/// more checks than there are places to show them.
///
/// The differences that matter:
/// <list type="bullet">
/// <item>Prices are SPINEL, and the tiers are 1 / 3 / 6 rather than pesetas.</item>
/// <item>Trade checks never refund, so there is no refund item to carry.</item>
/// <item>The tab's other entries - the infinite Velvet Blue and the three
/// restocking gems - are REAL items and need no stand-in, so the slots planned
/// here cover the rotating check window only.</item>
/// </list>
///
/// Slot count is capped by <see cref="MerchantShopPlanner.MaxTradeSlots"/>,
/// which is a partition of the same 20 safe stand-in ids the shelf draws from,
/// not a separate pool. See MERCHANT_TRADE_DESIGN.md 4.6.9 for why that
/// partition exists and what would lift it.
/// </summary>
public static class TradeShopPlanner
{
    /// <summary>
    /// Spinel prices the apworld's tier pattern can produce
    /// (trade.TRADE_TIER_BY_PRICE). A slot's price is BAKED into the pak, so
    /// the mod may only ever show a check whose tier matches the slot - the
    /// same trick the shelf uses to avoid an unproven runtime price call.
    /// </summary>
    public static readonly IReadOnlyDictionary<string, int> TierSpinel =
        new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
        {
            ["FILLER"] = 1,
            ["USEFUL"] = 3,
            ["PROGRESSION"] = 6,
        };

    public static TradeShopPlan Plan(TradeShopSlotData trade)
    {
        ArgumentNullException.ThrowIfNull(trade);
        if (!trade.Enabled || trade.Checks.Count == 0)
        {
            return TradeShopPlan.Empty;
        }

        var planned = new List<TradeShopPlannedCheck>(trade.Checks.Count);
        var seenIdentities = new HashSet<string>(StringComparer.Ordinal);
        foreach (var check in trade.Checks.OrderBy(entry => entry.ReleaseIndex))
        {
            // Identity is what the mod acks against, so a duplicate would make
            // two checks share one acknowledgement and silently lose one - the
            // same failure the shelf guards against.
            if (!seenIdentities.Add(check.Identity))
            {
                continue;
            }

            planned.Add(new TradeShopPlannedCheck(
                check,
                DeriveMessageGuid("name", check.Identity),
                DeriveMessageGuid("caption", check.Identity)));
        }

        if (planned.Count == 0)
        {
            return TradeShopPlan.Empty;
        }

        // A room with fewer checks than slots does not need the spare ones,
        // and minting them would leave empty slots sitting in the tab.
        var slotCount = Math.Min(MerchantShopPlanner.MaxTradeSlots, planned.Count);
        return new TradeShopPlan(planned, AssignSlotTiers(planned, slotCount));
    }

    /// <summary>
    /// Hand out the display slots across the tiers present in the room, so a
    /// check of every tier always has somewhere to appear.
    ///
    /// One slot per tier is guaranteed first - a tier with no slot would make
    /// its checks permanently undisplayable, which on the Trade tab means
    /// permanently unbuyable. The remainder splits by demand (largest
    /// remainder), so a room that is mostly 1-spinel checks mostly gets
    /// 1-spinel slots.
    /// </summary>
    private static IReadOnlyList<TradeShopSlot> AssignSlotTiers(
        IReadOnlyList<TradeShopPlannedCheck> checks,
        int slotCount)
    {
        var demand = checks
            .GroupBy(entry => NormalizeTier(entry.Check.Tier), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.OrdinalIgnoreCase);

        var allocation = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (var tier in demand.Keys)
        {
            allocation[tier] = 1;
        }

        // More tiers than slots should be impossible (three tiers, seven
        // slots), but a room with a single check would trip it, so the
        // guaranteed pass is trimmed rather than allowed to overrun.
        var spare = slotCount - allocation.Count;
        if (spare > 0)
        {
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
                if (placed >= slotCount)
                {
                    break;
                }
                allocation[share.Key]++;
                placed++;
            }
        }

        var slots = new List<TradeShopSlot>(slotCount);
        foreach (var entry in allocation.OrderBy(e => e.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (!TierSpinel.TryGetValue(entry.Key, out var spinel))
            {
                continue;
            }
            for (var index = 0; index < entry.Value && slots.Count < slotCount; index++)
            {
                slots.Add(new TradeShopSlot(
                    MerchantShopPlanner.TradeSlotItemIds[slots.Count],
                    entry.Key,
                    spinel));
            }
        }

        return slots;
    }

    private static string NormalizeTier(string? tier)
    {
        var normalized = (tier ?? string.Empty).Trim();
        return TierSpinel.ContainsKey(normalized) ? normalized.ToUpperInvariant() : "FILLER";
    }

    /// <summary>
    /// Deterministic message GUID per check, so the fork can bake a check's
    /// text and the mod can point a slot at it without either side inventing
    /// strings or reporting anything back.
    ///
    /// Salted apart from the shelf's GUIDs on purpose: a trade check and a
    /// shop check can share an identity string shape, and colliding would make
    /// one overwrite the other's baked text.
    /// </summary>
    public static Guid DeriveMessageGuid(string kind, string identity)
    {
        var salt = Encoding.UTF8.GetBytes($"re4r:ap-trade-msg:{kind}:{identity}");
        return new Guid(MD5.HashData(salt));
    }
}

public sealed record TradeShopPlannedCheck(
    TradeShopCheck Check,
    Guid NameMsgGuid,
    Guid CaptionMsgGuid);

/// <summary>
/// One trade display slot: a stand-in engine item id the fork mints a reward
/// row for, and the FIXED spinel price it charges. The mod only shows a check
/// on a slot of the check's own tier, which is what lets the price live in the
/// pak.
/// </summary>
public sealed record TradeShopSlot(int ItemId, string Tier, int PriceSpinel);

/// <summary>
/// The whole tab plan: every trade check in the room, plus the slots the fork
/// mints for them. Slots are a display window the mod rotates checks through.
/// </summary>
public sealed record TradeShopPlan(
    IReadOnlyList<TradeShopPlannedCheck> Checks,
    IReadOnlyList<TradeShopSlot> Slots)
{
    public static readonly TradeShopPlan Empty =
        new(Array.Empty<TradeShopPlannedCheck>(), Array.Empty<TradeShopSlot>());

    public int Count => Checks.Count;

    public IReadOnlyList<int> SlotItemIds => Slots.Select(slot => slot.ItemId).ToArray();
}
