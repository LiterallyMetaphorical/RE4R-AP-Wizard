namespace RE4R.AP.Launcher.Models;

public sealed class LaunchModeOption
{
    public string Key { get; init; } = string.Empty;

    public string DisplayName { get; init; } = string.Empty;

    public string Description { get; init; } = string.Empty;

    public bool IsAvailable { get; init; }

    public override string ToString()
    {
        return DisplayName;
    }
}
