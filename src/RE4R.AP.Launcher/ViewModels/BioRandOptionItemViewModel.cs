using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json.Nodes;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

/// <summary>
/// One rendered BioRand option. Label, kind, range, per-mode default - all of it comes from
/// <see cref="BioRandOptionDefinition"/> (generated from BioRand's own schema), so the UI never
/// hard-codes an option.
/// </summary>
public sealed class BioRandOptionItemViewModel : ObservableObject
{
    private readonly BioRandOptionDefinition _definition;
    private bool _boolValue;
    private double _numberValue;
    private bool _isEnabled = true;
    private bool _isVisible = true;
    private string _forcedNotice = string.Empty;

    public BioRandOptionItemViewModel(BioRandOptionDefinition definition)
    {
        _definition = definition ?? throw new ArgumentNullException(nameof(definition));
    }

    /// <summary>Raised when the player changes this option (used to flip the mode to Custom).</summary>
    public event Action<BioRandOptionItemViewModel>? ValueChangedByUser;

    /// <summary>Set while a preset is being applied, so programmatic writes don't look like tweaks.</summary>
    public bool SuppressChangeNotifications { get; set; }

    public string Key => _definition.Key;

    public string Label => _definition.Label;

    public string Description => _definition.Description;

    public bool HasDescription => !string.IsNullOrWhiteSpace(_definition.Description);

    /// <summary>
    /// Descriptions render inline for the switches - the meaningful toggles (Random Items, Random
    /// Enemies, ...) - and for note rows, and as tooltips everywhere else. Showing them under all
    /// 419 options, most of which are rows in a ratio matrix, would double the height of every tab
    /// for no gain.
    /// </summary>
    public bool ShowInlineDescription => (IsSwitch || IsNote) && HasDescription;

    public bool IsAdvanced => _definition.Advanced;

    public bool IsSwitch => _definition.IsSwitch;

    /// <summary>
    /// A display-only row: label plus description, no control. Used for the
    /// Random Events pointer, which is AP-authored and lives in the YAML now.
    /// Note items are never registered in the options dictionary, so they can
    /// never emit a config value.
    /// </summary>
    public bool IsNote => string.Equals(_definition.Type, "note", StringComparison.OrdinalIgnoreCase);

    public bool IsNumeric => !_definition.IsSwitch && !IsNote;

    public bool IsPercent => _definition.IsPercent;

    public double Min => _definition.Min ?? 0d;

    public double Max => _definition.Max ?? 1d;

    public double Step => _definition.Step ?? (_definition.IsPercent || Max <= 2 ? 0.01d : 1d);

    public bool BoolValue
    {
        get => _boolValue;
        set
        {
            if (SetProperty(ref _boolValue, value) && !SuppressChangeNotifications)
            {
                ValueChangedByUser?.Invoke(this);
            }
        }
    }

    public double NumberValue
    {
        get => _numberValue;
        set
        {
            if (SetProperty(ref _numberValue, value))
            {
                OnPropertyChanged(nameof(ValueText));
                if (!SuppressChangeNotifications)
                {
                    ValueChangedByUser?.Invoke(this);
                }
            }
        }
    }

    public string ValueText => IsPercent
        ? string.Format(CultureInfo.CurrentCulture, "{0:0}%", _numberValue * 100d)
        : _numberValue.ToString(_numberValue is > -10 and < 10 ? "0.##" : "0", CultureInfo.CurrentCulture);

    /// <summary>
    /// False where the player cannot decide this option, because something else has already
    /// decided it. Currently only Random Items / Random Enemies under an AP-authored Random
    /// Events roll, which BioRand throws without.
    /// </summary>
    public bool IsEnabled
    {
        get => _isEnabled;
        set => SetProperty(ref _isEnabled, value);
    }

    /// <summary>
    /// Why this option is showing a value the player did not choose. Empty for the normal case.
    /// A greyed switch on its own reads as "broken" or "not available in this mode"; the row has
    /// to say who took the decision, or the screen is lying by omission (Cam, 2026-08-07: picked
    /// the no-enemy-randomization preset, got randomized enemies).
    /// </summary>
    public string ForcedNotice
    {
        get => _forcedNotice;
        set
        {
            if (SetProperty(ref _forcedNotice, value))
            {
                OnPropertyChanged(nameof(HasForcedNotice));
            }
        }
    }

    public bool HasForcedNotice => !string.IsNullOrWhiteSpace(_forcedNotice);

    /// <summary>Hidden when this is one of BioRand's advanced options and Show Advanced is off.</summary>
    public bool IsVisible
    {
        get => _isVisible;
        set => SetProperty(ref _isVisible, value);
    }

    public void LoadValue(JsonNode? node)
    {
        var previous = SuppressChangeNotifications;
        SuppressChangeNotifications = true;
        try
        {
            if (node is not JsonValue value)
            {
                return;
            }

            if (IsSwitch)
            {
                if (value.TryGetValue<bool>(out var flag))
                {
                    BoolValue = flag;
                }

                return;
            }

            if (value.TryGetValue<double>(out var number))
            {
                NumberValue = Math.Clamp(number, Min, Max);
            }
        }
        finally
        {
            SuppressChangeNotifications = previous;
        }
    }

    public JsonNode? ToJsonNode() => IsSwitch
        ? JsonValue.Create(BoolValue)
        : JsonValue.Create(NumberValue);
}

/// <summary>A sub-group header within a page (e.g. "Waves", "Treasure Classes").</summary>
public sealed class BioRandOptionGroupViewModel
{
    public required string Title { get; init; }

    /// <summary>One or two lines under the header. Blank for most groups.</summary>
    public string Description { get; init; } = string.Empty;

    public bool HasTitle => !string.IsNullOrWhiteSpace(Title);

    public bool HasDescription => !string.IsNullOrWhiteSpace(Description);

    public ObservableCollection<BioRandOptionItemViewModel> Options { get; } = new();
}

/// <summary>A tab: General, Merchant, Inventory, Valuables, Items, Enemies, Health.</summary>
public sealed class BioRandOptionPageViewModel : ObservableObject
{
    private bool _showAdvanced;

    public required string Title { get; init; }

    public bool IsEnemiesPage => string.Equals(Title, "Enemies", StringComparison.Ordinal);

    /// <summary>
    /// Enemies leads with a preset and keeps the individual knobs behind this.
    /// Every other tab has no preset to lead with, so it shows its options
    /// outright and this stays true.
    /// </summary>
    public bool ShowAdvanced
    {
        get => _showAdvanced || !IsEnemiesPage;
        set
        {
            if (SetProperty(ref _showAdvanced, value))
            {
                OnPropertyChanged(nameof(ShowAdvanced));
            }
        }
    }

    public ObservableCollection<BioRandOptionGroupViewModel> Groups { get; } = new();
}
