using System.Windows.Input;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

/// <summary>
/// One button in the window's sticky footer.
/// </summary>
/// <remarks>
/// Step navigation used to live inside each screen, which meant it scrolled
/// away on long pages - a player could be looking at settings with no visible
/// way forward (Cam 2026-07-31). Screens now publish their actions and the
/// shell pins them above the log, so Back/Continue sit in the same place on
/// every step.
/// </remarks>
public sealed class FooterButtonViewModel : ObservableObject
{
    private string _label;
    private bool _isVisible = true;

    public FooterButtonViewModel(string label, ICommand? command, bool isPrimary = false)
    {
        _label = label;
        Command = command;
        IsPrimary = isPrimary;
    }

    public string Label
    {
        get => _label;
        set => SetProperty(ref _label, value);
    }

    public ICommand? Command { get; }

    /// <summary>The step's forward action - bolded so the eye lands on it.</summary>
    public bool IsPrimary { get; }

    public bool IsVisible
    {
        get => _isVisible;
        set => SetProperty(ref _isVisible, value);
    }
}
