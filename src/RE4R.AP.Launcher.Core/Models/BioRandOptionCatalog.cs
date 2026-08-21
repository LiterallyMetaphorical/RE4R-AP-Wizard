using System.Text.Json;
using System.Text.Json.Nodes;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// Every BioRand option the launcher exposes, loaded from <c>assets/Data/biorand_options.json</c>
/// (GENERATED from BioRand's own Re4rRandomizerConfigurationDefinition - see the file's _comment).
///
/// AP SAFETY (verified in the fork 2026-07-13, see BIORAND_OPTIONS_DESIGN.md): item-generation
/// options CANNOT corrupt an AP check. AP placements are written by explicit manifest item id and
/// merged LAST (last-write-wins), so BioRand may re-roll the whole world and AP then overwrites its
/// 476 locations on top. The genuine AP-breakers are CONTENT/SCOPE removal, which is why
/// <see cref="ApLockedKeys"/> is forced after everything else and those keys are absent from the
/// catalog entirely.
/// </summary>
public static class BioRandOptionCatalog
{
    public const int ModeApOnly = 1;          // AP Item Randomization Only
    public const int ModeFullItem = 2;        // Full BioRand Item Randomization
    public const int ModeFullItemEnemy = 3;   // Full BioRand Item + Enemy Randomization

    /// <summary>
    /// Pseudo-mode: the player tweaked an option away from a preset. Not a preset itself - the
    /// stored values are the truth, and <see cref="BioRandOptions.BaseMode"/> records which preset
    /// it started from.
    /// </summary>
    public const int ModeCustom = 4;

    /// <summary>
    /// Forced by <c>ManifestBuilder</c> AFTER the preset and any user tweak, so nothing can smuggle
    /// in a scope change that removes or strands AP checks. These are deliberately NOT in the
    /// catalog, so they can never be rendered or edited.
    /// - campaign: BuildApPlacements THROWS if a manifest GUID's campaign != randomizer campaign.
    /// - start-chapter: starting at N makes every AP check in chapters 1..N-1 unreachable.
    /// - skip-ashley-section: deletes a whole segment, and any AP checks in it. (BioRand default TRUE!)
    /// - game-version: must match the setup harvest; not user-facing.
    /// - random-events: the multiworld authors the event set at generation time (the YAML option);
    ///   the roll arrives via slot_data and is pinned in as ap-forced-events. A local toggle here
    ///   would let a patch fire events the room's logic never modeled.
    /// </summary>
    public static readonly string[] ApLockedKeys =
    [
        "game-version",
        "campaign",
        "start-chapter",
        "skip-ashley-section",
        "ap-mode",
        "ap-placements",
        "random-events",
    ];

    public const string RandomItemsKey = "random-items";
    public const string RandomEnemiesKey = "random-enemies";
    public const string RandomEventsKey = "random-events";
    public const string RandomMerchantKey = "random-merchant";
    public const string RandomMerchantPricesKey = "random-merchant-prices";
    public const string RandomWeaponStatsKey = "random-weapon-stats";
    // The per-chapter restock schedule (~60 scale options). Its consumer is
    // the same modifier random-merchant gates, so it is inert while the
    // Archipelago merchant owns the shop.
    public const string MerchantStockKeyPrefix = "merchant-stock-";
    // The two starting-weapon class pickers. They choose the class of the
    // primary and secondary BioRand rolls into the opening case, and those
    // rolls do not happen at all once the settings file asks for a starting
    // arsenal - the arsenal count IS the weapon count then. Inert controls,
    // so they grey out.
    public const string StartingWeaponPrimaryKeyPrefix = "inventory-weapon-primary-";
    // The 38 per-boss HP dials and the switch that decides whether anything
    // reads them. EnemyModifier keeps the whole boss branch inside
    // "if (boss-random-health)", so with the switch off every one of those
    // dials is inert - which cost a live test on a Del Lago set to 1 HP that
    // never took damage differently (Cam, 2026-08-21).
    public const string BossRandomHealthKey = "boss-random-health";
    public const string BossHealthKeyPrefix = "boss-health-";
    public const string StartingWeaponSecondaryKeyPrefix = "inventory-weapon-secondary-";

    private const string CatalogFileName = "biorand_options.json";

    /// <summary>Overrides the assets/Data directory (used by test harnesses).</summary>
    public static string? AssetsDataDirectoryPathOverride { get; set; }

    private static readonly Lazy<BioRandOptionCatalogDocument> _document = new(Load, isThreadSafe: true);

    public static IReadOnlyList<BioRandOptionPage> Pages => _document.Value.Pages;

    private static readonly Lazy<IReadOnlyList<BioRandOptionDefinition>> _definitions = new(
        () => Pages.SelectMany(p => p.Groups).SelectMany(g => g.Items).ToList(),
        isThreadSafe: true);

    public static IReadOnlyList<BioRandOptionDefinition> Definitions => _definitions.Value;

    private static readonly Lazy<Dictionary<string, BioRandOptionDefinition>> _byKey = new(
        () => Definitions.ToDictionary(d => d.Key, StringComparer.Ordinal),
        isThreadSafe: true);

    public static BioRandOptionDefinition? Find(string key) =>
        _byKey.Value.TryGetValue(key, out var definition) ? definition : null;

    /// <summary>Every catalog key set to its default for <paramref name="mode"/>.</summary>
    public static Dictionary<string, JsonNode?> ResolveDefaults(int mode)
    {
        var values = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
        foreach (var definition in Definitions)
        {
            values[definition.Key] = definition.DefaultFor(mode);
        }

        return values;
    }

    public static bool GetBool(IReadOnlyDictionary<string, JsonNode?> values, string key) =>
        values.TryGetValue(key, out var node)
        && node is JsonValue value
        && value.TryGetValue<bool>(out var flag)
        && flag;

    private static BioRandOptionCatalogDocument Load()
    {
        var directory = AssetsDataDirectoryPathOverride
            ?? Path.Combine(AppContext.BaseDirectory, "assets", "Data");
        var path = Path.Combine(directory, CatalogFileName);

        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"The BioRand option catalog was not found at {path}. " +
                $"Copy {CatalogFileName} into assets/Data before launching.",
                path);
        }

        var document = JsonSerializer.Deserialize<BioRandOptionCatalogDocument>(File.ReadAllText(path))
            ?? throw new InvalidDataException($"{CatalogFileName} could not be parsed.");

        // An AP-locked key inside the catalog would be user-editable and could strand checks.
        var leaked = document.Pages
            .SelectMany(p => p.Groups)
            .SelectMany(g => g.Items)
            .Select(i => i.Key)
            .Intersect(ApLockedKeys, StringComparer.Ordinal)
            .ToList();
        if (leaked.Count > 0)
        {
            throw new InvalidDataException(
                $"{CatalogFileName} exposes AP-locked key(s) as editable options: {string.Join(", ", leaked)}. " +
                "These must be forced by ManifestBuilder, never rendered.");
        }

        return document;
    }
}
