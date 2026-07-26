using System.Collections.ObjectModel;
using System.Windows.Input;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

public sealed class SetupViewModel : ObservableObject
{
    private const string SuccessBrush = "#D9F2E3";
    private const string SuccessForegroundBrush = "#115E2D";
    private const string WarningBrush = "#FFF4D6";
    private const string WarningForegroundBrush = "#8A5800";
    private const string ErrorBrush = "#FDE5E5";
    private const string ErrorForegroundBrush = "#8A1F1F";
    private const string NeutralBrush = "#EFEFEF";
    private const string NeutralForegroundBrush = "#555555";

    private string _installPath = string.Empty;
    private string _detectedGameVersionText = "Select your RE4R install path to detect the game version.";
    private string _fingerprintSummaryText = "No RE4R install inspected yet.";
    private string _setupStatusText = "BioRand setup has not been run yet.";
    private string _selectedGameVersion = string.Empty;
    private string _re4rStatusLabel = "Unknown";
    private string _re4rStatusText = "RE4R install detection has not run yet.";
    private string _re4rStatusBackground = NeutralBrush;
    private string _re4rStatusForeground = NeutralForegroundBrush;
    private ICommand? _browseCommand;
    private ICommand? _installReFrameworkCommand;
    private ICommand? _installArchipelagoLuaModCommand;
    private string _reFrameworkStatusLabel = "Unknown";
    private string _reFrameworkStatusText = "REFramework detection has not run yet.";
    private string _reFrameworkStatusBackground = NeutralBrush;
    private string _reFrameworkStatusForeground = NeutralForegroundBrush;
    private bool _canInstallReFramework;
    private string _archipelagoLuaModStatusLabel = "Unknown";
    private string _archipelagoLuaModStatusText = "Archipelago Lua mod detection has not run yet.";
    private string _archipelagoLuaModStatusBackground = NeutralBrush;
    private string _archipelagoLuaModStatusForeground = NeutralForegroundBrush;
    private bool _canInstallArchipelagoLuaMod;
    private string _separateWaysStatusLabel = "Unknown";
    private string _separateWaysStatusText = "Separate Ways DLC detection has not run yet.";
    private string _separateWaysStatusBackground = NeutralBrush;
    private string _separateWaysStatusForeground = NeutralForegroundBrush;
    private ICommand? _clearBioRandCacheCommand;
    private string _bioRandCacheText = "BioRand cache: checking size…";
    private bool _canClearBioRandCache;
    private ICommand? _continueCommand;

    public string InstallPath
    {
        get => _installPath;
        set => SetProperty(ref _installPath, value);
    }

    public string DetectedGameVersionText
    {
        get => _detectedGameVersionText;
        set => SetProperty(ref _detectedGameVersionText, value);
    }

    public string FingerprintSummaryText
    {
        get => _fingerprintSummaryText;
        set => SetProperty(ref _fingerprintSummaryText, value);
    }

    public string SetupStatusText
    {
        get => _setupStatusText;
        set => SetProperty(ref _setupStatusText, value);
    }

    public ObservableCollection<string> SupportedGameVersions { get; } = new();

    public string SelectedGameVersion
    {
        get => _selectedGameVersion;
        set => SetProperty(ref _selectedGameVersion, value);
    }

    public string Re4rStatusLabel
    {
        get => _re4rStatusLabel;
        set => SetProperty(ref _re4rStatusLabel, value);
    }

    public string Re4rStatusText
    {
        get => _re4rStatusText;
        set => SetProperty(ref _re4rStatusText, value);
    }

    public string Re4rStatusBackground
    {
        get => _re4rStatusBackground;
        set => SetProperty(ref _re4rStatusBackground, value);
    }

    public string Re4rStatusForeground
    {
        get => _re4rStatusForeground;
        set => SetProperty(ref _re4rStatusForeground, value);
    }

    public ICommand? BrowseCommand
    {
        get => _browseCommand;
        set => SetProperty(ref _browseCommand, value);
    }

    /// <summary>
    /// Leaves the Setup Status screen for the landing. Always enabled: an
    /// organizer or YAML-only player must get past setup even while the RE4R
    /// checks fail (joining stays gated on the blockers regardless).
    /// </summary>
    public ICommand? ContinueCommand
    {
        get => _continueCommand;
        set => SetProperty(ref _continueCommand, value);
    }

    /// <summary>Reclaims the ~850 MB BioRand cache (now in LocalAppData).</summary>
    public ICommand? ClearBioRandCacheCommand
    {
        get => _clearBioRandCacheCommand;
        set => SetProperty(ref _clearBioRandCacheCommand, value);
    }

    /// <summary>e.g. "BioRand cache: 0.9 GB (in LocalAppData)".</summary>
    public string BioRandCacheText
    {
        get => _bioRandCacheText;
        set => SetProperty(ref _bioRandCacheText, value);
    }

    /// <summary>False while empty or a clear is mid-flight (hides/disables the button).</summary>
    public bool CanClearBioRandCache
    {
        get => _canClearBioRandCache;
        set => SetProperty(ref _canClearBioRandCache, value);
    }

    public ICommand? InstallReFrameworkCommand
    {
        get => _installReFrameworkCommand;
        set
        {
            if (SetProperty(ref _installReFrameworkCommand, value))
            {
                OnPropertyChanged(nameof(ShowInstallReFrameworkButton));
            }
        }
    }

