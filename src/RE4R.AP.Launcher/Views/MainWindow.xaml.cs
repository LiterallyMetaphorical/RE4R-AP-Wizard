using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using RE4R.AP.Launcher.ViewModels;
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
