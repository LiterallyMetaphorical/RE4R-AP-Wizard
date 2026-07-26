using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Input;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using RE4R.AP.Launcher.Infrastructure;
using RE4R.AP.Launcher.Services;

namespace RE4R.AP.Launcher.ViewModels;

/// <summary>
/// The organizer's Generation Guidance screen (redesign step 4): a numbered
/// checklist that walks the rarest role through generating a multiworld on
/// their own Archipelago install and hosting it on archipelago.gg. The
/// launcher only guides - it never runs the AP installer or
/// ArchipelagoGenerate. Progress (AP path, collected YAMLs, pasted room
/// details) persists in the pending-session draft so the organizer can leave
/// and come back days later; the checklist ends by handing the room address
/// to the Join screen.
/// </summary>
public sealed class GenerationGuidanceViewModel : ObservableObject
{
    private readonly IUiDialogService _dialogService;
    private readonly ActionViewModel _action;
    private readonly PendingSessionDraftStore _draftStore;
    private readonly YamlInspectionService _yamlInspection;
    private readonly ArchipelagoInstallationService _apService;

    private readonly AsyncRelayCommand _browseApFolderCommand;
    private readonly RelayCommand _openApReleasePageCommand;
    private readonly AsyncRelayCommand _copyApworldCommand;
    private readonly AsyncRelayCommand _addYamlsCommand;
    private readonly AsyncRelayCommand _addMyOwnYamlCommand;
    private readonly AsyncRelayCommand _copyYamlsToPlayersCommand;
    private readonly RelayCommand _openApRootFolderCommand;
    private readonly RelayCommand _openPlayersFolderCommand;
    private readonly RelayCommand _openOutputFolderCommand;
    private readonly RelayCommand _openUploadsPageCommand;
    private readonly AsyncRelayCommand _refreshCommand;
    private readonly RelayCommand _copySummaryCommand;
    private readonly AsyncRelayCommand _continueToJoinCommand;

    private ArchipelagoInstallInspection _inspection = new();
    private ArchipelagoInstallationService.InstalledWorldsCatalog? _worldsCatalog;
    private string _worldsCatalogKey = string.Empty;
    private string _bundledWorldVersion = string.Empty;
    private PendingSessionDraft? _draft;
    private bool _isRestoring;
    private CancellationTokenSource? _refreshCancellationSource;
    private CancellationTokenSource? _draftSaveCancellationSource;

    private string _apInstallPath = string.Empty;
    private string _apInstallStatusText = "Looking for an Archipelago install...";
    private string _apVersionNoteText = string.Empty;
    private string _apworldVersionText = string.Empty;
    private string _apworldStatusText = string.Empty;
    private string _yamlPanelStatusText = "No settings files collected yet.";
    private string _playersFolderWarningText = string.Empty;
    private string _outputStatusText = string.Empty;
    private string _roomAddress = string.Empty;
    private string _roomUrl = string.Empty;
    private string _playersRecapText = string.Empty;
    private bool _step1Done;
    private bool _step2Done;
    private bool _step3Done;
    private bool _step4Done;
    private bool _step6Done;
    private bool _showAddMyOwnYaml;
    private ICommand? _backToLandingCommand;
    // Wizard layer (Cam 2026-07-12: one step per screen, Next gated on the
    // step's auto-detected Done). Wizard step numbers are 1..7 and are NOT
    // the same as the StepNDone flag names (the own-YAML step was inserted
    // as wizard step 3, and upload + create-room merged into one step per
    // Cam 2026-07-20): 1->Step1Done, 2->Step2Done, 3->OwnYamlReady,
    // 4->Step3Done (collect), 5->Step4Done (generate), 6->Step6Done
    // (upload + create room + paste address), 7 last (send friends).
    private int _currentStepNumber = 1;
    private bool _ownYamlReady;
    private string _ownYamlStatusText = "Not configured yet.";
    private readonly RelayCommand _backStepCommand;
    private readonly RelayCommand _nextStepCommand;
    private readonly RelayCommand _configureOwnYamlCommand;

