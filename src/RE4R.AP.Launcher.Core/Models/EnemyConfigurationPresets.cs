using System.Text.Json;
using System.Text.Json.Nodes;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>Curated enemy mixes. Keys are BioRand catalog keys, never launcher-only settings.</summary>
public sealed record EnemyConfigurationPreset(
    string Key,
    string DisplayName,
    string Description,
    string Intensity,
    IReadOnlyDictionary<string, JsonNode?> Values,
    string? CrowdKey = null,
    string? RosterKey = null);

/// <summary>One point on the Crowd axis (how busy fights are).</summary>
public sealed record EnemyCrowdPoint(string Key, string Label);

/// <summary>One step on the Roster axis (how scary the mix is).</summary>
public sealed record EnemyRosterStep(string Key, string Label);

/// <summary>A possession gate for a class's randomized spawns. The manifest builder sends the
/// enabled gates (members + item id) to the fork, which echoes back the spawn identities it
/// rolled; the room file writer hands both to the in-game mod.</summary>
public sealed record EnemyClassGate(
    string ClassKey,
    string Type,
    string? Item,
    int ItemEngineId,
    bool Enabled,
    IReadOnlyList<string> Members);

/// <summary>
/// Enemy preset curves, loaded from <c>assets/Data/enemy_presets.json</c>. Two orthogonal axes
/// (Crowd x Roster); the five user-facing presets are curated pairs of them. Per-enemy ratio
/// values derive from the catalog defaults times the roster step's class multiplier (Boss rows
/// are absolute), so a retune is a data edit plus restage, not a rebuild. Design + census
/// evidence: ENEMY_CLASS_DESIGN.md (untracked, repo root).
/// </summary>
public static class EnemyConfigurationPresets
{
    private const string DataFileName = "enemy_presets.json";

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

    private static readonly Lazy<Model> _model = new(Load, isThreadSafe: true);

    public static IReadOnlyList<EnemyConfigurationPreset> Named => _model.Value.Pairs;

    public static IReadOnlyList<EnemyConfigurationPreset> All => _model.Value.All;

    public static IReadOnlyList<EnemyCrowdPoint> CrowdPoints => _model.Value.CrowdPoints;

    public static IReadOnlyList<EnemyRosterStep> RosterSteps => _model.Value.RosterSteps;

    public static IReadOnlyList<EnemyClassGate> Gates => _model.Value.Gates;

    /// <summary>The named pair for a dial combination, or null when the combo is off-ladder.</summary>
    public static EnemyConfigurationPreset? FindPair(string crowdKey, string rosterKey) =>
        _model.Value.Pairs.FirstOrDefault(p =>
            string.Equals(p.CrowdKey, crowdKey, StringComparison.Ordinal)
            && string.Equals(p.RosterKey, rosterKey, StringComparison.Ordinal));

    /// <summary>
    /// Complete Enemies+Health state for an arbitrary dial combination. Off-ladder combos get a
    /// synthesized preset keyed <c>dials:crowd+roster</c> so the existing complete-state
    /// matching keeps working (any hand tweak still reads as Custom).
    /// </summary>
    public static EnemyConfigurationPreset BuildCombination(string crowdKey, string rosterKey)
    {
        var pair = FindPair(crowdKey, rosterKey);
        if (pair != null)
        {
            return pair;
        }

        var model = _model.Value;
        var crowd = model.CrowdDocs.FirstOrDefault(c => c.Key == crowdKey)
            ?? throw new InvalidOperationException($"Unknown crowd point: {crowdKey}.");
        var roster = model.RosterDocs.FirstOrDefault(r => r.Key == rosterKey)
            ?? throw new InvalidOperationException($"Unknown roster step: {rosterKey}.");
        var label = $"{crowd.Label} + {roster.Label}";
        return BuildPreset(
            model.Document,
            key: $"dials:{crowdKey}+{rosterKey}",
            name: label,
            flavor: "Your own mix of crowd and roster.",
            intensity: label,
            crowd,
            roster);
    }

    private sealed record Model(
        JsonObject Document,
        IReadOnlyList<CrowdDoc> CrowdDocs,
        IReadOnlyList<RosterDoc> RosterDocs,
        IReadOnlyList<EnemyConfigurationPreset> Pairs,
        IReadOnlyList<EnemyConfigurationPreset> All,
        IReadOnlyList<EnemyCrowdPoint> CrowdPoints,
        IReadOnlyList<EnemyRosterStep> RosterSteps,
        IReadOnlyList<EnemyClassGate> Gates);

    private sealed record CrowdDoc(string Key, string Label, JsonObject Values);

    private sealed record RosterDoc(
        string Key, string Label, int Index, JsonObject ClassMultipliers,
        double HpPosition, JsonObject Rails, JsonObject Parasites);

