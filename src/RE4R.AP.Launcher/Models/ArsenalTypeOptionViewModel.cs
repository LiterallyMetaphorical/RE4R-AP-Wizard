using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.Models;

/// <summary>
/// One weapon class the Starting Arsenal draw may take. Mirrors the
/// apworld's starting_arsenal_types keys, which mirror BioRand's own
/// starting-inventory pickers; "special" means the Rocket Launcher.
/// </summary>
public sealed class ArsenalTypeOptionViewModel : ObservableObject
{
    private bool _isSelected = true;

    public string Key { get; init; } = string.Empty;

    public string Label { get; init; } = string.Empty;

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }
}
