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
    private bool _deathLink;
    private bool _allowMissableLocations;
    private bool _randomizeGatedKeys;
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

        RebuildYamlPreview();
    }

    public ObservableCollection<TypewriterOptionViewModel> TypewriterOptions { get; } = new();

    public IReadOnlyList<string> DifficultyOptions { get; } = ["Standard", "Hardcore", "Assisted", "Professional"];

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
            }
        }
    }

    /// <summary>Always-shown one-liner explaining what this file is.</summary>
    public string FileExplainer =>
        "A settings file (YAML) is a small text file that describes how your RE4R plays - "
        + "difficulty, deathlink, which locations hold checks. Every Archipelago player has one for their game.";

    /// <summary>Role-aware next-step guidance under the title.</summary>
    public string HeaderDescription => IsOrganizerContext
        ? "This is your own settings file for the multiworld you're organizing. Save or copy it, then head back to the guide - "
          + "you'll drop it in alongside everyone else's when you collect settings files."
        : "Save or copy your settings file and send it to whoever is organizing the multiworld (usually over Discord). "
          + "They'll generate the multiworld and send back your room address and slot name.";

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

    public bool RandomizeGatedKeys
    {
        get => _randomizeGatedKeys;
        set
        {
            if (SetProperty(ref _randomizeGatedKeys, value))
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
        set => SetProperty(ref _backToLandingCommand, value);
    }

    public ICommand SaveYamlCommand { get; }

    public ICommand CopyYamlCommand { get; }

    private string SuggestedFileName =>
        string.IsNullOrWhiteSpace(SlotName) ? "RE4R_You.yaml" : $"RE4R_{SlotName.Trim()}.yaml";

    private bool CanUseYaml()
    {
        return !string.IsNullOrWhiteSpace(SlotName) && !IsSlotNameBlocking();
    }

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

        DeathLink = draft.DeathLink;
        AllowMissableLocations = draft.AllowMissableLocations;
        RandomizeGatedKeys = draft.RandomizeGatedKeys;
        var selected = new HashSet<string>(draft.UnlockedTypewriterStageIds, StringComparer.Ordinal);
        foreach (var option in TypewriterOptions)
        {
            option.IsSelected = selected.Contains(option.StageId);
        }

        StatusText = $"Restored your saved settings from {draft.SavedAtUtc.ToLocalTime():yyyy-MM-dd HH:mm}.";
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
                draft.DeathLink = DeathLink;
                draft.AllowMissableLocations = AllowMissableLocations;
                draft.RandomizeGatedKeys = RandomizeGatedKeys;
                draft.UnlockedTypewriterStageIds = TypewriterOptions
                    .Where(option => option.IsSelected)
                    .Select(option => option.StageId)
                    .ToList();
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
            DeathLink = DeathLink,
            AllowMissableLocations = AllowMissableLocations,
            RandomizeGatedKeys = RandomizeGatedKeys,
            UnlockedTypewriterStageIds = TypewriterOptions
                .Where(option => option.IsSelected)
                .Select(option => option.StageId)
                .ToArray(),
        };
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