    public GenerationGuidanceViewModel(
        IUiDialogService dialogService,
        ActionViewModel action,
        PendingSessionDraftStore draftStore,
        YamlInspectionService yamlInspection,
        ArchipelagoInstallationService apService)
    {
        _dialogService = dialogService ?? throw new ArgumentNullException(nameof(dialogService));
        _action = action ?? throw new ArgumentNullException(nameof(action));
        _draftStore = draftStore ?? throw new ArgumentNullException(nameof(draftStore));
        _yamlInspection = yamlInspection ?? throw new ArgumentNullException(nameof(yamlInspection));
        _apService = apService ?? throw new ArgumentNullException(nameof(apService));

        _browseApFolderCommand = new AsyncRelayCommand(BrowseApFolderAsync);
        _openApReleasePageCommand = new RelayCommand(() => OpenUrl(ArchipelagoInstallationService.ApReleasePageUrl));
        _copyApworldCommand = new AsyncRelayCommand(CopyApworldAsync, () => _inspection.IsUsable);
        _addYamlsCommand = new AsyncRelayCommand(AddYamlsAsync);
        _addMyOwnYamlCommand = new AsyncRelayCommand(AddMyOwnYamlAsync, () => ShowAddMyOwnYaml);
        _copyYamlsToPlayersCommand = new AsyncRelayCommand(CopyYamlsToPlayersAsync, () => _inspection.IsUsable && CollectedYamls.Count > 0);
        _openApRootFolderCommand = new RelayCommand(() => OpenFolder(_inspection.RootPath), () => _inspection.IsUsable);
        _openPlayersFolderCommand = new RelayCommand(
            () => OpenFolder(ArchipelagoInstallationService.GetPlayersPath(_inspection.RootPath), createFirst: true),
            () => _inspection.IsUsable);
        _openOutputFolderCommand = new RelayCommand(
            () => OpenFolder(ArchipelagoInstallationService.GetOutputPath(_inspection.RootPath), createFirst: true),
            () => _inspection.IsUsable);
        _openUploadsPageCommand = new RelayCommand(() => OpenUrl(ArchipelagoInstallationService.UploadsPageUrl));
        _refreshCommand = new AsyncRelayCommand(() => RefreshAllAsync());
        _copySummaryCommand = new RelayCommand(CopySummaryForFriends, () => Step6Done);
        _continueToJoinCommand = new AsyncRelayCommand(ContinueToJoinAsync, () => Step6Done);
        _backStepCommand = new RelayCommand(
            () => CurrentStepNumber = Math.Max(1, CurrentStepNumber - 1),
            () => CurrentStepNumber > 1);
        _nextStepCommand = new RelayCommand(
            () => CurrentStepNumber = Math.Min(TotalSteps, CurrentStepNumber + 1),
            () => CurrentStepNumber < TotalSteps && CanAdvanceFromCurrentStep());
        _configureOwnYamlCommand = new RelayCommand(() => ConfigureYamlRequested?.Invoke());

        BrowseApFolderCommand = _browseApFolderCommand;
        OpenApReleasePageCommand = _openApReleasePageCommand;
        CopyApworldCommand = _copyApworldCommand;
        AddYamlsCommand = _addYamlsCommand;
        AddMyOwnYamlCommand = _addMyOwnYamlCommand;
        CopyYamlsToPlayersCommand = _copyYamlsToPlayersCommand;
        OpenApRootFolderCommand = _openApRootFolderCommand;
        OpenPlayersFolderCommand = _openPlayersFolderCommand;
        OpenOutputFolderCommand = _openOutputFolderCommand;
        OpenUploadsPageCommand = _openUploadsPageCommand;
        RefreshCommand = _refreshCommand;
        CopySummaryCommand = _copySummaryCommand;
        ContinueToJoinCommand = _continueToJoinCommand;
    }

    /// <summary>Raised after the room details are saved; the shell prefills Session and opens Join.</summary>
    public event Action? JoinRoomRequested;

    /// <summary>Raised by wizard step 3; the shell opens Configure Your YAML with a return path here.</summary>
    public event Action? ConfigureYamlRequested;

    public const int TotalSteps = 7;

    public int CurrentStepNumber
    {
        get => _currentStepNumber;
        private set
        {
            var clamped = Math.Clamp(value, 1, TotalSteps);
            if (!SetProperty(ref _currentStepNumber, clamped))
            {
                return;
            }

            OnPropertyChanged(nameof(StepProgressText));
            OnPropertyChanged(nameof(IsStep1Visible));
            OnPropertyChanged(nameof(IsStep2Visible));
            OnPropertyChanged(nameof(IsStep3Visible));
            OnPropertyChanged(nameof(IsStep4Visible));
            OnPropertyChanged(nameof(IsStep5Visible));
            OnPropertyChanged(nameof(IsStep6Visible));
            OnPropertyChanged(nameof(IsStep7Visible));
            RefreshWizardCommands();
            if (!_isRestoring)
            {
                _ = SaveDraftAsync();
            }
        }
    }

    public string StepProgressText => $"Step {CurrentStepNumber} of {TotalSteps}";

    public bool IsStep1Visible => CurrentStepNumber == 1;
    public bool IsStep2Visible => CurrentStepNumber == 2;
    public bool IsStep3Visible => CurrentStepNumber == 3;
    public bool IsStep4Visible => CurrentStepNumber == 4;
    public bool IsStep5Visible => CurrentStepNumber == 5;
    public bool IsStep6Visible => CurrentStepNumber == 6;
    public bool IsStep7Visible => CurrentStepNumber == 7;

