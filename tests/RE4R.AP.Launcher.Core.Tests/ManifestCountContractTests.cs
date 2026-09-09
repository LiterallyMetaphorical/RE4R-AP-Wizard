using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using Xunit;

namespace RE4R.AP.Launcher.Core.Tests;

/// <summary>
/// The count contract behind every patch: what the room scouts against what
/// the bundled static data and the slot data declare. Runs against the real
/// assets/Data/re4r_ap_static.json, so the numbers are the shipped ones.
/// </summary>
public sealed class ManifestCountContractTests
{
    private const string GameVersion = "31 Mar 2026";
    private const int ConnectedSlot = 1;
    private const int OtherSlot = 2;

    private static async Task<StaticGameData> LoadStaticAsync() =>
        await new StaticGameDataProvider(RepoPaths.AssetsData).LoadAsync();

    private static (ManifestBuilder Builder, List<string> Log) BuilderWithLog()
    {
        var builder = new ManifestBuilder(new StaticGameDataProvider(RepoPaths.AssetsData));
        var log = new List<string>();
        builder.LogMessage += log.Add;
        return (builder, log);
    }

    /// <summary>Every location holds another player's item: no item lookups needed.</summary>
    private static List<ScoutLocationResult> Foreign(IEnumerable<long> locationIds) =>
        locationIds.Select(id => new ScoutLocationResult
        {
            LocationId = id,
            ItemId = 1,
            OwningPlayerSlot = OtherSlot,
        }).ToList();

    private static ArchipelagoScoutSessionResult Room(
        IReadOnlyList<ScoutLocationResult> locations,
        Action<RoomShape>? shape = null)
    {
        var s = new RoomShape();
        shape?.Invoke(s);
        return new ArchipelagoScoutSessionResult
        {
            NormalizedServer = "wss://archipelago.gg:1",
            SeedName = "test-seed",
            SlotName = "Tester",
            ConnectedPlayerSlot = ConnectedSlot,
            Locations = locations,
            RoomLocationIds = locations.Select(location => location.LocationId).ToList(),
            MerchantShop = s.MerchantShop,
            TradeShop = s.TradeShop,
            Mercenaries = s.Mercenaries,
            GameMode = s.GameMode,
            PatchedCampaign = s.PatchedCampaign,
        };
    }

    private sealed class RoomShape
    {
        public MerchantShopSlotData MerchantShop { get; set; } = MerchantShopSlotData.Disabled;
        public TradeShopSlotData TradeShop { get; set; } = TradeShopSlotData.Disabled;
        public MercenariesSlotData Mercenaries { get; set; } = MercenariesSlotData.Disabled;
        public string GameMode { get; set; } = "campaign";
        public string? PatchedCampaign { get; set; }
    }

    private static IReadOnlyList<KeyValuePair<long, StaticShopSlot>> ShopSlotsInOrder(StaticGameData data) =>
        data.ShopSlots.OrderBy(pair => pair.Value.PhysicalChapter).ThenBy(pair => pair.Value.Slot).ToList();

    private static MerchantShopSlotData Shop(StaticGameData data, int count) => new()
    {
        Enabled = true,
        Slots = ShopSlotsInOrder(data).Take(count).Select((pair, index) => new MerchantShopSlot
        {
            LocationCode = pair.Key,
            Index = index + 1,
            Identity = pair.Value.Name,
            UnlockChapter = pair.Value.PhysicalChapter,
            ChapterOrdinal = pair.Value.Slot,
            Classification = "FILLER",
            DisplayName = "Green Herb x1",
            PlayerName = "Someone",
            Remote = true,
        }).ToList(),
        Tiers = new Dictionary<string, MerchantShopTier>(StringComparer.OrdinalIgnoreCase)
        {
            ["FILLER"] = new MerchantShopTier(5000, 120832000, "Emerald"),
        },
    };

    private static IReadOnlyList<KeyValuePair<long, StaticTradeCheck>> TradeChecksInOrder(StaticGameData data) =>
        data.TradeChecks.OrderBy(pair => pair.Value.ReleaseIndex).ToList();

