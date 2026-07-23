using System.Windows.Input;

namespace RE4R.AP.Launcher.Infrastructure;

public sealed class AsyncRelayCommand : ICommand
{
    private readonly Func<Task> _executeAsync;
    private readonly Func<bool>? _canExecute;

    public AsyncRelayCommand(Func<Task> executeAsync, Func<bool>? canExecute = null)
    {
        _executeAsync = executeAsync ?? throw new ArgumentNullException(nameof(executeAsync));
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    // Wired once by App at startup; an exception escaping an async-void
    // Execute would otherwise crash the process (and orphan a hosted AP
    // server, since OnClosing never runs on a crash).
    public static event Action<Exception>? UnhandledException;

    public bool CanExecute(object? parameter)
    {
        return _canExecute?.Invoke() ?? true;
    }

    public async void Execute(object? parameter)
    {
        try
        {
            await _executeAsync();
        }
        catch (Exception ex)
        {
            var handler = UnhandledException;
            if (handler is null)
            {
                throw;
            }

            handler(ex);
        }
    }

    public void NotifyCanExecuteChanged()
    {
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}