    public bool OwnYamlReady
    {
        get => _ownYamlReady;
        private set
        {
            if (SetProperty(ref _ownYamlReady, value))
            {
                RefreshWizardCommands();
            }
        }
    }

    public string OwnYamlStatusText
    {
        get => _ownYamlStatusText;
        private set => SetProperty(ref _ownYamlStatusText, value);
    }

    public ICommand BackStepCommand => _backStepCommand;

    public ICommand NextStepCommand => _nextStepCommand;

    public ICommand ConfigureOwnYamlCommand => _configureOwnYamlCommand;

    private bool CanAdvanceFromCurrentStep() => CurrentStepNumber switch
    {
        1 => Step1Done,
        2 => Step2Done,
        3 => OwnYamlReady,
        4 => Step3Done,
        5 => Step4Done,
        // The upload itself has no observable artifact; the pasted room
        // address is the proof the whole upload + create-room step happened.
        6 => Step6Done,
        _ => false,
    };

    private void RefreshWizardCommands()
    {
        _backStepCommand.NotifyCanExecuteChanged();
        _nextStepCommand.NotifyCanExecuteChanged();
    }

    /// <summary>Raised after any draft save so the shell can refresh the landing strip.</summary>
    public event Action? DraftSaved;

    public ObservableCollection<CollectedYamlViewModel> CollectedYamls { get; } = new();

    public string ApVersionPin => ArchipelagoInstallationService.ApVersionPin;

    public ICommand BrowseApFolderCommand { get; }

    public ICommand OpenApReleasePageCommand { get; }

    public ICommand CopyApworldCommand { get; }

    public ICommand AddYamlsCommand { get; }

    public ICommand AddMyOwnYamlCommand { get; }

    public ICommand CopyYamlsToPlayersCommand { get; }

    public ICommand OpenApRootFolderCommand { get; }

    public ICommand OpenPlayersFolderCommand { get; }

    public ICommand OpenOutputFolderCommand { get; }

    public ICommand OpenUploadsPageCommand { get; }

    public ICommand RefreshCommand { get; }

    public ICommand CopySummaryCommand { get; }

    public ICommand ContinueToJoinCommand { get; }

    public ICommand? BackToLandingCommand
    {
        get => _backToLandingCommand;
        set => SetProperty(ref _backToLandingCommand, value);
    }

    public string ApInstallPath
    {
        get => _apInstallPath;
        set
        {
            if (SetProperty(ref _apInstallPath, value) && !_isRestoring)
            {
                QueueDraftSave();
                _ = RefreshAllAsync();
            }
        }
    }

    public string ApInstallStatusText
    {
        get => _apInstallStatusText;
        private set => SetProperty(ref _apInstallStatusText, value);
    }

    public string ApVersionNoteText
    {
        get => _apVersionNoteText;
        private set
        {
            if (SetProperty(ref _apVersionNoteText, value))
            {
                OnPropertyChanged(nameof(HasApVersionNote));
            }
        }
    }

    public bool HasApVersionNote => !string.IsNullOrWhiteSpace(ApVersionNoteText);

    public string ApworldVersionText
    {
        get => _apworldVersionText;
        private set => SetProperty(ref _apworldVersionText, value);
    }

    public string ApworldStatusText
    {
        get => _apworldStatusText;
        private set => SetProperty(ref _apworldStatusText, value);
    }

    public string YamlPanelStatusText
    {
        get => _yamlPanelStatusText;
        private set => SetProperty(ref _yamlPanelStatusText, value);
    }

    public string PlayersFolderWarningText
    {
        get => _playersFolderWarningText;
        private set
        {
            if (SetProperty(ref _playersFolderWarningText, value))
            {
                OnPropertyChanged(nameof(HasPlayersFolderWarning));
            }
        }
    }

    public bool HasPlayersFolderWarning => !string.IsNullOrWhiteSpace(PlayersFolderWarningText);

    public string OutputStatusText
    {
        get => _outputStatusText;
        private set => SetProperty(ref _outputStatusText, value);
    }

    public string RoomAddress
    {
        get => _roomAddress;
        set
        {
            if (SetProperty(ref _roomAddress, value))
            {
                RecomputeRoomSteps();
                if (!_isRestoring)
                {
                    QueueDraftSave();
                }
            }
        }
    }

    public string RoomUrl
    {
        get => _roomUrl;
        set
        {
            if (SetProperty(ref _roomUrl, value) && !_isRestoring)
            {
                QueueDraftSave();
            }
        }
    }

    public string PlayersRecapText
    {
        get => _playersRecapText;
        private set => SetProperty(ref _playersRecapText, value);
    }

    public bool Step1Done
    {
        get => _step1Done;
        private set
        {
            if (SetProperty(ref _step1Done, value))
            {
                RefreshWizardCommands();
            }
        }
    }

