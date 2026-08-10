using System.Collections.ObjectModel;
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

    private LaunchModeOption? _selectedMode;
    private bool _showAdvanced;
    private bool _isApplyingPreset;
    private bool _isPinnedToPreviousPatch;
    private bool _isUnlockedForChange;
    private bool _randomEventsForced;
    private string _pinnedNotice = string.Empty;
    private string _modeStatusText = "Choose a launch mode to continue.";

    public BioRandOptionsViewModel()
    {
        BuildPages();
        ApplyAdvancedFilter();
        ApplyPreset(BioRandOptionCatalog.ModeApOnly);
    }

    public ObservableCollection<LaunchModeOption> AvailableModes { get; } = new();

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

    private void BuildPages()
    {
        foreach (var page in BioRandOptionCatalog.Pages)
        {
            var pageVm = new BioRandOptionPageViewModel { Title = page.Title };
            foreach (var group in page.Groups)
            {
                var groupVm = new BioRandOptionGroupViewModel { Title = group.Title };
                foreach (var definition in group.Items)
                {
                    var item = new BioRandOptionItemViewModel(definition);
                    item.ValueChangedByUser += OnOptionChangedByUser;
                    _itemsByKey[definition.Key] = item;
                    groupVm.Options.Add(item);
                }

                pageVm.Groups.Add(groupVm);
            }

            Pages.Add(pageVm);
        }

        AddRandomEventsNote();
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
