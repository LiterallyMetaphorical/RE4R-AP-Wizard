using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text.Json.Nodes;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Infrastructure;
using RE4R.AP.Launcher.Models;

namespace RE4R.AP.Launcher.ViewModels;

/// <summary>
/// The BioRand options screen: mode cards (presets) plus BioRand's own seven tabs, rendered from
/// the generated catalog.
///
/// Modes 1-3 are PRESETS. Tweaking any option flips the selection to a fourth, pseudo "Custom"
/// card, so a mode card can never silently lie about what will be generated. Picking a real mode
/// again re-applies its preset.
/// </summary>
public sealed class BioRandOptionsViewModel : ObservableObject
{
    private const string SelectModeKey = "select";
    private const string CustomModeKey = "custom";

    private readonly Dictionary<string, BioRandOptionItemViewModel> _itemsByKey =
        new(StringComparer.Ordinal);
    private readonly HashSet<string> _enemyOptionKeys = new(StringComparer.Ordinal);

    private LaunchModeOption? _selectedMode;
    private EnemyConfigurationPreset _selectedEnemyPreset = EnemyConfigurationPresets.Custom;
    // Dial state. When the combination is one of the five named pairs the
    // picker shows that preset; off-ladder combos keep the picker on Custom
    // and this holds the synthesized preset (its promise line included).
    private EnemyCrowdPoint? _selectedCrowdPoint;
    private EnemyRosterStep? _selectedRosterStep;
    private EnemyVitalityPoint? _selectedVitalityPoint;
    private EnemyConfigurationPreset? _activeDialPreset;
    private bool _isSyncingDials;
    private bool _gearScattered;
    // The Méndez ratios as they stood when the exclusion toggle last went on,
    // so unchecking restores the player's own numbers. Session-scoped.
    private Dictionary<string, double>? _mendezValuesBeforeExclusion;
    private bool _showAdvanced;
    private bool _isApplyingPreset;
    private bool _isPinnedToPreviousPatch;
    private bool _isUnlockedForChange;
    private bool _randomEventsForced;
    private bool _merchantOwnedByAp;
    private bool? _weaponStatsFromYaml;
    private string _pinnedNotice = string.Empty;
    private string _modeStatusText = "Choose a launch mode to continue.";

    public BioRandOptionsViewModel()
    {
        BuildPages();
        ApplyAdvancedFilter();
        ApplyPreset(BioRandOptionCatalog.ModeApOnly);
    }

    public ObservableCollection<LaunchModeOption> AvailableModes { get; } = new();

    public IReadOnlyList<EnemyConfigurationPreset> EnemyPresets => EnemyConfigurationPresets.All;

    public EnemyConfigurationPreset SelectedEnemyPreset
    {
        get => _selectedEnemyPreset;
        set
        {
            if (!SetProperty(ref _selectedEnemyPreset, value))
            {
                return;
            }

            if (value.Key == EnemyConfigurationPresets.Custom.Key)
            {
                if (!_isSyncingDials)
                {
                    _activeDialPreset = null;
                    SyncDialsFrom(null, null, null);
                }

                OnPropertyChanged(nameof(EnemyPresetDescription));
                return;
            }

            _activeDialPreset = null;
            SyncDialsFrom(value.CrowdKey, value.RosterKey, value.VitalityKey);
            ApplyEnemyPreset(value);
        }
    }

    public string EnemyPresetDescription => _activeDialPreset is { } dialed
        ? $"{dialed.DisplayName}. {dialed.Description}"
        : $"{SelectedEnemyPreset.Intensity} intensity. {SelectedEnemyPreset.Description}";

    public IReadOnlyList<EnemyCrowdPoint> CrowdPoints => EnemyConfigurationPresets.CrowdPoints;

    public IReadOnlyList<EnemyRosterStep> RosterSteps => EnemyConfigurationPresets.RosterSteps;

    public IReadOnlyList<EnemyVitalityPoint> VitalityPoints => EnemyConfigurationPresets.VitalityPoints;

    /// <summary>Vitality dial (how tough each enemy is). Null while hand-tweaked values make the mix Custom.</summary>
    public EnemyVitalityPoint? SelectedVitalityPoint
    {
        get => _selectedVitalityPoint;
        set
        {
            if (SetProperty(ref _selectedVitalityPoint, value) && !_isSyncingDials)
            {
                ApplyDialCombination();
            }
        }
    }

    /// <summary>Crowd dial (how busy fights are). Null while hand-tweaked values make the mix Custom.</summary>
    public EnemyCrowdPoint? SelectedCrowdPoint
    {
        get => _selectedCrowdPoint;
        set
        {
            if (SetProperty(ref _selectedCrowdPoint, value) && !_isSyncingDials)
            {
                ApplyDialCombination();
            }

            OnPropertyChanged(nameof(ShowScatterIntensityWarning));
        }
    }

