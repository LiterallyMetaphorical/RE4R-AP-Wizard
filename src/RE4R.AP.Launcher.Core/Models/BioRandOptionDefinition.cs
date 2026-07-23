using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// One BioRand option, as declared by BioRand itself.
///
/// The whole catalog is GENERATED from BioRand's own <c>Re4rRandomizerConfigurationDefinition</c>
/// and shipped as <c>assets/Data/biorand_options.json</c>, so keys, labels, types, ranges and
/// defaults match BioRand exactly and a future BioRand update is a re-dump rather than a rewrite.
/// </summary>
public sealed class BioRandOptionDefinition
{
    /// <summary>The exact BioRand config key. A typo means BioRand silently ignores the option.</summary>
    [JsonPropertyName("key")]
    public string Key { get; set; } = string.Empty;

    [JsonPropertyName("label")]
    public string Label { get; set; } = string.Empty;

    [JsonPropertyName("description")]
    public string Description { get; set; } = string.Empty;

    /// <summary>BioRand's own type name: switch, range, percent, scale.</summary>
    [JsonPropertyName("type")]
    public string Type { get; set; } = "switch";

    [JsonPropertyName("min")]
    public double? Min { get; set; }

    [JsonPropertyName("max")]
    public double? Max { get; set; }

    [JsonPropertyName("step")]
    public double? Step { get; set; }

    /// <summary>BioRand's own "advanced" flag - hidden unless the player opts in.</summary>
    [JsonPropertyName("advanced")]
    public bool Advanced { get; set; }

    /// <summary>Per-mode defaults: index 0 = mode 1, 1 = mode 2, 2 = mode 3.</summary>
    [JsonPropertyName("defaults")]
    public List<JsonNode?> Defaults { get; set; } = new();

    [JsonIgnore]
    public bool IsSwitch => string.Equals(Type, "switch", StringComparison.OrdinalIgnoreCase);

    [JsonIgnore]
    public bool IsPercent => string.Equals(Type, "percent", StringComparison.OrdinalIgnoreCase);

    public JsonNode? DefaultFor(int mode)
    {
        var index = Math.Clamp(mode, 1, 3) - 1;
        return index < Defaults.Count ? Defaults[index]?.DeepClone() : null;
    }
}

public sealed class BioRandOptionGroup
{
    [JsonPropertyName("title")]
    public string Title { get; set; } = string.Empty;

    [JsonPropertyName("items")]
    public List<BioRandOptionDefinition> Items { get; set; } = new();
}

public sealed class BioRandOptionPage
{
    [JsonPropertyName("title")]
    public string Title { get; set; } = string.Empty;

    [JsonPropertyName("groups")]
    public List<BioRandOptionGroup> Groups { get; set; } = new();
}

public sealed class BioRandOptionCatalogDocument
{
    [JsonPropertyName("schema_version")]
    public int SchemaVersion { get; set; }

    [JsonPropertyName("pages")]
    public List<BioRandOptionPage> Pages { get; set; } = new();
}