    public ICommand? InstallArchipelagoLuaModCommand
    {
        get => _installArchipelagoLuaModCommand;
        set
        {
            if (SetProperty(ref _installArchipelagoLuaModCommand, value))
            {
                OnPropertyChanged(nameof(ShowInstallArchipelagoLuaModButton));
            }
        }
    }

    public string ReFrameworkStatusLabel
    {
        get => _reFrameworkStatusLabel;
        set => SetProperty(ref _reFrameworkStatusLabel, value);
    }

    public string ReFrameworkStatusText
    {
        get => _reFrameworkStatusText;
        set => SetProperty(ref _reFrameworkStatusText, value);
    }

    public string ReFrameworkStatusBackground
    {
        get => _reFrameworkStatusBackground;
        set => SetProperty(ref _reFrameworkStatusBackground, value);
    }

    public string ReFrameworkStatusForeground
    {
        get => _reFrameworkStatusForeground;
        set => SetProperty(ref _reFrameworkStatusForeground, value);
    }

    public bool CanInstallReFramework
    {
        get => _canInstallReFramework;
        set
        {
            if (SetProperty(ref _canInstallReFramework, value))
            {
                OnPropertyChanged(nameof(ShowInstallReFrameworkButton));
            }
        }
    }

    public bool ShowInstallReFrameworkButton => CanInstallReFramework && InstallReFrameworkCommand is not null;

    public string ArchipelagoLuaModStatusLabel
    {
        get => _archipelagoLuaModStatusLabel;
        set => SetProperty(ref _archipelagoLuaModStatusLabel, value);
    }

    public string ArchipelagoLuaModStatusText
    {
        get => _archipelagoLuaModStatusText;
        set => SetProperty(ref _archipelagoLuaModStatusText, value);
    }

    public string ArchipelagoLuaModStatusBackground
    {
        get => _archipelagoLuaModStatusBackground;
        set => SetProperty(ref _archipelagoLuaModStatusBackground, value);
    }

    public string ArchipelagoLuaModStatusForeground
    {
        get => _archipelagoLuaModStatusForeground;
        set => SetProperty(ref _archipelagoLuaModStatusForeground, value);
    }

    public bool CanInstallArchipelagoLuaMod
    {
        get => _canInstallArchipelagoLuaMod;
        set
        {
            if (SetProperty(ref _canInstallArchipelagoLuaMod, value))
            {
                OnPropertyChanged(nameof(ShowInstallArchipelagoLuaModButton));
            }
        }
    }

    public bool ShowInstallArchipelagoLuaModButton => CanInstallArchipelagoLuaMod && InstallArchipelagoLuaModCommand is not null;

    public string SeparateWaysStatusLabel
    {
        get => _separateWaysStatusLabel;
        set => SetProperty(ref _separateWaysStatusLabel, value);
    }

    public string SeparateWaysStatusText
    {
        get => _separateWaysStatusText;
        set => SetProperty(ref _separateWaysStatusText, value);
    }

    public string SeparateWaysStatusBackground
    {
        get => _separateWaysStatusBackground;
        set => SetProperty(ref _separateWaysStatusBackground, value);
    }

    public string SeparateWaysStatusForeground
    {
        get => _separateWaysStatusForeground;
        set => SetProperty(ref _separateWaysStatusForeground, value);
    }

    public void SetRe4rStatus(string label, string text, string severity)
    {
        Re4rStatusLabel = label;
        Re4rStatusText = text;
        ApplySeverity(severity, out var background, out var foreground);
        Re4rStatusBackground = background;
        Re4rStatusForeground = foreground;
    }

    public void SetReFrameworkStatus(string label, string text, string severity)
    {
        ReFrameworkStatusLabel = label;
        ReFrameworkStatusText = text;
        ApplySeverity(severity, out var background, out var foreground);
        ReFrameworkStatusBackground = background;
        ReFrameworkStatusForeground = foreground;
    }

    public void SetSeparateWaysStatus(string label, string text, string severity)
    {
        SeparateWaysStatusLabel = label;
        SeparateWaysStatusText = text;
        ApplySeverity(severity, out var background, out var foreground);
        SeparateWaysStatusBackground = background;
        SeparateWaysStatusForeground = foreground;
    }

    public void SetArchipelagoLuaModStatus(string label, string text, string severity)
    {
        ArchipelagoLuaModStatusLabel = label;
        ArchipelagoLuaModStatusText = text;
        ApplySeverity(severity, out var background, out var foreground);
        ArchipelagoLuaModStatusBackground = background;
        ArchipelagoLuaModStatusForeground = foreground;
    }

    private static void ApplySeverity(string severity, out string background, out string foreground)
    {
        switch (severity)
        {
            case "success":
                background = SuccessBrush;
                foreground = SuccessForegroundBrush;
                break;
            case "warning":
                background = WarningBrush;
                foreground = WarningForegroundBrush;
                break;
            case "error":
                background = ErrorBrush;
                foreground = ErrorForegroundBrush;
                break;
            default:
                background = NeutralBrush;
                foreground = NeutralForegroundBrush;
                break;
        }
    }
}
