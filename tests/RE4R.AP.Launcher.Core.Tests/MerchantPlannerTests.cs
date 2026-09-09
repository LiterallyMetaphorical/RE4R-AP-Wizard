using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using Xunit;

namespace RE4R.AP.Launcher.Core.Tests;

/// <summary>
/// The two merchant planners are the agreement between the room file (read
/// by the mod) and the manifest (read by the fork): both sides call the same
/// planner, so the stand-in ids, the fixed tier per row and the message GUIDs
/// match by construction. These tests pin that construction.
/// </summary>
public sealed class MerchantPlannerTests
{
    private static readonly IReadOnlyDictionary<string, MerchantShopTier> ShopTiers =
        new Dictionary<string, MerchantShopTier>(StringComparer.OrdinalIgnoreCase)
        {
            ["FILLER"] = new MerchantShopTier(5000, 120832000, "Emerald"),
            ["USEFUL"] = new MerchantShopTier(7000, 120835200, "Yellow Diamond"),
            ["PROGRESSION"] = new MerchantShopTier(9000, 120857600, "Red Beryl"),
        };

    private static MerchantShopSlotData Shop(params (string Classification, int Count)[] mix)
    {
        var slots = new List<MerchantShopSlot>();
        foreach (var (classification, count) in mix)
        {
            for (var i = 0; i < count; i++)
            {
                var index = slots.Count + 1;
                slots.Add(new MerchantShopSlot
                {
                    LocationCode = 1_000_000 + index,
                    Index = index,
                    Identity = $"shop:chapter:{(index - 1) / 3 + 1}:check:{(index - 1) % 3 + 1}",
                    UnlockChapter = (index - 1) / 3 + 1,
                    Classification = classification,
                });
            }
        }

        return new MerchantShopSlotData { Enabled = true, Slots = slots, Tiers = ShopTiers };
    }

    private static TradeShopSlotData Trade(params (string Tier, int Count)[] mix)
    {
        var checks = new List<TradeShopCheck>();
        foreach (var (tier, count) in mix)
        {
            for (var i = 0; i < count; i++)
            {
                var release = checks.Count + 1;
                checks.Add(new TradeShopCheck
                {
                    LocationCode = 2_000_000 + release,
                    Identity = $"trade:release:{release}",
                    ReleaseIndex = release,
                    Chapter = (release - 1) / 3 + 1,
                    Tier = tier,
                    PriceSpinel = TradeShopPlanner.TierSpinel.TryGetValue(tier, out var price) ? price : 1,
                });
            }
        }

        return new TradeShopSlotData { Enabled = true, Checks = checks };
    }

    [Fact]
    public void TheTwoTabsSplitTheSafeStandinPoolAndNeverTouchTheLastFour()
    {
        // A pak built on all 24 ids crashes the game six seconds in (2026-08-17),
        // so the shelf and the trade tab partition the front 20 between them.
        Assert.Equal(24, MerchantShopPlanner.StandinItemIds.Count);
        Assert.Equal(20, MerchantShopPlanner.SafeStandinCount);
        Assert.Equal(13, MerchantShopPlanner.RowItemIds.Count);
        Assert.Equal(7, MerchantShopPlanner.TradeSlotItemIds.Count);
        Assert.Empty(MerchantShopPlanner.RowItemIds.Intersect(MerchantShopPlanner.TradeSlotItemIds));

        var safe = MerchantShopPlanner.StandinItemIds.Take(MerchantShopPlanner.SafeStandinCount).ToHashSet();
        Assert.All(MerchantShopPlanner.RowItemIds, id => Assert.Contains(id, safe));
        Assert.All(MerchantShopPlanner.TradeSlotItemIds, id => Assert.Contains(id, safe));
    }

    [Fact]
    public void ShopPlanIsEmptyWhenTheRoomHasNoShelfChecks()
    {
        Assert.Same(MerchantShopPlan.Empty, MerchantShopPlanner.Plan(MerchantShopSlotData.Disabled));
        Assert.Same(MerchantShopPlan.Empty, MerchantShopPlanner.Plan(new MerchantShopSlotData { Enabled = true, Tiers = ShopTiers }));
    }

