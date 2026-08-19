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
        var gameMode = NormalizeGameMode(request.GameMode);
        var scoreChecks = NormalizeMercenariesScoreChecks(request.MercenariesScoreChecks);

        var gameOptions = new YamlMappingNode
        {
            { "game_mode", gameMode },
            { "mercenaries_score_checks", scoreChecks },
            { "difficulty", request.Difficulty.Trim().ToLowerInvariant() },
            { "progression_balancing", progressionBalancing.ToString(System.Globalization.CultureInfo.InvariantCulture) },
            { "check_guidance", checkGuidance },
            { "death_link", request.DeathLink ? "true" : "false" },
            { "allow_missable_locations", request.AllowMissableLocations ? "true" : "false" },
            { "shuffle_keycards", request.ShuffleKeycards ? "true" : "false" },
            { "minimize_backtracking", request.MinimizeBacktracking ? "true" : "false" },
            { "random_events", request.RandomEvents ? "true" : "false" },
            { "tutorial", request.Tutorial ? "true" : "false" },
        };

        var unlockedTypewriters = new YamlSequenceNode(
            request.UnlockedTypewriterStageIds
                .Where(stageId => !string.IsNullOrWhiteSpace(stageId))
                .OrderBy(stageId => stageId, StringComparer.Ordinal)
                .Select(stageId => SingleQuotedScalar(stageId)));

        gameOptions.Add("unlocked_typewriters", unlockedTypewriters);
        root.Add("Resident Evil 4 Remake", gameOptions);

        var yaml = new YamlStream(new YamlDocument(root));
        using var writer = new StringWriter();
        yaml.Save(writer, assignAnchors: false);
        return writer.ToString();
    }

    private static string NormalizeGameMode(string? value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant().Replace(" ", "_").Replace("+", "and");
        return normalized switch
        {
            "campaign_and_mercenaries" or "campaignandmercenaries" => "campaign_and_mercenaries",
            "mercenaries_only" or "mercenariesonly" or "mercenaries" => "mercenaries_only",
            _ => "campaign"
        };
    }

    private static string NormalizeMercenariesScoreChecks(string? value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant().Replace(" ", "_");
        return normalized switch
        {
            "a_only" or "aonly" => "a_only",
            "full" => "full",
            _ => "standard"
        };
    }

    private static string NormalizeCheckGuidance(string? value)
    {
        var normalized = (value ?? string.Empty).Trim().ToLowerInvariant();
        return normalized is "off" or "markers" or "markers_rarity" ? normalized : "markers";
    }

    private static YamlScalarNode SingleQuotedScalar(string value) =>
        new(value) { Style = ScalarStyle.SingleQuoted };
}

