using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// The player's BioRand choices: a launch mode plus the resolved value of every catalog option.
///
/// Modes 1-3 are PRESETS. The moment the player tweaks any option away from its preset value the
/// mode becomes <see cref="BioRandOptionCatalog.ModeCustom"/> - so a mode card can never silently
/// lie about what will actually be generated. <see cref="BaseMode"/> records which preset Custom
/// started from (used to fill in any key the stored values are missing).
///
/// Persisted in session records (re-patch pinning replays these verbatim, so the same room rebuilds
/// the same world) and in launcher settings (last used).
///
/// Migration: records written before the catalog existed carry the old typed properties. Those are
/// unknown properties now, so System.Text.Json ignores them and the record lands on Mode=1 with an
/// empty <see cref="Values"/>, which falls back to the mode-1 preset. That is correct - mode 1 was
/// the only mode those records could have used.
/// </summary>
public sealed class BioRandOptions
{
    /// <summary>1 = AP items only, 2 = + item randomization, 3 = + enemies, 4 = Custom.</summary>
    [JsonPropertyName("mode")]
    public int Mode { get; set; } = BioRandOptionCatalog.ModeApOnly;

    /// <summary>Which preset a Custom config started from. Ignored when Mode is 1-3.</summary>
    [JsonPropertyName("base_mode")]
    public int BaseMode { get; set; } = BioRandOptionCatalog.ModeApOnly;

    /// <summary>
    /// Fully resolved catalog values (not deltas), so a later change to a preset can never
    /// retroactively alter a session that has already been patched.
    /// </summary>
    [JsonPropertyName("values")]
    public Dictionary<string, JsonNode?> Values { get; set; } = new(StringComparer.Ordinal);

    public bool IsCustom => Mode == BioRandOptionCatalog.ModeCustom;

    /// <summary>The preset whose defaults back this config (itself, unless Custom).</summary>
    public int EffectiveBaseMode => IsCustom
        ? Math.Clamp(BaseMode, BioRandOptionCatalog.ModeApOnly, BioRandOptionCatalog.ModeFullItemEnemy)
        : Math.Clamp(Mode, BioRandOptionCatalog.ModeApOnly, BioRandOptionCatalog.ModeFullItemEnemy);

    public static BioRandOptions CreateDefault() => ForMode(BioRandOptionCatalog.ModeApOnly);

    public static BioRandOptions ForMode(int mode)
    {
        var normalized = Math.Clamp(mode, BioRandOptionCatalog.ModeApOnly, BioRandOptionCatalog.ModeFullItemEnemy);
        return new BioRandOptions
        {
            Mode = normalized,
            BaseMode = normalized,
            Values = BioRandOptionCatalog.ResolveDefaults(normalized),
        };
    }

    public static BioRandOptions Sanitize(BioRandOptions? options)
    {
        if (options is null)
        {
            return CreateDefault();
        }

        var mode = Math.Clamp(options.Mode, BioRandOptionCatalog.ModeApOnly, BioRandOptionCatalog.ModeCustom);
        var baseMode = Math.Clamp(
            mode == BioRandOptionCatalog.ModeCustom ? options.BaseMode : mode,
            BioRandOptionCatalog.ModeApOnly,
            BioRandOptionCatalog.ModeFullItemEnemy);

        // Start from the preset so a partial (or legacy) value bag can never leave a key unset - an
        // unset key falls through to BioRand's own default, which is exactly how the mode-1 purity
        // violations (phantom merchants/enemies) got in.
        var resolved = BioRandOptionCatalog.ResolveDefaults(baseMode);
        if (options.Values is not null)
        {
            foreach (var pair in options.Values)
            {
                if (BioRandOptionCatalog.Find(pair.Key) is not null)
                {
                    resolved[pair.Key] = pair.Value?.DeepClone();
                }
            }
        }

        return new BioRandOptions { Mode = mode, BaseMode = baseMode, Values = resolved };
    }

    /// <summary>True when any value differs from <paramref name="mode"/>'s preset.</summary>
    public bool DiffersFromPreset(int mode)
    {
        var preset = BioRandOptionCatalog.ResolveDefaults(mode);
        foreach (var pair in preset)
        {
            var mine = Values.TryGetValue(pair.Key, out var value) ? value : null;
            if (!JsonNode.DeepEquals(mine, pair.Value))
            {
                return true;
            }
        }

        return false;
    }

    public bool GetBool(string key, bool fallback = false)
    {
        if (Values.TryGetValue(key, out var node) && node is JsonValue value && value.TryGetValue<bool>(out var result))
        {
            return result;
        }

        return fallback;
    }

    public double GetNumber(string key, double fallback = 0d)
    {
        if (Values.TryGetValue(key, out var node) && node is JsonValue value && value.TryGetValue<double>(out var result))
        {
            return result;
        }

        return fallback;
    }
}
