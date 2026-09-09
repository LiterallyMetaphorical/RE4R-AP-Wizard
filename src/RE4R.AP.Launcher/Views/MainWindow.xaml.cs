using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using RE4R.AP.Launcher.ViewModels;
using RE4R.AP.Launcher.Core.Services;
using RE4R.AP.Launcher.Core.Utilities;
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
        // The process once outlived its window with nothing left to do and
        // no line in the log to say where (09-02). Dispose is guarded so a
        // failure here cannot stop the shutdown or raise a dialog with no
        // window behind it, and the shutdown is asked for explicitly rather
        // than left to the window count.
        // The view model is null when the constructor itself threw, which is
        // exactly when this runs: the startup failure raised its own dialog,
        // then closing the half-built window raised a second one about a null
        // reference (live 2026-09-06, after a stale asset file stopped the
        // launcher starting). One honest dialog is enough.
        try
        {
            _viewModel?.Dispose();
        }
        catch (Exception ex)
        {
            LauncherFileLog.Append($"[lifecycle] main window dispose failed: {ex}");
        }

        LauncherFileLog.Append("[lifecycle] main window closed; shutting down");
        LauncherFileLog.Flush();
        base.OnClosed(e);

        // Armed BEFORE the shutdown request, not after it: a shutdown that
        // never completes leaves the process alive with no window, and
        // App.OnExit - where this used to be armed - never runs to catch it
        // (live twice on 2026-09-07, the second blocking a deploy).
        App.StartExitWatchdog(0, "the window closed");

        var app = Application.Current;
        if (app is not null && !app.Dispatcher.HasShutdownStarted)
        {
            try
            {
                app.Shutdown();
            }
            catch (Exception ex)
            {
                LauncherFileLog.Append($"[lifecycle] shutdown request failed: {ex}");
            }
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Null when the constructor threw; see OnClosed. A window with no view
        // model has nothing running, so it closes without a word.
        var busy = _viewModel?.HasBusyOperation == true;
        LauncherFileLog.Append(
            $"[lifecycle] main window closing (busy: {(busy ? "yes" : "no")})");
        if (busy)
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
                LauncherFileLog.Append("[lifecycle] close cancelled: kept open while busy");
                e.Cancel = true;
                return;
            }

            LauncherFileLog.Append("[lifecycle] closing while busy at the user's request");
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
