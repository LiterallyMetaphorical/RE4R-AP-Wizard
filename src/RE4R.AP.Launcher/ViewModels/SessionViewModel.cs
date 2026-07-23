using RE4R.AP.Launcher.Infrastructure;

namespace RE4R.AP.Launcher.ViewModels;

public sealed class SessionViewModel : ObservableObject
{
    private string _serverAddress = string.Empty;
    private string _slotName = string.Empty;
    private string _password = string.Empty;
    private string _roomUrl = string.Empty;
    private string _currentSessionText = "Enter an AP server and slot to view session state.";
    private string _lastPatchedText = "Last patched: n/a";
    private string _warningText = string.Empty;

    public string ServerAddress
    {
        get => _serverAddress;
        set => SetProperty(ref _serverAddress, value);
    }

    public string SlotName
    {
        get => _slotName;
        set => SetProperty(ref _slotName, value);
    }

    public string Password
    {
        get => _password;
        set => SetProperty(ref _password, value);
    }

    public string RoomUrl
    {
        get => _roomUrl;
        set => SetProperty(ref _roomUrl, value);
    }

    public string CurrentSessionText
    {
        get => _currentSessionText;
        set => SetProperty(ref _currentSessionText, value);
    }

    public string LastPatchedText
    {
        get => _lastPatchedText;
        set => SetProperty(ref _lastPatchedText, value);
    }

    public string WarningText
    {
        get => _warningText;
        set
        {
            if (SetProperty(ref _warningText, value))
            {
                OnPropertyChanged(nameof(HasWarning));
            }
        }
    }

    public bool HasWarning => !string.IsNullOrWhiteSpace(WarningText);
}
