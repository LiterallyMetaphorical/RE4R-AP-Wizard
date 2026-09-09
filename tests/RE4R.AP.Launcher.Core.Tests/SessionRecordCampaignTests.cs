using System.Text.Json;
using RE4R.AP.Launcher.Core.Models;
using Xunit;

namespace RE4R.AP.Launcher.Core.Tests;

/// <summary>
/// What a saved session remembers about the campaign it patched, and whether
/// the launcher can tell one campaign's installed patch from another's.
///
/// The mode alone cannot: Leon's room and Ada's room are both "not Mercenaries
/// only", so a resume check comparing that boolean would hand one campaign's
/// patch to the other's room.
/// </summary>
public sealed class SessionRecordCampaignTests
{
    [Theory]
    // Records written before the campaign was recorded. Leon's was the only
    // campaign anyone could patch, so the mode still answers for them.
    [InlineData("campaign", null, "Main Story")]
    [InlineData("campaign_and_mercenaries", null, "Main Story")]
    [InlineData("mercenaries_only", null, "")]
    [InlineData("MERCENARIES_ONLY", null, "")]
    // Records that say so use their own answer.
    [InlineData("campaign", "Main Story", "Main Story")]
    [InlineData("campaign", "Separate Ways", "Separate Ways")]
    [InlineData("mercenaries_only", "", "")]
    public void ARecordKnowsWhatItPatched(string gameMode, string? patchedCampaign, string expected)
    {
        var record = new SessionRecord { GameMode = gameMode, PatchedCampaign = patchedCampaign };

        Assert.Equal(expected, record.CampaignPatched);
    }

    [Fact]
    public void TwoCampaignsAreToldApart()
    {
        // The reason the field exists. Under the old comparison both of these
        // read as "not Mercenaries only" and counted as the same thing.
        var leon = new SessionRecord { GameMode = "campaign", PatchedCampaign = "Main Story" };
        var ada = new SessionRecord { GameMode = "campaign", PatchedCampaign = "Separate Ways" };

        Assert.NotEqual(leon.CampaignPatched, ada.CampaignPatched);
    }

    [Fact]
    public void TheCampaignSurvivesASaveAndLoad()
    {
        var saved = JsonSerializer.Serialize(new SessionRecord
        {
            SeedName = "seed",
            GameMode = "campaign",
            PatchedCampaign = "Separate Ways",
        });

        Assert.Contains("\"patched_campaign\":\"Separate Ways\"", saved, StringComparison.Ordinal);
        Assert.Equal("Separate Ways", JsonSerializer.Deserialize<SessionRecord>(saved)!.CampaignPatched);
    }

    [Fact]
    public void ARecordFileWrittenBeforeThisStillReads()
    {
        // No patched_campaign key at all, which is every record on disk today.
        const string onDisk = """{"seed_name":"seed","game_mode":"campaign_and_mercenaries","status":"active"}""";

        var record = JsonSerializer.Deserialize<SessionRecord>(onDisk)!;

        Assert.Null(record.PatchedCampaign);
        Assert.Equal("Main Story", record.CampaignPatched);
    }

    [Fact]
    public void TheComputedAnswerIsNotWrittenToTheFile()
    {
        // It is derived, so writing it would put a second, staler copy of the
        // same fact in the file.
        var saved = JsonSerializer.Serialize(new SessionRecord { GameMode = "campaign" });

        Assert.DoesNotContain("CampaignPatched", saved, StringComparison.OrdinalIgnoreCase);
    }
}
