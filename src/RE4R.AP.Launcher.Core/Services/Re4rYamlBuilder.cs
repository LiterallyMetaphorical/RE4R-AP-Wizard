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
            { "difficulty", request.Difficulty.Trim().ToLowerInvariant() },
            { "progression_balancing", progressionBalancing.ToString(System.Globalization.CultureInfo.InvariantCulture) },
            { "check_guidance", checkGuidance },
            { "marker_detail", NormalizeMarkerDetail(request.MarkerDetail) },
            { "death_link", request.DeathLink ? "true" : "false" },
            { "allow_missable_locations", request.AllowMissableLocations ? "true" : "false" },
            { "shuffle_keycards", request.ShuffleKeycards ? "true" : "false" },
            { "minimize_backtracking", request.MinimizeBacktracking ? "true" : "false" },
            { "random_events", request.RandomEvents ? "true" : "false" },
            { "shop_checks", Math.Clamp(request.ShopChecks, 0, 24).ToString(System.Globalization.CultureInfo.InvariantCulture) },
            { "tutorial", request.Tutorial ? "true" : "false" },
        };

        var unlockedTypewriters = new YamlSequenceNode(
            request.UnlockedTypewriterStageIds
                .Where(stageId => !string.IsNullOrWhiteSpace(stageId))
                .OrderBy(stageId => stageId, StringComparer.Ordinal)
                .Select(stageId => SingleQuotedScalar(stageId)));

        gameOptions.Add("unlocked_typewriters", unlockedTypewriters);

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

    private static string NormalizeMarkerDetail(string? value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant();
        return normalized is "minimal" or "basic" or "locate" or "identify" ? normalized : "locate";
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
