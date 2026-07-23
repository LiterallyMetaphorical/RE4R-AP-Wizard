using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.Models;

public sealed class TypewriterOptionViewModel : ObservableObject
{
    private bool _isSelected;

    public string StageId { get; init; } = string.Empty;

    public string DisplayName { get; init; } = string.Empty;

    public bool IsSelected
    {
        get => _isSelected;
        set => SetProperty(ref _isSelected, value);
    }
}
