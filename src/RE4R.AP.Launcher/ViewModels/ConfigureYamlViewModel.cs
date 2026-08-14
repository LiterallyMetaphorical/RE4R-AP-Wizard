using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Windows.Input;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using RE4R.AP.Launcher.Infrastructure;
using RE4R.AP.Launcher.Models;
using RE4R.AP.Launcher.Services;

namespace RE4R.AP.Launcher.ViewModels;

/// <summary>
/// First-class "Configure your RE4R YAML" step, extracted from the retired
/// host flow so both joiners and organizers can build their settings file
/// without touching any hosting machinery. Works standalone: it needs no
/// game install, no room, and no network.
/// </summary>
public sealed class ConfigureYamlViewModel : ObservableObject
{
    private readonly Re4rYamlBuilder _re4rYamlBuilder;
    private readonly IUiDialogService _dialogService;
    private readonly ActionViewModel _action;
    private readonly PendingSessionDraftStore _draftStore;
    private readonly AsyncRelayCommand _saveYamlCommand;
    private readonly RelayCommand _copyYamlCommand;

    private string _slotName = string.Empty;
    private string _slotNameError = string.Empty;
    private string _selectedDifficulty = "Standard";
    private int _progressionBalancing = 70;
    private CheckGuidanceOption _selectedCheckGuidance = CheckGuidanceOptionList[0];
    private MarkerDetailOption _selectedMarkerDetail = MarkerDetailOptionList[2];
    private bool _deathLink;
    private bool _allowMissableLocations;
    private bool _shuffleKeycards;
    private bool _minimizeBacktracking;
    private bool _randomEvents;
    private int _shopChecks = 16;
    private bool _shopChecksEnabled = true;
    private bool _tutorial = true;
    private string _yamlPreview = "Enter your slot name to generate the YAML preview.";
    private string _statusText = "Choose your RE4R settings - they save automatically as you edit.";
    private ICommand? _backToLandingCommand;
    private bool _isOrganizerContext;
    private bool _isRestoring;
    private CancellationTokenSource? _autoSaveCancellationSource;

    public ConfigureYamlViewModel(
        Re4rYamlBuilder re4rYamlBuilder,
        IUiDialogService dialogService,
        ActionViewModel action,
        PendingSessionDraftStore draftStore)
    {
        _re4rYamlBuilder = re4rYamlBuilder ?? throw new ArgumentNullException(nameof(re4rYamlBuilder));
        _dialogService = dialogService ?? throw new ArgumentNullException(nameof(dialogService));
        _action = action ?? throw new ArgumentNullException(nameof(action));
        _draftStore = draftStore ?? throw new ArgumentNullException(nameof(draftStore));

        _saveYamlCommand = new AsyncRelayCommand(SaveYamlAsync, CanUseYaml);
        _copyYamlCommand = new RelayCommand(CopyYaml, CanUseYaml);
        SaveYamlCommand = _saveYamlCommand;
        CopyYamlCommand = _copyYamlCommand;

        foreach (var option in CreateTypewriterOptions())
        {
            option.PropertyChanged += OnTypewriterOptionPropertyChanged;
            TypewriterOptions.Add(option);
        }

        // Amondo's request: the AP item/location options, in the editor instead
        // of hand-written. Each pair is two directions on one list, so it is one
        // picker with a stance per row rather than two lists that could
        // contradict each other.
        var staticData = new StaticGameDataProvider().TryLoad();
        ItemSelection = new YamlSelectionListViewModel(
            "Items",
            "Anywhere",
            "Keep in my world",
            "Send to another world",
            "Search items...",
            staticData?.ItemGroups ?? new Dictionary<string, List<string>>(),
            staticData?.Items.Values.Select(item => item.Name) ?? Enumerable.Empty<string>());
        LocationSelection = new YamlSelectionListViewModel(
            "Locations",
            "Anything",
            "Never anything important",
            "Always something important",
            "Search locations...",
            staticData?.LocationGroups ?? new Dictionary<string, List<string>>(),
            staticData?.Locations.Values.Select(location => location.Name) ?? Enumerable.Empty<string>());
        ItemSelection.SelectionChanged += OnSelectionChanged;
        LocationSelection.SelectionChanged += OnSelectionChanged;

        RebuildYamlPreview();
    }