    private static readonly IReadOnlyDictionary<string, TradeShopGem> ThreeGems =
        new Dictionary<string, TradeShopGem>(StringComparer.OrdinalIgnoreCase)
        {
            ["emerald"] = new TradeShopGem(120832000, 3),
            ["yellow_diamond"] = new TradeShopGem(120835200, 4),
            ["red_beryl"] = new TradeShopGem(120857600, 5),
        };

    private static TradeShopSlotData Trade(StaticGameData data, int count)
    {
        var cumulative = 0;
        var checks = new List<TradeShopCheck>();
        foreach (var pair in TradeChecksInOrder(data).Take(count))
        {
            cumulative += pair.Value.PriceSpinel;
            checks.Add(new TradeShopCheck
            {
                LocationCode = pair.Key,
                Identity = pair.Value.Name,
                ReleaseIndex = pair.Value.ReleaseIndex,
                Chapter = pair.Value.Chapter,
                ChapterOrdinal = pair.Value.ChapterOrdinal,
                PriceSpinel = pair.Value.PriceSpinel,
                Tier = pair.Value.PriceSpinel switch { 6 => "PROGRESSION", 3 => "USEFUL", _ => "FILLER" },
                CumulativeSpinel = cumulative,
                DisplayName = "Handgun Ammo x10",
                PlayerName = "Someone",
                Remote = true,
            });
        }

        return new TradeShopSlotData
        {
            Enabled = true,
            Checks = checks,
            Gems = ThreeGems,
            VelvetBlueSpinel = 2,
            SpinelItemId = 120800000,
            SpinelPoolTotal = cumulative,
        };
    }

    private static long[] RankIds(StaticGameData data, params string[] ranks) =>
        data.Mercenaries
            .Where(pair => ranks.Contains(pair.Value.Rank, StringComparer.Ordinal))
            .Select(pair => pair.Key)
            .OrderBy(id => id)
            .ToArray();

    private static MercenariesSlotData Mercs(long[] ids) => new()
    {
        Enabled = true,
        RankFloor = "c",
        RankCeiling = "a",
        StartingCharacter = "Leon",
        StartingStage = "Village",
        LocationIds = ids,
    };

    [Fact]
    public async Task BundledStaticDataHasTheShippedCounts()
    {
        var data = await LoadStaticAsync();

        Assert.Equal("0.7.5", data.WorldVersion);
        Assert.Equal(456, data.Counts.LocationsTotal);
        Assert.Equal(456, data.LocationCodes.Count);
        Assert.Equal(456, data.Locations.Count);
        Assert.Equal(120, data.ShopSlots.Count);
        Assert.Equal(45, data.TradeChecks.Count);
        Assert.Equal(192, data.Mercenaries.Count); // 0.7.5: 32 per rank, C to S++
        Assert.Single(data.DifficultyInertLocations);
        Assert.All(data.Locations.Values, location => Assert.False(string.IsNullOrWhiteSpace(location.Guid)));
    }