    /// <summary>Roster dial (how scary the mix is). Null while hand-tweaked values make the mix Custom.</summary>
    public EnemyRosterStep? SelectedRosterStep
    {
        get => _selectedRosterStep;
        set
        {
            if (SetProperty(ref _selectedRosterStep, value) && !_isSyncingDials)
            {
                ApplyDialCombination();
            }

            OnPropertyChanged(nameof(ShowScatterIntensityWarning));
        }
    }

    /// <summary>
    /// Set by the shell alongside <see cref="MerchantOwnedByAp"/>: true when the player's
    /// settings scatter the merchant's gear into the multiworld (D10).
    /// </summary>
    public bool GearScattered
    {
        get => _gearScattered;
        set
        {
            if (SetProperty(ref _gearScattered, value))
            {
                OnPropertyChanged(nameof(ShowScatterIntensityWarning));
            }
        }
    }

    /// <summary>
    /// Scattered gear thins the early arsenal while heavy Crowd/Roster settings raise what the
    /// player must answer; warn when both are on the table (ENEMY_CLASS_DESIGN.md rider).
    /// </summary>
    public bool ShowScatterIntensityWarning =>
        _gearScattered
        && (IndexOfOrMinusOne(EnemyConfigurationPresets.CrowdPoints, _selectedCrowdPoint) >= 3
            || IndexOfOrMinusOne(EnemyConfigurationPresets.RosterSteps, _selectedRosterStep) >= 3);

    public string ScatterIntensityWarning =>
        "Merchant gear is scattered into the multiworld, so your arsenal grows as deliveries "
        + "land, not on the game's schedule. At this intensity the roster can outpace your kit. "
        + "Consider Busy / Wild or below, or turn the gear shuffle off in your settings file.";

    private static int IndexOfOrMinusOne<T>(IReadOnlyList<T> list, T? item) where T : class
    {
        if (item == null)
        {
            return -1;
        }

        for (var i = 0; i < list.Count; i++)
        {
            if (ReferenceEquals(list[i], item))
            {
                return i;
            }
        }

        return -1;
    }

    private void SyncDialsFrom(string? crowdKey, string? rosterKey, string? vitalityKey)
    {
        _isSyncingDials = true;
        try
        {
            SelectedCrowdPoint = crowdKey is null
                ? null
                : EnemyConfigurationPresets.CrowdPoints.FirstOrDefault(c => c.Key == crowdKey);
            SelectedRosterStep = rosterKey is null
                ? null
                : EnemyConfigurationPresets.RosterSteps.FirstOrDefault(r => r.Key == rosterKey);
            SelectedVitalityPoint = vitalityKey is null
                ? null
                : EnemyConfigurationPresets.VitalityPoints.FirstOrDefault(v => v.Key == vitalityKey);
        }
        finally
        {
            _isSyncingDials = false;
        }
    }

    private void ApplyDialCombination()
    {
        if (_selectedCrowdPoint is not { } crowd
            || _selectedRosterStep is not { } roster
            || _selectedVitalityPoint is not { } vitality)
        {
            return;
        }

        var combination = EnemyConfigurationPresets.BuildCombination(crowd.Key, roster.Key, vitality.Key);
        if (EnemyConfigurationPresets.FindPair(crowd.Key, roster.Key, vitality.Key) is { } pair)
        {
            _activeDialPreset = null;
            SelectedEnemyPreset = pair;
            return;
        }

        // Off-ladder mix: the picker reads Custom (the combination is not in
        // its list), the description carries the synthesized promise line.
        _activeDialPreset = combination;
        _isSyncingDials = true;
        try
        {
            SelectedEnemyPreset = EnemyConfigurationPresets.Custom;
        }
        finally
        {
            _isSyncingDials = false;
        }

        ApplyEnemyPreset(combination);
        OnPropertyChanged(nameof(EnemyPresetDescription));
    }

    /// <summary>Removes both Méndez classes from BioRand's random-enemy probability table.</summary>
    public bool ExcludeDifficultMendezEncounters
    {
        get => EnemyConfigurationPresets.MendezPoolKeys.All(key =>
            _itemsByKey.TryGetValue(key, out var item) && Math.Abs(item.NumberValue) < .0001d);
        set
        {
            if (value && !ExcludeDifficultMendezEncounters)
            {
                // Remember what the player actually had: unchecking must give
                // their numbers back, not the preset/mode defaults, or a
                // custom ratio silently dies the first time they toggle this.
                _mendezValuesBeforeExclusion = ReadCurrentMendezPoolValues();
            }

            var restored = _mendezValuesBeforeExclusion;
            var values = value
                ? EnemyConfigurationPresets.MendezPoolKeys.ToDictionary(key => key, _ => 0d, StringComparer.Ordinal)
                : restored is not null && restored.Values.Any(number => Math.Abs(number) >= .0001d)
                    ? restored
                    : GetEnabledMendezPoolValues();
            if (!value)
            {
                _mendezValuesBeforeExclusion = null;
            }

            var changed = false;
            foreach (var (key, number) in values)
            {
                if (_itemsByKey.TryGetValue(key, out var item) && Math.Abs(item.NumberValue - number) >= .0001d)
                {
                    item.LoadValue(JsonValue.Create(number));
                    changed = true;
                }
            }

            if (changed)
            {
                MarkEnemyPresetCustom();
                MarkModeCustom();
                OnPropertyChanged(nameof(ExcludeDifficultMendezEncounters));
            }
        }
    }