    public bool Step2Done
    {
        get => _step2Done;
        private set
        {
            if (SetProperty(ref _step2Done, value))
            {
                RefreshWizardCommands();
            }
        }
    }

    public bool Step3Done
    {
        get => _step3Done;
        private set
        {
            if (SetProperty(ref _step3Done, value))
            {
                RefreshWizardCommands();
            }
        }
    }

    public bool Step4Done
    {
        get => _step4Done;
        private set
        {
            if (SetProperty(ref _step4Done, value))
            {
                RefreshWizardCommands();
            }
        }
    }

    public bool Step6Done
    {
        get => _step6Done;
        private set
        {
            if (SetProperty(ref _step6Done, value))
            {
                OnPropertyChanged(nameof(Step7Done));
                RefreshWizardCommands();
            }
        }
    }

    /// <summary>Send-to-friends has no observable file state; the pasted room address is the proof.</summary>
    public bool Step7Done => Step6Done;

    public bool ShowAddMyOwnYaml
    {
        get => _showAddMyOwnYaml;
        private set
        {
            if (SetProperty(ref _showAddMyOwnYaml, value))
            {
                _addMyOwnYamlCommand.NotifyCanExecuteChanged();
            }
        }
    }

    /// <summary>
    /// Called every time the screen is opened: restores the persisted
    /// checklist (or starts fresh with auto-detection) and re-derives every
    /// step state from what is actually on disk.
    /// </summary>
    public async Task EnterAsync()
    {
        _isRestoring = true;
        try
        {
            _draft = await _draftStore.TryLoadAsync();

            CollectedYamls.Clear();
            if (_draft is not null)
            {
                foreach (var entry in _draft.CollectedYamls)
                {
                    if (!File.Exists(entry.CachePath))
                    {
                        _action.AppendLog($"Skipping the collected settings file {entry.FileName}: its cached copy is gone.");
                        continue;
                    }

                    CollectedYamls.Add(new CollectedYamlViewModel(entry.FileName, entry.CachePath, entry.SourcePath, RemoveYaml));
                }

                if (!string.IsNullOrWhiteSpace(_draft.ApInstallPath))
                {
                    _apInstallPath = _draft.ApInstallPath;
                    OnPropertyChanged(nameof(ApInstallPath));
                }

                _roomAddress = _draft.RoomAddress;
                OnPropertyChanged(nameof(RoomAddress));
                _roomUrl = _draft.RoomUrl;
                OnPropertyChanged(nameof(RoomUrl));
                // Resume the wizard where the organizer left off (0 = legacy
                // draft from before the wizard; start at step 1). Drafts saved
                // before the upload/create-room merge counted 8 steps, so a
                // saved step can point past today's last step.
                CurrentStepNumber = RestoreStepNumber(_draft.GuidanceStep, _draft.RoomAddress);
            }

            if (string.IsNullOrWhiteSpace(_apInstallPath))
            {
                var detected = _apService.TryDetectDefaultInstall();
                if (detected is not null)
                {
                    _apInstallPath = detected.RootPath;
                    OnPropertyChanged(nameof(ApInstallPath));
                    _action.AppendLog($"Detected an existing Archipelago install at {detected.RootPath}.");
                }
            }

            RecomputeRoomSteps();
        }
        finally
        {
            _isRestoring = false;
        }

        await RefreshAllAsync();
    }

    private async Task BrowseApFolderAsync()
    {
        var initial = Directory.Exists(ApInstallPath) ? ApInstallPath : ArchipelagoInstallationService.DefaultInstallPath;
        var chosen = await _dialogService.BrowseForFolderAsync(initial);
        if (string.IsNullOrWhiteSpace(chosen))
        {
            return;
        }

        var inspection = _apService.Inspect(chosen);
        if (!inspection.GeneratorFound)
        {
            _action.ErrorMessage =
                $"That folder doesn't contain a supported Archipelago generator ({string.Join(", ", ArchipelagoInstallationService.GeneratorFileNames)}). "
                + "Pick the folder where Archipelago is installed.";
            return;
        }

        ApInstallPath = chosen;
        _action.AppendLog($"Using the Archipelago install at {chosen}.");
        await SaveDraftAsync();
    }

    private async Task CopyApworldAsync()
    {
        try
        {
            var destination = await _apService.CopyApworldAsync(_inspection.RootPath);
            _action.AppendLog($"Copied RE4R.apworld into {destination}.");
            await SaveDraftAsync();
        }
        catch (Exception ex)
        {
            ReportActionFailure($"Failed to copy RE4R.apworld into your Archipelago folder: {ex.Message}");
        }

        await RefreshAllAsync();
    }

