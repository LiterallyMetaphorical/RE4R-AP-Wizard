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
    private string _pinnedNotice = string.Empty;
    private string _modeStatusText = "Choose a launch mode to continue.";
    private string _dependencyNotice = string.Empty;

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
    /// Explains an option we had to switch off for the player - currently only Random Events,
    /// which makes BioRand throw unless Random Items AND Random Enemies are both on. Never act
    /// silently.
    /// </summary>
    public string DependencyNotice
    {
        get => _dependencyNotice;
        set
        {
            if (SetProperty(ref _dependencyNotice, value))
            {
                OnPropertyChanged(nameof(HasDependencyNotice));
            }
        }
    }

    public bool HasDependencyNotice => !string.IsNullOrWhiteSpace(DependencyNotice);

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

        RefreshDependencies();
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

        RefreshDependencies();
    }

    /// <summary>Any player tweak means the config is no longer the preset - so say so.</summary>
    private void OnOptionChangedByUser(BioRandOptionItemViewModel item)
    {
        if (_isApplyingPreset)
        {
            return;
        }

        RefreshDependencies();

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

    /// <summary>
    /// Random Events makes BioRand THROW unless Random Items AND Random Enemies are both on. Switch
    /// it off and TELL the player rather than letting the patch fail (or acting silently).
    /// </summary>
    private void RefreshDependencies()
    {
        if (!_itemsByKey.TryGetValue(BioRandOptionCatalog.RandomEventsKey, out var events))
        {
            return;
        }

        var items = _itemsByKey.TryGetValue(BioRandOptionCatalog.RandomItemsKey, out var i) && i.BoolValue;
        var enemies = _itemsByKey.TryGetValue(BioRandOptionCatalog.RandomEnemiesKey, out var e) && e.BoolValue;
        var satisfied = items && enemies;

        events.IsEnabled = satisfied;

        if (!satisfied && events.BoolValue)
        {
            var previous = events.SuppressChangeNotifications;
            events.SuppressChangeNotifications = true;
            events.BoolValue = false;
            events.SuppressChangeNotifications = previous;

            DependencyNotice =
                "Random Events was switched off: it needs both Random Items and Random Enemies, " +
                "and BioRand cannot generate without them.";
            return;
        }

        if (satisfied)
        {
            DependencyNotice = string.Empty;
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
            "mode3" => "Everything in Full Item Randomization, plus randomized enemies, bosses, the merchant and random events.",
            CustomModeKey => "Custom: your own mix of BioRand options. Your multiworld checks are shuffled and pinned no matter what you change here.",
            _ => "Choose a launch mode to continue.",
        };
    }
}