    private Dictionary<string, double> ReadCurrentMendezPoolValues()
    {
        return EnemyConfigurationPresets.MendezPoolKeys.ToDictionary(
            key => key,
            key => _itemsByKey.TryGetValue(key, out var item) ? item.NumberValue : 0d,
            StringComparer.Ordinal);
    }

    /// <summary>Set by the shell: opts in to changing a config pinned to a previous patch.</summary>
    public System.Windows.Input.ICommand? UnlockCommand { get; set; }

    /// <summary>The seven BioRand tabs.</summary>
    public ObservableCollection<BioRandOptionPageViewModel> Pages { get; } = new();

    /// <summary>The Custom card, revealed only once the player tweaks something.</summary>
    public LaunchModeOption CustomMode { get; } = new()
    {
        Key = CustomModeKey,
        DisplayName = "Custom",
        Description = "Your own mix. Starts from whichever mode you last picked, with your changes on top.",
        IsAvailable = true,
    };

    public LaunchModeOption? SelectedMode
    {
        get => _selectedMode;
        set
        {
            if (!SetProperty(ref _selectedMode, value))
            {
                return;
            }

            // Selecting a real mode re-applies its preset. Selecting Custom does NOT reset values -
            // Custom IS the current values.
            var mode = ModeNumberOf(value?.Key);
            if (mode is >= BioRandOptionCatalog.ModeApOnly and <= BioRandOptionCatalog.ModeFullItemEnemy)
            {
                ApplyPreset(mode);
            }

            UpdateModeState();
        }
    }

    /// <summary>
    /// Mirrors BioRand's own "Show Advanced" toggle. Only 3 of the 419 options carry BioRand's
    /// advanced flag - like BioRand, every other option (including the big ratio matrices) is
    /// visible by default.
    /// </summary>
    public bool ShowAdvanced
    {
        get => _showAdvanced;
        set
        {
            if (SetProperty(ref _showAdvanced, value))
            {
                ApplyAdvancedFilter();
            }
        }
    }

    private void ApplyAdvancedFilter()
    {
        foreach (var item in _itemsByKey.Values)
        {
            item.IsVisible = !item.IsAdvanced || _showAdvanced;
        }
    }

    public string ModeStatusText
    {
        get => _modeStatusText;
        set => SetProperty(ref _modeStatusText, value);
    }

    /// <summary>
    /// True when this room was already patched, so the recorded options are being shown and the
    /// patch will replay them. Without this the screen would silently lie: the workflow replays the
    /// recorded options and discards whatever the player picks here.
    /// </summary>
    public bool IsPinnedToPreviousPatch
    {
        get => _isPinnedToPreviousPatch;
        private set
        {
            if (SetProperty(ref _isPinnedToPreviousPatch, value))
            {
                OnPropertyChanged(nameof(IsLocked));
                OnPropertyChanged(nameof(AreOptionsEditable));
            }
        }
    }

    /// <summary>Set once the player opts in to changing a pinned config (they were warned first).</summary>
    public bool IsUnlockedForChange
    {
        get => _isUnlockedForChange;
        set
        {
            if (SetProperty(ref _isUnlockedForChange, value))
            {
                OnPropertyChanged(nameof(IsLocked));
                OnPropertyChanged(nameof(AreOptionsEditable));
            }
        }
    }

    public bool IsLocked => IsPinnedToPreviousPatch && !IsUnlockedForChange;

    public bool AreOptionsEditable => !IsLocked;

    public string PinnedNotice
    {
        get => _pinnedNotice;
        private set => SetProperty(ref _pinnedNotice, value);
    }

    /// <summary>
    /// Show the options recorded at the first patch, locked. Called when the launcher already has an
    /// open session record for the room the player is about to (re-)patch.
    /// </summary>
    public void PinToPreviousPatch(BioRandOptions recorded, string modeName)
    {
        Apply(recorded);
        IsUnlockedForChange = false;
        IsPinnedToPreviousPatch = true;
        PinnedNotice =
            $"This multiworld was already patched using {modeName}. Re-patching replays those exact settings, " +
            "so your world is rebuilt identically. Choose \"Change Options\" to pick different ones.";
    }

    /// <summary>Back to a normal, editable first patch.</summary>
    public void ClearPin()
    {
        IsPinnedToPreviousPatch = false;
        IsUnlockedForChange = false;
        PinnedNotice = string.Empty;
    }