    private async Task AddYamlsAsync()
    {
        var files = await _dialogService.BrowseForFilesAsync(
            "Add your friends' settings files (YAML)",
            "YAML settings files|*.yaml;*.yml|All files|*.*",
            multiSelect: true);
        if (files.Count == 0)
        {
            return;
        }

        foreach (var file in files)
        {
            try
            {
                var (cachePath, fileName, isDuplicate) = await _apService.CacheCollectedYamlAsync(file);
                if (isDuplicate && CollectedYamls.Any(row => string.Equals(row.CachePath, cachePath, StringComparison.OrdinalIgnoreCase)))
                {
                    _action.AppendLog($"Skipped {Path.GetFileName(file)}: an identical settings file is already collected.");
                    continue;
                }

                CollectedYamls.Add(new CollectedYamlViewModel(fileName, cachePath, file, RemoveYaml));
                _action.AppendLog($"Collected the settings file {fileName}.");
            }
            catch (Exception ex)
            {
                ReportActionFailure($"Could not add {Path.GetFileName(file)}: {ex.Message}");
            }
        }

        await SaveDraftAsync();
        await RefreshAllAsync();
    }

    private async Task AddMyOwnYamlAsync()
    {
        var draft = _draft;
        if (draft is null || string.IsNullOrWhiteSpace(draft.YamlText) || string.IsNullOrWhiteSpace(draft.SlotName))
        {
            return;
        }

        try
        {
            var fileName = $"RE4R_{draft.SlotName}.yaml";
            var (cachePath, cachedName) = await _apService.CacheYamlTextAsync(fileName, draft.YamlText);
            var existing = CollectedYamls.FirstOrDefault(row => string.Equals(row.CachePath, cachePath, StringComparison.OrdinalIgnoreCase));
            if (existing is null)
            {
                CollectedYamls.Add(new CollectedYamlViewModel(cachedName, cachePath, "(from Configure Your YAML)", RemoveYaml));
            }

            _action.AppendLog($"Added your own settings file ({cachedName}) from Configure Your YAML.");
            await SaveDraftAsync();
        }
        catch (Exception ex)
        {
            ReportActionFailure($"Could not add your own settings file: {ex.Message}");
        }

        await RefreshAllAsync();
    }

