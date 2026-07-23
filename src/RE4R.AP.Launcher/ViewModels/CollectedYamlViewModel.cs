using System.Windows.Input;
using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

/// <summary>
/// One collected player YAML row on the Generation Guidance screen: the
/// parsed player/game when readable, otherwise the parse problem, plus a
/// soft warning when no installed world matches the game.
/// </summary>
public sealed class CollectedYamlViewModel : ObservableObject
{
    private string _playerName = string.Empty;
    private string _gameName = string.Empty;
    private bool _isParsed;
    private string _issueText = string.Empty;

    public CollectedYamlViewModel(string fileName, string cachePath, string sourcePath, Action<CollectedYamlViewModel> onRemove)
    {
        FileName = fileName;
        CachePath = cachePath;
        SourcePath = sourcePath;
        RemoveCommand = new RelayCommand(() => onRemove(this));
    }

    public string FileName { get; }

    public string CachePath { get; }

    public string SourcePath { get; }

    public ICommand RemoveCommand { get; }

    /// <summary>Set once the file has been run through the YAML inspector, parseable or not.</summary>
    public bool ParseAttempted { get; set; }

    public string PlayerName
    {
        get => _playerName;
        set
        {
            if (SetProperty(ref _playerName, value))
            {
                OnPropertyChanged(nameof(DisplayTitle));
            }
        }
    }

    public string GameName
    {
        get => _gameName;
        set
        {
            if (SetProperty(ref _gameName, value))
            {
                OnPropertyChanged(nameof(DisplayTitle));
            }
        }
    }

    public bool IsParsed
    {
        get => _isParsed;
        set
        {
            if (SetProperty(ref _isParsed, value))
            {
                OnPropertyChanged(nameof(DisplayTitle));
            }
        }
    }

    public string DisplayTitle => IsParsed ? $"{PlayerName} - {GameName}" : FileName;

    public string FileNameDetail => IsParsed ? FileName : string.Empty;

    public string IssueText
    {
        get => _issueText;
        set
        {
            if (SetProperty(ref _issueText, value))
            {
                OnPropertyChanged(nameof(HasIssue));
            }
        }
    }

    public bool HasIssue => !string.IsNullOrWhiteSpace(IssueText);
}
