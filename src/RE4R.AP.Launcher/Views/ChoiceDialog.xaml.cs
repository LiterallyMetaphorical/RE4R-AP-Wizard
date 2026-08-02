using System.Windows;

namespace RE4R.AP.Launcher.Views;

/// <summary>
/// A confirm dialog whose buttons say what they DO. Windows' stock MessageBox
/// can only offer Yes/No/Cancel, which forced every prompt to explain a
/// mapping ("Yes to resume, No to re-patch") that players cannot be expected
/// to hold in their head. Every button here carries an action label instead.
/// </summary>
public partial class ChoiceDialog : Window
{
    public sealed record Choice(string Label, int Index, FontWeight FontWeight);

    public string TitleText { get; }
    public string MessageText { get; }
    public IReadOnlyList<Choice> Choices { get; }

    /// <summary>Index into the labels list, or null when the window is closed.</summary>
    public int? ChosenIndex { get; private set; }

    public ChoiceDialog(string title, string message, IReadOnlyList<string> choiceLabels, int primaryIndex = 0)
    {
        TitleText = title;
        MessageText = message;
        Choices = choiceLabels
            .Select((label, index) => new Choice(
                label,
                index,
                index == primaryIndex ? FontWeights.SemiBold : FontWeights.Normal))
            .ToList();
        DataContext = this;
        InitializeComponent();
    }

    /// <summary>
    /// Escape dismisses without choosing, which every caller reads as the
    /// cancel/decline side - the safe outcome in all of them. Without this the
    /// only way out of a prompt you did not mean to open is the title-bar X.
    /// </summary>
    protected override void OnPreviewKeyDown(System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Escape)
        {
            e.Handled = true;
            Close();
        }

        base.OnPreviewKeyDown(e);
    }

    private void OnChoiceClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: Choice choice })
        {
            ChosenIndex = choice.Index;
            DialogResult = true;
        }
    }

    /// <summary>Shows the dialog and returns the chosen index, or null if dismissed.</summary>
    public static int? Show(Window owner, string title, string message, IReadOnlyList<string> choiceLabels, int primaryIndex = 0)
    {
        var dialog = new ChoiceDialog(title, message, choiceLabels, primaryIndex)
        {
            Owner = owner,
        };
        dialog.ShowDialog();
        return dialog.ChosenIndex;
    }
}
