using System.Text.Json.Nodes;
using RE4R.AP.Launcher.Core.Models;

// Resolve assets/Data by walking up from the build output, so the harness
// runs from any checkout location.
var assetsRoot = AppContext.BaseDirectory;
while (assetsRoot != null
    && !File.Exists(Path.Combine(assetsRoot, "assets", "Data", "biorand_options.json")))
{
    assetsRoot = Path.GetDirectoryName(assetsRoot);
}

BioRandOptionCatalog.AssetsDataDirectoryPathOverride = Path.Combine(
    assetsRoot ?? throw new InvalidOperationException("assets/Data not found above the harness"),
    "assets", "Data");

var pass = 0;
var fail = 0;

void Check(string name, bool condition)
{
    if (condition) { pass++; }
    else { fail++; Console.WriteLine($"FAIL {name}"); }
}

double Num(EnemyConfigurationPreset p, string key) =>
    p.Values.TryGetValue(key, out var n) && n is JsonValue v && v.TryGetValue<double>(out var d)
        ? d : double.NaN;

bool Flag(EnemyConfigurationPreset p, string key) =>
    p.Values.TryGetValue(key, out var n) && n is JsonValue v && v.TryGetValue<bool>(out var b) && b;

var named = EnemyConfigurationPresets.Named;
Check("five named pairs", named.Count == 5);
Check("All = Custom + 5", EnemyConfigurationPresets.All.Count == 6
    && ReferenceEquals(EnemyConfigurationPresets.All[0], EnemyConfigurationPresets.Custom));
Check("axes exposed 5x5x5", EnemyConfigurationPresets.CrowdPoints.Count == 5
    && EnemyConfigurationPresets.RosterSteps.Count == 5
    && EnemyConfigurationPresets.VitalityPoints.Count == 5);

var gentle = named[0];
var varied = named[1];
var wild = named[2];
var menacing = named[3];
var apex = named[4];

Check("gentle keys", gentle.Key == "gentle-remix" && gentle.CrowdKey == "sparse" && gentle.RosterKey == "familiar" && gentle.VitalityKey == "soft");

// Ratio derivation: catalog default x roster multiplier, boss rows absolute.
Check("gentle chainsaw .04", Math.Abs(Num(gentle, "enemy-ratio-chainsaw") - 0.04) < 1e-9);
Check("gentle garrador .02", Math.Abs(Num(gentle, "enemy-ratio-garrador") - 0.02) < 1e-9);
Check("gentle brute .08", Math.Abs(Num(gentle, "enemy-ratio-brute") - 0.08) < 1e-9);
Check("gentle zealot_red .03", Math.Abs(Num(gentle, "enemy-ratio-zealot_red") - 0.03) < 1e-9);
Check("gentle fodder untouched", Math.Abs(Num(gentle, "enemy-ratio-villager") - 0.5) < 1e-9);
Check("gentle dread zero", Num(gentle, "enemy-ratio-regenerador") == 0
    && Num(gentle, "enemy-ratio-iron_maiden") == 0);
Check("gentle boss zero", Num(gentle, "enemy-ratio-krauser_1") == 0
    && Num(gentle, "enemy-ratio-verdugo") == 0
    && Num(gentle, "enemy-ratio-mendez_chase") == 0);

Check("wild regen .01", Math.Abs(Num(wild, "enemy-ratio-regenerador") - 0.01) < 1e-9);
Check("wild iron maiden snaps 0", Num(wild, "enemy-ratio-iron_maiden") == 0);

Check("menacing krauser_1 .06", Math.Abs(Num(menacing, "enemy-ratio-krauser_1") - 0.06) < 1e-9);
Check("menacing mendez snow .08", Math.Abs(Num(menacing, "enemy-ratio-mendez_chase") - 0.08) < 1e-9);
Check("apex krauser_1 .12", Math.Abs(Num(apex, "enemy-ratio-krauser_1") - 0.12) < 1e-9);
Check("apex chainsaw .38", Math.Abs(Num(apex, "enemy-ratio-chainsaw") - 0.38) < 1e-9);
Check("apex regen .06", Math.Abs(Num(apex, "enemy-ratio-regenerador") - 0.06) < 1e-9);

// SW trio pinned zero at every step.
foreach (var p in named)
{
    Check($"{p.Key} trio zero",
        Num(p, "enemy-ratio-pesanta") == 0
        && Num(p, "enemy-ratio-u3") == 0
        && Num(p, "enemy-ratio-sadler_human") == 0);
}

