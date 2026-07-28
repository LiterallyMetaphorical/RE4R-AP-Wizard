using System.Windows.Input;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

/// <summary>
/// Landing state machine (redesign step 2, question order per Cam
/// 2026-07-12): an auto-surfaced session banner when a patched/in-progress
/// session exists, a draft strip for the joiner who configured a YAML and is
/// waiting on room details, then ONE question at a time - role first ("Are
/// you organizing this multiworld, or is someone else?"), and only the
/// someone-else answer reveals the room-address question.
/// </summary>
public sealed class LandingViewModel : ObservableObject
{
    private const string OkBackground = "#D9F2E3";
    private const string OkBorder = "#9CD6B4";
    private const string WarnBackground = "#FFF4D6";
    private const string WarnBorder = "#E8C97A";
    private const string NeutralBackground = "#EFEFEF";
    private const string NeutralBorder = "#D4D4D4";

    private string _blockingIssuesText = string.Empty;
    private bool _isBannerVisible;
    private string _bannerTitle = string.Empty;
    private string _bannerBody = string.Empty;
    private string _bannerBackground = NeutralBackground;
    private string _bannerBorder = NeutralBorder;
    private bool _showOpenRoomPage;
    private bool _showReconnectPrefill;
    private bool _showFixAddress;
    private bool _showRepatch;
    private bool _showFinishPatch;
    private bool _showRetire;
    private bool _isDraftVisible;
    private string _draftText = string.Empty;
    private string _draftPrimaryButtonText = DefaultDraftPrimaryButtonText;

    public const string DefaultDraftPrimaryButtonText = "I Got My Room Address - Join";
    private ICommand? _startCreateCommand;
    private ICommand? _startJoinCommand;
    private ICommand? _startConfigureYamlCommand;
    private ICommand? _openRoomPageCommand;
    private ICommand? _reconnectPrefillCommand;
    private ICommand? _fixAddressCommand;
    private ICommand? _repatchCommand;
    private ICommand? _finishPatchCommand;
    private ICommand? _retireCommand;
    private ICommand? _draftJoinCommand;
    private ICommand? _draftEditCommand;
    private ICommand? _openSetupCommand;

    public string BlockingIssuesText
    {
        get => _blockingIssuesText;
        set
        {
            if (SetProperty(ref _blockingIssuesText, value))
            {
                OnPropertyChanged(nameof(HasBlockingIssues));
            }
        }
    }

    public bool HasBlockingIssues => !string.IsNullOrWhiteSpace(BlockingIssuesText);

    public bool IsBannerVisible
    {
        get => _isBannerVisible;
        private set => SetProperty(ref _isBannerVisible, value);
    }

    public string BannerTitle
    {
        get => _bannerTitle;
        private set => SetProperty(ref _bannerTitle, value);
    }

    public string BannerBody
    {
        get => _bannerBody;
        private set => SetProperty(ref _bannerBody, value);
    }

    public string BannerBackground
    {
        get => _bannerBackground;
        private set => SetProperty(ref _bannerBackground, value);
    }

    public string BannerBorder
    {
        get => _bannerBorder;
        private set => SetProperty(ref _bannerBorder, value);
    }

    public bool ShowOpenRoomPage
    {
        get => _showOpenRoomPage;
        private set => SetProperty(ref _showOpenRoomPage, value);
    }

    public bool ShowReconnectPrefill
    {
        get => _showReconnectPrefill;
        private set => SetProperty(ref _showReconnectPrefill, value);
    }

    public bool ShowFixAddress
    {
        get => _showFixAddress;
        private set => SetProperty(ref _showFixAddress, value);
    }

    public bool ShowRepatch
    {
        get => _showRepatch;
        private set => SetProperty(ref _showRepatch, value);
    }

    public bool ShowFinishPatch
    {
        get => _showFinishPatch;
        private set => SetProperty(ref _showFinishPatch, value);
    }

    public bool ShowRetire
    {
        get => _showRetire;
        private set => SetProperty(ref _showRetire, value);
    }

    public bool IsDraftVisible
    {
        get => _isDraftVisible;
        private set => SetProperty(ref _isDraftVisible, value);
    }

