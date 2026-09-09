using RE4R.AP.Launcher.Core.Models;
using YamlDotNet.Core;
using YamlDotNet.RepresentationModel;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class Re4rYamlBuilder
{
    public string Build(Re4rYamlRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        var slotName = request.SlotName.Trim();
        if (string.IsNullOrWhiteSpace(slotName))
        {
            throw new ArgumentException("RE4R YAML generation requires a slot name.", nameof(request));
        }

        // Slot name, description, and stage IDs are single-quoted so PyYAML
        // keeps them as strings; unquoted they re-type (e.g. "40530" -> int),
        // which OptionSet.VerifyKeys rejects and which corrupts numeric or
        // bool-like slot names.
        var root = new YamlMappingNode
        {
            { "description", SingleQuotedScalar($"RE4R AP - {slotName}") },
            { "name", SingleQuotedScalar(slotName) },
            { "game", "Resident Evil 4 Remake" },
        };

        // progression_balancing is emitted as a bare integer scalar so PyYAML
        // types it as an int (which AP's NamedRange option expects); the 0-99
        // clamp guards against a malformed draft. check_guidance is one of a
        // fixed set of keys - an unknown value falls back to the safe default.
        var progressionBalancing = Math.Clamp(request.ProgressionBalancing, 0, 99);
        var checkGuidance = NormalizeCheckGuidance(request.CheckGuidance);

        var gameOptions = new YamlMappingNode
        {
            // Included Content (apworld 0.7.2): what the slot plays. Always
            // emitted, so the file says it plainly.
            { "included_content", new YamlSequenceNode(IncludedContentNames(request).Select(SingleQuotedScalar)) },
            { "mercenaries_rank_floor", MercenariesRankRange(request).Floor },
            { "mercenaries_rank_ceiling", MercenariesRankRange(request).Ceiling },
            // 0.7.4: a Mercenaries-only slot has no campaign to carry its
            // progression, so its ranks always may (the apworld refuses
            // otherwise); the switch only means something with the campaign.
            { "mercenaries_progression", request.MercenariesProgression || IsMercenariesOnly(request) ? "true" : "false" },
            { "difficulty", request.Difficulty.Trim().ToLowerInvariant() },
            { "progression_balancing", progressionBalancing.ToString(System.Globalization.CultureInfo.InvariantCulture) },
            { "check_guidance", checkGuidance },
            { "marker_detail", NormalizeMarkerDetail(request.MarkerDetail) },
            { "death_link", request.DeathLink ? "true" : "false" },
            { "allow_missable_locations", request.AllowMissableLocations ? "true" : "false" },
            { "shuffle_keycards", request.ShuffleKeycards ? "true" : "false" },
            { "shuffle_merchant_gear", request.ShuffleMerchantGear ? "true" : "false" },
            { "starting_arsenal", Math.Clamp(request.StartingArsenal, 0, 2).ToString() },
            { "random_weapon_stats", NormalizeWeaponRandomization(request.WeaponRandomization) },
            { "minimize_backtracking", request.MinimizeBacktracking ? "true" : "false" },
            { "random_events", request.RandomEvents ? "true" : "false" },
            { "merchant_checks_per_chapter", Math.Clamp(request.MerchantChecksPerChapter, 0, 6).ToString(System.Globalization.CultureInfo.InvariantCulture) },
            { "merchant_checks", NormalizeMerchantChecks(request.MerchantChecks) },
        };

        // [Trade takeover, Phase 2] Always emitted now that the options
        // screen owns it. The apworld REFUSES to generate with trade checks
        // and no shuffle_merchant_gear (the takeover strips the vanilla tab,
        // so trade checks without the shuffle would sell against a tab BioRand
        // still owns), so the dependency is forced here rather than left for a
        // player to discover: gear off means Trade off, the same way
        // ConfigureYamlViewModel already forces starting_arsenal to 0.
        var tradeChecks = request.ShuffleMerchantGear
            ? Math.Clamp(request.TradeChecksPerChapter, 0, 3)
            : 0;
        gameOptions.Add(
            "trade_checks_per_chapter",
            tradeChecks.ToString(System.Globalization.CultureInfo.InvariantCulture));

        var unlockedTypewriters = new YamlSequenceNode(
            request.UnlockedTypewriterStageIds
                .Where(stageId => !string.IsNullOrWhiteSpace(stageId))
                .OrderBy(stageId => stageId, StringComparer.Ordinal)
                .Select(stageId => SingleQuotedScalar(stageId)));

        gameOptions.Add("unlocked_typewriters", unlockedTypewriters);

        // Starting Arsenal types: only when the player trimmed the set. The
        // full set is the apworld default, and emitting it anyway would churn
        // every existing YAML for nothing.
        if (request.StartingArsenalTypes.Count > 0)
        {
            gameOptions.Add("starting_arsenal_types", new YamlSequenceNode(
                request.StartingArsenalTypes.Select(SingleQuotedScalar)));
        }

        // Archipelago's per-game item/location lists. Emitted ONLY when a
        // player actually picked something: an empty sequence here would be
        // harmless to generation but would churn every existing YAML and make
        // the file look configured when it is not.
        AddNameList(gameOptions, "local_items", request.LocalItems);
        AddNameList(gameOptions, "non_local_items", request.NonLocalItems);
        AddNameList(gameOptions, "exclude_locations", request.ExcludeLocations);
        AddNameList(gameOptions, "priority_locations", request.PriorityLocations);

        root.Add("Resident Evil 4 Remake", gameOptions);

        var yaml = new YamlStream(new YamlDocument(root));
        using var writer = new StringWriter();
        yaml.Save(writer, assignAnchors: false);
        return writer.ToString();
    }

    private static string NormalizeCheckGuidance(string? value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant();
        return normalized is "off" or "markers" or "markers_rarity" ? normalized : "markers";
    }

    private static IEnumerable<string> IncludedContentNames(Re4rYamlRequest request)
    {
        // Never empty: the apworld refuses an empty list and the screen refuses
        // to continue without one of the two, so this guards a hand-built
        // request only.
        var names = new List<string>();
        if (request.IncludeMainCampaign || !request.IncludeMercenaries)
        {
            names.Add("Main Campaign");
        }
        if (request.IncludeMercenaries)
        {
            names.Add("Mercenaries");
        }
        return names;
    }

    private static bool IsMercenariesOnly(Re4rYamlRequest request) =>
        request.IncludeMercenaries && !request.IncludeMainCampaign;

    // The rank ladder, lowest first. Both the display names ("S+") and the
    // apworld's keys ("s_plus") land here.
    private static readonly string[] MercenariesRankLadder =
        ["c", "b", "a", "s", "s_plus", "s_plus_plus"];

    private static int MercenariesRankIndex(string? value, int fallback)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant();
        normalized = normalized switch
        {
            "s+" or "splus" => "s_plus",
            "s++" or "splusplus" => "s_plus_plus",
            _ => normalized,
        };
        var index = Array.IndexOf(MercenariesRankLadder, normalized);
        return index >= 0 ? index : fallback;
    }

    // Markers given backwards are read in order rather than refused: the
    // apworld would reject them, and a range has no direction to a player.
    private static (string Floor, string Ceiling) MercenariesRankRange(Re4rYamlRequest request)
    {
        var floor = MercenariesRankIndex(request.MercenariesRankFloor, 0);
        var ceiling = MercenariesRankIndex(request.MercenariesRankCeiling, 2);
        if (ceiling < floor)
        {
            (floor, ceiling) = (ceiling, floor);
        }
        return (MercenariesRankLadder[floor], MercenariesRankLadder[ceiling]);
    }

    private static string NormalizeMerchantChecks(string? value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant();
        return normalized is "local_only" or "remote_only" ? normalized : "mixed";
    }

    // The yaml key keeps its Toggle-era name (random_weapon_stats) so old
    // files and old apworlds stay compatible; the VALUES are the three-way.
    private static string NormalizeWeaponRandomization(string? value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant();
        return normalized is "stats_only" or "full" ? normalized : "off";
    }

    private static string NormalizeMarkerDetail(string? value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant();
        return normalized is "minimal" or "basic" or "locate" or "identify" or "developer"
            ? normalized
            : "locate";
    }

    // Item and location names are single-quoted for the same reason slot names
    // are: an unquoted name that looks numeric or bool-like re-types under
    // PyYAML and then matches nothing in the apworld. Sorted and de-duplicated
    // so the same selection always produces the same file.
    private static void AddNameList(
        YamlMappingNode gameOptions,
        string key,
        IReadOnlyCollection<string>? names)
    {
        if (names is null || names.Count == 0)
        {
            return;
        }

        var cleaned = names
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Select(name => name.Trim())
            .Distinct(StringComparer.Ordinal)
            .OrderBy(name => name, StringComparer.Ordinal)
            .ToList();

        if (cleaned.Count == 0)
        {
            return;
        }

        gameOptions.Add(key, new YamlSequenceNode(cleaned.Select(SingleQuotedScalar)));
    }

    private static YamlScalarNode SingleQuotedScalar(string value) =>
        new(value) { Style = ScalarStyle.SingleQuoted };
}
