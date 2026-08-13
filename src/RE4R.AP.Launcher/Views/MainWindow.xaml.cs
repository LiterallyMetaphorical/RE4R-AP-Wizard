using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using RE4R.AP.Launcher.ViewModels;
using RE4R.AP.Launcher.Core.Services;
using RE4R.AP.Launcher.Services;

namespace RE4R.AP.Launcher.Views;

public partial class MainWindow : Window
{
    private readonly MainWindowViewModel _viewModel;

    public MainWindow()
    {
        InitializeComponent();
        _viewModel = new MainWindowViewModel(new WpfDialogService(this));
        DataContext = _viewModel;
        Loaded += MainWindow_OnLoaded;
        UpdateThemeButton();
    }

    // Set while syncing the switch to the current theme, so seeding its state
    // does not read as the user having flipped it.
    private bool _suppressThemeToggle;

    /// <summary>
    /// Point the switch at the theme in force. Checked is light, and the knob
    /// shows the CURRENT theme's icon rather than the one you would move to.
    /// </summary>
    private void UpdateThemeButton()
    {
        _suppressThemeToggle = true;
        ThemeToggleButton.IsChecked = ThemeService.Current == ThemeService.Light;
        _suppressThemeToggle = false;
    }

    // Checked/Unchecked rather than Click on purpose: Click only fires for a
    // real press, so a switch flipped any other way (accessibility tooling, a
    // programmatic set) would move on screen while the theme stayed put. That
    // is exactly what happened the first time this was wired to Click.
    private async void ThemeToggle_OnChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressThemeToggle)
        {
            return;
        }

        // Read the switch rather than inverting the current theme: the toggle
        // has already moved by the time Click fires, and deriving the answer
        // from anything else risks the two disagreeing.
        var next = ThemeToggleButton.IsChecked == true ? ThemeService.Light : ThemeService.Dark;
        ThemeService.Apply(next);

        // The banner and status chips resolve a theme KEY through a converter,
        // and a converter has no reason to re-run just because the dictionary
        // changed. Nudge those bindings so the switch repaints everything at
        // once instead of leaving a few surfaces on the old palette.
        _viewModel.RefreshThemedBrushes();

        // Persist afterwards. The switch is what the player asked for and it has
        // already happened on screen; a settings file that cannot be written
        // should cost them the preference next launch, not the switch now.
        try
        {
            var store = new SettingsStore();
            var settings = await store.LoadAsync();
            settings.Theme = next;
            await store.SaveAsync(settings);
        }
        catch (Exception ex)
        {
            _viewModel.Action.AppendLog($"Could not save the theme preference: {ex.Message}");
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        _viewModel.Dispose();
        base.OnClosed(e);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_viewModel.HasBusyOperation)
        {
            var proceed = ChoiceDialog.Show(
                this,
                "Something Is Still Running",
                "Patching or setup is still in progress. Closing now can leave your game "
                    + "install half-patched - you would need to patch again to fix it.",
                ["Close Anyway", "Keep It Open"],
                primaryIndex: 1) == 0;
            if (!proceed)
            {
                e.Cancel = true;
                return;
            }
        }

        base.OnClosing(e);
    }

    private async void MainWindow_OnLoaded(object sender, RoutedEventArgs e)
    {
        await _viewModel.InitializeAsync();
    }

    private void LogTextBox_OnTextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        LogTextBox.ScrollToEnd();
    }

    private void BioRandLink_OnClick(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(
                new ProcessStartInfo("https://github.com/biorand/re4r")
                {
                    UseShellExecute = true,
                });
        }
        catch (Exception ex)
        {
            _viewModel.Action.AppendLog($"Failed to open the BioRand page in your browser: {ex.Message}");
        }
    }

}