    private void RemoveYaml(CollectedYamlViewModel row)
    {
        CollectedYamls.Remove(row);
        try
        {
            _apService.RemoveCachedYaml(row.CachePath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _action.AppendLog($"Could not delete the cached copy of {row.FileName}: {ex.Message}");
        }

        _action.AppendLog($"Removed the settings file {row.FileName} from the collection.");
        _ = SaveDraftAsync();
        _ = RefreshAllAsync();
    }

    private async Task CopyYamlsToPlayersAsync()
    {
        try
        {
            var entries = BuildDraftEntries();
            var copied = await _apService.CopyCachedYamlsToPlayersAsync(entries, _inspection.RootPath);
            _action.AppendLog($"Copied {copied} settings file(s) into {ArchipelagoInstallationService.GetPlayersPath(_inspection.RootPath)}.");
            await SaveDraftAsync();
        }
        catch (Exception ex)
        {
            ReportActionFailure($"Failed to copy the settings files into the Players folder: {ex.Message}");
        }

        await RefreshAllAsync();
    }

    private void CopySummaryForFriends()
    {
        try
        {
            var lines = new List<string> { $"Room address: {RoomAddress.Trim()}" };
            if (!string.IsNullOrWhiteSpace(RoomUrl))
            {
                lines.Add($"Room page: {RoomUrl.Trim()}");
            }

            var parsedRows = CollectedYamls.Where(row => row.IsParsed).ToList();
            if (parsedRows.Count > 0)
            {
                lines.Add("Slot names (must match exactly, including capitals):");
                lines.AddRange(parsedRows.Select(row => $"- {row.PlayerName} ({row.GameName})"));
            }

            _ = CopySummaryTextAsync(string.Join(Environment.NewLine, lines));
            _action.AppendLog("Copied the room summary for your friends to the clipboard.");
        }
        catch (Exception ex)
        {
            ReportActionFailure(
                "Could not copy to the clipboard - another program may be using it. "
                    + $"Try again in a moment. ({ex.Message})");
        }
    }

    private async Task CopySummaryTextAsync(string text)
    {
        try
        {
            await _dialogService.SetClipboardTextAsync(text);
        }
        catch (Exception ex)
        {
            ReportActionFailure(
                "Could not copy to the clipboard - another program may be using it. "
                    + $"Try again in a moment. ({ex.Message})");
        }
    }

    private async Task ContinueToJoinAsync()
    {
        await SaveDraftAsync();
        _action.AppendLog($"Room details saved. Handing {RoomAddress.Trim()} to the Join screen.");
        JoinRoomRequested?.Invoke();
    }

    private async Task RefreshAllAsync()
    {
        _refreshCancellationSource?.Cancel();
        _refreshCancellationSource?.Dispose();
        _refreshCancellationSource = new CancellationTokenSource();
        var token = _refreshCancellationSource.Token;

        _inspection = _apService.Inspect(ApInstallPath);
        RefreshStep1Texts();
        RefreshCommandStates();

        if (string.IsNullOrWhiteSpace(_bundledWorldVersion))
        {
            _bundledWorldVersion = await _apService.ReadApworldWorldVersionAsync(_apService.ApworldSourcePath, token);
        }

        ApworldVersionText = string.IsNullOrWhiteSpace(_bundledWorldVersion)
            ? "The launcher ships RE4R.apworld for your Archipelago install."
            : $"The launcher ships RE4R.apworld version {_bundledWorldVersion}.";

        if (!_inspection.IsUsable)
        {
            Step2Done = false;
            Step3Done = false;
            Step4Done = false;
            ApworldStatusText = "Waiting for a valid Archipelago folder (step 1).";
            PlayersFolderWarningText = string.Empty;
            OutputStatusText = "Waiting for a valid Archipelago folder (step 1).";
            RefreshYamlPanelStatus(playersReady: false);
            RefreshRecapAndOwnYaml();
            return;
        }

        try
        {
            var copyState = await _apService.GetApworldCopyStateAsync(_inspection.RootPath, token);
            if (token.IsCancellationRequested)
            {
                return;
            }

            Step2Done = copyState == ArchipelagoInstallationService.ApworldCopyState.UpToDate;
            ApworldStatusText = copyState switch
            {
                ArchipelagoInstallationService.ApworldCopyState.UpToDate =>
                    $"RE4R.apworld is in {ArchipelagoInstallationService.GetCustomWorldsPath(_inspection.RootPath)} and up to date.",
                ArchipelagoInstallationService.ApworldCopyState.Outdated =>
                    "A DIFFERENT RE4R.apworld is in custom_worlds - copy again to replace it with this launcher's version.",
                _ => "Not copied yet.",
            };

            await EnsureRowsParsedAsync();
            await RefreshWorldsCatalogAsync(token);
            var playersState = await _apService.CheckPlayersFolderAsync(BuildDraftEntries(), _inspection.RootPath, token);
            if (token.IsCancellationRequested)
            {
                return;
            }

            ApplyWorldFlagsToRows();
            RefreshYamlPanelStatus(playersState.AllCollectedPresent);
            Step3Done = CollectedYamls.Count > 0
                && CollectedYamls.All(row => row.IsParsed)
                && playersState.AllCollectedPresent;
            PlayersFolderWarningText = playersState.ExtraYamlNames.Count == 0
                ? string.Empty
                : $"The Players folder also contains {playersState.ExtraYamlNames.Count} other settings file(s) "
                    + $"({string.Join(", ", playersState.ExtraYamlNames.Take(4))}{(playersState.ExtraYamlNames.Count > 4 ? ", ..." : string.Empty)}). "
                    + "ArchipelagoGenerate uses EVERY file in that folder - remove the ones that don't belong to this multiworld.";

            var newestZip = _apService.FindNewestOutputZip(_inspection.RootPath);
            Step4Done = newestZip is not null;
            if (newestZip is null)
            {
                OutputStatusText = "No AP_*.zip in the output folder yet - run ArchipelagoGenerate, then click Check Again.";
            }
            else
            {
                var age = DateTime.UtcNow - newestZip.LastWriteTimeUtc;
                var ageText = age.TotalMinutes < 60
                    ? $"{Math.Max(0, (int)age.TotalMinutes)} minute(s) ago"
                    : age.TotalHours < 48
                        ? $"{(int)age.TotalHours} hour(s) ago"
                        : $"{(int)age.TotalDays} day(s) ago";
                OutputStatusText = $"Found {newestZip.Name} (created {ageText}).";
                if (age.TotalHours >= 1)
                {
                    OutputStatusText += " Make sure this is YOUR new multiworld and not an older one - regenerate if unsure.";
                }
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex)
        {
            _action.AppendLog($"Could not refresh the guidance checklist: {ex.Message}");
        }

        RefreshRecapAndOwnYaml();
        RefreshCommandStates();
    }

    private void RefreshStep1Texts()
    {
        if (string.IsNullOrWhiteSpace(ApInstallPath))
        {
            Step1Done = false;
            ApInstallStatusText =
                $"No Archipelago install found at {ArchipelagoInstallationService.DefaultInstallPath}. "
                + $"Install Archipelago {ApVersionPin} from the release page, or Browse to an existing install.";
            ApVersionNoteText = string.Empty;
            return;
        }

        if (!_inspection.RootExists)
        {
            Step1Done = false;
            ApInstallStatusText = $"The folder {ApInstallPath} does not exist.";
            ApVersionNoteText = string.Empty;
            return;
        }

        if (!_inspection.GeneratorFound)
        {
            Step1Done = false;
            ApInstallStatusText =
                $"{ApInstallPath} exists but has no supported Archipelago generator - it isn't a full Archipelago install.";
            ApVersionNoteText = string.Empty;
            return;
        }

        Step1Done = true;
        if (_inspection.HasVersion && _inspection.MatchesVersionPin)
        {
            ApInstallStatusText = $"Archipelago {_inspection.DetectedVersion} found at {ApInstallPath}.";
            ApVersionNoteText = string.Empty;
        }
        else if (_inspection.HasVersion)
        {
            ApInstallStatusText = $"Archipelago {_inspection.DetectedVersion} found at {ApInstallPath}.";
            ApVersionNoteText =
                $"This launcher targets Archipelago {ApVersionPin} - newer versions may not work with RE4R. "
                + $"If generation fails or the RE4R world refuses to load, install {ApVersionPin} from the release page.";
        }
        else
        {
            ApInstallStatusText = $"Archipelago found at {ApInstallPath}.";
            ApVersionNoteText =
                $"Couldn't read its version - make sure it is Archipelago {ApVersionPin} (newer versions may not work with RE4R).";
        }
    }

    private async Task RefreshWorldsCatalogAsync(CancellationToken cancellationToken)
    {
        var customWorlds = ArchipelagoInstallationService.GetCustomWorldsPath(_inspection.RootPath);
        var libWorlds = Path.Combine(_inspection.RootPath, "lib", "worlds");
        var key = $"{_inspection.RootPath}|{SafeLastWrite(customWorlds)}|{SafeLastWrite(libWorlds)}";
        if (_worldsCatalog is not null && string.Equals(key, _worldsCatalogKey, StringComparison.Ordinal))
        {
            return;
        }

        _worldsCatalog = await _apService.LoadInstalledWorldsCatalogAsync(_inspection.RootPath, cancellationToken);
        _worldsCatalogKey = key;

        static string SafeLastWrite(string path)
        {
            try
            {
                return Directory.Exists(path) ? Directory.GetLastWriteTimeUtc(path).Ticks.ToString() : "none";
            }
            catch (Exception)
            {
                return "none";
            }
        }
    }

    private async Task EnsureRowsParsedAsync()
    {
        foreach (var row in CollectedYamls.Where(row => !row.ParseAttempted).ToList())
        {
            row.ParseAttempted = true;
            try
            {
                var info = await _yamlInspection.ReadPlayerYamlAsync(row.CachePath);
                row.PlayerName = info.PlayerName;
                row.GameName = info.GameName;
                row.IsParsed = true;
                row.IssueText = string.Empty;
            }
            catch (Exception ex)
            {
                row.IsParsed = false;
                row.IssueText = $"Couldn't read this settings file: {FirstLine(ex.Message)}Ask the player to re-export it.";
            }
        }
    }

    private void ApplyWorldFlagsToRows()
    {
        foreach (var row in CollectedYamls)
        {
            ApplyWorldFlag(row);
        }
    }

    private void ApplyWorldFlag(CollectedYamlViewModel row)
    {
        if (!row.IsParsed || _worldsCatalog is null)
        {
            return;
        }

        row.IssueText = ArchipelagoInstallationService.IsGameSatisfied(_worldsCatalog, row.GameName)
            ? string.Empty
            : $"No installed world found for '{row.GameName}' - generation will fail unless its .apworld is added to your Archipelago (custom_worlds).";
    }

    private void RefreshYamlPanelStatus(bool playersReady)
    {
        if (CollectedYamls.Count == 0)
        {
            YamlPanelStatusText = "No settings files collected yet. Every player sends you one - yours comes from Configure Your YAML.";
            return;
        }

        var unparsed = CollectedYamls.Count(row => !row.IsParsed);
        var summary = $"{CollectedYamls.Count} settings file(s) collected";
        if (unparsed > 0)
        {
            summary += $", {unparsed} unreadable";
        }

        summary += playersReady
            ? ". All of them are in the Players folder."
            : ". Copy them into the Players folder when the list is complete.";
        YamlPanelStatusText = summary;
    }

    private void RefreshRecapAndOwnYaml()
    {
        var parsedRows = CollectedYamls.Where(row => row.IsParsed).ToList();
        PlayersRecapText = parsedRows.Count == 0
            ? "Collect settings files in step 3 to see each player's slot name here."
            : string.Join(
                Environment.NewLine,
                parsedRows.Select(row => $"• {row.PlayerName} - {row.GameName}"));

        var draft = _draft;
        ShowAddMyOwnYaml = draft is not null
            && !string.IsNullOrWhiteSpace(draft.YamlText)
            && !string.IsNullOrWhiteSpace(draft.SlotName)
            && !CollectedYamls.Any(row =>
                row.IsParsed && string.Equals(row.PlayerName, draft.SlotName, StringComparison.Ordinal));

        OwnYamlReady = draft is not null
            && !string.IsNullOrWhiteSpace(draft.YamlText)
            && !string.IsNullOrWhiteSpace(draft.SlotName);
        OwnYamlStatusText = OwnYamlReady && draft is not null
            ? $"Your settings file is ready for slot '{draft.SlotName}' (saved {draft.SavedAtUtc.ToLocalTime():yyyy-MM-dd HH:mm})."
            : "Not configured yet - your own settings file is required before collecting everyone else's.";
    }

    /// <summary>
    /// Maps a persisted wizard position onto today's step list. Anything past
    /// the merged upload/create-room step falls back to it until a room
    /// address exists - that address is the only proof the step happened.
    /// </summary>
    private static int RestoreStepNumber(int savedStep, string roomAddress)
    {
        if (savedStep <= 0)
        {
            return 1;
        }

        var step = Math.Min(savedStep, TotalSteps);
        return step >= 6 && string.IsNullOrWhiteSpace(roomAddress) ? 6 : step;
    }

    private void RecomputeRoomSteps()
    {
        Step6Done = !string.IsNullOrWhiteSpace(RoomAddress);
        _copySummaryCommand.NotifyCanExecuteChanged();
        _continueToJoinCommand.NotifyCanExecuteChanged();
    }

    private List<CollectedYamlDraftEntry> BuildDraftEntries()
    {
        var previous = _draft?.CollectedYamls ?? new List<CollectedYamlDraftEntry>();
        return CollectedYamls
            .Select(row =>
            {
                var existing = previous.FirstOrDefault(entry =>
                    string.Equals(entry.CachePath, row.CachePath, StringComparison.OrdinalIgnoreCase));
                return new CollectedYamlDraftEntry
                {
                    FileName = row.FileName,
                    CachePath = row.CachePath,
                    SourcePath = row.SourcePath,
                    AddedAtUtc = existing?.AddedAtUtc ?? DateTimeOffset.UtcNow,
                };
            })
            .ToList();
    }

    private void QueueDraftSave()
    {
        _draftSaveCancellationSource?.Cancel();
        _draftSaveCancellationSource?.Dispose();
        _draftSaveCancellationSource = new CancellationTokenSource();
        var token = _draftSaveCancellationSource.Token;
        _ = Task.Run(
            async () =>
            {
                try
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(700), token);
                    // Back onto the dispatcher: SaveDraftAsync snapshots the
                    // CollectedYamls collection, which belongs to the UI thread.
                    await _dialogService.InvokeOnUiThreadAsync(SaveDraftAsync);
                }
                catch (OperationCanceledException)
                {
                }
            },
            CancellationToken.None);
    }

