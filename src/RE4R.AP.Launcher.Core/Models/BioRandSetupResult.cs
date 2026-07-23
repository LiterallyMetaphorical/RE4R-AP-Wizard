namespace RE4R.AP.Launcher.Core.Models;

public sealed class BioRandSetupResult
{
    public bool Success { get; init; }

    public int ExitCode { get; init; }

    public string BioRandVersionDescriptor { get; init; } = string.Empty;

    public string ErrorMessage { get; init; } = string.Empty;

    public string CacheDirectoryPath { get; init; } = string.Empty;

    public IReadOnlyList<string> StandardOutputLines { get; init; } = Array.Empty<string>();

    public IReadOnlyList<string> StandardErrorLines { get; init; } = Array.Empty<string>();
}
