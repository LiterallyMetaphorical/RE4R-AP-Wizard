using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using Xunit;
using YamlDotNet.RepresentationModel;

namespace RE4R.AP.Launcher.Core.Tests;

/// <summary>
/// The settings file the options screen writes. Every option the apworld
/// reads has to come out under its exact key, in the exact spelling the
/// apworld accepts, and quoted where PyYAML would otherwise re-type it.
/// </summary>
public sealed class Re4rYamlBuilderTests
{
    private static readonly Re4rYamlBuilder Builder = new();

    private static Re4rYamlRequest Request(Action<Re4rYamlRequest>? configure = null)
    {
        var request = new Re4rYamlRequest { SlotName = "Tester" };
        configure?.Invoke(request);
        return request;
    }

    private static YamlMappingNode GameOptions(string yaml)
    {
        var stream = new YamlStream();
        stream.Load(new StringReader(yaml));
        var root = (YamlMappingNode)stream.Documents[0].RootNode;
        return (YamlMappingNode)root.Children[new YamlScalarNode("Resident Evil 4 Remake")];
    }

    private static string? Scalar(YamlMappingNode options, string key) =>
        options.Children.TryGetValue(new YamlScalarNode(key), out var node)
            ? ((YamlScalarNode)node).Value
            : null;

    private static List<string> Sequence(YamlMappingNode options, string key) =>
        ((YamlSequenceNode)options.Children[new YamlScalarNode(key)])
            .Children
            .Select(node => ((YamlScalarNode)node).Value ?? string.Empty)
            .ToList();

    private static bool Has(YamlMappingNode options, string key) =>
        options.Children.ContainsKey(new YamlScalarNode(key));

    [Fact]
    public void DefaultRequestPlaysTheCampaignAlone()
    {
        var options = GameOptions(Builder.Build(Request()));

        Assert.Equal(new[] { "Main Campaign" }, Sequence(options, "included_content"));
        Assert.Equal("c", Scalar(options, "mercenaries_rank_floor"));
        Assert.Equal("a", Scalar(options, "mercenaries_rank_ceiling"));
        Assert.Equal("standard", Scalar(options, "difficulty"));
    }

    [Fact]
    public void BothContentsAreWrittenInTheApworldsNames()
    {
        var yaml = Builder.Build(Request(r => r.IncludeMercenaries = true));

        Assert.Equal(new[] { "Main Campaign", "Mercenaries" }, Sequence(GameOptions(yaml), "included_content"));
    }

    [Fact]
    public void MercenariesAloneLeavesTheCampaignOut()
    {
        var yaml = Builder.Build(Request(r =>
        {
            r.IncludeMainCampaign = false;
            r.IncludeMercenaries = true;
        }));

        Assert.Equal(new[] { "Mercenaries" }, Sequence(GameOptions(yaml), "included_content"));
    }

    [Fact]
    public void NeitherContentFallsBackToTheCampaign()
    {
        // The apworld refuses an empty list; a hand-built request must never
        // produce one.
        var yaml = Builder.Build(Request(r =>
        {
            r.IncludeMainCampaign = false;
            r.IncludeMercenaries = false;
        }));

        Assert.Equal(new[] { "Main Campaign" }, Sequence(GameOptions(yaml), "included_content"));
    }

    [Theory]
    [InlineData("c", "c")]
    [InlineData("S+", "s_plus")]
    [InlineData("s_plus", "s_plus")]
    [InlineData("S++", "s_plus_plus")]
    [InlineData("nonsense", "c")]
    public void TheRankFloorIsNormalisedToTheApworldsKeys(string given, string expected)
    {
        var yaml = Builder.Build(Request(r =>
        {
            r.MercenariesRankFloor = given;
            r.MercenariesRankCeiling = "s_plus_plus";
        }));

        Assert.Equal(expected, Scalar(GameOptions(yaml), "mercenaries_rank_floor"));
    }

    [Fact]
    public void MarkersGivenBackwardsAreWrittenInOrder()
    {
        // A range has no direction to a player, and the apworld refuses one
        // that runs backwards, so the builder puts them right.
        var yaml = Builder.Build(Request(r =>
        {
            r.MercenariesRankFloor = "s_plus";
            r.MercenariesRankCeiling = "b";
        }));

        var options = GameOptions(yaml);
        Assert.Equal("b", Scalar(options, "mercenaries_rank_floor"));
        Assert.Equal("s_plus", Scalar(options, "mercenaries_rank_ceiling"));
    }

    [Fact]
    public void ASingleRankRangeWritesTheSameRankTwice()
    {
        var yaml = Builder.Build(Request(r =>
        {
            r.MercenariesRankFloor = "a";
            r.MercenariesRankCeiling = "a";
        }));

        var options = GameOptions(yaml);
        Assert.Equal("a", Scalar(options, "mercenaries_rank_floor"));
        Assert.Equal("a", Scalar(options, "mercenaries_rank_ceiling"));
    }