    public string DraftText
    {
        get => _draftText;
        private set => SetProperty(ref _draftText, value);
    }

    public string DraftPrimaryButtonText
    {
        get => _draftPrimaryButtonText;
        private set => SetProperty(ref _draftPrimaryButtonText, value);
    }

    private bool _isRoleStage = true;

    /// <summary>First landing question: organizer role. One question at a time.</summary>
    public bool IsRoleStage
    {
        get => _isRoleStage;
        private set
        {
            if (SetProperty(ref _isRoleStage, value))
            {
                OnPropertyChanged(nameof(IsAddressStage));
            }
        }
    }

    public bool IsAddressStage => !IsRoleStage;

    public ICommand AnswerSomeoneElseCommand => _answerSomeoneElseCommand ??= new RelayCommand(() => IsRoleStage = false);

    public ICommand BackToRoleQuestionCommand => _backToRoleQuestionCommand ??= new RelayCommand(() => IsRoleStage = true);

    private RelayCommand? _answerSomeoneElseCommand;
    private RelayCommand? _backToRoleQuestionCommand;

    public ICommand? StartCreateCommand
    {
        get => _startCreateCommand;
        set => SetProperty(ref _startCreateCommand, value);
    }

    /// <summary>Returns to the Setup Status screen (the launcher's first screen).</summary>
    public ICommand? OpenSetupCommand
    {
        get => _openSetupCommand;
        set => SetProperty(ref _openSetupCommand, value);
    }

    public ICommand? StartJoinCommand
    {
        get => _startJoinCommand;
        set => SetProperty(ref _startJoinCommand, value);
    }

    public ICommand? StartConfigureYamlCommand
    {
        get => _startConfigureYamlCommand;
        set => SetProperty(ref _startConfigureYamlCommand, value);
    }

    public ICommand? OpenRoomPageCommand
    {
        get => _openRoomPageCommand;
        set => SetProperty(ref _openRoomPageCommand, value);
    }

    public ICommand? ReconnectPrefillCommand
    {
        get => _reconnectPrefillCommand;
        set => SetProperty(ref _reconnectPrefillCommand, value);
    }

    /// <summary>
    /// One-click heal: re-derive the room's current address from the room
    /// page, verify the seed, rewrite the connection files. No re-patch.
    /// </summary>
    public ICommand? FixAddressCommand
    {
        get => _fixAddressCommand;
        set => SetProperty(ref _fixAddressCommand, value);
    }

    /// <summary>Re-patches the banner session in place (recorded options replayed).</summary>
    public ICommand? RepatchCommand
    {
        get => _repatchCommand;
        set => SetProperty(ref _repatchCommand, value);
    }

    public ICommand? FinishPatchCommand
    {
        get => _finishPatchCommand;
        set => SetProperty(ref _finishPatchCommand, value);
    }

    public ICommand? RetireCommand
    {
        get => _retireCommand;
        set => SetProperty(ref _retireCommand, value);
    }

    public ICommand? DraftJoinCommand
    {
        get => _draftJoinCommand;
        set => SetProperty(ref _draftJoinCommand, value);
    }

    public ICommand? DraftEditCommand
    {
        get => _draftEditCommand;
        set => SetProperty(ref _draftEditCommand, value);
    }

    public void HideBanner()
    {
        IsBannerVisible = false;
        ShowOpenRoomPage = false;
        ShowReconnectPrefill = false;
        ShowFixAddress = false;
        ShowRepatch = false;
        ShowFinishPatch = false;
        ShowRetire = false;
    }

    public void ShowReadyBanner(string slotName, string serverDisplay, bool hasRoomUrl, bool seedVerified)
    {
        BannerTitle = $"Your multiworld {slotName} is all set!";
        BannerBody = (seedVerified
                ? $"Your room answered at {serverDisplay} and confirmed it is this multiworld. Just launch RE4R from Steam to continue - it will reconnect you automatically. "
                : $"Just launch RE4R from Steam to continue - it will reconnect you automatically ({serverDisplay}). ")
            + "Re-Patch This Session applies launcher updates to this same world (same seed, same item placements). "
            + "Or set up a new multiworld below.";
        BannerBackground = OkBackground;
        BannerBorder = OkBorder;
        ShowOpenRoomPage = hasRoomUrl;
        ShowReconnectPrefill = false;
        ShowFixAddress = false;
        ShowRepatch = true;
        ShowFinishPatch = false;
        ShowRetire = true;
        IsBannerVisible = true;
    }

