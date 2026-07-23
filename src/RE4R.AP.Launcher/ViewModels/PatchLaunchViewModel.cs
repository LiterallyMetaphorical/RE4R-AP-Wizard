using System.Collections.ObjectModel;
using System.Linq;
using System.Windows.Input;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

/// <summary>
/// One visible row of the patch phase checklist (field note: "loading bar
/// with phases" - the raw log gave no sense of progress or duration).
/// </summary>
public sealed class WorkflowStageItem : ObservableObject
{
    private bool _isRunning;
    private bool _isDone;
    private bool _isFailed;

    public WorkflowStageItem(WorkflowStep step, string label)
    {
        Step = step;
        Label = label;
    }

    public WorkflowStep Step { get; }

    public string Label { get; }

    public bool IsRunning
    {
        get => _isRunning;
        set
        {
            if (SetProperty(ref _isRunning, value))
            {
                OnPropertyChanged(nameof(Marker));
            }
        }
    }

    public bool IsDone
    {
        get => _isDone;
        set
        {
            if (SetProperty(ref _isDone, value))
            {
                OnPropertyChanged(nameof(Marker));
            }
        }
    }

    public bool IsFailed
    {
        get => _isFailed;
        set
        {
            if (SetProperty(ref _isFailed, value))
            {
                OnPropertyChanged(nameof(Marker));
            }
        }
    }

    public string Marker => IsFailed ? "✕" : IsDone ? "✓" : IsRunning ? "▶" : "•";
}

public sealed class PatchLaunchViewModel : ObservableObject
{
    private readonly LaunchWorkflowService _workflowService;
    private CancellationTokenSource? _workflowCancellationSource;
    private string _title = "Patch + Launch";
    private string _description = "Run the shared scout, manifest, BioRand, Lua install, and AP client startup workflow.";
    private string _completionText = string.Empty;
    private bool _isRunning;
    private bool _showRetry;
    private ICommand? _backToLandingCommand;
    private ICommand? _retryCommand;

    public PatchLaunchViewModel(LaunchWorkflowService workflowService, ActionViewModel action)
    {
        _workflowService = workflowService ?? throw new ArgumentNullException(nameof(workflowService));
        Action = action ?? throw new ArgumentNullException(nameof(action));
        CancelCommand = new RelayCommand(CancelWorkflowFromCommand, () => IsRunning);

        Stages = new ObservableCollection<WorkflowStageItem>
        {
            new(WorkflowStep.ValidateSettings, "Checking prerequisites"),
            new(WorkflowStep.CheckSetup, "BioRand setup (first time or after updates: about a minute)"),
            new(WorkflowStep.ScoutApServer, "Contacting your room and reading item placements"),
            new(WorkflowStep.CheckExistingSession, "Checking saved sessions"),
            new(WorkflowStep.BuildManifest, "Building the AP manifest"),
            new(WorkflowStep.RunBioRandGeneration, "BioRand is generating your world (a few minutes)"),
            new(WorkflowStep.InstallPatchFiles, "Installing patch files (you confirm first)"),
            new(WorkflowStep.InstallLuaModFiles, "Installing the Archipelago mod"),
            new(WorkflowStep.WriteSessionRecord, "Saving your session"),
            new(WorkflowStep.WriteConnectionInfo, "Writing connection info for RE4R"),
        };
    }

    public ObservableCollection<WorkflowStageItem> Stages { get; }

    public WorkflowStep? LastFailedStep { get; private set; }

    public string LastErrorMessage { get; private set; } = string.Empty;

    public ActionViewModel Action { get; }

    public string Title
    {
        get => _title;
        set => SetProperty(ref _title, value);
    }

    public string Description
    {
        get => _description;
        set => SetProperty(ref _description, value);
    }

    public string CompletionText
    {
        get => _completionText;
        private set
        {
            if (SetProperty(ref _completionText, value))
            {
                OnPropertyChanged(nameof(HasCompletionText));
            }
        }
    }

    public bool HasCompletionText => !string.IsNullOrWhiteSpace(CompletionText);

    public bool IsRunning
    {
        get => _isRunning;
        private set
        {
            if (SetProperty(ref _isRunning, value))
            {
                ((RelayCommand)CancelCommand).NotifyCanExecuteChanged();
            }
        }
    }

