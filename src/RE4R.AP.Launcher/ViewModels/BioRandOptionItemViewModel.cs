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
    /// Enemies, ...) - and as tooltips everywhere else. Showing them under all 419 options, most of
    /// which are rows in a ratio matrix, would double the height of every tab for no gain.
    /// </summary>
    public bool ShowInlineDescription => IsSwitch && HasDescription;

    public bool IsAdvanced => _definition.Advanced;

    public bool IsSwitch => _definition.IsSwitch;

    public bool IsNumeric => !_definition.IsSwitch;

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
    /// False where the option cannot take effect right now - currently only Random Events, which
    /// makes BioRand throw unless Random Items AND Random Enemies are both on.
    /// </summary>
    public bool IsEnabled
    {
        get => _isEnabled;
        set => SetProperty(ref _isEnabled, value);
    }

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

    public bool HasTitle => !string.IsNullOrWhiteSpace(Title);

    public ObservableCollection<BioRandOptionItemViewModel> Options { get; } = new();
}

/// <summary>A tab: General, Merchant, Inventory, Valuables, Items, Enemies, Health.</summary>
public sealed class BioRandOptionPageViewModel
{
    public required string Title { get; init; }

    public ObservableCollection<BioRandOptionGroupViewModel> Groups { get; } = new();
}