// Crowd values survive verbatim.
Check("gentle crowd sparse", Math.Abs(Num(gentle, "extra-enemy-amount")) < 1e-9
    && Math.Abs(Num(gentle, "enemy-multiplier") - 1.0) < 1e-9);
Check("apex crowd overrun", Math.Abs(Num(apex, "extra-enemy-amount") - 0.6) < 1e-9
    && Math.Abs(Num(apex, "enemy-variety") - 35) < 1e-9
    && Math.Abs(Num(apex, "enemy-pack-max") - 4) < 1e-9);

// Rails ride roster.
Check("gentle rails on", Flag(gentle, "balanced-enemies") && Flag(gentle, "nice-mendez-hill"));
Check("menacing rails off", !Flag(menacing, "balanced-enemies") && !Flag(menacing, "nice-mendez-hill"));

// HP position narrows the band toward the floor.
Check("gentle chainsaw hp 4000..7850",
    Math.Abs(Num(gentle, "enemy-health-min-chainsaw") - 4000) < 1e-9
    && Math.Abs(Num(gentle, "enemy-health-max-chainsaw") - 7850) < 1e-9);
Check("apex chainsaw hp full band",
    Math.Abs(Num(apex, "enemy-health-max-chainsaw") - 15000) < 1e-9);
Check("health switches owned", Flag(gentle, "enemy-random-health")
    && Flag(gentle, "enemy-health-progressive-difficulty"));
Check("boss-fight hp NOT owned", !gentle.Values.ContainsKey("boss-random-health")
    && !gentle.Values.ContainsKey("boss-health-min-sadler"));
Check("mendez_chase has no hp rows", !gentle.Values.ContainsKey("enemy-health-max-mendez_chase"));

// Parasites ride roster.
Check("gentle parasites", Math.Abs(Num(gentle, "parasite-ratio-none") - 0.97) < 1e-9);
Check("apex parasites", Math.Abs(Num(apex, "parasite-ratio-none") - 0.8) < 1e-9);

// Generated promise lines.
Check("gentle promise", gentle.Description.Contains("No bosses.")
    && gentle.Description.Contains("No lab horrors.")
    && gentle.Description.Contains("Minibosses stay rare.")
    && gentle.Description.Contains("Crowds: sparse.")
    && gentle.Description.Contains("Toughness: soft."));
Check("menacing promise taste", menacing.Description.Contains("Bosses make a first appearance."));
Check("apex promise walk", apex.Description.Contains("Bosses walk the world.")
    && apex.Description.Contains("Lab horrors are loose."));

// Pair lookup + off-ladder combos.
Check("FindPair on-ladder", ReferenceEquals(EnemyConfigurationPresets.FindPair("sparse", "familiar", "soft"), gentle));
Check("FindPair off-ladder null", EnemyConfigurationPresets.FindPair("overrun", "familiar", "soft") == null);
var horde = EnemyConfigurationPresets.BuildCombination("overrun", "familiar", "soft");
Check("horde combo", horde.Key == "dials:overrun+familiar+soft"
    && Math.Abs(Num(horde, "extra-enemy-amount") - 0.6) < 1e-9
    && Math.Abs(Num(horde, "enemy-ratio-chainsaw") - 0.04) < 1e-9
    && Num(horde, "enemy-ratio-krauser_1") == 0);
var hunt = EnemyConfigurationPresets.BuildCombination("sparse", "apex", "full");
Check("hunt combo", Math.Abs(Num(hunt, "enemy-multiplier") - 1.0) < 1e-9
    && Math.Abs(Num(hunt, "enemy-ratio-chainsaw") - 0.38) < 1e-9);
Check("BuildCombination returns pair on-ladder",
    ReferenceEquals(EnemyConfigurationPresets.BuildCombination("busy", "wild", "sturdy"), named[2]));

// Gates.
var gates = EnemyConfigurationPresets.Gates;
var dreadGate = gates.FirstOrDefault(g => g.ClassKey == "dread");
Check("dread gate live", dreadGate is { Enabled: true, Type: "item", Item: "Biosensor Scope x1", ItemEngineId: 116004800 });
Check("dread gate members", dreadGate != null
    && dreadGate.Members.SequenceEqual(new[] { "regenerador", "iron_maiden", "super_iron_maiden" }));
Check("arsenal gates scaffolded off", gates.Any(g => g is { ClassKey: "miniboss", Enabled: false })
    && gates.Any(g => g is { ClassKey: "boss", Enabled: false }));

