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
    string? RosterKey = null,
    string? VitalityKey = null);

/// <summary>One point on the Crowd axis (how busy fights are).</summary>
public sealed record EnemyCrowdPoint(string Key, string Label)
{
    // The themed ComboBox renders the record's ToString in its selection
    // box regardless of DisplayMemberPath (live 2026-08-16), so ToString IS
    // the display contract for all three dial records.
    public override string ToString() => Label;
}

/// <summary>One step on the Roster axis (how scary the mix is). <see cref="ClassLock"/> means
/// spawns may only reroll within their vanilla occupant's class at this step (the threat map
/// stays the designed campaign's), with classLockExempt classes eligible everywhere.</summary>
public sealed record EnemyRosterStep(string Key, string Label, bool ClassLock)
{
    public override string ToString() => Label;
}

/// <summary>One point on the Vitality axis (how tough each enemy's random-health band is).</summary>
public sealed record EnemyVitalityPoint(string Key, string Label)
{
    public override string ToString() => Label;
}

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

    public static IReadOnlyList<EnemyVitalityPoint> VitalityPoints => _model.Value.VitalityPoints;

    public static IReadOnlyList<EnemyClassGate> Gates => _model.Value.Gates;

    /// <summary>Class key -> member class keys, straight from the data file.</summary>
    public static IReadOnlyDictionary<string, IReadOnlyList<string>> ClassMembers => _model.Value.ClassMembers;

    /// <summary>Classes exempt from the class lock (eligible everywhere; the wandering cow rule).</summary>
    public static IReadOnlyList<string> ClassLockExemptClasses => _model.Value.ClassLockExempt;

    /// <summary>
    /// Which roster step a complete option state was built from, or null for hand-tuned values.
    /// Matched on the step's OWN keys (rails, parasites, ratios), so the other dials do not
    /// disturb it. Drives the class lock at manifest time: the lock is part of a named step's
    /// promise, so hand-tuned Custom states never emit it.
    /// </summary>
    public static EnemyRosterStep? DetectRosterStep(Func<string, JsonNode?> valueGetter)
    {
        foreach (var (step, fragment) in _model.Value.RosterFragments)
        {
            if (FragmentMatches(fragment, valueGetter))
            {
                return step;
            }
        }

        return null;
    }

    /// <summary>Which Vitality point a state's HP bands were built from, or null when hand-tuned.</summary>
    public static EnemyVitalityPoint? DetectVitalityPoint(Func<string, JsonNode?> valueGetter)
    {
        foreach (var (point, fragment) in _model.Value.VitalityFragments)
        {
            if (FragmentMatches(fragment, valueGetter))
            {
                return point;
            }
        }

        return null;
    }

    /// <summary>Which Crowd point a state's crowd values were built from, or null when hand-tuned.</summary>
    public static EnemyCrowdPoint? DetectCrowdPoint(Func<string, JsonNode?> valueGetter)
    {
        for (var i = 0; i < _model.Value.CrowdDocs.Count; i++)
        {
            var doc = _model.Value.CrowdDocs[i];
            var matched = true;
            foreach (var (key, expected) in doc.Values)
            {
                if (expected is not JsonValue || !ValueMatches(valueGetter(key), expected))
                {
                    matched = false;
                    break;
                }
            }

            if (matched)
            {
                return _model.Value.CrowdPoints[i];
            }
        }

        return null;
    }

    private static bool FragmentMatches(
        IReadOnlyDictionary<string, JsonNode?> fragment, Func<string, JsonNode?> valueGetter)
    {
        foreach (var (key, expected) in fragment)
        {
            if (!ValueMatches(valueGetter(key), expected))
            {
                return false;
            }
        }

        return true;
    }

    private static bool ValueMatches(JsonNode? actual, JsonNode? expected)
    {
        if (actual is not JsonValue actualValue || expected is not JsonValue expectedValue)
        {
            return false;
        }

        if (expectedValue.TryGetValue<bool>(out var expectedFlag))
        {
            return actualValue.TryGetValue<bool>(out var actualFlag) && actualFlag == expectedFlag;
        }

        return expectedValue.TryGetValue<double>(out var expectedNumber)
            && actualValue.TryGetValue<double>(out var actualNumber)
            && Math.Abs(actualNumber - expectedNumber) < .0001d;
    }

    /// <summary>
    /// Concrete example HP bands for a Vitality point, so the dial shows real numbers
    /// instead of adjectives. Honest scope note: these are positions on BIORAND's
    /// randomization bands; the game's own fixed HP varies per enemy and difficulty and
    /// has not been calibrated onto this ladder yet.
    /// </summary>
    public static string DescribeVitality(string vitalityKey)
    {
        var vitality = _model.Value.VitalityDocs.FirstOrDefault(v => v.Key == vitalityKey);
        if (vitality == null)
        {
            return string.Empty;
        }

        var parts = new List<string>();
        foreach (var (member, label) in ExampleEnemies)
        {
            var minDefinition = BioRandOptionCatalog.Find($"enemy-health-min-{member}");
            var maxDefinition = BioRandOptionCatalog.Find($"enemy-health-max-{member}");
            if (minDefinition == null || maxDefinition == null)
            {
                continue;
            }

            var min = minDefinition.DefaultFor(BioRandOptionCatalog.ModeFullItemEnemy)?.GetValue<double>() ?? 0d;
            var max = maxDefinition.DefaultFor(BioRandOptionCatalog.ModeFullItemEnemy)?.GetValue<double>() ?? min;
            var scaledMax = Math.Max(Math.Round(min + vitality.HpPosition * (max - min)), min);
            parts.Add($"{label} {min:n0} to {scaledMax:n0}");
        }

        return string.Join(", ", parts);
    }

    private static readonly (string Member, string Label)[] ExampleEnemies =
    [
        ("villager", "Villager"),
        ("chainsaw", "Chainsaw Man"),
        ("regenerador", "Regenerador"),
    ];

    /// <summary>The named pair for a dial combination, or null when the combo is off-ladder.</summary>
    public static EnemyConfigurationPreset? FindPair(string crowdKey, string rosterKey, string vitalityKey) =>
        _model.Value.Pairs.FirstOrDefault(p =>
            string.Equals(p.CrowdKey, crowdKey, StringComparison.Ordinal)
            && string.Equals(p.RosterKey, rosterKey, StringComparison.Ordinal)
            && string.Equals(p.VitalityKey, vitalityKey, StringComparison.Ordinal));

    /// <summary>
    /// Complete Enemies+Health state for an arbitrary dial combination. Off-ladder combos get a
    /// synthesized preset keyed <c>dials:crowd+roster+vitality</c> so the existing
    /// complete-state matching keeps working (any hand tweak still reads as Custom).
    /// </summary>
    public static EnemyConfigurationPreset BuildCombination(string crowdKey, string rosterKey, string vitalityKey)
    {
        var pair = FindPair(crowdKey, rosterKey, vitalityKey);
        if (pair != null)
        {
            return pair;
        }

        var model = _model.Value;
        var crowd = model.CrowdDocs.FirstOrDefault(c => c.Key == crowdKey)
            ?? throw new InvalidOperationException($"Unknown crowd point: {crowdKey}.");
        var roster = model.RosterDocs.FirstOrDefault(r => r.Key == rosterKey)
            ?? throw new InvalidOperationException($"Unknown roster step: {rosterKey}.");
        var vitality = model.VitalityDocs.FirstOrDefault(v => v.Key == vitalityKey)
            ?? throw new InvalidOperationException($"Unknown vitality point: {vitalityKey}.");
        var label = $"{crowd.Label} + {roster.Label} + {vitality.Label}";
        return BuildPreset(
            model.Document,
            key: $"dials:{crowdKey}+{rosterKey}+{vitalityKey}",
            name: label,
            flavor: "Your own mix of crowd, roster and vitality.",
            intensity: label,
            crowd,
            roster,
            vitality);
    }

    private sealed record Model(
        JsonObject Document,
        IReadOnlyList<CrowdDoc> CrowdDocs,
        IReadOnlyList<RosterDoc> RosterDocs,
        IReadOnlyList<VitalityDoc> VitalityDocs,
        IReadOnlyList<EnemyConfigurationPreset> Pairs,
        IReadOnlyList<EnemyConfigurationPreset> All,
        IReadOnlyList<EnemyCrowdPoint> CrowdPoints,
        IReadOnlyList<EnemyRosterStep> RosterSteps,
        IReadOnlyList<EnemyVitalityPoint> VitalityPoints,
        IReadOnlyList<EnemyClassGate> Gates,
        IReadOnlyDictionary<string, IReadOnlyList<string>> ClassMembers,
        IReadOnlyList<string> ClassLockExempt,
        IReadOnlyList<(EnemyRosterStep Step, IReadOnlyDictionary<string, JsonNode?> Fragment)> RosterFragments,
        IReadOnlyList<(EnemyVitalityPoint Point, IReadOnlyDictionary<string, JsonNode?> Fragment)> VitalityFragments);

    private sealed record CrowdDoc(string Key, string Label, JsonObject Values);

    private sealed record RosterDoc(
        string Key, string Label, int Index, JsonObject ClassMultipliers,
        JsonObject Rails, JsonObject Parasites, bool ClassLock);

    private sealed record VitalityDoc(string Key, string Label, double HpPosition);

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
                (JsonObject)t.Item1["rails"]!,
                (JsonObject)t.Item1["parasites"]!,
                t.Item1["classLock"]?.GetValue<bool>() ?? false))
            .ToList();
        var vitalityDocs = ((JsonArray)document["vitalityPoints"]!)
            .Select(node => (JsonObject)node!)
            .Select(o => new VitalityDoc(
                (string)o["key"]!, (string)o["label"]!,
                o["hpPosition"]!.GetValue<double>()))
            .ToList();

        var pairs = new List<EnemyConfigurationPreset>();
        foreach (var pairNode in (JsonArray)document["pairs"]!)
        {
            var pair = (JsonObject)pairNode!;
            var crowd = crowdDocs.First(c => c.Key == (string)pair["crowd"]!);
            var roster = rosterDocs.First(r => r.Key == (string)pair["roster"]!);
            var vitality = vitalityDocs.First(v => v.Key == (string)pair["vitality"]!);
            pairs.Add(BuildPreset(
                document,
                key: (string)pair["key"]!,
                name: (string)pair["name"]!,
                flavor: (string)pair["description"]!,
                intensity: (string)pair["intensity"]!,
                crowd,
                roster,
                vitality));
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

        var classMembers = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal);
        foreach (var (classKey, classNode) in (JsonObject)document["classes"]!)
        {
            classMembers[classKey] = ((JsonArray)((JsonObject)classNode!)["members"]!)
                .Select(m => (string)m!)
                .ToList();
        }

        var classLockExempt = document["classLockExempt"] is JsonArray exemptArray
            ? exemptArray.Select(node => (string)node!).ToList()
            : [];

        var steps = rosterDocs.Select(r => new EnemyRosterStep(r.Key, r.Label, r.ClassLock)).ToList();
        var fragments = rosterDocs
            .Select((r, index) => (
                Step: steps[index],
                Fragment: (IReadOnlyDictionary<string, JsonNode?>)ComputeRosterFragment(document, r)))
            .ToList();
        var vitalityPoints = vitalityDocs.Select(v => new EnemyVitalityPoint(v.Key, v.Label)).ToList();
        var vitalityFragments = vitalityDocs
            .Select((v, index) => (
                Point: vitalityPoints[index],
                Fragment: (IReadOnlyDictionary<string, JsonNode?>)ComputeVitalityFragment(document, v)))
            .ToList();

        return new Model(
            document,
            crowdDocs,
            rosterDocs,
            vitalityDocs,
            pairs,
            [Custom, .. pairs],
            crowdDocs.Select(c => new EnemyCrowdPoint(c.Key, c.Label)).ToList(),
            steps,
            vitalityPoints,
            gates,
            classMembers,
            classLockExempt,
            fragments,
            vitalityFragments);
    }

    private static EnemyConfigurationPreset BuildPreset(
        JsonObject document, string key, string name, string flavor, string intensity,
        CrowdDoc crowd, RosterDoc roster, VitalityDoc vitality)
    {
        // A preset owns every Enemies-tab value PLUS the Health page's enemy rows (the
        // Vitality axis needs them). Boss-fight HP (boss-health-*) stays a free player dial.
        var map = SeedOwnedKeys();

        foreach (var (optionKey, value) in crowd.Values)
        {
            Apply(map, optionKey, value);
        }

        foreach (var (optionKey, value) in ComputeRosterFragment(document, roster))
        {
            map[optionKey] = value;
        }

        foreach (var (optionKey, value) in ComputeVitalityFragment(document, vitality))
        {
            map[optionKey] = value;
        }

        var bossAbsolute = (JsonObject)document["bossAbsolute"]!;
        var description = $"{flavor} {BuildPromise(roster, crowd, vitality, bossAbsolute)}";
        return new EnemyConfigurationPreset(
            key, name, description, intensity, map, crowd.Key, roster.Key, vitality.Key);
    }

    /// <summary>
    /// Every key a roster step OWNS, with its computed value: rails, parasites and all class
    /// ratio rows. (HP bands belong to the Vitality axis.) This is both what a preset applies
    /// on top of the crowd values and the signature <see cref="DetectRosterStep"/> matches a
    /// saved state against.
    /// </summary>
    private static Dictionary<string, JsonNode?> ComputeRosterFragment(JsonObject document, RosterDoc roster)
    {
        var fragment = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);

        foreach (var (optionKey, value) in roster.Rails)
        {
            Apply(fragment, optionKey, value);
        }

        foreach (var (optionKey, value) in roster.Parasites)
        {
            Apply(fragment, optionKey, value);
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

                Apply(fragment, ratioKey, value);
            }
        }

        return fragment;
    }

    /// <summary>
    /// Every key a Vitality point OWNS: the HP band rows for each roster enemy that has
    /// them. What a preset applies last, and the signature <see cref="DetectVitalityPoint"/>
    /// matches a saved state against.
    /// </summary>
    private static Dictionary<string, JsonNode?> ComputeVitalityFragment(JsonObject document, VitalityDoc vitality)
    {
        var fragment = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
        foreach (var (_, classNode) in (JsonObject)document["classes"]!)
        {
            foreach (var memberNode in (JsonArray)((JsonObject)classNode!)["members"]!)
            {
                ApplyHealthBand(fragment, (string)memberNode!, vitality.HpPosition);
            }
        }

        return fragment;
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
    private static string BuildPromise(RosterDoc roster, CrowdDoc crowd, VitalityDoc vitality, JsonObject bossAbsolute)
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

        return $"{bossLine} {dreadLine} {minibossLine} Crowds: {crowd.Label.ToLowerInvariant()}. "
            + $"Toughness: {vitality.Label.ToLowerInvariant()}.";
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
