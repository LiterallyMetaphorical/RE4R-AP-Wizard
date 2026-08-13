using System.Windows;
using System.Windows.Threading;
using RE4R.AP.Launcher.Core.Utilities;
using RE4R.AP.Launcher.Core.Services;
using RE4R.AP.Launcher.Infrastructure;
using RE4R.AP.Launcher.Services;

namespace RE4R.AP.Launcher;

/// <summary>
/// Interaction logic for App.xaml
/// </summary>
public partial class App : Application
{
    private DateTime _lastUnhandledReportUtc = DateTime.MinValue;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Apply the saved theme before the first window is built, so the
        // launcher never flashes the wrong one on the way up.
        //
        // TryLoad, NOT LoadAsync().GetAwaiter().GetResult(): the dispatcher
        // context exists by this point, so blocking on the async path queues
        // its continuation onto the thread being blocked and the launcher hangs
        // with a live process and no window. That is not theoretical - it is
        // what the first version of this did.
        try
        {
            ThemeService.Apply(new SettingsStore().TryLoad().Theme);
        }
        catch (Exception)
        {
            ThemeService.Apply(ThemeService.Dark);
        }

        AsyncRelayCommand.UnhandledException += exception =>
            ReportUnhandledException(exception, "a launcher action");
        DispatcherUnhandledException += OnDispatcherUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        e.Handled = true;

        // The Window base ctor registers into Windows before a derived ctor
        // can fail, so the count alone cannot detect a startup failure -
        // check whether any window actually made it on screen. (IsVisible
        // stays true for minimized windows, so this cannot misfire later.)
        var anyWindowVisible = false;
        foreach (Window window in Windows)
        {
            if (window.IsVisible)
            {
                anyWindowVisible = true;
                break;
            }
        }

        if (!anyWindowVisible)
        {
            // Nothing is on screen (e.g. MainWindow construction failed).
            // Keeping a windowless process alive would leave a zombie, and
            // nothing can be mid-operation this early - exit cleanly instead.
            LauncherFileLog.Append($"[crash-guard] startup failure: {e.Exception}");
            LauncherFileLog.Close();
            try
            {
                MessageBox.Show(
                    $"The launcher could not start.\n\nDetails: {e.Exception.Message}",
                    "RE4R AP Launcher",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
            }
            catch
            {
            }

            Shutdown(1);
            return;
        }

        ReportUnhandledException(e.Exception, "the launcher UI");
    }

    protected override void OnExit(ExitEventArgs e)
    {
        // Flush and release the buffered disk log so the tail of the session
        // is never lost on a normal close.
        LauncherFileLog.Close();
        base.OnExit(e);
    }

    private void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        e.SetObserved();
        // Log here, on this thread: if the UI thread is hung, the marshaled
        // dialog below never runs and the exception would vanish unrecorded.
        LauncherFileLog.Append($"[crash-guard] a background task: {e.Exception}");
        LauncherFileLog.Flush();
        // Marshal off the finalizer thread: a modal dialog here would block
        // all finalization process-wide until the user clicks OK.
        var exception = e.Exception?.GetBaseException() ?? new Exception("Unknown background task failure.");
        Dispatcher.BeginInvoke(() => ShowUnhandledExceptionDialog(exception, "a background task"));
    }

    private void ReportUnhandledException(Exception exception, string source)
    {
        // Full exception with stack trace goes to the disk log before the
        // rate limiter so every occurrence is recorded even when the dialog
        // is suppressed.
        LauncherFileLog.Append($"[crash-guard] {source}: {exception}");
        LauncherFileLog.Flush();
        ShowUnhandledExceptionDialog(exception, source);
    }

    private void ShowUnhandledExceptionDialog(Exception exception, string source)
    {
        // Keeping the process alive preserves in-progress launcher state;
        // rate-limiting stops a repeating failure from storming dialogs.
        var now = DateTime.UtcNow;
        if (now - _lastUnhandledReportUtc < TimeSpan.FromSeconds(5))
        {
            return;
        }

        _lastUnhandledReportUtc = now;

        try
        {
            MessageBox.Show(
                $"Something went wrong in {source}, but the launcher is still running.\n\n"
                    + $"Details: {exception.Message}\n\n"
                    + "If the last action did not finish, try it again.",
                "RE4R AP Launcher",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
        catch
        {
            // Error reporting must never take the launcher down.
        }
    }
}