// Class lock: flags, membership exposure, and roster detection from values.
Check("classLock flags", EnemyConfigurationPresets.RosterSteps.Select(s => s.ClassLock)
    .SequenceEqual(new[] { true, true, false, false, false }));
Check("class members exposed", EnemyConfigurationPresets.ClassMembers["fodder"].Contains("colmillos")
    && EnemyConfigurationPresets.ClassMembers["ambient"].SequenceEqual(new[] { "cow", "pig" }));
Check("ambient exempt", EnemyConfigurationPresets.ClassLockExemptClasses.SequenceEqual(new[] { "ambient" }));
var detectGentle = EnemyConfigurationPresets.DetectRosterStep(key => gentle.Values.GetValueOrDefault(key));
Check("detect familiar from gentle", detectGentle is { Key: "familiar", ClassLock: true });
var detectApex = EnemyConfigurationPresets.DetectRosterStep(key => apex.Values.GetValueOrDefault(key));
Check("detect apex", detectApex is { Key: "apex", ClassLock: false });
var detectHorde = EnemyConfigurationPresets.DetectRosterStep(key => horde.Values.GetValueOrDefault(key));
Check("detect familiar from horde combo", detectHorde is { Key: "familiar", ClassLock: true });
var tweaked = new Dictionary<string, JsonNode?>(gentle.Values, StringComparer.Ordinal)
{
    ["enemy-ratio-chainsaw"] = JsonValue.Create(0.25),
};
Check("tweaked values detect nothing",
    EnemyConfigurationPresets.DetectRosterStep(key => tweaked.GetValueOrDefault(key)) == null);

// Vitality axis: unwelded HP, mixed combos, independent detection.
var tanky = EnemyConfigurationPresets.BuildCombination("sparse", "familiar", "full");
Check("tanky gentle: soft roster, full HP", Math.Abs(Num(tanky, "enemy-ratio-chainsaw") - 0.04) < 1e-9
    && Math.Abs(Num(tanky, "enemy-health-max-chainsaw") - 15000) < 1e-9);
var glass = EnemyConfigurationPresets.BuildCombination("sparse", "apex", "soft");
Check("glass apex: apex roster, floor HP", Math.Abs(Num(glass, "enemy-ratio-chainsaw") - 0.38) < 1e-9
    && Math.Abs(Num(glass, "enemy-health-max-chainsaw") - 7850) < 1e-9);
var detectVit = EnemyConfigurationPresets.DetectVitalityPoint(key => gentle.Values.GetValueOrDefault(key));
Check("detect soft from gentle", detectVit is { Key: "soft" });
var hpTweaked = new Dictionary<string, JsonNode?>(gentle.Values, StringComparer.Ordinal)
{
    ["enemy-health-max-chainsaw"] = JsonValue.Create(9999d),
};
Check("hp tweak blanks vitality only",
    EnemyConfigurationPresets.DetectVitalityPoint(key => hpTweaked.GetValueOrDefault(key)) == null
    && EnemyConfigurationPresets.DetectRosterStep(key => hpTweaked.GetValueOrDefault(key)) is { Key: "familiar" });
Check("detect crowd sparse", EnemyConfigurationPresets.DetectCrowdPoint(key => gentle.Values.GetValueOrDefault(key)) is { Key: "sparse" });

// Every named pair owns an identical key set (complete-state matching depends on it).
var keySet = new HashSet<string>(gentle.Values.Keys, StringComparer.Ordinal);
Check("uniform key ownership", named.All(p => keySet.SetEquals(p.Values.Keys)));
Check("mendez pool keys owned", EnemyConfigurationPresets.MendezPoolKeys.All(keySet.Contains));


// Vitality display + example numbers.
Check("dial records ToString", EnemyConfigurationPresets.CrowdPoints[0].ToString() == "Sparse"
    && EnemyConfigurationPresets.RosterSteps[0].ToString() == "Familiar"
    && EnemyConfigurationPresets.VitalityPoints[2].ToString() == "Sturdy");
var softText = EnemyConfigurationPresets.DescribeVitality("soft");
Check("vitality examples computed", softText.Contains("Villager 600 to 1,300")
    && softText.Contains("Chainsaw Man 4,000 to 7,850"));
Check("vitality examples full band", EnemyConfigurationPresets.DescribeVitality("full").Contains("Chainsaw Man 4,000 to 15,000"));

Console.WriteLine($"{pass} passed, {fail} failed");
return fail == 0 ? 0 : 1;