    /// <summary>local_items / non_local_items, as one stance per item.</summary>
    public YamlSelectionListViewModel ItemSelection { get; }

    /// <summary>exclude_locations / priority_locations, as one stance per location.</summary>
    public YamlSelectionListViewModel LocationSelection { get; }

    // Archipelago drops local_items and non_local_items entirely when a seed
    // has one player (Main.py clears them before fill), so a solo player who
    // sets them gets silence. Say so rather than let them wonder.
    public string ItemSelectionHint =>
        "Only applies in a multiworld. A solo seed ignores these, because there is nowhere else for an item to go. "
        + "Progression is everything the logic can require, and it contains the other two: the 28 Key Items, the Small Key, "
        + "and the Biosensor Scope. Choose Key Items for the doors and quest items alone, or search for one item by name.";

    public string LocationSelectionHint =>
        "\"Never anything important\" keeps progression and useful items off a spot. \"Always something important\" reserves it for one. Marking a lot of spots as important can over-constrain generation, so use it sparingly.";

    public ObservableCollection<TypewriterOptionViewModel> TypewriterOptions { get; } = new();

    public IReadOnlyList<string> DifficultyOptions { get; } = ["Standard", "Hardcore", "Assisted", "Professional"];

    // Mirrors ArchipelagoRE4R/options.py CheckGuidance (off/markers/markers_rarity).
    // The friendly label is shown in the dropdown; Value is written to the YAML.
    private static readonly IReadOnlyList<CheckGuidanceOption> CheckGuidanceOptionList =
    [
        new("Markers (recommended)", "markers", "Markers"),
        new("Markers + rarity colours", "markers_rarity", "+ Rarity"),
        new("Off (no markers)", "off", "Off"),
    ];

    public IReadOnlyList<CheckGuidanceOption> CheckGuidanceOptions => CheckGuidanceOptionList;

    // Ceiling on how much a world marker may say. Players still choose their
    // own level in game; this is the most the host allows. Ordered least to
    // most revealing, defaulting to Locate: everything about finding the spot,
    // nothing about what the multiworld put in it.
    private static readonly IReadOnlyList<MarkerDetailOption> MarkerDetailOptionList =
    [
        new("Minimal - distance and height", "minimal", "Minimal"),
        new("Basic - + chapter and area", "basic", "Basic"),
        new("Locate - + item, container, how to reach it (recommended)", "locate", "Locate"),
        new("Identify - + the real item and its owner (spoiler)", "identify", "Identify"),
    ];

    public IReadOnlyList<MarkerDetailOption> MarkerDetailOptions => MarkerDetailOptionList;