    public ICommand CancelCommand { get; }

    public bool ShowRetry
    {
        get => _showRetry;
        set => SetProperty(ref _showRetry, value);
    }

    public ICommand? RetryCommand
    {
        get => _retryCommand;
        set => SetProperty(ref _retryCommand, value);
    }

    public ICommand? BackToLandingCommand
    {
        get => _backToLandingCommand;
        set => SetProperty(ref _backToLandingCommand, value);
    }

    /// <summary>
    /// Marks the checklist as the workflow advances. Must be called on the
    /// UI thread (the owner marshals).
    /// </summary>
    public void MarkStepStarting(WorkflowStep step)
    {
        var reached = false;
        foreach (var stage in Stages)
        {
            if (stage.Step == step)
            {
                reached = true;
                stage.IsRunning = true;
                stage.IsFailed = false;
                continue;
            }

            if (!reached)
            {
                stage.IsRunning = false;
                stage.IsDone = true;
                stage.IsFailed = false;
            }
            else
            {
                stage.IsRunning = false;
                stage.IsDone = false;
            }
        }
    }

    private void ResetStages()
    {
        foreach (var stage in Stages)
        {
            stage.IsRunning = false;
            stage.IsDone = false;
            stage.IsFailed = false;
        }
    }

    private void MarkAllStagesDone()
    {
        foreach (var stage in Stages)
        {
            stage.IsRunning = false;
            stage.IsFailed = false;
            stage.IsDone = true;
        }
    }

    private void MarkRunningStageFailed()
    {
        var running = Stages.FirstOrDefault(stage => stage.IsRunning);
        if (running is not null)
        {
            running.IsRunning = false;
            running.IsFailed = true;
        }
    }

    /// <summary>
    /// Cancels a workflow in flight. Called on launcher close so a patch
    /// that keeps running during teardown cannot spawn an orphaned AP
    /// client after the tracked one is stopped.
    /// </summary>
    public void CancelWorkflow()
    {
        _workflowCancellationSource?.Cancel();
    }

    public async Task<bool> BeginAsync(LaunchWorkflowRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (IsRunning)
        {
            Action.AppendLog("Patch + launch is already running.");
            return false;
        }

        _workflowCancellationSource?.Cancel();
        _workflowCancellationSource?.Dispose();
        _workflowCancellationSource = new CancellationTokenSource();

        CompletionText = string.Empty;
        LastFailedStep = null;
        LastErrorMessage = string.Empty;
        ShowRetry = false;
        ResetStages();
        Action.ClearError();
        Action.StatusText = "Running patch + launch workflow...";
        Action.AppendLog("Starting the shared patch + launch workflow.");
        IsRunning = true;

        try
        {
            var result = await _workflowService.RunAsync(request, _workflowCancellationSource.Token);
            if (result.Success)
            {
                MarkAllStagesDone();
                CompletionText = result.FinalMessage;
                Action.StatusText = result.FinalMessage;
                return true;
            }

            if (result.Cancelled)
            {
                CompletionText = "Patch + launch was cancelled.";
                Action.StatusText = CompletionText;
            }
            else
            {
                Action.StatusText = "Patch + launch did not complete successfully.";
            }
        }
        catch (OperationCanceledException)
        {
            CompletionText = "Patch + launch was cancelled.";
            Action.StatusText = CompletionText;
        }
        catch (WorkflowException ex)
        {
            LastFailedStep = ex.Step;
            LastErrorMessage = ex.Message;
            MarkRunningStageFailed();
            Action.ErrorMessage = ex.Message;
            Action.StatusText = ex.Message;
            Action.AppendLog($"Patch + launch failed during {ex.Step}: {ex.Message}");
        }
        catch (Exception ex)
        {
            var message = $"Patch + launch failed unexpectedly: {ex.Message}";
            LastFailedStep = WorkflowStep.ValidateSettings;
            LastErrorMessage = message;
            MarkRunningStageFailed();
            Action.ErrorMessage = message;
            Action.StatusText = message;
            Action.AppendLog(message);
        }
        finally
        {
            IsRunning = false;
        }

        return false;
    }

    private void CancelWorkflowFromCommand()
    {
        if (!IsRunning)
        {
            return;
        }

        Action.AppendLog("Cancelling patch + launch workflow.");
        CancelWorkflow();
    }
}
