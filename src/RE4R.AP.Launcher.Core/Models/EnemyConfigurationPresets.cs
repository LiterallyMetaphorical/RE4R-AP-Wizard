using System.Text.Json.Nodes;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>Curated enemy mixes. Keys are BioRand catalog keys, never launcher-only settings.</summary>
public sealed record EnemyConfigurationPreset(
    string Key,
    string DisplayName,
    string Description,
    string Intensity,
    IReadOnlyDictionary<string, JsonNode?> Values);

public static class EnemyConfigurationPresets
{
    private static readonly IReadOnlyDictionary<string, JsonNode?> Empty =
        new Dictionary<string, JsonNode?>(StringComparer.Ordinal);

    /// <summary>Every class key BioRand can put in its random-enemy probability table for Méndez.</summary>
    public static readonly IReadOnlyList<string> MendezPoolKeys =
    [
        "enemy-ratio-mendez_chase",
        "enemy-ratio-mendez_2",
    ];

    public static readonly EnemyConfigurationPreset Custom = new(
        "custom", "Custom", "Your current enemy settings.", "Mixed", Empty);

    public static readonly IReadOnlyList<EnemyConfigurationPreset> Named =
    [
        Preset("gentle-remix", "Gentle Remix", "New placements, restrained crowds, safe hill and Krauser opener.", "1 / 5",
            ("random-enemies", true), ("extra-enemy-amount", 0d), ("enemy-multiplier", 1d),
            ("enemy-waves-probability", 0d), ("enemy-scale-probability", 0d),
            ("balanced-enemies", true), ("nice-mendez-hill", true), ("mendez-down-resistance", 0d),
            ("enemy-ratio-mendez_chase", 0d), ("enemy-ratio-mendez_2", 0d)),
        Preset("guided-variety", "Guided Variety", "More variety without turning every room into a pile-up.", "2 / 5",
            ("random-enemies", true), ("extra-enemy-amount", .10d), ("enemy-multiplier", 1.15d),
            ("enemy-waves-probability", .03d), ("enemy-waves-min", 2d), ("enemy-waves-max", 2d),
            ("enemy-scale-probability", .02d), ("balanced-enemies", true), ("nice-mendez-hill", true),
            ("mendez-down-resistance", .10d),
            ("enemy-ratio-mendez_chase", 0d), ("enemy-ratio-mendez_2", 0d)),
        Preset("village-siege", "Village Siege", "Busy fights, occasional follow-up waves, still constrained around spikes.", "3 / 5",
            ("random-enemies", true), ("extra-enemy-amount", .25d), ("enemy-multiplier", 1.4d),
            ("enemy-waves-probability", .12d), ("enemy-waves-min", 2d), ("enemy-waves-max", 3d),
            ("enemy-scale-probability", .05d), ("balanced-enemies", true), ("nice-mendez-hill", true),
            ("mendez-down-resistance", .20d),
            ("enemy-ratio-mendez_chase", 0d), ("enemy-ratio-mendez_2", 0d)),
        Preset("relentless", "Relentless", "Dense, recurring encounters. Removes hill and Krauser safety rails.", "4 / 5",
            ("random-enemies", true), ("extra-enemy-amount", .40d), ("enemy-multiplier", 1.75d),
            ("enemy-waves-probability", .25d), ("enemy-waves-min", 2d), ("enemy-waves-max", 4d),
            ("enemy-scale-probability", .10d), ("balanced-enemies", false), ("nice-mendez-hill", false),
            ("mendez-down-resistance", .40d), ("enemies-unleashed", true),
            ("enemy-ratio-mendez_chase", .08d), ("enemy-ratio-mendez_2", .01d)),
        Preset("unstable-chaos", "Unstable Chaos", "Large packs, frequent waves, wild sizes. Stability can suffer.", "5 / 5",
            ("random-enemies", true), ("extra-enemy-amount", .60d), ("enemy-multiplier", 2.25d),
            ("enemy-variety", 35d), ("enemy-pack-max", 4d), ("enemy-waves-probability", .40d),
            ("enemy-waves-min", 3d), ("enemy-waves-max", 5d), ("enemy-scale-probability", .20d),
            ("balanced-enemies", false), ("nice-mendez-hill", false), ("mendez-down-resistance", .70d),
            ("enemies-unleashed", true),
            ("enemy-ratio-mendez_chase", .08d), ("enemy-ratio-mendez_2", .01d)),
    ];

    public static readonly IReadOnlyList<EnemyConfigurationPreset> All = [Custom, .. Named];

    private static EnemyConfigurationPreset Preset(
        string key, string name, string description, string intensity, params (string Key, object Value)[] values)
    {
        // A configuration preset owns every Enemy-tab value. That gives reload matching a complete
        // state to compare, instead of letting an unrelated enemy edit continue to look like a preset.
        var map = BioRandOptionCatalog.Pages
            .Where(page => string.Equals(page.Title, "Enemies", StringComparison.Ordinal))
            .SelectMany(page => page.Groups)
            .SelectMany(group => group.Items)
            .ToDictionary(item => item.Key, item => item.DefaultFor(BioRandOptionCatalog.ModeFullItemEnemy), StringComparer.Ordinal);

        foreach (var pair in values)
        {
            var definition = BioRandOptionCatalog.Find(pair.Key)
                ?? throw new InvalidOperationException($"Unknown enemy preset key: {pair.Key}.");
            var value = pair.Value switch
            {
                bool flag => JsonValue.Create(flag),
                double number => JsonValue.Create(number),
                _ => throw new InvalidOperationException($"Unsupported preset value for {pair.Key}."),
            };

            var isValid = value is JsonValue jsonValue
                && (definition.IsSwitch
                    ? jsonValue.TryGetValue<bool>(out _)
                    : jsonValue.TryGetValue<double>(out var configuredNumber)
                        && configuredNumber >= definition.Min && configuredNumber <= definition.Max);
            if (!isValid)
            {
                throw new InvalidOperationException($"Invalid enemy preset value for {pair.Key}.");
            }

            map[pair.Key] = value;
        }

        return new EnemyConfigurationPreset(key, name, description, intensity, map);
    }
}