    private async Task SaveDraftAsync()
    {
        try
        {
            var entries = BuildDraftEntries();
            _draft = await _draftStore.UpdateAsync(draft =>
            {
                draft.Role = PendingSessionDraft.OrganizerRole;
                draft.ApInstallPath = ApInstallPath.Trim();
                draft.CollectedYamls = entries;
                draft.RoomAddress = RoomAddress.Trim();
                draft.RoomUrl = RoomUrl.Trim();
                draft.GuidanceStep = CurrentStepNumber;
            });
            DraftSaved?.Invoke();
        }
        catch (Exception ex)
        {
            _action.AppendLog($"Could not save your organizer progress: {ex.Message}");
        }
    }

    private void RefreshCommandStates()
    {
        _copyApworldCommand.NotifyCanExecuteChanged();
        _copyYamlsToPlayersCommand.NotifyCanExecuteChanged();
        _openApRootFolderCommand.NotifyCanExecuteChanged();
        _openPlayersFolderCommand.NotifyCanExecuteChanged();
        _openOutputFolderCommand.NotifyCanExecuteChanged();
        _copySummaryCommand.NotifyCanExecuteChanged();
        _continueToJoinCommand.NotifyCanExecuteChanged();
    }

    private void OpenFolder(string path, bool createFirst = false)
    {
        try
        {
            if (createFirst)
            {
                Directory.CreateDirectory(path);
            }

            _ = _dialogService.OpenFolderAsync(path);
            _action.AppendLog($"Opened {path}.");
        }
        catch (Exception ex)
        {
            ReportActionFailure($"Failed to open {path}: {ex.Message}");
        }
    }

    private void OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            _action.AppendLog($"Opened {url} in your browser.");
        }
        catch (Exception ex)
        {
            ReportActionFailure($"Failed to open {url} in your browser: {ex.Message}");
        }
    }

    private void ReportActionFailure(string message)
    {
        _action.AppendLog(message);
        _action.ErrorMessage = message;
    }

    private static string FirstLine(string message)
    {
        var newlineIndex = message.IndexOfAny(['\r', '\n']);
        var line = newlineIndex >= 0 ? message[..newlineIndex] : message;
        return line.EndsWith('.') ? line + " " : line + ". ";
    }
}