    public MarkerDetailOption SelectedMarkerDetail
    {
        get => _selectedMarkerDetail;
        set
        {
            // The ComboBox can push a transient null while its items rebuild.
            if (value is not null && SetProperty(ref _selectedMarkerDetail, value))
            {
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    // Landmarks the progression-balancing slider soft-snaps to. Any 0-99 value
    // is still selectable; the snap just makes the common picks easy to land on.
    private static readonly (int Value, string Name)[] ProgressionBalancingLandmarks =
    [
        (0, "Disabled"),
        (50, "Normal"),
        (70, "Recommended"),
        (99, "Aggressive"),
    ];

    private const int ProgressionBalancingSnapRadius = 2;

    public event Action? DraftSaved;

    public string SlotName
    {
        get => _slotName;
        set
        {
            if (SetProperty(ref _slotName, value))
            {
                ValidateSlotName();
                RebuildYamlPreview();
                UpdateCommandStates();
                QueueDraftSave();
                // The handoff panel names the file they are about to send.
                OnPropertyChanged(nameof(SuggestedFileName));
            }
        }
    }

    public string SlotNameError
    {
        get => _slotNameError;
        private set
        {
            if (SetProperty(ref _slotNameError, value))
            {
                OnPropertyChanged(nameof(HasSlotNameError));
            }
        }
    }

    public bool HasSlotNameError => !string.IsNullOrWhiteSpace(SlotNameError);

    /// <summary>
    /// True when the screen was opened from the organizer's Generation Guidance
    /// wizard (their own settings file), false when opened from the landing as
    /// a joiner. Drives role-aware header copy so the organizer isn't told to
    /// "send it to whoever is organizing" - they ARE that person.
    /// </summary>
    public bool IsOrganizerContext
    {
        get => _isOrganizerContext;
        set
        {
            if (SetProperty(ref _isOrganizerContext, value))
            {
                OnPropertyChanged(nameof(HeaderDescription));
                OnPropertyChanged(nameof(ShowJoinerHandoff));
                OnPropertyChanged(nameof(YamlPreviewHint));
                RebuildFooter();
            }
        }
    }

    /// <summary>Always-shown one-liner explaining what this file is.</summary>
    public string FileExplainer =>
        "Archipelago calls these settings a YAML - a small text file describing how your RE4R plays "
        + "(difficulty, DeathLink, which options you want). Every player in a multiworld has one for "
        + "their game, and your host needs yours before they can generate the multiworld.";

    /// <summary>Role-aware next-step guidance under the title.</summary>
    public string HeaderDescription => IsOrganizerContext
        ? "This is your own settings file for the multiworld you're organizing. Save or copy it, then head back to the guide - "
          + "you'll drop it in alongside everyone else's when you collect settings files."
        : "Save or copy your settings file and send it to whoever is hosting the multiworld (usually over Discord). "
          + "They'll generate the multiworld and send back your room address - then continue below to join it. "
          + "Already sent yours? Continue straight on.";

    public string SelectedDifficulty
    {
        get => _selectedDifficulty;
        set
        {
            if (SetProperty(ref _selectedDifficulty, value))
            {
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    /// <summary>
    /// Stock AP progression balancing (0-99). The setter soft-snaps to the
    /// nearest landmark so the slider lands cleanly on Disabled/Normal/
    /// Recommended/Aggressive without forbidding the values in between.
    /// </summary>
    public int ProgressionBalancing
    {
        get => _progressionBalancing;
        set
        {
            var snapped = SoftSnapProgressionBalancing(value);
            if (SetProperty(ref _progressionBalancing, snapped))
            {
                OnPropertyChanged(nameof(ProgressionBalancingLabel));
                RebuildYamlPreview();
                QueueDraftSave();
            }
            else if (snapped != value)
            {
                // The raw slider value snapped back to where we already were
                // (e.g. nudging 71 -> 70). SetProperty saw no change, so the
                // slider still shows the un-snapped value - pull it back.
                OnPropertyChanged(nameof(ProgressionBalancing));
            }
        }
    }

    /// <summary>Numeric value plus its landmark name, e.g. "70 - Recommended".</summary>
    public string ProgressionBalancingLabel
    {
        get
        {
            foreach (var (value, name) in ProgressionBalancingLandmarks)
            {
                if (value == _progressionBalancing)
                {
                    return $"{_progressionBalancing} - {name}";
                }
            }

            return $"{_progressionBalancing} - Custom";
        }
    }

    public CheckGuidanceOption SelectedCheckGuidance
    {
        get => _selectedCheckGuidance;
        set
        {
            // The ComboBox can push a transient null while its items rebuild.
            if (value is not null && SetProperty(ref _selectedCheckGuidance, value))
            {
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    public bool DeathLink
    {
        get => _deathLink;
        set
        {
            if (SetProperty(ref _deathLink, value))
            {
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    public bool AllowMissableLocations
    {
        get => _allowMissableLocations;
        set
        {
            if (SetProperty(ref _allowMissableLocations, value))
            {
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    public bool ShuffleKeycards
    {
        get => _shuffleKeycards;
        set
        {
            if (SetProperty(ref _shuffleKeycards, value))
            {
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    public bool MinimizeBacktracking
    {
        get => _minimizeBacktracking;
        set
        {
            if (SetProperty(ref _minimizeBacktracking, value))
            {
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    public bool RandomEvents
    {
        get => _randomEvents;
        set
        {
            if (!SetProperty(ref _randomEvents, value))
            {
                return;
            }

            RebuildYamlPreview();
            QueueDraftSave();

            // Warn on the way ON, where the choice is actually made (this is
            // the YAML option now: the multiworld rolls the event set at
            // generation, so the moment to think twice is here, not at patch
            // time). Restores of a saved draft do not re-warn.
            if (value && !_isRestoring)
            {
                WarnRandomEventsExperimental();
            }
        }
    }

    /// <summary>
    /// How many merchant buy-tab rows are AP checks. Clamped to the apworld's
    /// own range so a hand-edited draft cannot produce a YAML the world
    /// rejects.
    /// </summary>
    public int ShopChecks
    {
        get => _shopChecks;
        set
        {
            var clamped = Math.Clamp(value, 0, 24);
            if (SetProperty(ref _shopChecks, clamped))
            {
                OnPropertyChanged(nameof(ShopChecksLabel));
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    /// <summary>
    /// On/off for the merchant. The count lives behind it, so turning the
    /// feature off does not mean hunting for zero on a slider, and turning it
    /// back on remembers the number you had.
    /// </summary>
    public bool ShopChecksEnabled
    {
        get => _shopChecksEnabled;
        set
        {
            if (SetProperty(ref _shopChecksEnabled, value))
            {
                OnPropertyChanged(nameof(ShopChecksLabel));
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    /// <summary>Slider read-out, e.g. "16 shop checks".</summary>
    public string ShopChecksLabel => !_shopChecksEnabled
        ? "Off - the merchant sells no checks"
        : $"{_shopChecks} shop check{(_shopChecks == 1 ? string.Empty : "s")}";

    /// <summary>
    /// The old BioRand-page warning said the logic knows nothing about Random
    /// Events, and turned the option back off by default. That is no longer
    /// true: the multiworld authors the event set and the logic reacts. This
    /// is its replacement - an experimental-feature note, not a logic alarm.
    /// </summary>
    private async void WarnRandomEventsExperimental()
    {
        try
        {
            // Yield first: this arrives from a checkbox's property-change
            // notification, and opening a modal dialog inside that never
            // shows. Let the input event finish, then prompt.
            await Task.Yield();

            var proceed = await _dialogService.ConfirmProceedWithWarningAsync(
                "Random Events Is Experimental",
                "The multiworld will pick BioRand's Random Events itself when this room "
                + "generates. Only events the logic understands can fire, and the seed's "
                + "logic reacts to them: a couple of checks can trade places, and one event "
                + "can remove the Hexagonal Emblem pickup and hand the emblem to a guardian "
                + "enemy instead."
                + Environment.NewLine + Environment.NewLine
                + "This is new and lightly tested. The in-game markers follow moved checks, "
                + "but expect rough edges, and report anything odd."
                + Environment.NewLine + Environment.NewLine
                + "Patching happens through this launcher's bundled BioRand, which turns the "
                + "events machinery on automatically for rooms that use this.",
                proceedLabel: "Keep It On",
                cancelLabel: "Turn It Back Off");

            if (!proceed)
            {
                RandomEvents = false;
                _action.AppendLog("Random Events turned back off.");
            }
            else
            {
                _action.AppendLog("Random Events enabled (experimental): the multiworld will author the event set.");
            }
        }
        catch (Exception ex)
        {
            _action.AppendLog($"Could not show the Random Events note: {ex.Message}");
        }
    }

    public bool Tutorial
    {
        get => _tutorial;
        set
        {
            if (SetProperty(ref _tutorial, value))
            {
                RebuildYamlPreview();
                QueueDraftSave();
            }
        }
    }

    public string YamlPreview
    {
        get => _yamlPreview;
        private set => SetProperty(ref _yamlPreview, value);
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
                RebuildFooter();
            }
        }
    }

    /// <summary>
    /// The joiner's onward step. Join leads here first (the settings file has
    /// no prerequisites), so this screen carries the path forward rather than
    /// dead-ending at Back. The next screen states what it needs - this
    /// button does not ask or assume anything.
    /// </summary>
    public ICommand? ContinueCommand
    {
        get => _continueCommand;
        set
        {
            if (SetProperty(ref _continueCommand, value))
            {
                RebuildFooter();
            }
        }
    }

    private ICommand? _continueCommand;

    /// <summary>Sticky footer actions, pinned by the shell above the log.</summary>
    public System.Collections.ObjectModel.ObservableCollection<FooterButtonViewModel> FooterButtons { get; } = new();

    private void RebuildFooter()
    {
        FooterButtons.Clear();
        FooterButtons.Add(new FooterButtonViewModel("Back", BackToLandingCommand));
        FooterButtons.Add(new FooterButtonViewModel("Save to File...", SaveYamlCommand));
        FooterButtons.Add(new FooterButtonViewModel("Copy to Clipboard", CopyYamlCommand));
        // Both roles get Continue. The organizer's command (wired by the
        // shell) returns to the guide and advances it, so the host no longer
        // pays Back-then-Next for what a joiner does in one press
        // (playtest round 2).
        FooterButtons.Add(new FooterButtonViewModel("Continue", ContinueCommand, isPrimary: true));
    }

    public ICommand SaveYamlCommand { get; }

    public ICommand CopyYamlCommand { get; }

    /// <summary>
    /// Shown to joiners only: an organizer generating their own multiworld is
    /// not sending anything to anybody.
    /// </summary>
    public bool ShowJoinerHandoff => !IsOrganizerContext;

    // An organizer reaches this screen too, and telling them to send their file
    // "to your host" is telling them to post it to themselves. The panels either
    // side of this already switch on context; this line was loose text and got
    // missed when they did (fafa8cb).
    public string YamlPreviewHint => IsOrganizerContext
        ? "This updates automatically from the settings above. Save it into your Players folder alongside everyone else's, or copy it if you would rather paste it in yourself."
        : "This updates automatically from the settings above. Save or copy it to send the file to your host - your settings are remembered here either way.";

    /// <summary>Opens the folder holding the bundled RE4R.apworld.</summary>
    public System.Windows.Input.ICommand? OpenApworldFolderCommand { get; set; }

    public string SuggestedFileName =>
        string.IsNullOrWhiteSpace(SlotName) ? "RE4R_You.yaml" : $"RE4R_{SlotName.Trim()}.yaml";

    private bool CanUseYaml()
    {
        return !string.IsNullOrWhiteSpace(SlotName) && !IsSlotNameBlocking();
    }

    /// <summary>
    /// Continuing needs a usable slot name - it is the player's identity in
    /// the room, and the join step cannot be completed without it.
    /// </summary>
    public bool CanContinue => CanUseYaml();

    // Archipelago silently truncates slot names to 16 characters at
    // generation time and refuses the reserved name - authoring an invalid
    // slot here would strand the player at connect with a raw InvalidSlot
    // days later (review: slot-name-validation / audit launcherui-8).
    private void ValidateSlotName()
    {
        var raw = SlotName;
        var trimmed = raw.Trim();

        if (string.IsNullOrEmpty(trimmed))
        {
            SlotNameError = string.Empty;
            return;
        }

        if (trimmed.Length > 16)
        {
            SlotNameError = $"Too long ({trimmed.Length} characters) - Archipelago cuts slot names to 16, and you would never be able to connect. Shorten it.";
            return;
        }

        if (string.Equals(trimmed, "Archipelago", StringComparison.OrdinalIgnoreCase))
        {
            SlotNameError = "That name is reserved by Archipelago - pick a different one.";
            return;
        }

        SlotNameError = !string.Equals(raw, trimmed, StringComparison.Ordinal)
            ? "Note: spaces at the start or end will be removed."
            : string.Empty;
    }

    private bool IsSlotNameBlocking()
    {
        var trimmed = SlotName.Trim();
        return trimmed.Length > 16
            || string.Equals(trimmed, "Archipelago", StringComparison.OrdinalIgnoreCase);
    }

    private async Task SaveYamlAsync()
    {
        if (!CanUseYaml())
        {
            return;
        }

        var targetPath = await _dialogService.BrowseForSaveFileAsync(
            "Save your RE4R YAML settings file",
            "YAML Files|*.yaml;*.yml",
            SuggestedFileName);

        if (string.IsNullOrWhiteSpace(targetPath))
        {
            return;
        }

        try
        {
            await File.WriteAllTextAsync(targetPath, BuildYaml());
            _action.AppendLog($"Saved RE4R YAML to {targetPath}.");
            StatusText = $"Saved {Path.GetFileName(targetPath)}. Send this file to whoever is generating your multiworld - the launcher will remember these settings.";
            _autoSaveCancellationSource?.Cancel();
            await PersistDraftAsync();
        }
        catch (Exception ex)
        {
            ReportActionFailure($"Failed to save the YAML file: {ex.Message}");
        }
    }

    private void CopyYaml()
    {
        if (!CanUseYaml())
        {
            return;
        }

        try
        {
            _ = CopyYamlToClipboardAsync();
        }
        catch (Exception ex)
        {
            ReportClipboardFailure(ex);
        }
    }

    private async Task CopyYamlToClipboardAsync()
    {
        try
        {
            await _dialogService.SetClipboardTextAsync(BuildYaml());
            _action.AppendLog("Copied the RE4R YAML to the clipboard.");
            StatusText = "YAML copied. Paste it into a file or a message to whoever is generating your multiworld - the launcher will remember these settings.";
            _autoSaveCancellationSource?.Cancel();
            await PersistDraftAsync();
        }
        catch (Exception ex)
        {
            ReportClipboardFailure(ex);
        }
    }

    private void ReportClipboardFailure(Exception ex) =>
        ReportActionFailure(
            "Could not copy to the clipboard - another program may be using it. "
                + $"Try again in a moment. ({ex.Message})");

    /// <summary>
    /// Restores a previously saved draft (slot + options) so the joiner who
    /// returns days later continues where they left off.
    /// </summary>
    public void ApplyDraft(PendingSessionDraft draft)
    {
        ArgumentNullException.ThrowIfNull(draft);

        // Restoring must not immediately re-queue a save of what was loaded.
        _isRestoring = true;
        try
        {
            ApplyDraftCore(draft);
        }
        finally
        {
            _isRestoring = false;
        }
    }

    private void ApplyDraftCore(PendingSessionDraft draft)
    {
        SlotName = draft.SlotName;
        if (DifficultyOptions.Contains(draft.Difficulty))
        {
            SelectedDifficulty = draft.Difficulty;
        }

        ProgressionBalancing = draft.ProgressionBalancing;
        var guidance = CheckGuidanceOptions.FirstOrDefault(
            option => string.Equals(option.Value, draft.CheckGuidance, StringComparison.OrdinalIgnoreCase));
        if (guidance is not null)
        {
            SelectedCheckGuidance = guidance;
        }

        var markerDetail = MarkerDetailOptions.FirstOrDefault(
            option => string.Equals(option.Value, draft.MarkerDetail, StringComparison.OrdinalIgnoreCase));
        if (markerDetail is not null)
        {
            SelectedMarkerDetail = markerDetail;
        }

        DeathLink = draft.DeathLink;
        AllowMissableLocations = draft.AllowMissableLocations;
        ShuffleKeycards = draft.ShuffleKeycards;
        MinimizeBacktracking = draft.MinimizeBacktracking;
        RandomEvents = draft.RandomEvents;
        // A saved 0 means it was switched off; keep the slider on a sensible
        // number so switching it back on is not a fresh decision.
        ShopChecksEnabled = draft.ShopChecks > 0;
        ShopChecks = draft.ShopChecks > 0 ? draft.ShopChecks : 16;
        Tutorial = draft.Tutorial;
        var selected = new HashSet<string>(draft.UnlockedTypewriterStageIds, StringComparer.Ordinal);
        foreach (var option in TypewriterOptions)
        {
            option.IsSelected = selected.Contains(option.StageId);
        }

        ItemSelection.ApplySelection(draft.LocalItems, draft.NonLocalItems);
        LocationSelection.ApplySelection(draft.ExcludeLocations, draft.PriorityLocations);

        StatusText = $"Restored your saved settings from {draft.SavedAtUtc.ToLocalTime():yyyy-MM-dd HH:mm}.";
    }

    /// <summary>
    /// Writes the draft NOW instead of on the 700ms auto-save debounce.
    /// Leaving this screen must not race the timer: the join step reads the
    /// SAVED draft, so a player who types a slot name and immediately
    /// continues would otherwise arrive with it missing.
    /// </summary>
    public async Task FlushDraftAsync()
    {
        _autoSaveCancellationSource?.Cancel();
        await PersistDraftAsync();
    }

    private async Task PersistDraftAsync()
    {
        try
        {
            // Mutate-in-place via UpdateAsync: the organizer's Generation
            // Guidance checklist lives in the same draft file, and a
            // from-scratch save here would wipe it.
            await _draftStore.UpdateAsync(draft =>
            {
                draft.SlotName = SlotName.Trim();
                draft.Difficulty = SelectedDifficulty;
                draft.ProgressionBalancing = ProgressionBalancing;
                draft.CheckGuidance = SelectedCheckGuidance.Value;
                draft.MarkerDetail = SelectedMarkerDetail.Value;
                draft.DeathLink = DeathLink;
                draft.AllowMissableLocations = AllowMissableLocations;
                draft.ShuffleKeycards = ShuffleKeycards;
                draft.MinimizeBacktracking = MinimizeBacktracking;
                draft.RandomEvents = RandomEvents;
                draft.ShopChecks = ShopChecksEnabled ? ShopChecks : 0;
                draft.Tutorial = Tutorial;
                draft.UnlockedTypewriterStageIds = TypewriterOptions
                    .Where(option => option.IsSelected)
                    .Select(option => option.StageId)
                    .ToList();
                draft.LocalItems = ItemSelection.BuildFirstList().ToList();
                draft.NonLocalItems = ItemSelection.BuildSecondList().ToList();
                draft.ExcludeLocations = LocationSelection.BuildFirstList().ToList();
                draft.PriorityLocations = LocationSelection.BuildSecondList().ToList();
                draft.YamlText = BuildYaml();
            });
            DraftSaved?.Invoke();
        }
        catch (Exception ex)
        {
            _action.AppendLog($"Could not save the settings draft: {ex.Message}");
        }
    }

    private string BuildYaml()
    {
        return _re4rYamlBuilder.Build(BuildYamlRequest());
    }

    private Re4rYamlRequest BuildYamlRequest()
    {
        return new Re4rYamlRequest
        {
            SlotName = SlotName.Trim(),
            Difficulty = SelectedDifficulty.Trim().ToLowerInvariant(),
            ProgressionBalancing = ProgressionBalancing,
            CheckGuidance = SelectedCheckGuidance.Value,
            MarkerDetail = SelectedMarkerDetail.Value,
            DeathLink = DeathLink,
            AllowMissableLocations = AllowMissableLocations,
            ShuffleKeycards = ShuffleKeycards,
            MinimizeBacktracking = MinimizeBacktracking,
            RandomEvents = RandomEvents,
            ShopChecks = ShopChecksEnabled ? ShopChecks : 0,
            Tutorial = Tutorial,
            UnlockedTypewriterStageIds = TypewriterOptions
                .Where(option => option.IsSelected)
                .Select(option => option.StageId)
                .ToArray(),
            LocalItems = ItemSelection.BuildFirstList(),
            NonLocalItems = ItemSelection.BuildSecondList(),
            ExcludeLocations = LocationSelection.BuildFirstList(),
            PriorityLocations = LocationSelection.BuildSecondList(),
        };
    }

    private void OnSelectionChanged()
    {
        if (_isRestoring)
        {
            return;
        }

        RebuildYamlPreview();
        QueueDraftSave();
    }

    private void RebuildYamlPreview()
    {
        if (string.IsNullOrWhiteSpace(SlotName))
        {
            YamlPreview = "Enter your slot name to generate the YAML preview.";
            return;
        }

        YamlPreview = BuildYaml();
    }

    private void OnTypewriterOptionPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (string.Equals(e.PropertyName, nameof(TypewriterOptionViewModel.IsSelected), StringComparison.Ordinal))
        {
            RebuildYamlPreview();
            QueueDraftSave();
        }
    }

    /// <summary>
    /// Debounced auto-persist so filling the form is enough - returning to
    /// the organizer guide (or closing the launcher) must not lose the
    /// settings. Copy/Save still persist immediately; before this they were
    /// accidentally the ONLY draft writers, so the guide's step 3 stayed
    /// locked until the player pressed one of them.
    /// </summary>
    private void QueueDraftSave()
    {
        if (_isRestoring)
        {
            return;
        }

        _autoSaveCancellationSource?.Cancel();
        _autoSaveCancellationSource?.Dispose();
        _autoSaveCancellationSource = new CancellationTokenSource();
        var token = _autoSaveCancellationSource.Token;
        _ = Task.Run(
            async () =>
            {
                try
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(700), token);
                    // Back onto the dispatcher: PersistDraftAsync snapshots
                    // TypewriterOptions, which belongs to the UI thread.
                    await _dialogService.InvokeOnUiThreadAsync(PersistIfUsableAsync);
                }
                catch (OperationCanceledException)
                {
                }
            },
            CancellationToken.None);
    }

    private Task PersistIfUsableAsync()
    {
        return CanUseYaml() ? PersistDraftAsync() : Task.CompletedTask;
    }

    private void ReportActionFailure(string message)
    {
        _action.AppendLog(message);
        _action.ErrorMessage = message;
    }

    private void UpdateCommandStates()
    {
        _saveYamlCommand.NotifyCanExecuteChanged();
        _copyYamlCommand.NotifyCanExecuteChanged();
        // The shell watches CanContinue to gate the footer's Continue.
        OnPropertyChanged(nameof(CanContinue));
    }

    private static int SoftSnapProgressionBalancing(int value)
    {
        var clamped = Math.Clamp(value, 0, 99);
        foreach (var (landmark, _) in ProgressionBalancingLandmarks)
        {
            if (Math.Abs(clamped - landmark) <= ProgressionBalancingSnapRadius)
            {
                return landmark;
            }
        }

        return clamped;
    }

    private static IEnumerable<TypewriterOptionViewModel> CreateTypewriterOptions()
    {
        // Mirrored from ArchipelagoRE4R/options.py. The UI displays the human-readable
        // names, while the generated YAML writes the underlying stage IDs.
        return
        [
            new TypewriterOptionViewModel { StageId = "40530", DisplayName = "Village Hunter Road Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "43300", DisplayName = "Farm Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "44200", DisplayName = "Abandoned Factory Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "44110", DisplayName = "Chief's House Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "40213", DisplayName = "Community Center Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "45401", DisplayName = "Church Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "46210", DisplayName = "Carrier Typewriter (Save Point) (Shooting Range Access)" },
            new TypewriterOptionViewModel { StageId = "47100", DisplayName = "Village to Control Post Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "47400", DisplayName = "Butchery Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "50200", DisplayName = "Castle Entrance Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "50400", DisplayName = "Audience Chamber Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "50600", DisplayName = "After Audience Chamber Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "51504", DisplayName = "After Bindery Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "51201", DisplayName = "Courtyard Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "53202", DisplayName = "Library Typewriter (Save Point) (Ashley)" },
            new TypewriterOptionViewModel { StageId = "54402", DisplayName = "The Depths Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "55100", DisplayName = "Mine Typewriter (Save Point) (Shooting Range)" },
            new TypewriterOptionViewModel { StageId = "55201", DisplayName = "After Blast Furnace Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "55300", DisplayName = "Hive Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "56100", DisplayName = "Ballroom Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "56103", DisplayName = "Clock Tower Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "60101", DisplayName = "Wharf Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "61500", DisplayName = "Utility Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "61107", DisplayName = "Facility 1 Typewriter (Save Point) (Shooting Range)" },
            new TypewriterOptionViewModel { StageId = "63109", DisplayName = "Waste Disposal to Cargo Depot Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "65100", DisplayName = "Campsite Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "66100", DisplayName = "After Ruins Typewriter (Save Point)" },
            new TypewriterOptionViewModel { StageId = "67103", DisplayName = "Specimen Storage Typewriter (Save Point) (Shooting Range)" },
            new TypewriterOptionViewModel { StageId = "68205", DisplayName = "Sanctuary Area 2 Typewriter (Save Point)" },
        ];
    }
}

/// <summary>
/// One entry in the Check Guidance dropdown: the friendly label shown to the
/// player and the underlying apworld option key (off / markers / markers_rarity)
/// written into the YAML.
/// </summary>
public sealed record CheckGuidanceOption(string Label, string Value, string Short);

public sealed record MarkerDetailOption(string Label, string Value, string Short);
