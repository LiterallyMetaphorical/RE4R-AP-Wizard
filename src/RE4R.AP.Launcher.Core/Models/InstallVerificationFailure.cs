namespace RE4R.AP.Launcher.Core.Models;

public sealed class InstallVerificationFailure
{
    public string RelativePath { get; init; } = string.Empty;

    public string ExpectedSha256 { get; init; } = string.Empty;

    public string ActualSha256 { get; init; } = string.Empty;

    public string Message { get; init; } = string.Empty;
}