    public bool HasSelectedMode => !string.IsNullOrWhiteSpace(SelectedMode?.Key)
        && !string.Equals(SelectedMode?.Key, SelectModeKey, StringComparison.Ordinal);

    public bool IsSelectedModeAvailable => SelectedMode?.IsAvailable == true;

    public bool IsOptionsVisible => HasSelectedMode && IsSelectedModeAvailable;

    public bool IsCustomSelected => string.Equals(SelectedMode?.Key, CustomModeKey, StringComparison.Ordinal);

    /// <summary>The preset Custom is built on (or the selected preset itself).</summary>
    public int BaseModeNumber { get; private set; } = BioRandOptionCatalog.ModeApOnly;

    public void Apply(BioRandOptions options)
    {
        var normalized = BioRandOptions.Sanitize(options);
        BaseModeNumber = normalized.EffectiveBaseMode;

        _isApplyingPreset = true;
        try
        {
            foreach (var pair in normalized.Values)
            {
                if (_itemsByKey.TryGetValue(pair.Key, out var item))
                {
                    item.LoadValue(pair.Value);
                }
            }

            var key = normalized.IsCustom ? CustomModeKey : ModeKeyOf(normalized.Mode);
            var mode = normalized.IsCustom
                ? CustomMode
                : AvailableModes.FirstOrDefault(m => string.Equals(m.Key, key, StringComparison.Ordinal));

            if (normalized.IsCustom)
            {
                EnsureCustomModeVisible();
            }

            // Assign the backing field: the setter would re-apply a preset and discard the values
            // we just loaded.
            _selectedMode = mode;
            OnPropertyChanged(nameof(SelectedMode));
        }
        finally
        {
            _isApplyingPreset = false;
        }

        // Same reason as ApplyPreset: a recorded config writes both keys, so
        // re-assert the forcing over it rather than showing a re-patch the
        // stale values its own manifest is about to override.
        ApplyRandomEventsForcing();

        UpdateEnemyPresetSelection();

        UpdateModeState();
    }

    public BioRandOptions Build()
    {
        var options = new BioRandOptions
        {
            Mode = IsCustomSelected ? BioRandOptionCatalog.ModeCustom : ModeNumberOf(SelectedMode?.Key),
            BaseMode = BaseModeNumber,
            Values = new Dictionary<string, JsonNode?>(StringComparer.Ordinal),
        };

        foreach (var item in _itemsByKey.Values)
        {
            options.Values[item.Key] = item.ToJsonNode();
        }

        return options;
    }

    // BioRand ships the Enemies page as ten groups, three of them with no
    // title at all - including the 36 drop-ratio sliders. Keyed on the group's
    // first option, which is stabler than an index and readable in a diff.
    // Titles fill the blanks; blurbs are only where the label alone leaves a
    // real question.
    private static readonly Dictionary<string, (string Title, string Blurb)> EnemyGroupHeadings =
        new(StringComparer.Ordinal)
        {
            ["random-enemies"] = ("Placement",
                "Whether BioRand re-rolls who appears where, and how many spawns it adds on top of the originals - including in areas that were quiet and in boss arenas."),
            ["enemy-multiplier"] = ("Crowd size and variety",
                "Multiplier duplicates the enemies a fight already has. Variety and pack size decide how many different types can share an area."),
            ["enemy-waves-probability"] = ("Waves",
                "Some fights send follow-up groups once the first is down."),
            ["enemy-scale-probability"] = ("Size",
                "Chance an enemy spawns unusually large or small."),
            ["balanced-enemies"] = ("Safety rails",
                "Keep these on for a first run or permadeath. They hold the nastiest types out of the spots that punish them most."),
            ["enemy-strong-mini-boss"] = ("Individual behaviour", ""),
            ["enemy-ratio-villager"] = ("Which enemies appear",
                "Relative weight per type. Higher means it turns up more often; zero takes it out of the pool entirely."),
            ["parasite-ratio-none"] = ("Parasites",
                "Which Plaga bursts out when you stagger or finish a host. None is the weight for no parasite at all."),
            ["random-enemy-drops"] = ("Drops",
                "Whether enemies drop randomized loot, and how much."),
            ["enemy-drop-ratio-none"] = ("What they drop",
                "Relative weight per item. These are shares of the drop table, not percentages, so raising one lowers everything else."),
            ["enemy-drop-valuable-weapon"] = ("Valuable drops",
                "Chance an enemy carries something worth more than ammo."),
        };
    private void BuildPages()
    {
        foreach (var page in BioRandOptionCatalog.Pages)
        {
            var pageVm = new BioRandOptionPageViewModel { Title = page.Title };
            foreach (var group in page.Groups)
            {
                var firstKey = group.Items.Count > 0 ? group.Items[0].Key : string.Empty;
                var heading = pageVm.IsEnemiesPage && EnemyGroupHeadings.TryGetValue(firstKey, out var found)
                    ? found
                    : (Title: group.Title, Blurb: string.Empty);
                var groupVm = new BioRandOptionGroupViewModel
                {
                    Title = string.IsNullOrWhiteSpace(group.Title) ? heading.Title : group.Title,
                    Description = heading.Blurb,
                };
                foreach (var definition in group.Items)
                {
                    var item = new BioRandOptionItemViewModel(definition);
                    item.ValueChangedByUser += OnOptionChangedByUser;
                    _itemsByKey[definition.Key] = item;
                    if (pageVm.IsEnemiesPage)
                    {
                        _enemyOptionKeys.Add(definition.Key);
                    }

                    // Random Enemies is promoted to the headline checkbox of
                    // the Enemies tab (both UIs), so it does not render as an
                    // ordinary row. It stays registered: presets,
                    // serialization and the Random Events forcing all address
                    // it through _itemsByKey.
                    if (string.Equals(definition.Key, BioRandOptionCatalog.RandomEnemiesKey, StringComparison.Ordinal))
                    {
                        RandomEnemiesOption = item;
                        item.PropertyChanged += OnRandomEnemiesOptionPropertyChanged;
                        continue;
                    }

                    groupVm.Options.Add(item);
                }

                pageVm.Groups.Add(groupVm);
            }

            Pages.Add(pageVm);
        }

        // Preset ownership extends past the Enemies page (the Health page's
        // enemy band rows ride the roster's HP position curve), so the
        // flip-to-Custom set derives from what a preset actually pins.
        foreach (var key in EnemyConfigurationPresets.Named[0].Values.Keys)
        {
            _enemyOptionKeys.Add(key);
        }

        AddRandomEventsNote();
        SyncEnemyPageBodyVisibility();
    }

