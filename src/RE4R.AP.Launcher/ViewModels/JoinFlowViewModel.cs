using System.ComponentModel;
using System.Linq;
using System.Windows.Input;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

public enum JoinFlowStep
{
    SessionInfo = 1,
    BioRandOptions = 2,
    Patching = 3,
}

public sealed class JoinFlowViewModel : ObservableObject
{
    private readonly RelayCommand _goToBioRandOptionsCommand;
    private readonly RelayCommand _backToSessionInfoCommand;
    private readonly RelayCommand _patchMyGameCommand;
    private JoinFlowStep _currentStep = JoinFlowStep.SessionInfo;
    private string _statusText = "Enter the server address and slot name your host gave you.";
    private ICommand? _backToLandingCommand;

    public JoinFlowViewModel(SessionViewModel session, ActionViewModel action, BioRandOptionsViewModel bioRandOptions)
    {
        Session = session ?? throw new ArgumentNullException(nameof(session));
        Action = action ?? throw new ArgumentNullException(nameof(action));
        BioRandOptions = bioRandOptions ?? throw new ArgumentNullException(nameof(bioRandOptions));

        _goToBioRandOptionsCommand = new RelayCommand(GoToBioRandOptions, CanProceedToBioRandOptions);
        _backToSessionInfoCommand = new RelayCommand(() => CurrentStep = JoinFlowStep.SessionInfo);
        _patchMyGameCommand = new RelayCommand(RequestPatchLaunch);

        GoToBioRandOptionsCommand = _goToBioRandOptionsCommand;
        BackToSessionInfoCommand = _backToSessionInfoCommand;
        PatchMyGameCommand = _patchMyGameCommand;

        Session.PropertyChanged += OnSessionPropertyChanged;
        RebuildFooter();
    }

    /// <summary>Sticky footer actions for the current sub-step.</summary>
    public System.Collections.ObjectModel.ObservableCollection<FooterButtonViewModel> FooterButtons { get; } = new();

    private void RebuildFooter()
    {
        FooterButtons.Clear();
        switch (CurrentStep)
        {
            case JoinFlowStep.SessionInfo:
                FooterButtons.Add(new FooterButtonViewModel("Back", BackToLandingCommand));
                FooterButtons.Add(new FooterButtonViewModel("Continue", GoToBioRandOptionsCommand, isPrimary: true));
                break;
            case JoinFlowStep.BioRandOptions:
                FooterButtons.Add(new FooterButtonViewModel("Back", BackToSessionInfoCommand));
                FooterButtons.Add(new FooterButtonViewModel("Patch My Game", PatchMyGameCommand, isPrimary: true));
                break;
            case JoinFlowStep.Patching:
                FooterButtons.Add(new FooterButtonViewModel("Back", BackToSessionInfoCommand));
                break;
        }
    }

    public event Action? PatchRequested;

    public SessionViewModel Session { get; }

    public ActionViewModel Action { get; }

    public BioRandOptionsViewModel BioRandOptions { get; }

    public JoinFlowStep CurrentStep
    {
        get => _currentStep;
        set
        {
            if (SetProperty(ref _currentStep, value))
            {
                OnPropertyChanged(nameof(IsSessionInfoStep));
                OnPropertyChanged(nameof(IsBioRandOptionsStep));
                OnPropertyChanged(nameof(IsPatchingStep));
                RebuildFooter();
            }
        }
    }

    public string StatusText
    {
        get => _statusText;
        private set => SetProperty(ref _statusText, value);
    }

    public ICommand? BackToLandingCommand
    {
        get => _backToLandingCommand;
        set
        {
            if (SetProperty(ref _backToLandingCommand, value))
            {
                // Wired after construction by the shell; the footer holds a
                // direct reference, so rebuild once it lands.
                RebuildFooter();
            }
        }
    }

    public ICommand GoToBioRandOptionsCommand { get; }

    public ICommand BackToSessionInfoCommand { get; }

    public ICommand PatchMyGameCommand { get; }

    public bool IsSessionInfoStep => CurrentStep == JoinFlowStep.SessionInfo;

    public bool IsBioRandOptionsStep => CurrentStep == JoinFlowStep.BioRandOptions;

    public bool IsPatchingStep => CurrentStep == JoinFlowStep.Patching;

    public void Enter()
    {
        CurrentStep = JoinFlowStep.SessionInfo;
        StatusText = "Enter the server address and slot name your host gave you.";
        BioRandOptions.SelectedMode = BioRandOptions.AvailableModes.FirstOrDefault(option => option.Key == "mode1");
    }

    /// <summary>
    /// Raised when the player reaches the options step, so the shell can pin the options to a
    /// previous patch of this same room (re-patch replays the recorded options).
    /// </summary>
    public Action? EnteringBioRandOptions { get; set; }

    private void GoToBioRandOptions()
    {
        CurrentStep = JoinFlowStep.BioRandOptions;
        StatusText = "Review the launch mode before patching your RE4R install.";

        // Deliberately does NOT reset the mode: Enter() already starts the flow on mode 1, and
        // re-forcing it here would throw away the player's choice every time they stepped Back and
        // Next again.
        EnteringBioRandOptions?.Invoke();
    }

    private bool CanProceedToBioRandOptions()
    {
        return !string.IsNullOrWhiteSpace(Session.ServerAddress)
            && !string.IsNullOrWhiteSpace(Session.SlotName);
    }

    private void RequestPatchLaunch()
    {
        CurrentStep = JoinFlowStep.Patching;
        StatusText = "Preparing the shared patch and launch workflow.";

        if (PatchRequested is null)
        {
            Action.AppendLog("No patch handler is connected; patching is unavailable in this context.");
            return;
        }

        PatchRequested.Invoke();
    }

    private void OnSessionPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (string.Equals(e.PropertyName, nameof(SessionViewModel.ServerAddress), StringComparison.Ordinal)
            || string.Equals(e.PropertyName, nameof(SessionViewModel.SlotName), StringComparison.Ordinal))
        {
            _goToBioRandOptionsCommand.NotifyCanExecuteChanged();
        }
    }
}
