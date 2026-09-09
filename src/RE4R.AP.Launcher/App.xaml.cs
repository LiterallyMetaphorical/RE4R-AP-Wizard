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
        LauncherFileLog.Append(
            $"[lifecycle] launcher {LauncherVersion()} started, process {Environment.ProcessId}");

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
        catch (Exception ex)
        {
            // Worth recording: a theme that fails to load leaves the window
            // painted in system defaults, which is confusing without a reason.
            LauncherFileLog.Append($"[theme] could not apply the saved theme: {ex.Message}");
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
        if (!AnyWindowVisible())
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
        LauncherFileLog.Append($"[lifecycle] exiting with code {e.ApplicationExitCode}");
        LauncherFileLog.Close();
        StartExitWatchdog(e.ApplicationExitCode, "exit");
        base.OnExit(e);
    }

    private static int _exitWatchdogArmed;

    /// <summary>
    /// The process once outlived its window with nothing left to do (09-02,
    /// twice in one afternoon) and no log line said where it stuck. Nothing
    /// legitimate runs after the window closes, so anything still holding the
    /// process open a few seconds later is a straggler: record it and end the
    /// process. The thread is a background thread, so it never holds the
    /// process open itself.
    ///
    /// [2026-09-07] Armed from the window's OnClosed as well, and that is the
    /// case that matters. It used to be armed only from OnExit, which runs
    /// AFTER the dispatcher has processed Shutdown - so the one failure it
    /// exists for, a shutdown that never completes, was the one it could not
    /// see. It happened twice that day: the log ended at "main window closed;
    /// shutting down" with no exit line and the process alive for hours, and
    /// the second one blocked a deploy. Idempotent, since both gates fire on
    /// an ordinary close.
    /// </summary>
    internal static void StartExitWatchdog(int exitCode, string armedBy)
    {
        if (Interlocked.Exchange(ref _exitWatchdogArmed, 1) != 0)
        {
            return;
        }

        try
        {
            var watchdog = new Thread(() =>
            {
                Thread.Sleep(TimeSpan.FromSeconds(5));
                LauncherFileLog.Append(
                    $"[lifecycle] the process was still alive 5 s after {armedBy}; ending it");
                LauncherFileLog.Close();
                Environment.Exit(exitCode);
            })
            {
                IsBackground = true,
                Name = "exit-watchdog",
            };
            watchdog.Start();
        }
        catch
        {
            // The watchdog is a safety net; failing to arm it must not matter.
        }
    }

    private static string LauncherVersion()
    {
        try
        {
            var assembly = typeof(App).Assembly;
            var informational = assembly
                .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
                .OfType<System.Reflection.AssemblyInformationalVersionAttribute>()
                .FirstOrDefault()?.InformationalVersion;
            return informational ?? assembly.GetName().Version?.ToString() ?? "?";
        }
        catch
        {
            return "?";
        }
    }

    private bool AnyWindowVisible()
    {
        foreach (Window window in Windows)
        {
            if (window.IsVisible)
            {
                return true;
            }
        }

        return false;
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
        // With no window on screen there is nobody to read a dialog, and a
        // modal box with no owner would hold a windowless process open until
        // someone found it. The exception is already in the disk log; make
        // sure the process is on its way out instead.
        if (!AnyWindowVisible())
        {
            LauncherFileLog.Append(
                $"[crash-guard] no window is on screen, so no dialog for {source}; shutting down");
            LauncherFileLog.Flush();
            if (!Dispatcher.HasShutdownStarted)
            {
                try
                {
                    Shutdown(1);
                }
                catch
                {
                }
            }

            return;
        }

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
