namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// A classified BioRand failure: which area broke, the full player-facing
/// message (area label, specifics, numbered repair steps, quoted evidence),
/// and the raw evidence line kept separate for logs and bug reports.
/// </summary>
public sealed class BioRandFailureReport
{
    /// <summary>Short area label, e.g. "BioRand cache incomplete".</summary>
    public string Area { get; init; } = string.Empty;

    /// <summary>The complete player-facing message shown in the failure banner.</summary>
    public string Message { get; init; } = string.Empty;

    /// <summary>What BioRand actually printed, e.g. the exception line. Null when it printed nothing usable.</summary>
    public string? Evidence { get; init; }
}
