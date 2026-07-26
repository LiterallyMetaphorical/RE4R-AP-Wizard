using System.Windows.Input;
using RE4R.AP.Launcher.Core.Utilities;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

public sealed class ActionViewModel : ObservableObject
{
    private const string HighlightBackgroundBrush = "#27AE60";
    private const string HighlightForegroundBrush = "#FFFFFF";
    private const string NeutralBackgroundBrush = "#E1E1E1";
    private const string NeutralForegroundBrush = "#555555";

    // The visible log keeps only a rolling window. Every appended line
    // rebuilds the bound LogText string and re-renders the TextBox on a
    // Normal-priority dispatcher operation - and WPF services input at a
    // LOWER priority than Normal, so an unbounded buffer turns chatty tool
    // output (BioRand's full setup prints one line per harvested file,
    // ~74k lines) into minutes of queued rebuilds during which clicks are
    // never processed (the step-0 "cannot press Proceed" freeze).
    // The complete history always goes to the disk log.
    private const int MaxVisibleLogLines = 300;
    private const string TrimmedNotice = "... older lines are in the disk log (Open Log Folder) ...";

    private readonly Queue<string> _logLines = new();
    private bool _logTrimmed;
    private bool _isBusy;
    private string _logText = string.Empty;
    private string _errorMessage = string.Empty;
    private string _statusText = "Ready.";
    private string _goButtonText = "Generate";
    private bool _isPrimaryActionVisible;
    private bool _isPrimaryActionHighlighted;
    private ICommand? _goCommand;
    private ICommand? _cancelCommand;
    private ICommand? _dismissErrorCommand;

    public bool IsBusy
    {
        get => _isBusy;
        set
        {
            if (SetProperty(ref _isBusy, value))
            {
                OnPropertyChanged(nameof(IsCancelVisible));
            }
        }
    }

    public string LogText
    {
        get => _logText;
        private set => SetProperty(ref _logText, value);
    }

    public string ErrorMessage
    {
        get => _errorMessage;
        set
        {
            if (SetProperty(ref _errorMessage, value))
            {
                OnPropertyChanged(nameof(HasError));
                if (HasError)
                {
                    LauncherFileLog.Append($"[error] {value}");
                }
            }
        }
    }

    public bool HasError => !string.IsNullOrWhiteSpace(ErrorMessage);

    public string StatusText
    {
        get => _statusText;
        set => SetProperty(ref _statusText, value);
    }

    public string GoButtonText
    {
        get => _goButtonText;
        set => SetProperty(ref _goButtonText, value);
    }

    public bool IsPrimaryActionVisible
    {
        get => _isPrimaryActionVisible;
        set => SetProperty(ref _isPrimaryActionVisible, value);
    }

    public bool IsPrimaryActionHighlighted
    {
        get => _isPrimaryActionHighlighted;
        set
        {
            if (SetProperty(ref _isPrimaryActionHighlighted, value))
            {
                OnPropertyChanged(nameof(GoButtonBackground));
                OnPropertyChanged(nameof(GoButtonForeground));
            }
        }
    }

    public bool IsCancelVisible => IsBusy;

    public string GoButtonBackground => IsPrimaryActionHighlighted ? HighlightBackgroundBrush : NeutralBackgroundBrush;

    public string GoButtonForeground => IsPrimaryActionHighlighted ? HighlightForegroundBrush : NeutralForegroundBrush;

    public ICommand? GoCommand
    {
        get => _goCommand;
        set => SetProperty(ref _goCommand, value);
    }

    public ICommand? CancelCommand
    {
        get => _cancelCommand;
        set => SetProperty(ref _cancelCommand, value);
    }

    public ICommand? DismissErrorCommand
    {
        get => _dismissErrorCommand;
        set => SetProperty(ref _dismissErrorCommand, value);
    }

    public void AppendLog(string message)
    {
        _logLines.Enqueue(message);
        TrimAndRebuildLogText();
        LauncherFileLog.Append(message);
    }

    /// <summary>
    /// Appends many lines in a single LogText rebuild. Used by the batched
    /// workflow-log drain; those lines were already teed to LauncherFileLog
    /// on the producer thread, so this must not tee them again.
    /// </summary>
    public void AppendLogBatch(IReadOnlyList<string> messages)
    {
        if (messages.Count == 0)
        {
            return;
        }

        foreach (var message in messages)
        {
            _logLines.Enqueue(message);
        }

        TrimAndRebuildLogText();
    }

    private void TrimAndRebuildLogText()
    {
        while (_logLines.Count > MaxVisibleLogLines)
        {
            _logLines.Dequeue();
            _logTrimmed = true;
        }

        LogText = _logTrimmed
            ? TrimmedNotice + Environment.NewLine + string.Join(Environment.NewLine, _logLines)
            : string.Join(Environment.NewLine, _logLines);
    }

    public void ClearLog()
    {
        _logLines.Clear();
        _logTrimmed = false;
        LogText = string.Empty;
    }

    public void ClearError()
    {
        ErrorMessage = string.Empty;
    }
}