    [Fact]
    public void ShelfRowsFollowTheRoomsMixWithOneRowPerTierGuaranteed()
    {
        // 45 checks: 30 filler, 10 useful, 5 progression. Thirteen rows: one
        // each guaranteed, the ten spare split by largest remainder (6 / 2 / 1,
        // the last one to filler's .67).
        var plan = MerchantShopPlanner.Plan(Shop(("FILLER", 30), ("USEFUL", 10), ("PROGRESSION", 5)));

        Assert.Equal(45, plan.Count);
        Assert.Equal(13, plan.Rows.Count);
        Assert.Equal(8, plan.Rows.Count(row => row.Classification == "FILLER"));
        Assert.Equal(3, plan.Rows.Count(row => row.Classification == "USEFUL"));
        Assert.Equal(2, plan.Rows.Count(row => row.Classification == "PROGRESSION"));
        Assert.Equal(MerchantShopPlanner.RowItemIds, plan.RowItemIds);
        Assert.All(plan.Rows, row => Assert.Equal(ShopTiers[row.Classification].Price, row.Tier.Price));
    }

    [Fact]
    public void ShelfMintsNoMoreRowsThanChecks()
    {
        // Five checks, five rows. The split is by largest remainder over the
        // spare rows after one per tier, so progression gets two rows for its
        // one check (0.6 beats filler's 0.4): rotation makes the spare row
        // harmless, and this pins the behaviour as it is.
        var plan = MerchantShopPlanner.Plan(Shop(("FILLER", 4), ("PROGRESSION", 1)));

        Assert.Equal(5, plan.Rows.Count);
        Assert.Equal(3, plan.Rows.Count(row => row.Classification == "FILLER"));
        Assert.Equal(2, plan.Rows.Count(row => row.Classification == "PROGRESSION"));
        Assert.Equal(MerchantShopPlanner.RowItemIds.Take(5), plan.RowItemIds);
    }