    [Theory]
    [InlineData(true, "true")]
    [InlineData(false, "false")]
    public void MercenariesProgressionIsAlwaysWritten(bool given, string expected)
    {
        // 0.7.4: on by default; a player who turns it off must see it in the file.
        var yaml = Builder.Build(Request(r => r.MercenariesProgression = given));

        Assert.Equal(expected, Scalar(GameOptions(yaml), "mercenaries_progression"));
    }

    [Fact]
    public void MercenariesOnlySlotsAlwaysAllowProgressionOnRanks()
    {
        // The unlocks are that slot's only progression; the apworld refuses the
        // switch off there, so the file never asks for it.
        var yaml = Builder.Build(Request(r =>
        {
            r.IncludeMainCampaign = false;
            r.IncludeMercenaries = true;
            r.MercenariesProgression = false;
        }));

        Assert.Equal("true", Scalar(GameOptions(yaml), "mercenaries_progression"));
    }

    [Fact]
    public void MercenariesProgressionDefaultsOn()
    {
        Assert.Equal("true", Scalar(GameOptions(Builder.Build(Request())), "mercenaries_progression"));
    }

    [Fact]
    public void TypewritersAreQuotedAndSorted()
    {
        // A bare 40530 re-types to an int under PyYAML; the apworld accepts
        // ids and names, and both must arrive as strings.
        var yaml = Builder.Build(Request(r =>
            r.UnlockedTypewriterStageIds = new[] { "43300", "40530", "Farm Typewriter", "" }));

        Assert.Equal(new[] { "40530", "43300", "Farm Typewriter" }, Sequence(GameOptions(yaml), "unlocked_typewriters"));
        Assert.Contains("- '40530'", yaml);
        Assert.Contains("- 'Farm Typewriter'", yaml);
    }

    [Fact]
    public void TradeChecksNeedTheGearShuffle()
    {
        var without = GameOptions(Builder.Build(Request(r =>
        {
            r.ShuffleMerchantGear = false;
            r.TradeChecksPerChapter = 3;
        })));
        var with = GameOptions(Builder.Build(Request(r =>
        {
            r.ShuffleMerchantGear = true;
            r.TradeChecksPerChapter = 5;
        })));

        Assert.Equal("0", Scalar(without, "trade_checks_per_chapter"));
        Assert.Equal("false", Scalar(without, "shuffle_merchant_gear"));
        Assert.Equal("3", Scalar(with, "trade_checks_per_chapter"));
    }

    [Fact]
    public void NameListsAppearOnlyWhenChosenAndComeOutSortedAndUnique()
    {
        var untouched = GameOptions(Builder.Build(Request()));
        Assert.False(Has(untouched, "exclude_locations"));
        Assert.False(Has(untouched, "priority_locations"));
        Assert.False(Has(untouched, "local_items"));
        Assert.False(Has(untouched, "non_local_items"));

        var chosen = GameOptions(Builder.Build(Request(r =>
        {
            r.ExcludeLocations = new[] { "Village", "Chests", " Village " };
            r.PriorityLocations = new[] { "Castle" };
            r.NonLocalItems = new[] { "Small Keys" };
        })));

        Assert.Equal(new[] { "Chests", "Village" }, Sequence(chosen, "exclude_locations"));
        Assert.Equal(new[] { "Castle" }, Sequence(chosen, "priority_locations"));
        Assert.Equal(new[] { "Small Keys" }, Sequence(chosen, "non_local_items"));
        Assert.False(Has(chosen, "local_items"));
    }

    [Fact]
    public void OptionsWithFixedSpellingsFallBackToSafeDefaults()
    {
        var options = GameOptions(Builder.Build(Request(r =>
        {
            r.MerchantChecks = "everyone";
            r.WeaponRandomization = "sometimes";
            r.MarkerDetail = "loud";
            r.CheckGuidance = "maybe";
            r.ProgressionBalancing = 250;
            r.StartingArsenal = 9;
            r.MerchantChecksPerChapter = 40;
        })));

        Assert.Equal("mixed", Scalar(options, "merchant_checks"));
        Assert.Equal("off", Scalar(options, "random_weapon_stats"));
        Assert.Equal("locate", Scalar(options, "marker_detail"));
        Assert.Equal("markers", Scalar(options, "check_guidance"));
        Assert.Equal("99", Scalar(options, "progression_balancing"));
        Assert.Equal("2", Scalar(options, "starting_arsenal"));
        Assert.Equal("6", Scalar(options, "merchant_checks_per_chapter"));
    }

    [Fact]
    public void SlotNamesStayStringsAndAreRequired()
    {
        var yaml = Builder.Build(Request(r => r.SlotName = "007"));
        Assert.Contains("name: '007'", yaml);

        Assert.Throws<ArgumentException>(() => Builder.Build(Request(r => r.SlotName = "   ")));
    }
}
