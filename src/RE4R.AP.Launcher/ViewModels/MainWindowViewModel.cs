using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Text.Json;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using RE4R.AP.Launcher.Core.Utilities;
using RE4R.AP.Launcher.Infrastructure;
using RE4R.AP.Launcher.Models;
using RE4R.AP.Launcher.Services;

namespace RE4R.AP.Launcher.ViewModels;

public sealed class MainWindowViewModel : ObservableObject, IDisposable
{
    private readonly IUiDialogService _dialogService;
    private readonly SettingsStore _settingsStore;
    private readonly SessionRecordStore _sessionRecordStore;
    private readonly BugReportService _bugReportService;
    private readonly StaticGameDataProvider _staticGameDataProvider;
    private readonly LaunchWorkflowService _workflowService;
    private readonly GameInstallationInspector _gameInstallationInspector;
    private readonly ReFrameworkInstallationService _reFrameworkInstallationService;
    private readonly LuaInstallService _luaInstallService;
    private readonly LauncherUpdateService _updateService = new();
    private readonly AsyncRelayCommand _browseCommand;
    private readonly AsyncRelayCommand _installReFrameworkCommand;
    private readonly AsyncRelayCommand _installArchipelagoLuaModCommand;
    private readonly RelayCommand _dismissErrorCommand;
    private readonly RelayCommand _openLogFolderCommand;
    private readonly RelayCommand _showCreateGuidanceCommand;
    private readonly RelayCommand _startJoinFlowCommand;
    private readonly RelayCommand _startConfigureYamlCommand;
    private readonly AsyncRelayCommand _continueFromConfigureYamlCommand;
    private readonly AsyncRelayCommand _organizerContinueFromConfigureYamlCommand;
    private readonly RelayCommand _returnToLandingCommand;
    private readonly AsyncRelayCommand _generateBugReportCommand;
    private readonly RelayCommand _openSetupCommand;
    private readonly RelayCommand _openRoomPageCommand;
    private readonly RelayCommand _openUpdateReleaseCommand;
    private readonly RelayCommand _dismissUpdateCommand;
    private readonly RelayCommand _reconnectPrefillCommand;
    private readonly RelayCommand _repatchPrefillCommand;
    private readonly AsyncRelayCommand _retireSessionCommand;
    private readonly AsyncRelayCommand _unlockBioRandOptionsCommand;
    private readonly RelayCommand _draftJoinCommand;
    private readonly AsyncRelayCommand _retryPatchCommand;
    private readonly AsyncRelayCommand _clearBioRandCacheCommand;
    private readonly AsyncRelayCommand _fixAddressCommand;
    private readonly RoomAddressHealService _roomAddressHealService;
    private readonly BioRandProcessRunner _cacheManager;
    private readonly PendingSessionDraftStore _draftStore;
    private SessionRecord? _bannerRecord;
    private PendingSessionDraft? _pendingDraft;
    private LaunchWorkflowRequest? _lastWorkflowRequest;
    private readonly System.Collections.Concurrent.ConcurrentQueue<string> _pendingWorkflowLogLines = new();
    private readonly Timer _workflowLogFlushTimer;

    private LauncherSettings _settings = LauncherSettings.CreateDefault();
    private StaticGameData? _staticData;
    private GameInstallationInspectionResult _inspection = GameInstallationInspectionResult.CreateDefault();
    private CancellationTokenSource? _installInspectionCancellationSource;
    private CancellationTokenSource? _sessionRefreshCancellationSource;
    private LauncherUpdateInfo? _updateInfo;
    private bool _hasUpdate;
    private string _updateBannerText = string.Empty;
    private bool _isInitializing;
    private bool _initialSetupRedirectDecided;
    private string _lastAutoDetectedGameVersion = string.Empty;
    private object? _currentScreen;