    [Fact]
    public async Task HealthyCampaignRoomBuildsEveryPlacement()
    {
        var data = await LoadStaticAsync();
        var (builder, log) = BuilderWithLog();

        var result = await builder.BuildAsync(Room(Foreign(data.LocationCodes)), null, GameVersion);

        Assert.Equal(456, result.GuidPlacementCount);
        Assert.Equal(456, result.PlaceholderItemCount);
        Assert.Equal(0, result.RealRe4rItemCount);
        Assert.Equal(0, result.SkippedNoGuidLocationCount);
        Assert.Contains(log, line => line.StartsWith("Room has 456 RE4R locations.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task OwnItemsResolveToEngineIdsAndMercenariesUnlocksToThePlaceholder()
    {
        var data = await LoadStaticAsync();
        var herb = data.Items.Single(pair => pair.Value.Name == "Green Herb x1");
        var unlock = data.Items.First(pair => pair.Value.Name.StartsWith("Mercenaries Character: ", StringComparison.Ordinal));
        var locations = Foreign(data.LocationCodes);
        locations[0] = new ScoutLocationResult { LocationId = locations[0].LocationId, ItemId = herb.Key, OwningPlayerSlot = ConnectedSlot };
        locations[1] = new ScoutLocationResult { LocationId = locations[1].LocationId, ItemId = unlock.Key, OwningPlayerSlot = ConnectedSlot };
        var (builder, _) = BuilderWithLog();

        var result = await builder.BuildAsync(Room(locations), null, GameVersion);

        Assert.Equal(1, result.RealRe4rItemCount);
        Assert.Equal(455, result.PlaceholderItemCount);
        Assert.Contains(herb.Value.BioRandItemId.ToString(), result.ConfigJson);
    }

    [Fact]
    public async Task ProgressiveGearInOwnWorldIsPlacedAsThePlaceholder()
    {
        // A ladder item has no engine id; the mod picks the tier on receipt,
        // so BioRand places the logo and the pickup sends the check.
        var data = await LoadStaticAsync();
        var knife = data.Items.Single(pair => pair.Value.Name == "Progressive Knife x1");
        var caseLadder = data.Items.Single(pair => pair.Value.Name == "Progressive Attache Case x1");
        var locations = Foreign(data.LocationCodes);
        locations[0] = new ScoutLocationResult { LocationId = locations[0].LocationId, ItemId = knife.Key, OwningPlayerSlot = ConnectedSlot };
        locations[1] = new ScoutLocationResult { LocationId = locations[1].LocationId, ItemId = caseLadder.Key, OwningPlayerSlot = ConnectedSlot };
        var (builder, _) = BuilderWithLog();

        var result = await builder.BuildAsync(Room(locations), null, GameVersion);

        Assert.True(knife.Value.BioRandItemId <= 0);
        Assert.True(caseLadder.Value.BioRandItemId <= 0);
        Assert.Equal(0, result.RealRe4rItemCount);
        Assert.Equal(456, result.PlaceholderItemCount);
    }

    [Fact]
    public async Task HardcoreRoomShortByTheInertSpotStillBuilds()
    {
        var data = await LoadStaticAsync();
        var inert = data.DifficultyInertLocations.Single().Code;
        var (builder, log) = BuilderWithLog();

        var result = await builder.BuildAsync(
            Room(Foreign(data.LocationCodes.Where(code => code != inert))), null, GameVersion);

        Assert.Equal(455, result.GuidPlacementCount);
        Assert.Contains(log, line => line.Contains("hard-difficulty spot(s)", StringComparison.Ordinal));
        Assert.Contains(log, line => line.StartsWith("Room has 455 RE4R locations.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task RoomMissingAnyOtherSpotIsRefusedAndNamesTheId()
    {
        var data = await LoadStaticAsync();
        var missing = data.LocationCodes.First(code => code != data.DifficultyInertLocations.Single().Code);
        var (builder, _) = BuilderWithLog();

        var error = await Assert.ThrowsAsync<ManifestBuildException>(() =>
            builder.BuildAsync(Room(Foreign(data.LocationCodes.Where(code => code != missing))), null, GameVersion));

        Assert.Contains("expects 456", error.Message, StringComparison.Ordinal);
        Assert.Contains($"(first: {missing})", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ShopSlotsMustMatchTheDeclaredCount()
    {
        var data = await LoadStaticAsync();
        var shopCodes = ShopSlotsInOrder(data).Take(45).Select(pair => pair.Key).ToList();
        var locations = Foreign(data.LocationCodes.Concat(shopCodes));

        var (builder, log) = BuilderWithLog();
        var result = await builder.BuildAsync(Room(locations, s => s.MerchantShop = Shop(data, 45)), null, GameVersion);
        Assert.Equal(456, result.GuidPlacementCount);
        Assert.Contains(log, line => line.Contains("Plus 45 merchant shop check(s).", StringComparison.Ordinal));

        var (refusing, _) = BuilderWithLog();
        var error = await Assert.ThrowsAsync<ManifestBuildException>(() =>
            refusing.BuildAsync(Room(locations, s => s.MerchantShop = Shop(data, 44)), null, GameVersion));
        Assert.Contains("45 merchant shop location(s) but its slot data describes 44", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TradeChecksMustMatchTheDeclaredCount()
    {
        var data = await LoadStaticAsync();
        var tradeCodes = TradeChecksInOrder(data).Select(pair => pair.Key).ToList();
        var locations = Foreign(data.LocationCodes.Concat(tradeCodes));

        var (builder, _) = BuilderWithLog();
        var result = await builder.BuildAsync(Room(locations, s => s.TradeShop = Trade(data, 45)), null, GameVersion);
        Assert.Equal(456, result.GuidPlacementCount);

        var (refusing, _) = BuilderWithLog();
        var error = await Assert.ThrowsAsync<ManifestBuildException>(() =>
            refusing.BuildAsync(Room(locations, s => s.TradeShop = Trade(data, 44)), null, GameVersion));
        Assert.Contains("45 trade check location(s) but its slot data describes 44", error.Message, StringComparison.Ordinal);

        var (disabled, _) = BuilderWithLog();
        var stale = await Assert.ThrowsAsync<ManifestBuildException>(() =>
            disabled.BuildAsync(Room(locations), null, GameVersion));
        Assert.Contains("45 trade check location(s) but its slot data describes 0", stale.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TradeBlockWithNoChecksIsARoomWithNoTradeLocations()
    {
        // Trade checks at 0, gear shuffle on: the block is enabled with no
        // checks and the room carries no trade location. The contract holds
        // (0 declared, 0 scouted) and the gems ride along for the mod.
        var data = await LoadStaticAsync();
        var (builder, _) = BuilderWithLog();

        var result = await builder.BuildAsync(
            Room(Foreign(data.LocationCodes), s => s.TradeShop = Trade(data, 0)), null, GameVersion);

        Assert.Equal(456, result.GuidPlacementCount);
    }

    [Fact]
    public async Task MercenariesRankChecksMustMatchTheDeclaredIds()
    {
        var data = await LoadStaticAsync();
        var standard = RankIds(data, "A", "S");
        Assert.Equal(64, standard.Length);
        var locations = Foreign(data.LocationCodes.Concat(standard));

        var (builder, log) = BuilderWithLog();
        var result = await builder.BuildAsync(
            Room(locations, s =>
            {
                s.GameMode = "campaign_and_mercenaries";
                s.Mercenaries = Mercs(standard);
            }), null, GameVersion);
        Assert.Equal(456, result.GuidPlacementCount);
        Assert.Contains(log, line => line.Contains("Plus 64 Mercenaries rank check(s).", StringComparison.Ordinal));

        var (refusing, _) = BuilderWithLog();
        var error = await Assert.ThrowsAsync<ManifestBuildException>(() =>
            refusing.BuildAsync(
                Room(locations, s =>
                {
                    s.GameMode = "campaign_and_mercenaries";
                    s.Mercenaries = Mercs(standard.Take(63).ToArray());
                }), null, GameVersion));
        Assert.Contains("64 Mercenaries rank check(s) but its slot data describes 63", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task MercenariesOnlyRoomNeedsNoWorldSpots()
    {
        var data = await LoadStaticAsync();
        var standard = RankIds(data, "A", "S");
        var (builder, log) = BuilderWithLog();

        var result = await builder.BuildAsync(
            Room(Foreign(standard), s =>
            {
                s.GameMode = "mercenaries_only";
                s.Mercenaries = Mercs(standard);
            }), null, GameVersion);

        Assert.Equal(0, result.GuidPlacementCount);
        Assert.Contains(log, line => line.StartsWith("Room has 0 RE4R locations.", StringComparison.Ordinal));
    }

    [Theory]
    // A room made before 0.7.6 says nothing, and Leon is what it was patched as.
    [InlineData(null, "Main Story")]
    // A room that says so gets what it asked for.
    [InlineData("Main Story", "Main Story")]
    public async Task TheManifestNamesTheCampaignTheRoomAskedFor(string? patchedCampaign, string expected)
    {
        // The fork reads this key and selects Ada when it says "Separate Ways",
        // so it has to be the room's answer rather than a constant. Behaviour
        // is unchanged for every room that exists today, which is the point.
        var data = await LoadStaticAsync();
        var (builder, _) = BuilderWithLog();

        var result = await builder.BuildAsync(
            Room(Foreign(data.LocationCodes), s => s.PatchedCampaign = patchedCampaign), null, GameVersion);

        Assert.Contains($"\"campaign\": \"{expected}\"", result.ConfigJson, StringComparison.Ordinal);
    }
}