    /// <summary>
    /// The promoted Random Enemies switch. The whole enemy configuration
    /// block (preset picker, Méndez exclusion, individual rows) only shows
    /// while it is on; off means enemies stay vanilla.
    /// </summary>
    public BioRandOptionItemViewModel? RandomEnemiesOption { get; private set; }

    public bool IsEnemyConfigurationVisible => RandomEnemiesOption?.BoolValue ?? true;

    private void OnRandomEnemiesOptionPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!string.Equals(e.PropertyName, nameof(BioRandOptionItemViewModel.BoolValue), StringComparison.Ordinal))
        {
            return;
        }

        OnPropertyChanged(nameof(IsEnemyConfigurationVisible));
        SyncEnemyPageBodyVisibility();
    }

    private void SyncEnemyPageBodyVisibility()
    {
        var enemiesPage = Pages.FirstOrDefault(page => page.IsEnemiesPage);
        if (enemiesPage is not null)
        {
            enemiesPage.IsBodyVisible = IsEnemyConfigurationVisible;
        }
    }

    /// <summary>
    /// Random Events is a BioRand original that Archipelago now authors: the
    /// multiworld picks the event set at generation time so the logic can
    /// react to it, which moved the choice into the player YAML. Rather than
    /// deleting the option from this screen silently, leave a read-only row
    /// where it used to live saying where it went. Display only: the row has
    /// no key in _itemsByKey, so it can never reach the BioRand config
    /// (ManifestBuilder forces the real key from slot_data).
    /// </summary>
    private void AddRandomEventsNote()
    {
        var generalGroup = Pages.FirstOrDefault(p => string.Equals(p.Title, "General", StringComparison.Ordinal))
            ?.Groups.FirstOrDefault();
        if (generalGroup is null)
        {
            return;
        }

        generalGroup.Options.Add(new BioRandOptionItemViewModel(new BioRandOptionDefinition
        {
            Key = "note-random-events",
            Label = "Random Events (set in your YAML)",
            Description =
                "A BioRand original, adapted for Archipelago: the multiworld now picks the "
                + "event set itself when it generates, so the logic can react to what the "
                + "events change. Turn it on with the experimental Random Events option in "
                + "your player YAML; whatever your room rolled is applied automatically "
                + "when you patch. It cannot run without item and enemy randomization, so "
                + "turning it on turns those on too, whichever mode you pick here.",
            Type = "note",
        }));
    }

    private void ApplyPreset(int mode)
    {
        BaseModeNumber = mode;
        var defaults = BioRandOptionCatalog.ResolveDefaults(mode);

        _isApplyingPreset = true;
        try
        {
            foreach (var pair in defaults)
            {
                if (_itemsByKey.TryGetValue(pair.Key, out var item))
                {
                    item.LoadValue(pair.Value);
                }
            }
        }
        finally
        {
            _isApplyingPreset = false;
        }

        // A preset writes every catalog key, including the two Random Events
        // overrides, so re-assert them or picking a card silently un-forces
        // what the patch is going to force anyway.
        ApplyRandomEventsForcing();
        UpdateEnemyPresetSelection();
    }

    /// <summary>
    /// Whether this session's Random Events roll is on. BioRand's EventModifier throws without
    /// BOTH random-items and random-enemies, so ManifestBuilder turns them on at patch time no
    /// matter which preset was picked. Until this landed, that override was invisible: pick "Full
    /// BioRand Item Randomization" (no enemy randomization), get randomized enemies, with the
    /// screen still showing Random Enemies off (Cam, live 2026-08-07).
    ///
    /// Read from the player's own settings draft, which is what the launcher knows at this point -
    /// the room's authoritative answer does not arrive until the scout, several steps later. It is
    /// therefore a strong hint, not a guarantee: the patch screen states what actually happened.
    /// </summary>
    public bool RandomEventsForced
    {
        get => _randomEventsForced;
        set
        {
            if (SetProperty(ref _randomEventsForced, value))
            {
                OnPropertyChanged(nameof(HasRandomEventsNotice));
                ApplyRandomEventsForcing();
                UpdateEnemyPresetSelection();
            }
        }
    }

    public bool HasRandomEventsNotice => _randomEventsForced;

    public string RandomEventsNotice =>
        "Your settings have Random Events on. It cannot run without item and enemy randomization, "
        + "so both are turned on when you patch, whichever mode you pick here.";

    private void ApplyRandomEventsForcing()
    {
        const string reason = "On because your Random Events setting needs it.";
        foreach (var key in new[] { BioRandOptionCatalog.RandomItemsKey, BioRandOptionCatalog.RandomEnemiesKey })
        {
            if (!_itemsByKey.TryGetValue(key, out var item))
            {
                continue;
            }

            if (_randomEventsForced)
            {
                // Suppressed: this is not the player tweaking the preset, so it
                // must not flip the mode card to Custom.
                item.LoadValue(System.Text.Json.Nodes.JsonValue.Create(true));
                item.IsEnabled = false;
                item.ForcedNotice = reason;
            }
            else
            {
                item.IsEnabled = true;
                item.ForcedNotice = string.Empty;
            }
        }

        ApplyMerchantForcing();
        ApplyWeaponStatsForcing();
    }

    /// <summary>
    /// The YAML's Random Weapon Stats choice, when the player's settings
    /// carry one. Null leaves BioRand's own switch player-controlled (drafts
    /// and rooms from before the option existed). Draft-sourced hint like
    /// the others; the manifest enforces the room's answer either way.
    /// </summary>
    public bool? WeaponStatsFromYaml
    {
        get => _weaponStatsFromYaml;
        set
        {
            if (SetProperty(ref _weaponStatsFromYaml, value))
            {
                ApplyWeaponStatsForcing();
            }
        }
    }

    private void ApplyWeaponStatsForcing()
    {
        if (!_itemsByKey.TryGetValue(BioRandOptionCatalog.RandomWeaponStatsKey, out var item))
        {
            return;
        }

        if (_weaponStatsFromYaml is bool yamlChoice)
        {
            // The multiworld holds the weapons, so their character rides
            // with them: the YAML decides once, every patch agrees.
            item.LoadValue(System.Text.Json.Nodes.JsonValue.Create(yamlChoice));
            item.IsEnabled = false;
            item.ForcedNotice = yamlChoice
                ? "On because your settings file says so - Random Weapon Stats rides with the multiworld's weapons."
                : "Off because your settings file says so - Random Weapon Stats rides with the multiworld's weapons.";
        }
        else
        {
            item.IsEnabled = true;
            item.ForcedNotice = string.Empty;
        }
    }

    /// <summary>
    /// True when the player's own settings give the multiworld the merchant
    /// (shop checks or scattered gear). Same draft-sourced hint as
    /// <see cref="RandomEventsForced"/>: the room's authoritative answer
    /// arrives at the scout, and the manifest enforces it either way.
    /// </summary>
    public bool MerchantOwnedByAp
    {
        get => _merchantOwnedByAp;
        set
        {
            if (SetProperty(ref _merchantOwnedByAp, value))
            {
                ApplyMerchantForcing();
            }
        }
    }

    private void ApplyMerchantForcing()
    {
        // Two owners cannot stock one shop: BioRand's merchant reroll would
        // put weapons back on a shelf the multiworld just took over (its
        // added arsenal is not pool-excludable) and reprice the check rows
        // whose price IS their classification. The whole reroll suite -
        // stock, prices and the per-chapter restock schedule - lives behind
        // random-merchant in the fork, so it is forced off and the restock
        // sliders grey out as the inert controls they become.
        const string reason =
            "Off because the multiworld runs this room's merchant (shop checks or scattered gear).";
        foreach (var (key, item) in _itemsByKey)
        {
            var isHeadline = string.Equals(key, BioRandOptionCatalog.RandomMerchantKey, StringComparison.Ordinal)
                || string.Equals(key, BioRandOptionCatalog.RandomMerchantPricesKey, StringComparison.Ordinal);
            var isStockDial = key.StartsWith(BioRandOptionCatalog.MerchantStockKeyPrefix, StringComparison.Ordinal);
            if (!isHeadline && !isStockDial)
            {
                continue;
            }

            if (_merchantOwnedByAp)
            {
                if (isHeadline)
                {
                    item.LoadValue(System.Text.Json.Nodes.JsonValue.Create(false));
                    item.ForcedNotice = reason;
                }

                item.IsEnabled = false;
            }
            else
            {
                item.IsEnabled = true;
                if (isHeadline)
                {
                    item.ForcedNotice = string.Empty;
                }
            }
        }
    }

    /// <summary>Any player tweak means the config is no longer the preset - so say so.</summary>
    private void OnOptionChangedByUser(BioRandOptionItemViewModel item)
    {
        if (_isApplyingPreset)
        {
            return;
        }

        if (!IsCustomSelected)
        {
            EnsureCustomModeVisible();
            _selectedMode = CustomMode;
            OnPropertyChanged(nameof(SelectedMode));
            UpdateModeState();
        }

        if (string.Equals(item.Key, "allow-bonus-items", StringComparison.Ordinal) && item.BoolValue)
        {
            ConfirmBonusWeaponsOrRevert(item);
        }
        if (_enemyOptionKeys.Contains(item.Key))
        {
            MarkEnemyPresetCustom();
        }

        // Ticking Random Enemies on from a bare Custom starts from the
        // mildest named mix, so the picker names a real configuration
        // instead of labelling untouched stock values Custom.
        if (string.Equals(item.Key, BioRandOptionCatalog.RandomEnemiesKey, StringComparison.Ordinal)
            && item.BoolValue
            && ReferenceEquals(_selectedEnemyPreset, EnemyConfigurationPresets.Custom))
        {
            SelectedEnemyPreset = EnemyConfigurationPresets.Named[0]; // Gentle Remix
        }

        if (EnemyConfigurationPresets.MendezPoolKeys.Contains(item.Key, StringComparer.Ordinal))
        {
            OnPropertyChanged(nameof(ExcludeDifficultMendezEncounters));
        }
    }

    /// <summary>
    /// Set by the shell: confirms the bonus-weapons force-unlock when the
    /// player switches allow-bonus-items on. Returning false vetoes the switch.
    /// </summary>
    public Func<Task<bool>>? ConfirmBonusWeaponsUnlockAsync { get; set; }

    private async void ConfirmBonusWeaponsOrRevert(BioRandOptionItemViewModel item)
    {
        var confirm = ConfirmBonusWeaponsUnlockAsync;
        if (confirm == null)
        {
            return;
        }

        try
        {
            // Yield first: a modal opened inside a checkbox's property-change
            // notification never shows (same dance as the Random Events
            // warning on the YAML screen).
            await Task.Yield();
            if (!await confirm())
            {
                item.LoadValue(System.Text.Json.Nodes.JsonValue.Create(false));
            }
        }
        catch
        {
            // Fail closed: no answer means no force-unlock.
            item.LoadValue(System.Text.Json.Nodes.JsonValue.Create(false));
        }
    }

    private void ApplyEnemyPreset(EnemyConfigurationPreset preset)
    {
        _isApplyingPreset = true;
        try
        {
            foreach (var (key, value) in preset.Values)
            {
                if (_itemsByKey.TryGetValue(key, out var item))
                {
                    item.LoadValue(value);
                }
            }
        }
        finally
        {
            _isApplyingPreset = false;
        }

        OnPropertyChanged(nameof(ExcludeDifficultMendezEncounters));
        MarkModeCustom();
        OnPropertyChanged(nameof(EnemyPresetDescription));
    }

    private Dictionary<string, double> GetEnabledMendezPoolValues()
    {
        var source = _selectedEnemyPreset.Key == EnemyConfigurationPresets.Custom.Key
            ? BioRandOptionCatalog.ResolveDefaults(BaseModeNumber)
            : _selectedEnemyPreset.Values;
        return EnemyConfigurationPresets.MendezPoolKeys.ToDictionary(
            key => key,
            key => source.TryGetValue(key, out var value)
                && value is JsonValue jsonValue
                && jsonValue.TryGetValue<double>(out var number)
                ? number
                : 0d,
            StringComparer.Ordinal);
    }

    private void UpdateEnemyPresetSelection()
    {
        var preset = EnemyConfigurationPresets.Named.FirstOrDefault(candidate => candidate.Values.All(pair =>
            _itemsByKey.TryGetValue(pair.Key, out var item) && ValuesMatch(item, pair.Value)))
            ?? EnemyConfigurationPresets.Custom;

        // Not a named pair: the values may still be an off-ladder dial mix.
        // Each axis detects independently against its own fragment, so a
        // hand-tweak on one axis blanks only what it actually touched away
        // from; all three found means the dials restore on reload.
        EnemyConfigurationPreset? dialed = null;
        string? crowdKey = preset.CrowdKey;
        string? rosterKey = preset.RosterKey;
        string? vitalityKey = preset.VitalityKey;
        if (ReferenceEquals(preset, EnemyConfigurationPresets.Custom))
        {
            JsonNode? Getter(string key) => _itemsByKey.TryGetValue(key, out var item) ? item.ToJsonNode() : null;
            var crowd = EnemyConfigurationPresets.DetectCrowdPoint(Getter);
            var roster = EnemyConfigurationPresets.DetectRosterStep(Getter);
            var vitality = EnemyConfigurationPresets.DetectVitalityPoint(Getter);
            crowdKey = crowd?.Key;
            rosterKey = roster?.Key;
            vitalityKey = vitality?.Key;
            if (crowd != null && roster != null && vitality != null)
            {
                dialed = EnemyConfigurationPresets.BuildCombination(crowd.Key, roster.Key, vitality.Key);
            }
        }

        _activeDialPreset = dialed;
        SyncDialsFrom(crowdKey, rosterKey, vitalityKey);

        if (!ReferenceEquals(_selectedEnemyPreset, preset))
        {
            _selectedEnemyPreset = preset;
            OnPropertyChanged(nameof(SelectedEnemyPreset));
        }

        OnPropertyChanged(nameof(EnemyPresetDescription));
    }

    private void MarkEnemyPresetCustom()
    {
        var dialsWereSet = _selectedCrowdPoint != null || _selectedRosterStep != null
            || _selectedVitalityPoint != null || _activeDialPreset != null;
        if (dialsWereSet)
        {
            _activeDialPreset = null;
            SyncDialsFrom(null, null, null);
        }

        if (ReferenceEquals(_selectedEnemyPreset, EnemyConfigurationPresets.Custom))
        {
            if (dialsWereSet)
            {
                OnPropertyChanged(nameof(EnemyPresetDescription));
            }

            return;
        }

        _selectedEnemyPreset = EnemyConfigurationPresets.Custom;
        OnPropertyChanged(nameof(SelectedEnemyPreset));
        OnPropertyChanged(nameof(EnemyPresetDescription));
    }

    private static bool ValuesMatch(BioRandOptionItemViewModel item, JsonNode? value) => value is JsonValue jsonValue
        && (item.IsSwitch
            ? jsonValue.TryGetValue<bool>(out var flag) && item.BoolValue == flag
            : jsonValue.TryGetValue<double>(out var number) && Math.Abs(item.NumberValue - number) < .0001d);

    private void MarkModeCustom()
    {
        if (!IsCustomSelected)
        {
            EnsureCustomModeVisible();
            _selectedMode = CustomMode;
            OnPropertyChanged(nameof(SelectedMode));
            UpdateModeState();
        }
    }

    private void EnsureCustomModeVisible()
    {
        if (!AvailableModes.Contains(CustomMode))
        {
            AvailableModes.Add(CustomMode);
        }
    }

    private static int ModeNumberOf(string? key) => key switch
    {
        "mode1" => BioRandOptionCatalog.ModeApOnly,
        "mode2" => BioRandOptionCatalog.ModeFullItem,
        "mode3" => BioRandOptionCatalog.ModeFullItemEnemy,
        CustomModeKey => BioRandOptionCatalog.ModeCustom,
        _ => BioRandOptionCatalog.ModeApOnly,
    };

    private static string ModeKeyOf(int mode) => mode switch
    {
        BioRandOptionCatalog.ModeFullItem => "mode2",
        BioRandOptionCatalog.ModeFullItemEnemy => "mode3",
        _ => "mode1",
    };

    private void UpdateModeState()
    {
        OnPropertyChanged(nameof(HasSelectedMode));
        OnPropertyChanged(nameof(IsSelectedModeAvailable));
        OnPropertyChanged(nameof(IsOptionsVisible));
        OnPropertyChanged(nameof(IsCustomSelected));

        ModeStatusText = SelectedMode?.Key switch
        {
            SelectModeKey or null => "Choose a launch mode to continue.",
            "mode1" => "The multiworld shuffles the fixed item pickups. Everything else - items, enemies, the merchant - stays vanilla.",
            "mode2" => "The multiworld shuffles the check items, and BioRand re-rolls every other world pickup. Enemies and the merchant stay vanilla.",
            "mode3" => "Everything in Full Item Randomization, plus randomized enemies, bosses and the merchant. Random Events is decided by your YAML, not this mode.",
            CustomModeKey => "Custom: your own mix of BioRand options. Your multiworld checks are shuffled and pinned no matter what you change here.",
            _ => "Choose a launch mode to continue.",
        };
    }
}
