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

        var gameOptions = new YamlMappingNode
        {
            { "difficulty", request.Difficulty.Trim().ToLowerInvariant() },
            { "death_link", request.DeathLink ? "true" : "false" },
            { "allow_missable_locations", request.AllowMissableLocations ? "true" : "false" },
            { "randomize_gated_keys", request.RandomizeGatedKeys ? "true" : "false" },
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

    private static YamlScalarNode SingleQuotedScalar(string value) =>
        new(value) { Style = ScalarStyle.SingleQuoted };
}
