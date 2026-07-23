namespace RE4R.AP.Launcher.Core.Models;

public sealed class InstallResult
{
    public bool Success { get; init; }

    public bool Cancelled { get; init; }

    public int FilesCopiedCount { get; init; }

    public IReadOnlyList<InstallVerificationFailure> VerificationFailures { get; init; } = Array.Empty<InstallVerificationFailure>();
}
