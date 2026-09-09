using System.Text.Json;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using Xunit;

namespace RE4R.AP.Launcher.Core.Tests;

/// <summary>
/// The scout's reading of the server's Connected packet. The slot_data shapes
/// here are the ones the apworld emits (see its _trade_shop_slot_data,
/// _mercenaries_slot_data and _merchant_shop_slot_data), so a change on
/// either side that breaks the agreement fails here first.
/// </summary>
public sealed class ScoutPacketParsingTests
{
    private static JsonElement Packet(string slotDataJson) =>
        JsonDocument.Parse($$"""{"cmd":"Connected","team":0,"slot":1,"slot_data":{{slotDataJson}}}""").RootElement;

    private const string Gems =
        """{"emerald":{"item_id":120832000,"spinel":3},"yellow_diamond":{"item_id":120835200,"spinel":4},"red_beryl":{"item_id":120857600,"spinel":5}}""";

    [Fact]
    public void TradeBlockWithNoChecksIsStillEnabled()
    {
        // Trade checks at 0 with the gear shuffle on: the apworld enables the
        // block with no checks, and the launcher must carry it so the mod
        // can restock the three gems (2026-09-04).
        var trade = ArchipelagoScoutClient.ParseTradeShopSlotData(Packet(
            $$$"""{"trade_shop":{"enabled":true,"check_count":0,"checks":[],"velvet_blue_spinel":2,"gems":{{{Gems}}},"spinel_item_id":120800000,"spinel_pool_total":0,"shuffled_trade_item_ids":[119288000,120880000]}}"""));

        Assert.True(trade.Enabled);
        Assert.Empty(trade.Checks);
        Assert.Equal(3, trade.Gems.Count);
        Assert.Equal(2, trade.VelvetBlueSpinel);
        Assert.Equal(120800000, trade.SpinelItemId);
        Assert.Equal(new[] { 119288000, 120880000 }, trade.ShuffledTradeItemIds);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"trade_shop":{"enabled":false}}""")]
    [InlineData("""{"trade_shop":"broken"}""")]
    public void TradeBlockAbsentOrDisabledReadsDisabled(string slotData)
    {
        Assert.False(ArchipelagoScoutClient.ParseTradeShopSlotData(Packet(slotData)).Enabled);
    }

    [Fact]
    public void TradeCheckWithoutAPriceIsDroppedRatherThanGuessed()
    {
        var trade = ArchipelagoScoutClient.ParseTradeShopSlotData(Packet(
            $$$"""
            {"trade_shop":{"enabled":true,"checks":[
                {"code":3028805226,"identity":"trade:chapter:1:check:1","release_index":1,"chapter":1,"chapter_ordinal":1,"price_spinel":1,"tier":"FILLER","cumulative_spinel":1,"display_name":"Green Herb x1","player_name":"Tester","remote":false,"item_id":114400000,"item_stack":1},
                {"code":3028805227,"identity":"trade:chapter:1:check:2","release_index":2,"chapter":1,"chapter_ordinal":2,"tier":"USEFUL"}
            ],"gems":{{{Gems}}}}}
            """));

        var check = Assert.Single(trade.Checks);
        Assert.Equal(3028805226, check.LocationCode);
        Assert.Equal("trade:chapter:1:check:1", check.Identity);
        Assert.Equal("FILLER", check.Tier);
        Assert.Equal(1, check.PriceSpinel);
        Assert.Equal(114400000, check.ItemId);
        Assert.False(check.Remote);
    }

    [Fact]
    public void MercenariesBlockCollectsTheRankIdsFromTheMap()
    {
        var packet = Packet(
            """
            {"game_mode":"campaign_and_mercenaries","mercenaries":{"enabled":true,"game_mode":"campaign_and_mercenaries","rank_floor":"c","rank_ceiling":"a","starting_character":"Leon","starting_stage":"Village",
             "locations":{"Leon":{"Village":{"A":440001000,"S":440001001}},"Ada":{"Castle":{"A":440002000,"S":440002001}}}}}
            """);

        var mercenaries = ArchipelagoScoutClient.ParseMercenariesSlotData(packet);

        Assert.True(mercenaries.Enabled);
        Assert.Equal("c", mercenaries.RankFloor);
        Assert.Equal("a", mercenaries.RankCeiling);
        Assert.Equal("Leon", mercenaries.StartingCharacter);
        Assert.Equal("Village", mercenaries.StartingStage);
        Assert.Equal(new long[] { 440001000, 440001001, 440002000, 440002001 }, mercenaries.LocationIds);
        Assert.Equal("campaign_and_mercenaries", ArchipelagoScoutClient.ParseGameModeSlotData(packet));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"mercenaries":{"enabled":false}}""")]
    public void MercenariesAbsentOrDisabledReadsDisabled(string slotData)
    {
        Assert.False(ArchipelagoScoutClient.ParseMercenariesSlotData(Packet(slotData)).Enabled);
    }

    [Theory]
    [InlineData("{}", 20)]
    [InlineData("""{"difficulty":"assisted"}""", 10)]
    [InlineData("""{"difficulty":"standard"}""", 20)]
    [InlineData("""{"difficulty":"Hardcore"}""", 30)]
    [InlineData("""{"difficulty":"professional"}""", 40)]
    [InlineData("""{"difficulty":"nonsense"}""", 20)]
    public void TheRoomsDifficultyIsReadAsTheGameNumbersThem(string slotData, int expected)
    {
        // The merchant's shelf is written for this: a shop row carries one
        // stock setting and the game only applies it on a matching difficulty.
        Assert.Equal(expected, ArchipelagoScoutClient.ParseSlotDifficulty(Packet(slotData)));
    }

    [Theory]
    [InlineData("{}", "campaign")]
    [InlineData("""{"game_mode":"campaign"}""", "campaign")]
    [InlineData("""{"game_mode":"MERCENARIES_ONLY"}""", "mercenaries_only")]
    [InlineData("""{"game_mode":"separate_ways"}""", "campaign")]
    public void GameModeReadsTheThreeKnownModesAndDefaultsToTheCampaign(string slotData, string expected)
    {
        // Note the last case. An unrecognised mode reads as the campaign, which
        // is why patched_campaign exists: on its own, game_mode would have this
        // launcher patch Leon's game for a room built on content it has never
        // heard of. See the patched_campaign tests below.
        Assert.Equal(expected, ArchipelagoScoutClient.ParseGameModeSlotData(Packet(slotData)));
    }

    [Theory]
    [InlineData("""{"patched_campaign":"Main Story"}""", "Main Story")]
    [InlineData("""{"patched_campaign":""}""", "")]
    [InlineData("""{"patched_campaign":"  Separate Ways  "}""", "Separate Ways")]
    public void ThePatchedCampaignIsReadAsWritten(string slotData, string expected)
    {
        // Returned as written rather than lowercased: it is a patcher-facing
        // name, and an unrecognised one has to stay readable in the refusal.
        Assert.Equal(expected, ArchipelagoScoutClient.ParsePatchedCampaignSlotData(Packet(slotData)));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"patched_campaign":123}""")]
    [InlineData("""{"game_mode":"campaign"}""")]
    public void ARoomThatNeverSaysWhichCampaignReadsAsNull(string slotData)
    {
        // Null is "the room did not say", which is every room made before
        // 0.7.6. Those fall back to game_mode; an empty string would mean the
        // opposite, that the room needs no patch at all.
        Assert.Null(ArchipelagoScoutClient.ParsePatchedCampaignSlotData(Packet(slotData)));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Main Story")]
    [InlineData("main story")]
    public void ACampaignThisLauncherCanPatchIsAccepted(string? patchedCampaign)
    {
        ArchipelagoScoutClient.RefuseUnpatchableCampaign(patchedCampaign);
    }

    [Theory]
    [InlineData("Separate Ways")]
    [InlineData("Something From The Future")]
    public void ACampaignThisLauncherCannotPatchStopsTheScout(string patchedCampaign)
    {
        // The whole point of the key. Without it the room would come through
        // as a plain campaign room and Leon's game would be patched for it.
        // The bundled world data can know a room's locations while the bundled
        // patcher cannot build its campaign, so the location id check does not
        // cover this.
        var error = Assert.Throws<ArchipelagoScoutException>(
            () => ArchipelagoScoutClient.RefuseUnpatchableCampaign(patchedCampaign));

        Assert.Contains(patchedCampaign, error.Message, StringComparison.Ordinal);
        Assert.Contains("Nothing has been changed in your game.", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ASeparateWaysRoomIsRefusedStraightOffThePacket()
    {
        // The two halves as the scout runs them, against the slot_data the
        // apworld emits for an SW room (verified against a generated room,
        // 2026-09-06). Today game_mode alone would read this as a plain
        // campaign room and patch Leon's game for Ada.
        const string slotData =
            """{"included_content":["Separate Ways"],"game_mode":"campaign","patched_campaign":"Separate Ways"}""";

        Assert.Equal("campaign", ArchipelagoScoutClient.ParseGameModeSlotData(Packet(slotData)));

        var campaign = ArchipelagoScoutClient.ParsePatchedCampaignSlotData(Packet(slotData));
        Assert.Equal("Separate Ways", campaign);
        Assert.Throws<ArchipelagoScoutException>(
            () => ArchipelagoScoutClient.RefuseUnpatchableCampaign(campaign));
    }

    [Theory]
    // The room said, so its answer is used.
    [InlineData("Main Story", "campaign", "Main Story", false)]
    [InlineData("", "campaign", "", true)]
    // The room did not say, so game_mode decides. Every room before 0.7.6.
    [InlineData(null, "campaign", "Main Story", false)]
    [InlineData(null, "campaign_and_mercenaries", "Main Story", false)]
    [InlineData(null, "mercenaries_only", "", true)]
    public void WhatGetsPatchedPrefersTheRoomsAnswerAndFallsBackToTheMode(
        string? patchedCampaign, string gameMode, string expectedTarget, bool expectedMercenariesOnly)
    {
        var result = new ArchipelagoScoutSessionResult
        {
            GameMode = gameMode,
            PatchedCampaign = patchedCampaign,
        };

        Assert.Equal(expectedTarget, result.CampaignPatchTarget);
        Assert.Equal(expectedMercenariesOnly, result.MercenariesOnly);
        Assert.Equal(!expectedMercenariesOnly, result.CampaignIncluded);
    }

    [Fact]
    public void MerchantShopSlotWithoutAPricedTierIsDropped()
    {
        var shop = ArchipelagoScoutClient.ParseMerchantShopSlotData(Packet(
            """
            {"merchant_shop":{"enabled":true,"tiers":{"FILLER":{"price":5000,"refund_item_id":120832000,"refund_item_name":"Emerald"}},
             "slots":[
               {"code":1542324809,"index":1,"identity":"shop:chapter:1:check:1","unlock_chapter":1,"chapter_ordinal":1,"classification":"FILLER","display_name":"Green Herb x1","player_name":"Tester","remote":false,"item_id":114400000,"item_stack":1},
               {"code":1542324810,"index":2,"unlock_chapter":1,"classification":"PROGRESSION"},
               {"code":1542324811,"index":3,"unlock_chapter":2,"classification":"FILLER"}
             ]}}
            """));

        Assert.True(shop.Enabled);
        Assert.Equal(2, shop.Slots.Count);
        Assert.Equal("shop:chapter:1:check:1", shop.Slots[0].Identity);
        Assert.Equal("shop:slot:3", shop.Slots[1].Identity);
        Assert.Equal(5000, shop.Tiers["FILLER"].Price);
    }

    [Fact]
    public void MerchantTiersCarryTheSpinelRefundCountAndOldRoomsReadAsOneGem()
    {
        // The 0.7.2 refund rework (MERCHANT_TRADE_DESIGN.md 4.6): 1 / 3 / 6
        // spinel by tier. A room generated before it names a gemstone and no
        // count; that must read as exactly one, so the old room keeps the
        // behaviour it was generated with.
        var shop = ArchipelagoScoutClient.ParseMerchantShopSlotData(Packet(
            """
            {"merchant_shop":{"enabled":true,"tiers":{
               "FILLER":{"price":2500,"refund_item_id":120800000,"refund_item_name":"Spinel","refund_count":1},
               "USEFUL":{"price":7500,"refund_item_id":120800000,"refund_item_name":"Spinel","refund_count":3},
               "PROGRESSION":{"price":15000,"refund_item_id":120800000,"refund_item_name":"Spinel","refund_count":6}},
             "slots":[
               {"code":1542324809,"index":1,"identity":"shop:chapter:1:check:1","unlock_chapter":1,"chapter_ordinal":1,"classification":"USEFUL","display_name":"Red9 x1","player_name":"Other","remote":true,"item_id":0,"item_stack":0}
             ]}}
            """));

        Assert.Equal(3, shop.Tiers["USEFUL"].RefundCount);
        Assert.Equal(6, shop.Tiers["PROGRESSION"].RefundCount);
        Assert.Equal(120800000, shop.Tiers["FILLER"].RefundItemId);

        var oldRoom = ArchipelagoScoutClient.ParseMerchantShopSlotData(Packet(
            """
            {"merchant_shop":{"enabled":true,"tiers":{"FILLER":{"price":5000,"refund_item_id":120832000,"refund_item_name":"Emerald"}},
             "slots":[{"code":1542324809,"index":1,"unlock_chapter":1,"classification":"FILLER"}]}}
            """));

        Assert.Equal(1, oldRoom.Tiers["FILLER"].RefundCount);
        Assert.Equal("Emerald", oldRoom.Tiers["FILLER"].RefundItemName);
    }

    [Fact]
    public void RandomEventsReadRemovedChecksAsNumbersOrStrings()
    {
        var events = ArchipelagoScoutClient.ParseRandomEventsSlotData(Packet(
            """{"random_events":{"enabled":true,"chosen":["boat_fuel_moved",""],"event_data_hash":"abc","removed_checks":[123,"456","junk"]}}"""));

        Assert.True(events.Enabled);
        Assert.Equal(new[] { "boat_fuel_moved" }, events.ChosenEvents);
        Assert.Equal("abc", events.EventDataHash);
        Assert.Equal(new long[] { 123, 456 }, events.RemovedLocationCodes);
    }
}