    private static Model Load()
    {
        var directory = BioRandOptionCatalog.AssetsDataDirectoryPathOverride
            ?? Path.Combine(AppContext.BaseDirectory, "assets", "Data");
        var path = Path.Combine(directory, DataFileName);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"The enemy preset data was not found at {path}. " +
                $"Copy {DataFileName} into assets/Data before launching.", path);
        }

        var document = JsonNode.Parse(File.ReadAllText(path)) as JsonObject
            ?? throw new InvalidDataException($"{DataFileName} could not be parsed.");

        var crowdDocs = ((JsonArray)document["crowdPoints"]!)
            .Select(node => (JsonObject)node!)
            .Select(o => new CrowdDoc(
                (string)o["key"]!, (string)o["label"]!, (JsonObject)o["values"]!))
            .ToList();
        var rosterDocs = ((JsonArray)document["rosterSteps"]!)
            .Select((node, index) => ((JsonObject)node!, index))
            .Select(t => new RosterDoc(
                (string)t.Item1["key"]!, (string)t.Item1["label"]!, t.index,
                (JsonObject)t.Item1["classMultipliers"]!,
                t.Item1["hpPosition"]!.GetValue<double>(),
                (JsonObject)t.Item1["rails"]!,
                (JsonObject)t.Item1["parasites"]!))
            .ToList();

        var pairs = new List<EnemyConfigurationPreset>();
        foreach (var pairNode in (JsonArray)document["pairs"]!)
        {
            var pair = (JsonObject)pairNode!;
            var crowd = crowdDocs.First(c => c.Key == (string)pair["crowd"]!);
            var roster = rosterDocs.First(r => r.Key == (string)pair["roster"]!);
            pairs.Add(BuildPreset(
                document,
                key: (string)pair["key"]!,
                name: (string)pair["name"]!,
                flavor: (string)pair["description"]!,
                intensity: (string)pair["intensity"]!,
                crowd,
                roster));
        }

        var gates = new List<EnemyClassGate>();
        var classesObject = (JsonObject)document["classes"]!;
        if (document["gates"] is JsonObject gatesObject)
        {
            foreach (var (classKey, node) in gatesObject)
            {
                if (classKey.StartsWith('_') || node is not JsonObject gate)
                {
                    continue;
                }

                var members = classesObject[classKey] is JsonObject classObject
                    ? ((JsonArray)classObject["members"]!).Select(m => (string)m!).ToList()
                    : [];
                gates.Add(new EnemyClassGate(
                    classKey,
                    (string?)gate["type"] ?? "item",
                    (string?)gate["item"],
                    gate["itemEngineId"]?.GetValue<int>() ?? 0,
                    gate["enabled"]?.GetValue<bool>() ?? false,
                    members));
            }
        }

        return new Model(
            document,
            crowdDocs,
            rosterDocs,
            pairs,
            [Custom, .. pairs],
            crowdDocs.Select(c => new EnemyCrowdPoint(c.Key, c.Label)).ToList(),
            rosterDocs.Select(r => new EnemyRosterStep(r.Key, r.Label)).ToList(),
            gates);
    }

    private static EnemyConfigurationPreset BuildPreset(
        JsonObject document, string key, string name, string flavor, string intensity,
        CrowdDoc crowd, RosterDoc roster)
    {
        // A preset owns every Enemies-tab value PLUS the Health page's enemy rows (the HP
        // position curve needs them). Boss-fight HP (boss-health-*) stays a free player dial.
        var map = SeedOwnedKeys();

        foreach (var (optionKey, value) in crowd.Values)
        {
            Apply(map, optionKey, value);
        }

        foreach (var (optionKey, value) in roster.Rails)
        {
            Apply(map, optionKey, value);
        }

        foreach (var (optionKey, value) in roster.Parasites)
        {
            Apply(map, optionKey, value);
        }

        var classes = (JsonObject)document["classes"]!;
        var bossAbsolute = (JsonObject)document["bossAbsolute"]!;
        foreach (var (classKey, classNode) in classes)
        {
            var multiplierNode = roster.ClassMultipliers[classKey];
            var multiplier = multiplierNode?.GetValue<double>();
            foreach (var memberNode in (JsonArray)((JsonObject)classNode!)["members"]!)
            {
                var member = (string)memberNode!;
                var ratioKey = $"enemy-ratio-{member}";
                var definition = BioRandOptionCatalog.Find(ratioKey)
                    ?? throw new InvalidOperationException($"Unknown enemy ratio key: {ratioKey}.");

                double value;
                if (bossAbsolute[member] is JsonArray absolute)
                {
                    value = absolute[roster.Index]!.GetValue<double>();
                }
                else
                {
                    var fallback = multiplier
                        ?? throw new InvalidOperationException(
                            $"Roster step {roster.Key} lacks a multiplier for class {classKey}.");
                    var baseline = definition.DefaultFor(BioRandOptionCatalog.ModeFullItemEnemy)
                        ?.GetValue<double>() ?? 0d;
                    value = baseline * fallback;
                }

                // Snap-at-or-below .005 happens BEFORE rounding: a raw .005
                // (iron maiden at Wild) is a whisper the doc promises away,
                // and AwayFromZero rounding would otherwise resurrect it.
                value = value <= 0.005d + 1e-9
                    ? 0d
                    : Math.Round(value, 2, MidpointRounding.AwayFromZero);

                Apply(map, ratioKey, value);
                ApplyHealthBand(map, member, roster.HpPosition);
            }
        }

        var description = $"{flavor} {BuildPromise(roster, crowd, bossAbsolute)}";
        return new EnemyConfigurationPreset(
            key, name, description, intensity, map, crowd.Key, roster.Key);
    }

    /// <summary>Every preset-owned key at its mode-3 default: the Enemies page, plus the Health
    /// page's enemy band rows and the two enemy health switches.</summary>
    private static Dictionary<string, JsonNode?> SeedOwnedKeys()
    {
        var map = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
        foreach (var page in BioRandOptionCatalog.Pages)
        {
            var isEnemiesPage = string.Equals(page.Title, "Enemies", StringComparison.Ordinal);
            var isHealthPage = string.Equals(page.Title, "Health", StringComparison.Ordinal);
            if (!isEnemiesPage && !isHealthPage)
            {
                continue;
            }

            foreach (var group in page.Groups)
            {
                foreach (var item in group.Items)
                {
                    var owned = isEnemiesPage
                        || item.Key.StartsWith("enemy-health-", StringComparison.Ordinal)
                        || string.Equals(item.Key, "enemy-random-health", StringComparison.Ordinal);
                    if (owned)
                    {
                        map[item.Key] = item.DefaultFor(BioRandOptionCatalog.ModeFullItemEnemy);
                    }
                }
            }
        }

        return map;
    }

    /// <summary>Narrow an enemy's random-health band toward its floor: max' = min + t * (max - min).</summary>
    private static void ApplyHealthBand(Dictionary<string, JsonNode?> map, string member, double t)
    {
        var minDefinition = BioRandOptionCatalog.Find($"enemy-health-min-{member}");
        var maxDefinition = BioRandOptionCatalog.Find($"enemy-health-max-{member}");
        if (minDefinition == null || maxDefinition == null)
        {
            return; // e.g. mendez_chase is invincible and has no health rows
        }

        var min = minDefinition.DefaultFor(BioRandOptionCatalog.ModeFullItemEnemy)?.GetValue<double>() ?? 0d;
        var max = maxDefinition.DefaultFor(BioRandOptionCatalog.ModeFullItemEnemy)?.GetValue<double>() ?? min;
        var scaledMax = Math.Round(min + t * (max - min));
        Apply(map, minDefinition.Key, min);
        Apply(map, maxDefinition.Key, Math.Max(scaledMax, min));
    }

    /// <summary>The generated promise line: derived from data so copy can never drift from it.</summary>
    private static string BuildPromise(RosterDoc roster, CrowdDoc crowd, JsonObject bossAbsolute)
    {
        var bossMax = bossAbsolute
            .Where(pair => !pair.Key.StartsWith('_'))
            .Select(pair => ((JsonArray)pair.Value!)[roster.Index]!.GetValue<double>())
            .Max();
        var bossLine = bossMax <= 0d
            ? "No bosses."
            : bossMax <= 0.08 ? "Bosses make a first appearance." : "Bosses walk the world.";

        var dread = roster.ClassMultipliers["dread"]!.GetValue<double>();
        var dreadLine = dread <= 0d
            ? "No lab horrors."
            : dread < 1d ? "Lab horrors creep in." : "Lab horrors are loose.";

        var miniboss = roster.ClassMultipliers["miniboss"]!.GetValue<double>();
        var minibossLine = miniboss <= 0.2
            ? "Minibosses stay rare."
            : miniboss <= 0.9 ? "Minibosses show up." : "Minibosses are common.";

        return $"{bossLine} {dreadLine} {minibossLine} Crowds: {crowd.Label.ToLowerInvariant()}.";
    }

    private static void Apply(Dictionary<string, JsonNode?> map, string key, JsonNode? rawValue)
    {
        var definition = BioRandOptionCatalog.Find(key)
            ?? throw new InvalidOperationException($"Unknown enemy preset key: {key}.");
        var value = rawValue switch
        {
            JsonValue jsonValue when jsonValue.TryGetValue<bool>(out var flag) => JsonValue.Create(flag),
            JsonValue jsonValue when jsonValue.TryGetValue<double>(out var number) => JsonValue.Create(number),
            _ => throw new InvalidOperationException($"Unsupported preset value for {key}."),
        };
        Validate(definition, value, key);
        map[key] = value;
    }

    private static void Apply(Dictionary<string, JsonNode?> map, string key, double number)
    {
        var definition = BioRandOptionCatalog.Find(key)
            ?? throw new InvalidOperationException($"Unknown enemy preset key: {key}.");
        var value = JsonValue.Create(number);
        Validate(definition, value, key);
        map[key] = value;
    }

    private static void Validate(BioRandOptionDefinition definition, JsonValue value, string key)
    {
        var isValid = definition.IsSwitch
            ? value.TryGetValue<bool>(out _)
            : value.TryGetValue<double>(out var configuredNumber)
                && configuredNumber >= definition.Min && configuredNumber <= definition.Max;
        if (!isValid)
        {
            throw new InvalidOperationException($"Invalid enemy preset value for {key}.");
        }
    }
}