    [Fact]
    public void ShelfRefusesADuplicateIdentityAndAnUnpricedClassification()
    {
        var clashing = new MerchantShopSlotData
        {
            Enabled = true,
            Tiers = ShopTiers,
            Slots = new[]
            {
                new MerchantShopSlot { Index = 1, Identity = "shop:chapter:1:check:1", Classification = "FILLER" },
                new MerchantShopSlot { Index = 2, Identity = "shop:chapter:1:check:1", Classification = "FILLER" },
            },
        };
        var error = Assert.Throws<ManifestBuildException>(() => MerchantShopPlanner.Plan(clashing));
        Assert.Contains("appears twice", error.Message, StringComparison.Ordinal);

        var unpriced = new MerchantShopSlotData
        {
            Enabled = true,
            Tiers = ShopTiers,
            Slots = new[] { new MerchantShopSlot { Index = 1, Identity = "shop:chapter:1:check:1", Classification = "TRAP" } },
        };
        var unpricedError = Assert.Throws<ManifestBuildException>(() => MerchantShopPlanner.Plan(unpriced));
        Assert.Contains("does not price", unpricedError.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ShopChecksKeepTheirIndexOrderAndCarryStableGuids()
    {
        var shop = Shop(("USEFUL", 2), ("FILLER", 2));
        var first = MerchantShopPlanner.Plan(shop);
        var second = MerchantShopPlanner.Plan(shop);

        Assert.Equal(new[] { 1, 2, 3, 4 }, first.Checks.Select(check => check.Slot.Index));
        Assert.Equal(first.Checks.Select(check => check.NameMsgGuid), second.Checks.Select(check => check.NameMsgGuid));
        Assert.Equal(first.RowItemIds, second.RowItemIds);
        Assert.All(first.Checks, check => Assert.NotEqual(check.NameMsgGuid, check.CaptionMsgGuid));
        Assert.Equal(4, first.Checks.Select(check => check.NameMsgGuid).Distinct().Count());
    }

    [Fact]
    public void ShopAndTradeGuidsForTheSameIdentityNeverCollide()
    {
        // Both tabs bake text at derived GUIDs; a shared derivation would let a
        // trade check overwrite a shop check's text.
        Assert.NotEqual(
            MerchantShopPlanner.DeriveMessageGuid("name", "chapter:1:check:1"),
            TradeShopPlanner.DeriveMessageGuid("name", "chapter:1:check:1"));
        Assert.Equal(
            TradeShopPlanner.DeriveMessageGuid("name", "slot-empty"),
            TradeShopPlanner.EmptySlotNameMsgGuid);
        Assert.Equal(
            TradeShopPlanner.DeriveMessageGuid("caption", "slot-empty"),
            TradeShopPlanner.EmptySlotCaptionMsgGuid);
    }

    [Fact]
    public void TradeTiersArePricedOneThreeSix()
    {
        Assert.Equal(1, TradeShopPlanner.TierSpinel["FILLER"]);
        Assert.Equal(3, TradeShopPlanner.TierSpinel["USEFUL"]);
        Assert.Equal(6, TradeShopPlanner.TierSpinel["PROGRESSION"]);
        Assert.Equal(3, TradeShopPlanner.TierSpinel["useful"]);
    }

    [Fact]
    public void TradePlanIsEmptyWhenTheRoomHasNoTradeChecks()
    {
        Assert.Same(TradeShopPlan.Empty, TradeShopPlanner.Plan(TradeShopSlotData.Disabled));
        // Trade checks at 0 with the gear shuffle on: enabled, no checks.
        Assert.Same(TradeShopPlan.Empty, TradeShopPlanner.Plan(new TradeShopSlotData { Enabled = true }));
    }

    [Fact]
    public void TradeSlotsFollowTheRoomsMixAndNeverExceedSeven()
    {
        // 45 checks: 30 filler, 8 useful, 7 progression. Seven slots: one each
        // guaranteed, the four spare by largest remainder (2 / 0 / 0, then
        // useful's .71 and filler's .67).
        var plan = TradeShopPlanner.Plan(Trade(("FILLER", 30), ("USEFUL", 8), ("PROGRESSION", 7)));

        Assert.Equal(45, plan.Count);
        Assert.Equal(7, plan.Slots.Count);
        Assert.Equal(4, plan.Slots.Count(slot => slot.Tier == "FILLER"));
        Assert.Equal(2, plan.Slots.Count(slot => slot.Tier == "USEFUL"));
        Assert.Equal(1, plan.Slots.Count(slot => slot.Tier == "PROGRESSION"));
        Assert.Equal(MerchantShopPlanner.TradeSlotItemIds, plan.SlotItemIds);
        Assert.All(plan.Slots, slot => Assert.Equal(TradeShopPlanner.TierSpinel[slot.Tier], slot.PriceSpinel));
    }

    [Fact]
    public void TradeMintsNoMoreSlotsThanChecksAndOrdersThemByRelease()
    {
        var plan = TradeShopPlanner.Plan(Trade(("PROGRESSION", 1), ("FILLER", 2)));

        Assert.Equal(3, plan.Slots.Count);
        Assert.Equal(new[] { 1, 2, 3 }, plan.Checks.Select(check => check.Check.ReleaseIndex));
        Assert.Equal(MerchantShopPlanner.TradeSlotItemIds.Take(3), plan.SlotItemIds);
    }

    [Fact]
    public void TradeSkipsADuplicateIdentityInsteadOfFailingTheRoom()
    {
        var trade = new TradeShopSlotData
        {
            Enabled = true,
            Checks = new[]
            {
                new TradeShopCheck { Identity = "trade:release:1", ReleaseIndex = 1, Tier = "FILLER", PriceSpinel = 1 },
                new TradeShopCheck { Identity = "trade:release:1", ReleaseIndex = 2, Tier = "FILLER", PriceSpinel = 1 },
            },
        };

        var plan = TradeShopPlanner.Plan(trade);

        Assert.Equal(1, plan.Count);
        Assert.Single(plan.Slots);
    }

    [Fact]
    public void TradeReadsAnUnknownTierAsFillerAndAnyCaseAsItsOwn()
    {
        var plan = TradeShopPlanner.Plan(Trade(("junk", 2), ("useful", 1)));

        Assert.Equal(3, plan.Slots.Count);
        Assert.Equal(2, plan.Slots.Count(slot => slot.Tier == "FILLER" && slot.PriceSpinel == 1));
        Assert.Equal(1, plan.Slots.Count(slot => slot.Tier == "USEFUL" && slot.PriceSpinel == 3));
    }
}