    public MainWindowViewModel(
        IUiDialogService dialogService,
        SettingsStore? settingsStore = null,
        SessionRecordStore? sessionRecordStore = null,
        StaticGameDataProvider? staticGameDataProvider = null,
        LaunchWorkflowService? workflowService = null,
        GameInstallationInspector? gameInstallationInspector = null,
        ReFrameworkInstallationService? reFrameworkInstallationService = null,
        LuaInstallService? luaInstallService = null)
    {
        _dialogService = dialogService ?? throw new ArgumentNullException(nameof(dialogService));
        _settingsStore = settingsStore ?? new SettingsStore();
        _sessionRecordStore = sessionRecordStore ?? new SessionRecordStore(_settingsStore.AppDataRootPath);
        _bugReportService = new BugReportService(_settingsStore.AppDataRootPath);
        _staticGameDataProvider = staticGameDataProvider ?? new StaticGameDataProvider();
        _workflowService = workflowService
            ?? new LaunchWorkflowService(
                settingsStore: _settingsStore,
                staticGameDataProvider: _staticGameDataProvider,
                sessionRecordStore: _sessionRecordStore);
        _gameInstallationInspector = gameInstallationInspector ?? new GameInstallationInspector();
        _reFrameworkInstallationService = reFrameworkInstallationService ?? new ReFrameworkInstallationService();
        _luaInstallService = luaInstallService ?? new LuaInstallService();
        // Dedicated runner instance purely for cache size/clear from the Setup
        // panel. Its cache methods are pure path operations (no process launch),
        // and sharing _settingsStore makes it resolve the exact same cache paths
        // as the workflow service's own runner.
        _cacheManager = new BioRandProcessRunner(settingsStore: _settingsStore);
        _cacheManager.LogMessage += OnWorkflowLogMessage;
        // Room probe + one-click address heal (archipelago.gg port churn).
        // Shares the settings/record stores so it resolves the same
        // ap_connection.json paths and session records as the workflow.
        _roomAddressHealService = new RoomAddressHealService(_settingsStore, _sessionRecordStore);
        _roomAddressHealService.LogMessage += OnWorkflowLogMessage;

        Setup = new SetupViewModel();
        Session = new SessionViewModel();
        BioRandOptions = new BioRandOptionsViewModel();
        Action = new ActionViewModel();
        Landing = new LandingViewModel();

        // Workflow log lines arrive per-line from worker threads at BioRand
        // flood rates (~74k lines during a full setup harvest). They are teed
        // to disk on the producer thread and drained here in one batched
        // LogText rebuild per tick, at Background priority so WPF input
        // always outranks log rendering (papercut #0: frozen Proceed/Cancel).
        _workflowLogFlushTimer = new Timer(
            _ => _ = _dialogService.InvokeOnUiThreadAsync(
                () =>
                {
                    OnWorkflowLogFlushTick();
                    return Task.CompletedTask;
                },
                UiThreadPriority.Background),
            null,
            TimeSpan.FromMilliseconds(200),
            TimeSpan.FromMilliseconds(200));
        _draftStore = new PendingSessionDraftStore(_settingsStore.AppDataRootPath);
        _draftStore.LogMessage += OnWorkflowLogMessage;
        ConfigureYaml = new ConfigureYamlViewModel(
            new Re4rYamlBuilder(),
            _dialogService,
            Action,
            _draftStore);
        ConfigureYaml.DraftSaved += OnDraftSaved;
        GenerationGuidance = new GenerationGuidanceViewModel(
            _dialogService,
            Action,
            _draftStore,
            new YamlInspectionService(),
            new ArchipelagoInstallationService(_settingsStore.AppDataRootPath));
        GenerationGuidance.DraftSaved += OnDraftSaved;
        GenerationGuidance.JoinRoomRequested += OnGuidanceJoinRoomRequested;
        GenerationGuidance.ConfigureYamlRequested += OnGuidanceConfigureYamlRequested;
        JoinFlow = new JoinFlowViewModel(Session, Action, BioRandOptions);
        PatchLaunch = new PatchLaunchViewModel(_workflowService, Action);

        foreach (var version in GameInstallationInspector.SupportedBioRandGameVersions)
        {
            Setup.SupportedGameVersions.Add(version);
        }

        Setup.SelectedGameVersion = Setup.SupportedGameVersions.Last();

        // No "Please select..." sentinel: all modes are visible buttons, the
        // unavailable ones disabled with a Coming Soon badge (plan fix #3).
        //
        // ALL THREE MODES ARE LIVE (2026-07-13). BioRand is gameplay-deterministic for a fixed
        // seed+config (measured - the placement-decision log is identical across runs), and AP
        // checks cannot be corrupted by item randomization (AP placements are written by explicit
        // id and merged last). Mode 3 was unblocked by fork 90140f0, which reconciled the ap-mode
        // purity gates per mode so modes 2/3 actually get the BioRand world their config asks for.
        //
        // Mode 3 caveat worth knowing: BioRand's door/shutter LOCKS stay disabled in every AP mode.
        // They add locks vanilla lacks, and AP's logic (rules.py) models vanilla progression with
        // no knowledge of them, so an added lock whose key AP placed behind it would softlock.
        // Everything else in mode 3 (enemies, events, extra merchants, traps, containers) applies.
        BioRandOptions.AvailableModes.Add(
            new LaunchModeOption
            {
                Key = "mode1",
                DisplayName = "AP Item Randomization Only",
                Description = "Fixed item pickups hold what the multiworld placed there - what you find is what you (or another player) get. Enemies, merchant, and drops stay vanilla.",
                IsAvailable = true,
            });
        BioRandOptions.AvailableModes.Add(
            new LaunchModeOption
            {
                Key = "mode2",
                DisplayName = "Full BioRand Item Randomization",
                Description = "Multiworld checks stay exactly where the multiworld put them; BioRand re-rolls every other world pickup. Enemies and the merchant stay vanilla.",
                IsAvailable = true,
            });
        BioRandOptions.AvailableModes.Add(
            new LaunchModeOption
            {
                Key = "mode3",
                DisplayName = "Full BioRand Item + Enemy Randomization",
                Description = "Everything in Full BioRand Item Randomization, plus randomized enemies, bosses, the merchant, extra merchants and random events.",
                IsAvailable = true,
            });
        BioRandOptions.SelectedMode = BioRandOptions.AvailableModes.First();

        _browseCommand = new AsyncRelayCommand(BrowseInstallPathAsync, () => !Action.IsBusy);
        _installReFrameworkCommand = new AsyncRelayCommand(InstallReFrameworkAsync, () => !Action.IsBusy);
        _installArchipelagoLuaModCommand = new AsyncRelayCommand(InstallArchipelagoLuaModAsync, () => !Action.IsBusy);
        // Always executable: the dismiss buttons are visibility-gated on
        // HasError, and a CanExecute gate goes stale for writers that set
        // Action.ErrorMessage without calling RefreshCommandStates.
        _dismissErrorCommand = new RelayCommand(DismissError);
        _openLogFolderCommand = new RelayCommand(OpenLogFolder);
        // Ungated like Configure: organizing happens on the player's own
        // Archipelago install, so the guidance must open even while the RE4R
        // setup checks are failing.
        _showCreateGuidanceCommand = new RelayCommand(ShowCreateGuidance);
        _startJoinFlowCommand = new RelayCommand(() => StartJoinFlow(showJoinerHandoff: true), () => !Landing.HasBlockingIssues);
        // Deliberately ungated: building a YAML settings file needs no game
        // install, no room, and no network, so it must work even while setup
        // checks are failing.
        _startConfigureYamlCommand = new RelayCommand(StartConfigureYaml);
        // A slot name is mandatory: it is the player's identity in the room,
        // and continuing without one strands them at connect.
        _continueFromConfigureYamlCommand = new AsyncRelayCommand(
            ContinueFromConfigureYamlAsync,
            () => ConfigureYaml.CanContinue);
        // The organizer's Continue: one press for what used to be
        // Back-then-Next (the host paid two presses for what a joiner did in
        // one). Same slot-name gate as the joiner path.
        _organizerContinueFromConfigureYamlCommand = new AsyncRelayCommand(
            ContinueOrganizerFromConfigureYamlAsync,
            () => ConfigureYaml.CanContinue);
        ConfigureYaml.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(ConfigureYamlViewModel.CanContinue))
            {
                _continueFromConfigureYamlCommand.NotifyCanExecuteChanged();
                _organizerContinueFromConfigureYamlCommand.NotifyCanExecuteChanged();
            }
        };
        _returnToLandingCommand = new RelayCommand(NavigateToLanding);
        _generateBugReportCommand = new AsyncRelayCommand(GenerateBugReportAsync, () => !Action.IsBusy);
        _openSetupCommand = new RelayCommand(OpenSetupScreen);
        _openRoomPageCommand = new RelayCommand(OpenRoomPage);
        _updateService.LogMessage += OnWorkflowLogMessage;
        _openUpdateReleaseCommand = new RelayCommand(OpenUpdateRelease);
        _dismissUpdateCommand = new RelayCommand(() => HasUpdate = false);
        _reconnectPrefillCommand = new RelayCommand(StartJoinPrefilledFromBanner);
        _repatchPrefillCommand = new RelayCommand(StartRepatchFromBanner);
        _retireSessionCommand = new AsyncRelayCommand(RetireBannerSessionAsync, () => !Action.IsBusy);
        _unlockBioRandOptionsCommand = new AsyncRelayCommand(UnlockBioRandOptionsAsync, () => !Action.IsBusy);
        BioRandOptions.UnlockCommand = _unlockBioRandOptionsCommand;
        // Switching bonus weapons on force-unlocks them on the player's RE4R
        // profile at connect (the game otherwise deletes un-bought bonus
        // weapons from the inventory on death or reload), so it asks first.
        // Three, not four: the Infinite Rocket Launcher can still be stocked,
        // but it is a normal merchant purchase with no Extra Content record,
        // so there is nothing to unlock for it.
        BioRandOptions.ConfirmBonusWeaponsUnlockAsync = () => _dialogService.ConfirmProceedWithWarningAsync(
            "Bonus Weapons Get Force-Unlocked",
            "This lets the merchant stock the bonus weapons: Primal Knife, Chicago Sweeper, "
            + "Handcannon and Infinite Rocket Launcher."
            + Environment.NewLine + Environment.NewLine
            + "The first three are Extra Content Shop weapons. If your RE4R profile does not have "
            + "them unlocked, connecting in-game will force-unlock them on your profile - "
            + "permanently, exactly as if you had bought them in the Extra Content Shop. Only "
            + "those three are touched; without the unlock, the game deletes them from your "
            + "inventory on death or reload. The Infinite Rocket Launcher needs no unlock."
            + Environment.NewLine + Environment.NewLine
            + "Are you sure?",
            proceedLabel: "Force Unlock Them",
            cancelLabel: "Turn It Back Off");

        // Pin the options to the previous patch of this room whenever the player reaches the
        // options step, so a re-patch can't silently discard what they pick.
        JoinFlow.EnteringBioRandOptions = ApplyBioRandPinIfRePatch;
        _draftJoinCommand = new RelayCommand(StartJoinPrefilledFromDraft);
        _retryPatchCommand = new AsyncRelayCommand(RetryPatchLaunchAsync, () => !PatchLaunch.IsRunning && _lastWorkflowRequest is not null);
        PatchLaunch.RetryCommand = _retryPatchCommand;
        _clearBioRandCacheCommand = new AsyncRelayCommand(
            ClearBioRandCacheAsync,
            () => !Action.IsBusy && !PatchLaunch.IsRunning && Setup.CanClearBioRandCache);
        _fixAddressCommand = new AsyncRelayCommand(FixRoomAddressAsync, () => !Action.IsBusy);

        Setup.BrowseCommand = _browseCommand;
        Setup.InstallReFrameworkCommand = _installReFrameworkCommand;
        Setup.InstallArchipelagoLuaModCommand = _installArchipelagoLuaModCommand;
        Setup.ClearBioRandCacheCommand = _clearBioRandCacheCommand;
        Setup.ContinueCommand = _returnToLandingCommand;
        Action.DismissErrorCommand = _dismissErrorCommand;
        Landing.StartCreateCommand = _showCreateGuidanceCommand;
        Landing.StartJoinCommand = _startJoinFlowCommand;
        Landing.StartConfigureYamlCommand = _startConfigureYamlCommand;
        // The settings screen is the joiner's first stop, so it carries the
        // path onward to the room address instead of dead-ending.
        ConfigureYaml.ContinueCommand = _continueFromConfigureYamlCommand;
        var openApworldFolderCommand = new RelayCommand(OpenApworldFolder);
        JoinFlow.OpenApworldFolderCommand = openApworldFolderCommand;
        ConfigureYaml.OpenApworldFolderCommand = openApworldFolderCommand;
        // Session Info is where Join actually lands and where the player waits
        // on the host, so the handoff lives there - and both files must be
        // reachable from it, including the settings file made on the other screen.
        JoinFlow.SaveYamlCommand = ConfigureYaml.SaveYamlCommand;
        Landing.OpenRoomPageCommand = _openRoomPageCommand;
        Landing.ReconnectPrefillCommand = _reconnectPrefillCommand;
        Landing.FixAddressCommand = _fixAddressCommand;
        Landing.RepatchCommand = _repatchPrefillCommand;
        Landing.FinishPatchCommand = _reconnectPrefillCommand;
        Landing.RetireCommand = _retireSessionCommand;
        Landing.DraftJoinCommand = _draftJoinCommand;
        Landing.DraftEditCommand = _startConfigureYamlCommand;
        Landing.OpenSetupCommand = _openSetupCommand;
        ConfigureYaml.BackToLandingCommand = _returnToLandingCommand;
        GenerationGuidance.BackToLandingCommand = _returnToLandingCommand;
        JoinFlow.BackToLandingCommand = _returnToLandingCommand;
        PatchLaunch.BackToLandingCommand = _returnToLandingCommand;
        JoinFlow.PatchRequested += OnJoinPatchRequested;
        // Land on the role/landing screen; Setup Status only takes the first
        // screen when the boot inspection actually finds blockers (Cam
        // 2026-07-29 - a healthy install should not open on a checklist).
        // The redirect decision rides the FIRST inspection completion, in
        // UpdateLandingBlockingState.
        CurrentScreen = Landing;

        Setup.PropertyChanged += OnSetupPropertyChanged;
        Session.PropertyChanged += OnSessionPropertyChanged;
        BioRandOptions.PropertyChanged += OnBioRandOptionsPropertyChanged;
        _workflowService.LogMessage += OnWorkflowLogMessage;
        _reFrameworkInstallationService.LogMessage += OnWorkflowLogMessage;
        _luaInstallService.LogMessage += OnWorkflowLogMessage;
    }

    public SetupViewModel Setup { get; }

    public SessionViewModel Session { get; }

    public BioRandOptionsViewModel BioRandOptions { get; }

    public ActionViewModel Action { get; }

    public LandingViewModel Landing { get; }

    public ConfigureYamlViewModel ConfigureYaml { get; }

    public GenerationGuidanceViewModel GenerationGuidance { get; }

    public JoinFlowViewModel JoinFlow { get; }

    public PatchLaunchViewModel PatchLaunch { get; }

    public RelayCommand OpenLogFolderCommand => _openLogFolderCommand;

    public AsyncRelayCommand GenerateBugReportCommand => _generateBugReportCommand;

    public object? CurrentScreen
    {
        get => _currentScreen;
        set => SetProperty(ref _currentScreen, value);
    }

    /// <summary>A newer release exists on GitHub and the player has not dismissed the notice.</summary>
    public bool HasUpdate
    {
        get => _hasUpdate;
        private set => SetProperty(ref _hasUpdate, value);
    }

    public string UpdateBannerText
    {
        get => _updateBannerText;
        private set => SetProperty(ref _updateBannerText, value);
    }

    public RelayCommand OpenUpdateReleaseCommand => _openUpdateReleaseCommand;

    public RelayCommand DismissUpdateCommand => _dismissUpdateCommand;

    public async Task InitializeAsync()
    {
        if (_isInitializing)
        {
            return;
        }

        _isInitializing = true;
        Action.ClearLog();
        Action.ClearError();
        Action.StatusText = "Loading launcher state...";
        Action.AppendLog("Loading launcher state.");

        try
        {
            Action.AppendLog("Checking bundled RE4R AP world data.");
            _staticData = await _staticGameDataProvider.LoadAsync();
            Action.AppendLog(
                $"Loaded bundled world data version {_staticData.WorldVersion} " +
                $"({_staticData.Counts.LocationsTotal} locations, {_staticData.Counts.GuidLocations} GUID-backed).");

            Action.AppendLog("Loading saved launcher settings.");
            _settings = await _settingsStore.LoadAsync();
            ApplySettings(_settings);

            Action.AppendLog("Checking for a saved settings draft.");
            _pendingDraft = await _draftStore.TryLoadAsync();
            if (_pendingDraft is not null)
            {
                ConfigureYaml.ApplyDraft(_pendingDraft);
            }

            Action.AppendLog("Checking for saved AP connection info.");
            var connectionInfo = await TryLoadConnectionInfoAsync();
            if (connectionInfo is not null)
            {
                if (!string.IsNullOrWhiteSpace(connectionInfo.ServerAddress))
                {
                    Session.ServerAddress = connectionInfo.ServerAddress;
                }

                if (!string.IsNullOrWhiteSpace(connectionInfo.SlotName))
                {
                    Session.SlotName = connectionInfo.SlotName;
                }

                Session.Password = connectionInfo.Password ?? string.Empty;
                Action.AppendLog($"Loaded AP connection info from {GetConnectionInfoFilePath()}.");
            }

            Action.AppendLog("Running startup checks for the RE4R install and saved sessions.");
            await RefreshInstallInspectionAsync();
            await RefreshSessionStateAsync();

            // Fire-and-forget: walking ~850 MB of cache files must not delay the
            // ready state. The Setup panel shows "checking size…" until it lands.
            _ = RefreshBioRandCacheSizeAsync();

            // Same deal for the update check - it touches the network, so it can
            // never sit between the player and a usable window.
            _ = CheckForUpdateAsync();

            Action.StatusText = "Ready.";
            Action.AppendLog("Launcher UI is ready.");
        }
        catch (Exception ex)
        {
            var message = $"Failed to initialize the launcher UI: {ex.Message}";
            Action.AppendLog(message);
            Action.ErrorMessage = message;
            Action.StatusText = "Initialization failed.";
        }
        finally
        {
            _isInitializing = false;
            RefreshCommandStates();
        }
    }

    public void Dispose()
    {
        // Cancel the workflow first, while the log events are still hooked,
        // so any shutdown activity leaves a trace in the file log.
        PatchLaunch.CancelWorkflow();
        _workflowLogFlushTimer.Dispose();
        _workflowService.LogMessage -= OnWorkflowLogMessage;
        _reFrameworkInstallationService.LogMessage -= OnWorkflowLogMessage;
        _luaInstallService.LogMessage -= OnWorkflowLogMessage;
        _cacheManager.LogMessage -= OnWorkflowLogMessage;
        _draftStore.LogMessage -= OnWorkflowLogMessage;
        ConfigureYaml.DraftSaved -= OnDraftSaved;
        GenerationGuidance.DraftSaved -= OnDraftSaved;
        GenerationGuidance.JoinRoomRequested -= OnGuidanceJoinRoomRequested;
        GenerationGuidance.ConfigureYamlRequested -= OnGuidanceConfigureYamlRequested;
        JoinFlow.PatchRequested -= OnJoinPatchRequested;
        Setup.PropertyChanged -= OnSetupPropertyChanged;
        Session.PropertyChanged -= OnSessionPropertyChanged;
        BioRandOptions.PropertyChanged -= OnBioRandOptionsPropertyChanged;
        _installInspectionCancellationSource?.Cancel();
        _installInspectionCancellationSource?.Dispose();
        _sessionRefreshCancellationSource?.Cancel();
        _sessionRefreshCancellationSource?.Dispose();
    }

    public bool HasBusyOperation => Action.IsBusy || PatchLaunch.IsRunning;

    private void ShowCreateGuidance()
    {
        CurrentScreen = GenerationGuidance;
        Action.AppendLog("Opening the organizer's Generation Guidance checklist.");
        _ = GenerationGuidance.EnterAsync();
    }

    private void OnGuidanceConfigureYamlRequested()
    {
        // Configure opened from the organizer wizard's own-YAML step: Back
        // returns to the guide (not the landing) and re-enters it so the
        // step's Done state reflects the fresh draft. Continue does the same
        // and then advances the wizard - both restore the landing-context
        // commands so a later joiner visit gets joiner behavior.
        ConfigureYaml.BackToLandingCommand = new RelayCommand(() =>
        {
            RestoreConfigureYamlLandingCommands();
            CurrentScreen = GenerationGuidance;
            _ = GenerationGuidance.EnterAsync();
        });
        ConfigureYaml.ContinueCommand = _organizerContinueFromConfigureYamlCommand;
        ConfigureYaml.IsOrganizerContext = true;
        CurrentScreen = ConfigureYaml;
        Action.AppendLog("Opening Configure Your YAML from the organizer guide.");
    }

    private void RestoreConfigureYamlLandingCommands()
    {
        ConfigureYaml.BackToLandingCommand = _returnToLandingCommand;
        ConfigureYaml.ContinueCommand = _continueFromConfigureYamlCommand;
    }

    private async Task ContinueOrganizerFromConfigureYamlAsync()
    {
        // Flush before advancing: OwnYamlReady is computed from the stored
        // draft, so the wizard cannot pass its own-YAML step on an unsaved
        // edit. The reload keeps the cached copy current for the join-room
        // prefill later in the guide.
        await ConfigureYaml.FlushDraftAsync();
        _pendingDraft = await _draftStore.TryLoadAsync();

        RestoreConfigureYamlLandingCommands();
        CurrentScreen = GenerationGuidance;
        await GenerationGuidance.EnterAsync();
        if (GenerationGuidance.NextStepCommand.CanExecute(null))
        {
            GenerationGuidance.NextStepCommand.Execute(null);
        }
    }

    private void OnGuidanceJoinRoomRequested()
    {
        // The Create branch ends at the Join screen, prefilled: address and
        // room URL from the guidance paste-back, slot from the organizer's
        // own Configure draft when they have one. Seed identity comes from
        // the scout - no separate hand-back form exists by design.
        Session.ServerAddress = GenerationGuidance.RoomAddress.Trim();
        Session.RoomUrl = GenerationGuidance.RoomUrl.Trim();
        if (!string.IsNullOrWhiteSpace(_pendingDraft?.SlotName))
        {
            Session.SlotName = _pendingDraft.SlotName;
        }

        StartJoinFlow(showJoinerHandoff: false);
    }

    /// <param name="showJoinerHandoff">
    /// Whether Session Info should carry the "Waiting on your host?" panel. It
    /// is guidance for a joiner with no room yet, so a host arriving from their
    /// own checklist, and any path resuming a session that already has a room,
    /// pass false rather than telling them to send files to themselves.
    /// </param>
    private void StartJoinFlow(bool showJoinerHandoff)
    {
        if (string.IsNullOrWhiteSpace(Session.SlotName) && _pendingDraft is not null)
        {
            Session.SlotName = _pendingDraft.SlotName;
            Action.AppendLog($"Prefilled your slot name from the saved draft ({_pendingDraft.SlotName}). It must match the YAML you sent - exactly, including capitalization.");
        }

        JoinFlow.ShowJoinerHandoff = showJoinerHandoff;

        // Random Events drags item and enemy randomization on with it (BioRand
        // throws otherwise), and the options screen is asked to choose a mode
        // BEFORE the scout reports what the room actually rolled. The player's
        // own draft is the best answer available at this point; the patch
        // screen corrects the record once the real one arrives.
        JoinFlow.BioRandOptions.RandomEventsForced = _pendingDraft?.RandomEvents == true;
        JoinFlow.BioRandOptions.MerchantOwnedByAp = _pendingDraft is { } merchantDraft
            && (merchantDraft.ShopChecks > 0 || merchantDraft.ShuffleMerchantGear);

        CurrentScreen = JoinFlow;
        Action.AppendLog("Opening the join-session flow.");
        JoinFlow.Enter();
    }

    private void StartJoinPrefilledFromDraft()
    {
        var draft = _pendingDraft;
        if (draft is not null && draft.IsOrganizer && string.IsNullOrWhiteSpace(draft.RoomAddress))
        {
            // Mid-checklist organizer: the draft strip's primary action
            // continues the guide, not Join (there is no room to join yet).
            ShowCreateGuidance();
            return;
        }

        if (draft is not null)
        {
            if (!string.IsNullOrWhiteSpace(draft.SlotName))
            {
                Session.SlotName = draft.SlotName;
            }

            if (draft.IsOrganizer && !string.IsNullOrWhiteSpace(draft.RoomAddress))
            {
                Session.ServerAddress = draft.RoomAddress;
                Session.RoomUrl = draft.RoomUrl;
            }
        }

        StartJoinFlow(showJoinerHandoff: draft?.IsOrganizer != true);
    }

    private void StartJoinPrefilledFromBanner()
    {
        var record = _bannerRecord;
        if (record is not null)
        {
            Session.ServerAddress = record.NormalizedServer;
            Session.SlotName = record.SlotName;
            Session.RoomUrl = record.RoomUrl;
            Action.AppendLog(string.Equals(record.Status, "patch_in_progress", StringComparison.OrdinalIgnoreCase)
                ? "Finishing the interrupted patch: your details are prefilled - continue through to Patch My Game."
                : "Reconnect: your details are prefilled. If the room moved, update the address - re-scouting the same seed just updates the connection info without re-patching.");
        }

        StartJoinFlow(showJoinerHandoff: false);
    }

    private void StartRepatchFromBanner()
    {
        // Re-patch the banner session without re-walking the organizer/join
        // guidance: prefill from the record and jump straight to the options
        // step, where the re-patch pin replays the recorded options and the
        // only remaining action is Patch My Game.
        var record = _bannerRecord;
        if (record is null)
        {
            return;
        }

        Session.ServerAddress = record.NormalizedServer;
        Session.SlotName = record.SlotName;
        Session.RoomUrl = record.RoomUrl;
        Action.AppendLog(
            "Re-patch: your session details are prefilled and your recorded options will be replayed - "
            + "the same world is rebuilt, with the same items in the same places, using the launcher's current BioRand. "
            + "Just continue through to Patch My Game.");

        StartJoinFlow(showJoinerHandoff: false);
        JoinFlow.GoToBioRandOptionsCommand.Execute(null);
    }

    private void OpenRoomPage()
    {
        var url = _bannerRecord?.RoomUrl?.Trim();
        if (string.IsNullOrWhiteSpace(url))
        {
            return;
        }

        if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
            && !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            url = "https://" + url;
        }

        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            Action.AppendLog($"Opened the room page: {url}. Loading the page wakes a sleeping archipelago.gg room.");
        }
        catch (Exception ex)
        {
            SetError($"Failed to open the room page in your browser: {ex.Message}");
        }
    }

    /// <summary>
    /// A modded game folder, caught before the harvest copies the mod's work
    /// into the cache. Warn rather than block: the check keys off a game version
    /// table, and being wrong about that must not strand someone who is fine.
    /// </summary>
    private async Task<bool> ConfirmForeignPatchPaksAsync(IReadOnlyList<string> foreignPaks)
    {
        var list = string.Join(Environment.NewLine, foreignPaks.Select(name => "    " + name));
        return await _dialogService.ConfirmProceedWithWarningAsync(
            "Your Game Has Mod Files In It",
            "These files are in your RE4R folder but are not part of the game, and are not from this wizard:"
            + Environment.NewLine + Environment.NewLine + list
            + Environment.NewLine + Environment.NewLine
            + "The game loads them on top of everything else, so the wizard would copy their changes and treat them as the real game. "
            + "Patching almost always fails afterwards, usually with a crash that looks nothing like this."
            + Environment.NewLine + Environment.NewLine
            + "These are left behind by mod managers even after you uninstall the mod, and Steam's Verify Integrity does not delete them, "
            + "because Steam only knows about its own files. Delete them from your RE4R folder and patch again.",
            proceedLabel: "Patch Anyway",
            cancelLabel: "Let Me Remove Them");
    }

    /// <summary>
    /// Startup update check. Silent on every failure: no network, GitHub down,
    /// rate limit, or a machine that is simply offline must all look identical
    /// to "no update", never an error the player has to think about.
    /// </summary>
    private async Task CheckForUpdateAsync()
    {
        try
        {
            var info = await _updateService.CheckAsync();
            if (info is null || !info.IsNewer)
            {
                return;
            }

            await DispatchToUiAsync(() =>
            {
                _updateInfo = info;
                UpdateBannerText =
                    $"{info.DisplayName} is available. You are running {info.RunningVersion}.";
                HasUpdate = !string.IsNullOrWhiteSpace(info.ReleaseUrl);
            });
        }
        catch (Exception ex)
        {
            Action.AppendLog($"Update check skipped: {ex.Message}");
        }
    }

    private void OpenUpdateRelease()
    {
        var url = _updateInfo?.ReleaseUrl;
        if (string.IsNullOrWhiteSpace(url))
        {
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            Action.AppendLog($"Opened the release page: {url}");
        }
        catch (Exception ex)
        {
            SetError($"Failed to open the release page in your browser: {ex.Message}");
        }
    }

    /// <summary>
    /// Re-patching an already-patched room REPLAYS the options recorded at the first patch. Show
    /// those options, locked, so the screen can't silently discard whatever the player picks here.
    /// Matched on slot name: the authoritative key is seed+slot, but the seed only exists after the
    /// scout, and the launcher allows one multiworld at a time - so the open record IS the room
    /// being re-patched. If the match turns out to be wrong (the room was regenerated, giving a new
    /// seed), the workflow simply finds no record for that seed and treats it as a fresh patch.
    /// </summary>
    private void ApplyBioRandPinIfRePatch()
    {
        var record = _bannerRecord;
        var slot = Session.SlotName.Trim();

        if (record is null
            || string.IsNullOrWhiteSpace(slot)
            || !string.Equals(record.SlotName?.Trim(), slot, StringComparison.OrdinalIgnoreCase))
        {
            BioRandOptions.ClearPin();
            return;
        }

        // Qualified: the BioRandOptions PROPERTY (the view-model) shadows the Core model type here.
        var recorded = Core.Models.BioRandOptions.Sanitize(record.BioRandOptions);
        BioRandOptions.PinToPreviousPatch(recorded, DescribeMode(recorded));
    }

    private static string DescribeMode(BioRandOptions options) => options.Mode switch
    {
        BioRandOptionCatalog.ModeApOnly => "AP Item Randomization Only",
        BioRandOptionCatalog.ModeFullItem => "Full BioRand Item Randomization",
        BioRandOptionCatalog.ModeFullItemEnemy => "Full BioRand Item + Enemy Randomization",
        BioRandOptionCatalog.ModeCustom => "Custom settings",
        _ => "your previous settings",
    };

    /// <summary>
    /// The player wants to change a pinned config. Warn first - the non-check world re-rolls - then
    /// unlock. Their multiworld checks are pinned by GUID and cannot desync either way.
    /// </summary>
    private async Task UnlockBioRandOptionsAsync()
    {
        var confirmed = await _dialogService.ConfirmProceedWithWarningAsync(
            "Change This Multiworld's Options?",
            "Your multiworld checks stay exactly where they are - the same items in the same places, "
            + "so nothing desyncs and your friends are unaffected."
            + Environment.NewLine + Environment.NewLine
            + "But the REST of the world is re-rolled: other item pickups, and (in the enemy modes) "
            + "enemies and the merchant. An in-progress save was built against the old world, so you "
            + "should START A NEW GAME after patching."
            + Environment.NewLine + Environment.NewLine
            + "You can undo this by choosing the same options again.",
            proceedLabel: "Unlock and Change Options",
            cancelLabel: "Keep Them Locked");

        if (confirmed)
        {
            BioRandOptions.IsUnlockedForChange = true;
            Action.AppendLog("Options unlocked: this patch will re-roll the world around your multiworld checks. Start a new game afterwards.");
        }
    }

    private async Task RetireBannerSessionAsync()
    {
        var record = _bannerRecord;
        if (record is null)
        {
            return;
        }

        var confirmed = await _dialogService.ConfirmProceedWithWarningAsync(
            "Done With This Multiworld?",
            $"Mark {record.SlotName} on {record.SeedName} as finished?"
            + Environment.NewLine + Environment.NewLine
            + "RE4R will stop connecting to this room when launched.",
            proceedLabel: "Mark It Finished",
            cancelLabel: "Cancel");
        if (!confirmed)
        {
            return;
        }

        // Offer to restore vanilla now (delete the BioRand patch) rather than
        // sending the player to Steam's Verify Integrity by hand. Re-patching
        // this or another multiworld later is safe and reproduces the world.
        var restoreVanilla = await _dialogService.ConfirmProceedWithWarningAsync(
            "Restore Vanilla RE4R?",
            "Also remove the world patch now so RE4R plays normally again? "
            + "You can re-patch this or another multiworld anytime. Keeping the patch is fine too - "
            + "RE4R just won't connect to Archipelago."
            + Environment.NewLine + Environment.NewLine
            + "Close RE4R first if it's running, or a patch file may be locked.",
            proceedLabel: "Remove the Patch",
            cancelLabel: "Keep the Patch");

        var result = await _workflowService.RetireSessionAsync(record, restoreVanilla);
        Action.AppendLog($"Marked {record.SlotName} on {record.SeedName} as finished. RE4R will no longer auto-connect to it.");
        if (result.RestoreVanillaRequested)
        {
            if (result.VanillaRestored)
            {
                Action.AppendLog($"Restored vanilla RE4R (removed {result.PatchFilesRemoved} BioRand patch file(s)).");
            }
            else
            {
                Action.ErrorMessage = $"Removed {result.PatchFilesRemoved} BioRand patch file(s), but {result.PatchFilesFailed} could not be deleted - close RE4R and retire again, or use Steam > Verify integrity of game files.";
            }
        }
        await RefreshSessionStateAsync();
    }

    private async void OnDraftSaved()
    {
        try
        {
            _pendingDraft = await _draftStore.TryLoadAsync();
            await DispatchToUiAsync(UpdateLandingDraftState);
        }
        catch (Exception ex)
        {
            Action.AppendLog($"Could not refresh the settings draft state: {ex.Message}");
        }
    }

    private void UpdateLandingDraftState()
    {
        var draft = _pendingDraft;
        if (draft is null || Landing.IsBannerVisible)
        {
            Landing.SetDraft(null);
            return;
        }

        if (draft.IsOrganizer)
        {
            if (string.IsNullOrWhiteSpace(draft.RoomAddress))
            {
                Landing.SetDraft(
                    $"You're organizing a multiworld (last worked on {draft.SavedAtUtc.ToLocalTime():yyyy-MM-dd}). "
                    + "Pick up the guide where you left off.",
                    "Continue the Organizer Guide");
            }
            else
            {
                Landing.SetDraft(
                    $"Your room {draft.RoomAddress} is created. Join it now"
                    + (string.IsNullOrWhiteSpace(draft.SlotName) ? "." : $" as {draft.SlotName}."),
                    "Join My Room");
            }

            return;
        }

        if (string.IsNullOrWhiteSpace(draft.SlotName))
        {
            Landing.SetDraft(null);
            return;
        }

        Landing.SetDraft(
            $"You already configured your settings for slot {draft.SlotName} ({draft.SavedAtUtc.ToLocalTime():yyyy-MM-dd}). "
            + "Got your room address? Join now - your slot name is prefilled.");
    }

    private void StartConfigureYaml()
    {
        ConfigureYaml.IsOrganizerContext = false;
        CurrentScreen = ConfigureYaml;
        Action.AppendLog("Opening the Archipelago settings screen.");
    }

    /// <summary>
    /// Leaving the settings screen for the join step. The draft is flushed
    /// first (the auto-save is debounced, and the join step reads the SAVED
    /// draft), and the slot name is carried across directly so it is never
    /// lost to a race.
    /// </summary>
    private async Task ContinueFromConfigureYamlAsync()
    {
        await ConfigureYaml.FlushDraftAsync();

        // The flush writes to the store, not to this cached copy, and the join
        // step reads the copy (Random Events forcing, slot name). Without the
        // reload the settings just saved are a step behind for the rest of the
        // flow.
        _pendingDraft = await _draftStore.TryLoadAsync();

        var slotName = ConfigureYaml.SlotName.Trim();
        if (!string.IsNullOrWhiteSpace(slotName))
        {
            Session.SlotName = slotName;
        }

        StartJoinFlow(showJoinerHandoff: !ConfigureYaml.IsOrganizerContext);
    }

    private void NavigateToLanding()
    {
        CurrentScreen = Landing;
        Action.AppendLog("Returned to the landing screen.");
    }

    private void OpenSetupScreen()
    {
        CurrentScreen = Setup;
        Action.AppendLog("Opened the Setup Status screen.");
    }

    private void OnJoinPatchRequested()
    {
        _ = BeginJoinPatchLaunchAsync();
    }

    private async Task BeginJoinPatchLaunchAsync()
    {
        var request = await CreateLaunchWorkflowRequestAsync(
            Session.ServerAddress,
            Session.SlotName,
            Session.Password,
            isHostedSession: false);

        if (request is null)
        {
            return;
        }

        PatchLaunch.Title = "Patch + Launch";
        PatchLaunch.Description =
            $"Joining {request.ServerAddress} as slot {request.SlotName}. " +
            "Running the scout, manifest, BioRand, and Lua mod install workflow. " +
            "RE4R connects to Archipelago by itself once launched.";
        CurrentScreen = PatchLaunch;
        await ExecutePatchLaunchAsync(request);
    }

    private async Task<LaunchWorkflowRequest?> CreateLaunchWorkflowRequestAsync(
        string serverAddress,
        string slotName,
        string? password,
        bool isHostedSession)
    {
        Action.ClearError();
        RefreshCommandStates();

        var trimmedServerAddress = serverAddress.Trim();
        var trimmedSlotName = slotName.Trim();

        if (string.IsNullOrWhiteSpace(Setup.InstallPath))
        {
            SetError("Choose your RE4R install path in the Setup section before starting a session.");
            return null;
        }

        if (!_inspection.ExecutableFound)
        {
            SetError("The selected RE4R install path does not contain re4.exe. Pick your real Resident Evil 4 install folder and try again.");
            return null;
        }

        if (!_inspection.ReFrameworkDetected)
        {
            SetError("REFramework is required but not detected in the selected RE4R install. Install it from the Setup section first.");
            return null;
        }

        if (string.IsNullOrWhiteSpace(Setup.SelectedGameVersion))
        {
            SetError("Choose a BioRand game version in the Setup section before starting.");
            return null;
        }

        if (string.IsNullOrWhiteSpace(trimmedServerAddress))
        {
            SetError("Enter the AP server address before continuing.");
            return null;
        }

        if (string.IsNullOrWhiteSpace(trimmedSlotName))
        {
            SetError("Enter the AP slot name before continuing.");
            return null;
        }

        if (!_inspection.SeparateWaysDetected)
        {
            var proceedWithoutDlc = await _dialogService.ConfirmProceedWithWarningAsync(
                "Separate Ways DLC Not Detected",
                "The Separate Ways DLC is required - other players' items appear in your world using "
                + "its Archipelago-logo model. It could not be detected next to your RE4R install; "
                + "it's free on Steam if you're missing it." +
                Environment.NewLine + Environment.NewLine +
                "If your DLC is installed in a non-standard location, patching anyway is safe.",
                proceedLabel: "Patch Anyway",
                cancelLabel: "Cancel");
            if (!proceedWithoutDlc)
            {
                Action.AppendLog("Workflow stopped because Separate Ways DLC was not confirmed.");
                Action.StatusText = "Waiting for DLC confirmation.";
                return null;
            }
        }

        // The Treasure Map expansion ADDS treasure spawns rather than just
        // marking them, and 36 check locations sit on those spawns. Without it
        // they never appear, so they can never be collected - and if the
        // multiworld put a key item on one, the seed cannot be finished.
        if (!_inspection.TreasureMapDetected)
        {
            var proceedWithoutTreasureMap = await _dialogService.ConfirmProceedWithWarningAsync(
                "Treasure Map Expansion Not Detected",
                "The Treasure Map: Expansion DLC is required. It does not just mark treasures on "
                + "your map, it adds treasures that are not in the game without it, and 36 of your "
                + "multiworld checks sit on those exact spots."
                + Environment.NewLine + Environment.NewLine
                + "Without the DLC those 36 checks never appear, so you cannot collect them. If the "
                + "multiworld put a key item on one, nobody can finish the seed."
                + Environment.NewLine + Environment.NewLine
                + "If your DLC is installed in a non-standard location, patching anyway is safe.",
                proceedLabel: "Patch Anyway",
                cancelLabel: "Cancel");
            if (!proceedWithoutTreasureMap)
            {
                Action.AppendLog("Workflow stopped because the Treasure Map expansion was not confirmed.");
                Action.StatusText = "Waiting for DLC confirmation.";
                return null;
            }
        }

        await PersistSettingsAsync(trimmedServerAddress, trimmedSlotName);

        // Patching precedes a game relaunch, which truncates the framework log.
        // Preserve the last session's log now so a crash before this patch stays
        // recoverable for a bug report (best-effort; no-ops if unchanged).
        _bugReportService.RotateFrameworkLog(Setup.InstallPath.Trim());

        return new LaunchWorkflowRequest
        {
            Re4rInstallPath = Setup.InstallPath.Trim(),
            ServerAddress = trimmedServerAddress,
            RoomUrl = Session.RoomUrl.Trim(),
            SlotName = trimmedSlotName,
            Password = password,
            GameVersion = Setup.SelectedGameVersion,
            CurrentGameFingerprint = GameFingerprint.Sanitize(_inspection.Fingerprint),
            BioRandOptions = BioRandOptions.Build(),
            OverrideRecordedOptions = BioRandOptions.IsUnlockedForChange,
            IsHostedSession = isHostedSession,
            NotifyAsync = message => _dialogService.ShowNotificationAsync("RE4R AP Launcher", message),
            ConfirmOverwriteDifferentSeedAsync = prompt => _dialogService.ConfirmOverwriteDifferentSeedAsync(prompt),
            ChooseResumeActionAsync = prompt => _dialogService.ChooseResumeActionAsync(prompt),
            ConfirmForeignPatchPaksAsync = ConfirmForeignPatchPaksAsync,
            ConfirmPatchInstallAsync = confirmation => _dialogService.ConfirmInstallAsync(confirmation),
            ConfirmLuaInstallAsync = confirmation => _dialogService.ConfirmInstallAsync(confirmation),
            OnStepStarting = step => _ = DispatchToUiAsync(() => PatchLaunch.MarkStepStarting(step)),
        };
    }

    private async Task ExecutePatchLaunchAsync(LaunchWorkflowRequest request)
    {
        _lastWorkflowRequest = request;
        _retryPatchCommand.NotifyCanExecuteChanged();

        var succeeded = await PatchLaunch.BeginAsync(request);
        if (succeeded && _pendingDraft is not null)
        {
            // The draft's job is done - its session is now patched and has a
            // real record; stop greeting the player with the waiting state.
            await _draftStore.DeleteAsync();
            _pendingDraft = null;
        }

        if (!succeeded && PatchLaunch.LastFailedStep is { } failedStep)
        {
            var friendly = TranslateWorkflowError(failedStep, PatchLaunch.LastErrorMessage);
            if (IsPreCommitStep(failedStep))
            {
                // Nothing touched the game yet, so don't strand the player on
                // a dead Patching screen - return them to their details with
                // the translated error (review: patch-step-dead-end).
                Action.ErrorMessage = friendly;
                JoinFlow.CurrentStep = JoinFlowStep.SessionInfo;
                CurrentScreen = JoinFlow;
                Action.AppendLog("Returned to Session Info so the details can be corrected.");
            }
            else
            {
                Action.ErrorMessage = friendly;
                PatchLaunch.ShowRetry = true;
            }
        }

        _retryPatchCommand.NotifyCanExecuteChanged();
        _settings = await _settingsStore.LoadAsync();
        await RefreshInstallInspectionAsync();
        await RefreshSessionStateAsync();
    }

    private async Task RetryPatchLaunchAsync()
    {
        var request = _lastWorkflowRequest;
        if (request is null)
        {
            return;
        }

        Action.AppendLog("Retrying the patch + launch workflow.");
        CurrentScreen = PatchLaunch;
        await ExecutePatchLaunchAsync(request);
    }

    private static bool IsPreCommitStep(WorkflowStep step)
    {
        // Everything before the patch-confirm dialog: no game file has been
        // touched, so bouncing back to the input fields is always safe.
        return step is WorkflowStep.ValidateSettings
            or WorkflowStep.CheckSetup
            or WorkflowStep.ScoutApServer
            or WorkflowStep.CheckExistingSession
            or WorkflowStep.BuildManifest
            or WorkflowStep.RunBioRandGeneration;
    }

    private static string TranslateWorkflowError(WorkflowStep step, string message)
    {
        var raw = message ?? string.Empty;

        if (step == WorkflowStep.ScoutApServer)
        {
            if (raw.Contains("InvalidSlot", StringComparison.OrdinalIgnoreCase))
            {
                return "The room doesn't have a player with that slot name. It must match the settings file you sent - exactly, including capitalization (16 characters max). Fix it and try again.";
            }

            if (raw.Contains("InvalidPassword", StringComparison.OrdinalIgnoreCase))
            {
                return "The room refused the password. Check it with your organizer and try again.";
            }

            if (raw.Contains("InvalidGame", StringComparison.OrdinalIgnoreCase))
            {
                return "That slot exists but it isn't a Resident Evil 4 Remake slot. Double-check the slot name with your organizer.";
            }

            // The room answered but named locations this launcher does not
            // know. Saying "couldn't reach it" here sent a tester chasing a
            // sleeping-room fix for a version mismatch (Cam, live 2026-08-14).
            if (raw.Contains("bundled world data does not know", StringComparison.OrdinalIgnoreCase))
            {
                return "The room and this launcher disagree about RE4R's locations, so patching stopped before touching your game. The room was probably generated with a newer RE4R.apworld than this launcher bundles - update the launcher, or regenerate the room with the apworld this launcher ships."
                    + Environment.NewLine + Environment.NewLine + $"Details: {raw}";
            }

            return "Couldn't reach the room at that address. archipelago.gg rooms fall asleep after inactivity, and only opening the ROOM PAGE in a browser wakes them - wake it, double-check the address for typos, then try again."
                + Environment.NewLine + Environment.NewLine + $"Details: {raw}";
        }

        // Matches both input classifications from DescribeGenerationFailure:
        // explicit marker evidence ("recognized damaged or mismatched...") and
        // the negative-exit-code crash class, which prints no evidence but has
        // only ever meant this same repair path.
        if (step == WorkflowStep.RunBioRandGeneration
            && raw.Contains("damaged or mismatched game/cache input", StringComparison.OrdinalIgnoreCase))
        {
            return "BioRand found damaged or mismatched game/cache input while building your world."
                + Environment.NewLine + Environment.NewLine
                + "1. Verify your game files in Steam: right click Resident Evil 4, Properties, Installed Files, Verify integrity of game files."
                + Environment.NewLine
                + "2. Then clear the BioRand cache on the Setup screen, and patch again. Do this second: the cache is a copy of your game files, so clearing it before verifying just copies the same damage back."
                + Environment.NewLine
                + "3. If it still crashes, send the launcher log. It names the exact file BioRand was reading."
                + Environment.NewLine + Environment.NewLine + $"Details: {raw}";
        }

        if (step == WorkflowStep.RunBioRandGeneration
            && raw.Contains("BioRand failed internally", StringComparison.OrdinalIgnoreCase))
        {
            return "BioRand failed internally while building your world. No game-file repair is assumed. The captured [BioRand] output remains available in the launcher log; please provide that log."
                + Environment.NewLine + Environment.NewLine + $"Details: {raw}";
        }

        return raw;
    }

    private void UpdateLandingBlockingState()
    {
        var blockers = new List<string>();

        if (!_inspection.CanLaunch)
        {
            blockers.Add("RE4R install");
        }

        if (!_inspection.ReFrameworkDetected)
        {
            blockers.Add("REFramework");
        }

        // The in-game mod. Missing it is exactly as blocking as a missing
        // REFramework - the session connects to nothing and no check is ever
        // sent - but it was absent from this list, so a launcher that had
        // detected it missing still opened on the landing screen (Cam, live on
        // v0.1.2-alpha, after a REFramework reinstall wiped the mod). The
        // omission predates the boot-screen change; it only became visible
        // once this list decided the opening screen.
        if (!_inspection.ArchipelagoLuaModDetected)
        {
            blockers.Add("Archipelago Lua mod");
        }

        // The banner carries its own Open Setup button - no auto-navigation,
        // so a blocker appearing mid-flow never yanks the player off their
        // current screen.
        Landing.BlockingIssuesText = blockers.Count == 0
            ? string.Empty
            : $"Fix these on the Setup Status screen before joining a session: {string.Join(", ", blockers)}.";

        // One-shot boot redirect: the FIRST inspection decides whether Setup
        // Status takes over as the opening screen. Only ever fires while the
        // player is still on the landing (a fast click elsewhere wins), and
        // never again afterwards - mid-flow blockers stay banner-only.
        if (!_initialSetupRedirectDecided)
        {
            _initialSetupRedirectDecided = true;
            if (blockers.Count > 0 && ReferenceEquals(CurrentScreen, Landing))
            {
                CurrentScreen = Setup;
            }
        }

        _startJoinFlowCommand.NotifyCanExecuteChanged();
    }

    private void OnSetupPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_isInitializing)
        {
            return;
        }

        if (string.Equals(e.PropertyName, nameof(SetupViewModel.InstallPath), StringComparison.Ordinal))
        {
            QueueInstallInspectionRefresh();
        }

        if (string.Equals(e.PropertyName, nameof(SetupViewModel.InstallPath), StringComparison.Ordinal)
            || string.Equals(e.PropertyName, nameof(SetupViewModel.SelectedGameVersion), StringComparison.Ordinal))
        {
            RefreshCommandStates();
        }
    }

    private void OnSessionPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (_isInitializing)
        {
            return;
        }

        if (string.Equals(e.PropertyName, nameof(SessionViewModel.ServerAddress), StringComparison.Ordinal)
            || string.Equals(e.PropertyName, nameof(SessionViewModel.SlotName), StringComparison.Ordinal))
        {
            QueueSessionStateRefresh();
            RefreshCommandStates();
        }
    }

    private void OnBioRandOptionsPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!string.Equals(e.PropertyName, nameof(BioRandOptionsViewModel.SelectedMode), StringComparison.Ordinal)
            || _isInitializing)
        {
            return;
        }

        // Selecting a mode loads that mode's preset, so say so - otherwise a player who tweaked
        // Advanced options and then switched modes would silently lose them.
        if (BioRandOptions.HasSelectedMode && BioRandOptions.IsSelectedModeAvailable)
        {
            Action.AppendLog(
                $"{BioRandOptions.SelectedMode?.DisplayName ?? "Selected mode"} selected. " +
                "Options have been reset to this mode's defaults - open Advanced Options to change them.");
        }

        RefreshCommandStates();
    }

    private async Task BrowseInstallPathAsync()
    {
        var chosenPath = await _dialogService.BrowseForFolderAsync(Setup.InstallPath);
        if (!string.IsNullOrWhiteSpace(chosenPath))
        {
            Setup.InstallPath = chosenPath;
            _settings.Re4rInstallPath = chosenPath.Trim();
            await _settingsStore.SaveAsync(_settings);
            Action.AppendLog($"Saved RE4R install path to launcher settings: {chosenPath.Trim()}.");
        }
    }

    private async Task InstallReFrameworkAsync()
    {
        if (Action.IsBusy)
        {
            return;
        }

        if (!_inspection.InstallPathExists || string.IsNullOrWhiteSpace(Setup.InstallPath))
        {
            SetError("Choose a valid RE4R install path before installing REFramework.");
            return;
        }

        // One-dialog-per-install house pattern: writing a DLL into a Steam
        // game folder unannounced reads as malware to a non-technical player
        // (audit launcherui-9).
        var confirmed = await _dialogService.ConfirmProceedWithWarningAsync(
            "Install REFramework?",
            "REFramework is the mod loader that runs the Archipelago scripts inside RE4R. "
            + "This downloads its latest release from GitHub and writes dinput8.dll plus the "
            + "reframework folder into:"
            + Environment.NewLine + Environment.NewLine + Setup.InstallPath.Trim(),
            proceedLabel: "Download and Install",
            cancelLabel: "Cancel");
        if (!confirmed)
        {
            Action.AppendLog("REFramework install was declined.");
            return;
        }

        Action.ClearError();
        Action.AppendLog($"Preparing to install REFramework into {Setup.InstallPath}.");
        Action.StatusText = "Installing REFramework...";
        Action.IsBusy = true;
        // The chip narrates the real lifecycle instead of jumping
        // Missing -> Present (plan fix #1); a failure below flips it to
        // Failed with the button re-enabled as the retry.
        Setup.SetReFrameworkStatus("Downloading...", "Downloading the latest REFramework release from GitHub.", "warning");
        Setup.CanInstallReFramework = false;
        RefreshCommandStates();

        try
        {
            var result = await _reFrameworkInstallationService.InstallLatestAsync(Setup.InstallPath.Trim());
            Action.AppendLog(
                $"REFramework {result.ReleaseTag} installed from {result.AssetName}. " +
                $"Wrote {result.FilesWrittenCount} files.");
            Action.AppendLog("Re-checking the RE4R install for REFramework after installation.");
            await RefreshInstallInspectionAsync();
        }
        catch (Exception ex)
        {
            var message = $"Failed to install REFramework: {ex.Message}";
            Action.AppendLog(message);
            SetError(message);
            Action.StatusText = "REFramework install failed.";
            Setup.SetReFrameworkStatus("Failed", $"{ex.Message} Click Download & Install REFramework to try again.", "error");
            Setup.CanInstallReFramework = true;
            return;
        }
        finally
        {
            Action.IsBusy = false;
            RefreshCommandStates();
        }

        Action.StatusText = "REFramework install complete.";
    }

    private async Task InstallArchipelagoLuaModAsync()
    {
        if (Action.IsBusy)
        {
            return;
        }

        if (!_inspection.InstallPathExists || string.IsNullOrWhiteSpace(Setup.InstallPath))
        {
            SetError("Choose a valid RE4R install path before installing the Archipelago Lua mod.");
            return;
        }

        Action.ClearError();
        Action.AppendLog($"Preparing to copy the Archipelago Lua mod into {Setup.InstallPath}.");
        Action.StatusText = "Installing Archipelago Lua mod...";
        Action.IsBusy = true;
        RefreshCommandStates();

        try
        {
            var result = await _luaInstallService.InstallLuaModFilesAsync(
                Setup.InstallPath.Trim(),
                confirmation => _dialogService.ConfirmInstallAsync(confirmation));

            if (result.Cancelled)
            {
                Action.AppendLog("Archipelago Lua mod installation was cancelled.");
                Action.StatusText = "Lua mod install cancelled.";
                return;
            }

            if (!result.Success)
            {
                var verificationMessage = result.VerificationFailures.Count > 0
                    ? $"Archipelago Lua mod installation completed with {result.VerificationFailures.Count} verification failure(s)."
                    : "Archipelago Lua mod installation did not complete successfully.";
                Action.AppendLog(verificationMessage);
                SetError(verificationMessage);
                Action.StatusText = "Lua mod install failed.";
                return;
            }

            Action.AppendLog($"Archipelago Lua mod installed successfully. {result.FilesCopiedCount} files were copied.");
            Action.AppendLog("Re-checking the RE4R install for the Archipelago Lua mod after installation.");
            await RefreshInstallInspectionAsync();
        }
        catch (Exception ex)
        {
            var message = $"Failed to install the Archipelago Lua mod: {ex.Message}";
            Action.AppendLog(message);
            SetError(message);
            Action.StatusText = "Lua mod install failed.";
            return;
        }
        finally
        {
            Action.IsBusy = false;
            RefreshCommandStates();
        }

        Action.StatusText = "Archipelago Lua mod install complete.";
    }

    private void OpenLogFolder()
    {
        try
        {
            Directory.CreateDirectory(LauncherFileLog.LogDirectoryPath);
            _ = _dialogService.OpenFolderAsync(LauncherFileLog.LogDirectoryPath);
        }
        catch (Exception ex)
        {
            var message = $"Failed to open the log folder: {ex.Message}";
            Action.AppendLog(message);
            SetError(message);
        }
    }

    /// <summary>
    /// Bundle the session record, launcher log, framework log (+ preserved
    /// backups), crash dump and drop audit into one zip to attach in Discord,
    /// then open the folder holding it. Best-effort: a missing piece is noted in
    /// the report's manifest rather than failing the whole thing.
    /// </summary>
    private async Task GenerateBugReportAsync()
    {
        try
        {
            var installPath = Setup.InstallPath?.Trim() ?? string.Empty;
            var slotName = !string.IsNullOrWhiteSpace(Session.SlotName)
                ? Session.SlotName.Trim()
                : ConfigureYaml.SlotName?.Trim() ?? string.Empty;
            var version = LauncherUpdateService.GetRunningVersion();

            var zipPath = await Task.Run(
                () => _bugReportService.CreateBugReport(installPath, slotName, version));

            if (zipPath == null)
            {
                var failure = "Could not write the bug report. Check the log folder is writable.";
                Action.AppendLog(failure);
                SetError(failure);
                return;
            }

            Action.AppendLog($"Bug report saved: {zipPath}");
            var folder = Path.GetDirectoryName(zipPath);
            if (!string.IsNullOrEmpty(folder))
            {
                _ = _dialogService.OpenFolderAsync(folder);
            }
        }
        catch (Exception ex)
        {
            var message = $"Failed to generate the bug report: {ex.Message}";
            Action.AppendLog(message);
            SetError(message);
        }
    }

    private void OpenApworldFolder()
    {
        try
        {
            _ = _dialogService.OpenFolderAsync(
                Path.Combine(AppContext.BaseDirectory, "assets", "Data"));
        }
        catch (Exception ex)
        {
            var message = $"Failed to open the apworld folder: {ex.Message}";
            Action.AppendLog(message);
            SetError(message);
        }
    }

    private void QueueInstallInspectionRefresh()
    {
        _installInspectionCancellationSource?.Cancel();
        _installInspectionCancellationSource?.Dispose();
        _installInspectionCancellationSource = new CancellationTokenSource();
        _ = RefreshInstallInspectionAsync(_installInspectionCancellationSource.Token);
    }

    private async Task RefreshInstallInspectionAsync(CancellationToken cancellationToken = default)
    {
        await Task.Yield();
        if (cancellationToken.IsCancellationRequested)
        {
            return;
        }

        var inspection = _gameInstallationInspector.Inspect(Setup.InstallPath);
        if (cancellationToken.IsCancellationRequested)
        {
            return;
        }

        _inspection = inspection;

        if (string.IsNullOrWhiteSpace(Setup.InstallPath))
        {
            Action.AppendLog("RE4R install path is not set yet. Choose your game folder in the Setup section.");
        }
        else if (!inspection.InstallPathExists)
        {
            Action.AppendLog($"RE4R install path check failed because {Setup.InstallPath} does not exist.");
        }
        else
        {
            Action.AppendLog($"Inspecting RE4R install at {inspection.InstallPath}.");
            Action.AppendLog(inspection.FingerprintSummary);
            Action.AppendLog(inspection.DetectionSummary);

            if (string.IsNullOrWhiteSpace(_settings.SetupGameFingerprint))
            {
                Action.AppendLog("BioRand setup has not been run for this install yet.");
            }
            else if (string.Equals(_settings.SetupGameFingerprint, inspection.Fingerprint.FingerprintHash, StringComparison.Ordinal))
            {
                Action.AppendLog("BioRand setup matches the current game fingerprint.");
            }
            else
            {
                Action.AppendLog("BioRand setup is stale for this install because the game fingerprint changed. Setup will run again before patching.");
            }
        }

        await DispatchToUiAsync(() =>
        {
            Setup.DetectedGameVersionText = inspection.DetectionSummary;
            Setup.FingerprintSummaryText = inspection.FingerprintSummary;

            if (!string.IsNullOrWhiteSpace(inspection.DetectedBioRandGameVersion)
                && (string.IsNullOrWhiteSpace(Setup.SelectedGameVersion)
                    || string.Equals(Setup.SelectedGameVersion, _lastAutoDetectedGameVersion, StringComparison.Ordinal)))
            {
                Setup.SelectedGameVersion = inspection.DetectedBioRandGameVersion;
                _lastAutoDetectedGameVersion = inspection.DetectedBioRandGameVersion;
            }

            UpdateRe4rStatus(inspection);
            UpdateSetupStatusText();
            UpdateReFrameworkStatus(inspection);
            UpdateArchipelagoLuaModStatus(inspection);
            UpdateSeparateWaysStatus(inspection);
            UpdateLandingBlockingState();
        });

        QueueSessionStateRefresh();
    }

    private void QueueSessionStateRefresh()
    {
        _sessionRefreshCancellationSource?.Cancel();
        _sessionRefreshCancellationSource?.Dispose();
        _sessionRefreshCancellationSource = new CancellationTokenSource();
        _ = RefreshSessionStateAsync(_sessionRefreshCancellationSource.Token);
    }

    private async Task RefreshSessionStateAsync(CancellationToken cancellationToken = default)
    {
        await Task.Yield();
        if (cancellationToken.IsCancellationRequested)
        {
            return;
        }

        // Session detection reads the record store directly - never gated on
        // whatever happens to be typed in the address/slot boxes (review:
        // multi-session-model). Identity is seed+slot, so a room that moved
        // ports still surfaces. One-at-a-time: the newest open record is the
        // session this install is patched for.
        var openRecords = await _sessionRecordStore.LoadOpenSessionsAsync(cancellationToken);
        if (cancellationToken.IsCancellationRequested)
        {
            return;
        }

        var currentRecord = openRecords.FirstOrDefault();
        if (currentRecord is null)
        {
            _bannerRecord = null;
            Action.AppendLog("No open session records were found.");
            await DispatchToUiAsync(() =>
            {
                Session.CurrentSessionText = "Current session: none";
                Session.LastPatchedText = "Last patched: n/a";
                Session.WarningText = string.Empty;
                Landing.HideBanner();
                UpdateLandingDraftState();
            });
            return;
        }

        var warnings = new List<string>();
        if (string.Equals(currentRecord.Status, "patch_in_progress", StringComparison.OrdinalIgnoreCase))
        {
            warnings.Add("Your last patch didn't finish. Run the patch again to fix it - that's safe: it rebuilds the same world, with the same items in the same places.");
        }

        if (!string.IsNullOrWhiteSpace(_inspection.Fingerprint.FingerprintHash)
            && !string.IsNullOrWhiteSpace(currentRecord.GameFingerprintAtPatch.FingerprintHash)
            && !string.Equals(
                _inspection.Fingerprint.FingerprintHash,
                currentRecord.GameFingerprintAtPatch.FingerprintHash,
                StringComparison.Ordinal))
        {
            warnings.Add("Game version changed since the last patch. Re-patch is required.");
        }

        if (_staticData is not null
            && !string.Equals(_staticData.WorldVersion, currentRecord.WorldVersion, StringComparison.Ordinal))
        {
            warnings.Add("Bundled world data changed since the last patch. Re-patch is required.");
        }

        Action.AppendLog(
            $"Found session {currentRecord.SeedName} (slot {currentRecord.SlotName}) with status {currentRecord.Status}.");
        foreach (var warning in warnings)
        {
            Action.AppendLog(warning);
        }

        _bannerRecord = currentRecord;
        var isInProgress = string.Equals(currentRecord.Status, "patch_in_progress", StringComparison.OrdinalIgnoreCase);
        var serverDisplay = string.IsNullOrWhiteSpace(currentRecord.NormalizedServer)
            ? "unknown address"
            : currentRecord.NormalizedServer;

        await DispatchToUiAsync(() =>
        {
            Session.CurrentSessionText =
                $"Current session: {currentRecord.SlotName} on {currentRecord.SeedName} ({currentRecord.NormalizedServer}) - {currentRecord.Status}";
            Session.LastPatchedText = currentRecord.PatchedAtUtc == default
                ? "Last patched: n/a"
                : $"Last patched: {currentRecord.PatchedAtUtc.ToLocalTime():yyyy-MM-dd HH:mm:ss}";
            Session.WarningText = string.Join(Environment.NewLine, warnings);
            Landing.SetDraft(null);
            if (isInProgress)
            {
                Landing.ShowUnfinishedPatchBanner(currentRecord.SlotName, currentRecord.SeedName);
            }
            else
            {
                Landing.ShowCheckingBanner(currentRecord.SlotName, serverDisplay);
            }
        });

        if (isInProgress)
        {
            return;
        }

        // RoomInfo probe, not a bare TCP connect: archipelago.gg recycles
        // ports, so an ANSWERING address is not necessarily this session's
        // room (live 2026-07-22: a stranger's room answered the recorded port
        // and the banner promised "all set" while the game got InvalidSlot).
        // Only a matching RoomInfo seed_name earns the ready banner.
        var probe = await _roomAddressHealService.ProbeRoomAsync(currentRecord.NormalizedServer, cancellationToken);
        if (cancellationToken.IsCancellationRequested || !ReferenceEquals(_bannerRecord, currentRecord))
        {
            return;
        }

        var expectedSeed = (currentRecord.SeedName ?? string.Empty).Trim();
        var seedVerified = probe.Answered
            && expectedSeed.Length > 0
            && string.Equals(probe.SeedName, expectedSeed, StringComparison.Ordinal);
        // A record without a seed (legacy) cannot be verified - treat any
        // answer as ready, as before.
        var treatAsReady = probe.Answered && (seedVerified || expectedSeed.Length == 0);

        if (!probe.Answered)
        {
            Action.AppendLog($"Room check: {serverDisplay} did not answer. The room may be asleep or its address may have changed.");
        }
        else if (treatAsReady)
        {
            Action.AppendLog(seedVerified
                ? $"Room check: {serverDisplay} answered and confirmed seed {probe.SeedName} - the session is ready to play."
                : $"Room check: {serverDisplay} answered - the session is ready to play.");
        }
        else
        {
            Action.AppendLog(probe.SeedName.Length > 0
                ? $"Room check: {serverDisplay} answered with seed {probe.SeedName}, but this session is seed {expectedSeed} - a different room is on that address now."
                : $"Room check: {serverDisplay} answered but did not identify as an Archipelago room - treating the address as stale.");
        }

        var hasRoomUrl = !string.IsNullOrWhiteSpace(currentRecord.RoomUrl);
        await DispatchToUiAsync(() =>
        {
            if (treatAsReady)
            {
                Landing.ShowReadyBanner(currentRecord.SlotName, serverDisplay, hasRoomUrl, seedVerified);
            }
            else if (probe.Answered)
            {
                var foundSeedDisplay = probe.SeedName.Length > 0
                    ? $"a different multiworld (seed {probe.SeedName})"
                    : "not identifying itself as an Archipelago room";
                Landing.ShowWrongRoomBanner(currentRecord.SlotName, serverDisplay, foundSeedDisplay, hasRoomUrl);
            }
            else
            {
                Landing.ShowUnreachableBanner(currentRecord.SlotName, serverDisplay, hasRoomUrl);
            }
        });
    }

    /// <summary>
    /// One-click address heal from the banner: wake + read the room page,
    /// verify the answering room's seed, rewrite the session record and both
    /// ap_connection.json files, then re-run the room check. No re-patch.
    /// </summary>
    private async Task FixRoomAddressAsync()
    {
        var record = _bannerRecord;
        if (record is null)
        {
            return;
        }

        Action.AppendLog($"Fixing the room address for {record.SlotName} on {record.SeedName} from the room page...");
        var result = await _roomAddressHealService.HealAsync(record, Setup.InstallPath, CancellationToken.None);
        if (result.Succeeded)
        {
            Action.AppendLog(result.AddressChanged
                ? $"Room address fixed: RE4R will now connect to {result.HealedServer}."
                : "The recorded address was already correct - the room is awake and verified.");
            QueueSessionStateRefresh();
        }
        else
        {
            Action.ErrorMessage = result.FailureReason;
        }
    }

    private async Task PersistSettingsAsync()
    {
        await PersistSettingsAsync(Session.ServerAddress.Trim(), Session.SlotName.Trim());
    }

    private async Task PersistSettingsAsync(string serverAddress, string slotName)
    {
        _settings.Re4rInstallPath = Setup.InstallPath.Trim();
        _settings.LastServerAddress = serverAddress.Trim();
        _settings.LastSlotName = slotName.Trim();
        _settings.LastBioRandOptions = BioRandOptions.Build();
        _settings.CurrentGameFingerprint = GameFingerprint.Sanitize(_inspection.Fingerprint);
        await _settingsStore.SaveAsync(_settings);
    }

    private void ApplySettings(LauncherSettings settings)
    {
        settings = LauncherSettings.Sanitize(settings);
        Setup.InstallPath = settings.Re4rInstallPath;
        Session.ServerAddress = settings.LastServerAddress;
        Session.SlotName = settings.LastSlotName;
        BioRandOptions.Apply(settings.LastBioRandOptions);
    }

    private async Task<ApConnectionInfo?> TryLoadConnectionInfoAsync()
    {
        var filePath = GetConnectionInfoFilePath();
        if (!File.Exists(filePath))
        {
            return null;
        }

        try
        {
            Action.AppendLog($"Checking AP connection info at {filePath}.");
            await using var stream = File.OpenRead(filePath);
            var loaded = await JsonSerializer.DeserializeAsync<ApConnectionInfo>(stream);
            return loaded;
        }
        catch (JsonException)
        {
            Action.AppendLog($"Ignoring AP connection info at {filePath} because the file is malformed.");
            return null;
        }
        catch (IOException)
        {
            Action.AppendLog($"Ignoring AP connection info at {filePath} because the file could not be read.");
            return null;
        }
        catch (UnauthorizedAccessException)
        {
            Action.AppendLog($"Ignoring AP connection info at {filePath} because the file is not accessible.");
            return null;
        }
    }

    private string GetConnectionInfoFilePath()
    {
        return Path.Combine(_settingsStore.AppDataRootPath, "ap_connection.json");
    }

    private void UpdateRe4rStatus(GameInstallationInspectionResult inspection)
    {
        if (string.IsNullOrWhiteSpace(inspection.InstallPath))
        {
            Setup.SetRe4rStatus("Waiting", "Select your RE4R install path to detect the game and prerequisites.", "neutral");
            return;
        }

        if (!inspection.InstallPathExists)
        {
            Setup.SetRe4rStatus("Missing", "The selected RE4R install path does not exist.", "error");
            return;
        }

        if (!inspection.ExecutableFound)
        {
            Setup.SetRe4rStatus("Missing", "The selected folder does not contain re4.exe.", "error");
            return;
        }

        if (string.IsNullOrWhiteSpace(inspection.Fingerprint.FingerprintHash))
        {
            Setup.SetRe4rStatus("Warning", "The launcher found RE4R, but could not read a stable game fingerprint yet.", "warning");
            return;
        }

        Setup.SetRe4rStatus("Present", "RE4R was detected and the current game fingerprint was read successfully.", "success");
    }

    private void UpdateSetupStatusText()
    {
        if (string.IsNullOrWhiteSpace(Setup.InstallPath))
        {
            Setup.SetupStatusText = "Setup status will appear after you select an RE4R install path.";
            return;
        }

        if (!_inspection.InstallPathExists)
        {
            Setup.SetupStatusText = "Setup status unavailable because the selected install path does not exist.";
            return;
        }

        if (string.IsNullOrWhiteSpace(_inspection.Fingerprint.FingerprintHash))
        {
            Setup.SetupStatusText = "Setup status unavailable because the RE4R install fingerprint could not be read.";
            return;
        }

        if (string.IsNullOrWhiteSpace(_settings.SetupGameFingerprint))
        {
            Setup.SetupStatusText = "BioRand setup has not been run for this install yet.";
            return;
        }

        if (string.Equals(_settings.SetupGameFingerprint, _inspection.Fingerprint.FingerprintHash, StringComparison.Ordinal))
        {
            var setupTimestamp = _settings.SetupCompletedAtUtc?.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") ?? "unknown time";
            Setup.SetupStatusText = $"BioRand setup is current for this install. Last completed at {setupTimestamp}.";
            return;
        }

        Setup.SetupStatusText = "BioRand setup is stale for this install because the game fingerprint changed.";
    }

    private void UpdateReFrameworkStatus(GameInstallationInspectionResult inspection)
    {
        if (string.IsNullOrWhiteSpace(inspection.InstallPath))
        {
            Setup.SetReFrameworkStatus("Waiting", "Select your RE4R install path to detect REFramework.", "neutral");
            Setup.CanInstallReFramework = false;
            return;
        }

        if (!inspection.InstallPathExists)
        {
            Setup.SetReFrameworkStatus("Missing", "REFramework detection is unavailable because the install path does not exist.", "error");
            Setup.CanInstallReFramework = false;
            return;
        }

        if (inspection.ReFrameworkDetected)
        {
            Setup.SetReFrameworkStatus("Present", "REFramework was detected in your RE4R install.", "success");
            Setup.CanInstallReFramework = false;
            Action.AppendLog("REFramework detected in the selected RE4R install.");
            return;
        }

        var message = "REFramework is required but not detected in your RE4R install.";
        if (!inspection.ReFrameworkDllFound && !inspection.ReFrameworkDirectoryFound)
        {
            message += " Neither dinput8.dll nor the reframework folder was found.";
        }
        else if (!inspection.ReFrameworkDllFound)
        {
            message += " dinput8.dll was not found.";
        }
        else if (!inspection.ReFrameworkDirectoryFound)
        {
            message += " The reframework folder was not found.";
        }

        Setup.SetReFrameworkStatus("Missing", message, "error");
        Setup.CanInstallReFramework = true;
        Action.AppendLog(message);
    }

    private void UpdateArchipelagoLuaModStatus(GameInstallationInspectionResult inspection)
    {
        if (string.IsNullOrWhiteSpace(inspection.InstallPath))
        {
            Setup.SetArchipelagoLuaModStatus("Waiting", "Select your RE4R install path to detect the Archipelago Lua mod.", "neutral");
            Setup.CanInstallArchipelagoLuaMod = false;
            return;
        }

        if (!inspection.InstallPathExists)
        {
            Setup.SetArchipelagoLuaModStatus("Missing", "Archipelago Lua mod detection is unavailable because the install path does not exist.", "error");
            Setup.CanInstallArchipelagoLuaMod = false;
            return;
        }

        if (inspection.ArchipelagoLuaModDetected)
        {
            Setup.SetArchipelagoLuaModStatus("Present", "The Archipelago Lua mod was detected in your RE4R install.", "success");
            Setup.CanInstallArchipelagoLuaMod = false;
            Action.AppendLog("Archipelago Lua mod detected in the selected RE4R install.");
            return;
        }

        var message =
            "The Archipelago Lua mod is not fully installed in this RE4R folder yet. " +
            "The launcher will copy it during patching or re-patching.";

        if (!inspection.ArchipelagoLuaRootScriptFound && !inspection.ArchipelagoLuaDirectoryFound)
        {
            message += " Neither ArchipelagoRE4R.lua nor the ArchipelagoRE4R module folder was found.";
        }
        else if (!inspection.ArchipelagoLuaRootScriptFound)
        {
            message += " ArchipelagoRE4R.lua was not found.";
        }
        else if (!inspection.ArchipelagoLuaDirectoryFound)
        {
            message += " The ArchipelagoRE4R module folder was not found.";
        }

        Setup.SetArchipelagoLuaModStatus("Missing", message, "warning");
        Setup.CanInstallArchipelagoLuaMod = true;
        Action.AppendLog(message);
    }

    /// <summary>
    /// One status row covers BOTH required DLC. Separate Ways supplies the model
    /// other players' items wear; Treasure Map: Expansion adds the treasure
    /// spawns that 36 check locations sit on, so missing it makes those 36
    /// uncollectable rather than merely unmarked.
    /// </summary>
    private void UpdateSeparateWaysStatus(GameInstallationInspectionResult inspection)
    {
        if (string.IsNullOrWhiteSpace(inspection.InstallPath))
        {
            Setup.SetSeparateWaysStatus("Waiting", "Select your RE4R install path to check for the required DLC.", "neutral");
            return;
        }

        if (!inspection.InstallPathExists)
        {
            Setup.SetSeparateWaysStatus("Warning", "DLC detection is unavailable because the install path does not exist.", "warning");
            return;
        }

        if (inspection.SeparateWaysDetected && inspection.TreasureMapDetected)
        {
            Setup.SetSeparateWaysStatus("Present", "Separate Ways and Treasure Map: Expansion were both detected next to this RE4R install.", "success");
            Action.AppendLog("Both required DLC detected.");
            return;
        }

        var missing = new List<string>();
        if (!inspection.SeparateWaysDetected)
        {
            missing.Add("Separate Ways");
        }

        if (!inspection.TreasureMapDetected)
        {
            missing.Add("Treasure Map: Expansion");
        }

        var message = missing.Count == 1
            ? $"{missing[0]} was not found next to this RE4R install. Install it from Steam."
            : $"{string.Join(" and ", missing)} were not found next to this RE4R install. Install them from Steam.";

        if (!inspection.TreasureMapDetected)
        {
            message += " Without Treasure Map: Expansion, 36 of your checks never spawn and cannot be collected.";
        }

        Setup.SetSeparateWaysStatus("Warning", message, "warning");
        Action.AppendLog(message);
    }

    private void OnWorkflowLogMessage(string message)
    {
        // Tee to disk on the producer thread so a UI backlog can never drop
        // lines, then queue for the batched Background-priority drain. A
        // per-line Normal-priority dispatch starves WPF input under BioRand's
        // output floods.
        LauncherFileLog.Append(message);
        _pendingWorkflowLogLines.Enqueue(message);
    }

    private void OnWorkflowLogFlushTick()
    {
        if (_pendingWorkflowLogLines.IsEmpty)
        {
            return;
        }

        var batch = new List<string>();
        while (_pendingWorkflowLogLines.TryDequeue(out var line))
        {
            batch.Add(line);
        }

        Action.AppendLogBatch(batch);
    }

    private void SetError(string message)
    {
        Action.ErrorMessage = message;
        RefreshCommandStates();
    }

    private void DismissError()
    {
        Action.ClearError();
        RefreshCommandStates();
    }

    private void RefreshCommandStates()
    {
        _browseCommand.NotifyCanExecuteChanged();
        _installReFrameworkCommand.NotifyCanExecuteChanged();
        _installArchipelagoLuaModCommand.NotifyCanExecuteChanged();
        _dismissErrorCommand.NotifyCanExecuteChanged();
        _retireSessionCommand.NotifyCanExecuteChanged();
        _clearBioRandCacheCommand.NotifyCanExecuteChanged();
    }

    /// <summary>
    /// Recomputes the BioRand cache size off the UI thread and updates the
    /// Setup panel's label + Clear-button availability. Safe to fire-and-forget.
    /// </summary>
    private async Task RefreshBioRandCacheSizeAsync()
    {
        long bytes;
        try
        {
            bytes = await Task.Run(() => _cacheManager.GetCacheSizeBytes());
        }
        catch
        {
            bytes = 0;
        }

        await DispatchToUiAsync(() =>
        {
            Setup.BioRandCacheText = bytes > 0
                ? $"BioRand cache: {BioRandProcessRunner.FormatSize(bytes)} (in LocalAppData)"
                : "BioRand cache: empty (rebuilds automatically on next patch)";
            Setup.CanClearBioRandCache = bytes > 0;
            RefreshCommandStates();
        });
    }

    private async Task ClearBioRandCacheAsync()
    {
        var confirmed = await _dialogService.ConfirmProceedWithWarningAsync(
            "Clear the BioRand cache?",
            "This deletes the BioRand file cache (about 850 MB). Your next patch will "
            + "re-run BioRand setup once (about a minute) to rebuild it - no game files, "
            + "saves, or sessions are affected.",
            proceedLabel: "Clear the Cache",
            cancelLabel: "Cancel");
        if (!confirmed)
        {
            return;
        }

        Setup.CanClearBioRandCache = false;
        RefreshCommandStates();
        try
        {
            await Task.Run(() => _cacheManager.ClearCache());
        }
        finally
        {
            await RefreshBioRandCacheSizeAsync();
        }
    }

    private Task DispatchToUiAsync(System.Action action)
    {
        return _dialogService.InvokeOnUiThreadAsync(
            () =>
            {
            action();
                return Task.CompletedTask;
            });
    }


    private static string FormatWorkflowStep(WorkflowStep step)
    {
        return step switch
        {
            WorkflowStep.ValidateSettings => "settings validation",
            WorkflowStep.CheckSetup => "setup validation",
            WorkflowStep.ScoutApServer => "AP scouting",
            WorkflowStep.CheckExistingSession => "session check",
            WorkflowStep.BuildManifest => "manifest build",
            WorkflowStep.RunBioRandGeneration => "BioRand generation",
            WorkflowStep.InstallPatchFiles => "patch install",
            WorkflowStep.InstallLuaModFiles => "Lua install",
            WorkflowStep.SaveFileSafetyWarning => "save-file safety warning",
            WorkflowStep.WriteSessionRecord => "session record write",
            WorkflowStep.WriteConnectionInfo => "connection info write",
            _ => step.ToString(),
        };
    }

    /// <summary>Fan a theme switch out to the children that carry themed keys.</summary>
    public void RefreshThemedBrushes()
    {
        Setup.RefreshThemedBrushes();
        Action.RefreshThemedBrushes();
        Landing.RefreshThemedBrushes();
    }
}
