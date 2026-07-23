using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using YamlDotNet.RepresentationModel;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Pure-C# inspection of Archipelago player YAML files - no Python involved.
/// Extracted from the retired hosting service (redesign step 1b) because the
/// planned Generation Guidance screen needs per-file player/game parsing and
/// missing-apworld pre-checks for the organizer's collected YAMLs.
/// </summary>
public sealed class YamlInspectionService
{
    public async Task<ArchipelagoPlayerYamlInfo> ReadPlayerYamlAsync(
        string filePath,
        CancellationToken cancellationToken = default)
    {
        await using var stream = File.OpenRead(filePath);
        using var reader = new StreamReader(stream);
        var fileContents = await reader.ReadToEndAsync(cancellationToken);

        var yaml = new YamlStream();
        yaml.Load(new StringReader(fileContents));

        if (yaml.Documents.Count == 0 || yaml.Documents[0].RootNode is not YamlMappingNode rootMapping)
        {
            throw new YamlInspectionException($"Player YAML {filePath} could not be read because it does not contain a root mapping.");
        }

        var gameName = TryReadScalar(rootMapping, "game");
        var playerName = TryReadScalar(rootMapping, "name");

        if (string.IsNullOrWhiteSpace(gameName))
        {
            throw new YamlInspectionException($"Player YAML {filePath} is missing the required top-level 'game' field.");
        }

        if (string.IsNullOrWhiteSpace(playerName))
        {
            throw new YamlInspectionException($"Player YAML {filePath} is missing the required top-level 'name' field.");
        }

        return new ArchipelagoPlayerYamlInfo
        {
            FilePath = filePath,
            GameName = gameName,
            PlayerName = playerName,
        };
    }

    private static string TryReadScalar(YamlMappingNode rootMapping, string key)
    {
        foreach (var child in rootMapping.Children)
        {
            if (child.Key is YamlScalarNode scalarKey
                && string.Equals(scalarKey.Value, key, StringComparison.Ordinal)
                && child.Value is YamlScalarNode scalarValue)
            {
                return scalarValue.Value ?? string.Empty;
            }
        }

        return string.Empty;
    }
}