    public void ShowUnreachableBanner(string slotName, string serverDisplay, bool hasRoomUrl)
    {
        BannerTitle = $"Your multiworld {slotName} may be asleep.";
        BannerBody = $"The room at {serverDisplay} did not answer. archipelago.gg rooms pause after inactivity and can wake on a different address - "
            + (hasRoomUrl
                ? "Fix Address Automatically wakes the room from your room page, finds its current address, and updates the game connection (no re-patch)."
                : "open your room page to wake it, then reconnect (your game is NOT re-patched; it just updates the address).");
        BannerBackground = WarnBackground;
        BannerBorder = WarnBorder;
        ShowOpenRoomPage = hasRoomUrl;
        ShowReconnectPrefill = true;
        ShowFixAddress = hasRoomUrl;
        ShowRepatch = false;
        ShowFinishPatch = false;
        ShowRetire = true;
        IsBannerVisible = true;
    }

    /// <summary>
    /// The address answered, but a DIFFERENT room lives there now -
    /// archipelago.gg recycles ports, so this is the "stranger's room" case
    /// that used to render as "all set" (or as a baffling InvalidSlot
    /// in-game).
    /// </summary>
    public void ShowWrongRoomBanner(string slotName, string serverDisplay, string foundSeedDisplay, bool hasRoomUrl)
    {
        BannerTitle = $"A different multiworld is answering at your {slotName} address.";
        BannerBody = $"Something answered at {serverDisplay}, but it is {foundSeedDisplay} - not this session's room. "
            + "archipelago.gg reuses ports, so your room most likely woke up on a new address. "
            + (hasRoomUrl
                ? "Fix Address Automatically finds the current address from your room page and updates the game connection (no re-patch)."
                : "Open your room page to find the current address, then use Reconnect / Update Address.");
        BannerBackground = WarnBackground;
        BannerBorder = WarnBorder;
        ShowOpenRoomPage = hasRoomUrl;
        ShowReconnectPrefill = true;
        ShowFixAddress = hasRoomUrl;
        ShowRepatch = false;
        ShowFinishPatch = false;
        ShowRetire = true;
        IsBannerVisible = true;
    }

    public void ShowCheckingBanner(string slotName, string serverDisplay)
    {
        BannerTitle = $"Your multiworld {slotName} is patched.";
        BannerBody = $"Checking whether the room at {serverDisplay} is awake...";
        BannerBackground = NeutralBackground;
        BannerBorder = NeutralBorder;
        ShowOpenRoomPage = false;
        ShowReconnectPrefill = false;
        ShowFixAddress = false;
        ShowRepatch = false;
        ShowFinishPatch = false;
        ShowRetire = true;
        IsBannerVisible = true;
    }

    public void ShowUnfinishedPatchBanner(string slotName, string seedName)
    {
        BannerTitle = "Your last patch didn't finish.";
        BannerBody = $"The patch for {slotName} on {seedName} was interrupted. Finish it now - that's safe: it rebuilds the same world, with the same items in the same places.";
        BannerBackground = WarnBackground;
        BannerBorder = WarnBorder;
        ShowOpenRoomPage = false;
        ShowReconnectPrefill = false;
        ShowFixAddress = false;
        ShowRepatch = false;
        ShowFinishPatch = true;
        ShowRetire = false;
        IsBannerVisible = true;
    }

    public void SetDraft(string? draftText, string? primaryButtonText = null)
    {
        DraftText = draftText ?? string.Empty;
        DraftPrimaryButtonText = string.IsNullOrWhiteSpace(primaryButtonText)
            ? DefaultDraftPrimaryButtonText
            : primaryButtonText;
        IsDraftVisible = !string.IsNullOrWhiteSpace(draftText);
    }
}
