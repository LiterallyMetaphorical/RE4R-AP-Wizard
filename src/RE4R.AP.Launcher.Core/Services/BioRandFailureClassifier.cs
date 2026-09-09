using System.Text;
using System.Text.RegularExpressions;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Turns BioRand's exit code and captured output into a named failure area and
/// a message a player can act on without reading a stack trace.
///
/// Why this exists: the fork's CLI runs with PropagateExceptions and no
/// top-level catch, so even its player-facing RandomizerUserException prints as
/// "Unhandled exception. ..." and the process dies with the CLR's generic
/// -532462766. Three testers in one week (Arkad 08-21, Blue 08-26, OHMACS
/// 08-28) were shown that number while the actual cause sat one line above it
/// in the captured output; each was diagnosable from that line alone. The
/// classifier reads the evidence in order of specificity and always quotes
/// what BioRand actually said, so an unknown failure still surfaces its own
/// description instead of a generic sentence.
///
/// The composed messages carry their own numbered repair steps.
/// MainWindowViewModel.TranslateWorkflowError keeps legacy rewrites for the
/// pre-classifier phrasings; nothing here reuses those trigger phrases, so new
/// messages pass through the banner untouched.
/// </summary>
public static class BioRandFailureClassifier
{
    public const string AreaCacheIncomplete = "BioRand cache incomplete";
    public const string AreaCachePoisoned = "BioRand cache poisoned";
    public const string AreaOptions = "BioRand options";
    public const string AreaGameFiles = "Game files";
    public const string AreaCrash = "BioRand crash";
    public const string AreaFailure = "BioRand failure";

    // "Unhandled exception. IntelOrca.Biohazard.BioRand.RandomizerUserException: Unable to read '...'"
    private static readonly Regex UnhandledExceptionLine = new(
        @"Unhandled exception\.\s*(?<type>[A-Za-z_][\w.]*(?:Exception|Error)):\s*(?<message>.+)",
        RegexOptions.Compiled);

    // GetFileOrFail's wording for a pak-list path the cache never received.
    private static readonly Regex UnableToReadPath = new(
        @"Unable to read '(?<path>[^']+)'",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    // "Unable to find door to replace" / "Unable to find lights scene": the file
    // was readable but its content is not the vanilla content the patch expects.
    private static readonly Regex UnableToFindThing = new(
        @"Unable to find (?<what>.+)",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    // The fork's option-pair guards: "'Random Weapon Upgrades' requires 'Random
    // Upgraded Weapon Stats' to be enabled." Matched generically so future
    // guards classify without a launcher change.
    private static readonly Regex OptionPairGuard = new(
        @"'[^']+'\s+requires\s+'[^']+'",
        RegexOptions.Compiled);

    // Phrases that mean damaged or non-vanilla input even without a parsed
    // exception line (setup verdicts echoed by the fork, upstream file checks).
    private static readonly string[] InputEvidenceMarkers =
    [
        "cache is incomplete",
        "cache was built from a MODIFIED game",
        "does not match the real game",
        "checksum mismatch",
        "corrupt game file",
        "corrupted game file",
    ];

    public static BioRandFailureReport Classify(
        int exitCode,
        IReadOnlyList<string> stdoutLines,
        IReadOnlyList<string> stderrLines)
    {
        var exception = FindFirstException(stderrLines) ?? FindFirstException(stdoutLines);

        if (exception is not null)
        {
            var readMatch = UnableToReadPath.Match(exception.Message);
            if (readMatch.Success)
            {
                return BuildReport(
                    AreaCacheIncomplete,
                    $"generation stopped because the cache has no readable copy of '{readMatch.Groups["path"].Value}'. "
                    + "That file could not be read from your RE4R install when the cache was built, so the game data on disk is missing or damaged there. Your seed and settings are fine.",
                    [
                        "Verify your game files in Steam: right click Resident Evil 4, Properties, Installed Files, Verify integrity of game files. Let it repair.",
                        "Clear the BioRand cache from Setup Status. Do this second: the cache is a copy of your game files, and clearing it first just copies the same damage back.",
                        "Patch again. If it still fails, send a bug report zip (the Generate Bug Report button, bottom right of the launcher).",
                    ],
                    exception,
                    exitCode);
            }

            if (OptionPairGuard.IsMatch(exception.Message))
            {
                return BuildReport(
                    AreaOptions,
                    $"BioRand refused this option combination: {exception.Message} "
                    + "This rule comes from BioRand itself, not from the room or your YAML.",
                    [
                        "Open BioRand Options and adjust the two named options so the requirement holds.",
                        "Patch again.",
                    ],
                    exception,
                    exitCode);
            }

            var findMatch = UnableToFindThing.Match(exception.Message);
            if (findMatch.Success)
            {
                return BuildReport(
                    AreaCachePoisoned,
                    $"BioRand could not find {findMatch.Groups["what"].Value}, which means the cached copy of your game files does not match a clean install. "
                    + "The usual cause is a mod pak that was still installed when the cache was built, even one uninstalled long ago: Steam's Verify Integrity does not delete files it did not install.",
                    [
                        "In your RE4R folder, delete every re_chunk_000.pak.patch_007.pak and higher that the launcher did not install. Leave re_chunk_000.pak and patch_001 through patch_006 alone.",
                        "Verify your game files in Steam.",
                        "Clear the BioRand cache from Setup Status and patch again.",
                    ],
                    exception,
                    exitCode);
            }
        }

        var markerLine = FindFirstMarkerLine(stdoutLines, stderrLines);
        if (markerLine is not null)
        {
            return BuildReport(
                AreaGameFiles,
                "BioRand reported damaged or non-vanilla game data while building your world.",
                [
                    "Check your RE4R folder for patch paks above patch_006 that the launcher did not install, and delete them.",
                    "Verify your game files in Steam: right click Resident Evil 4, Properties, Installed Files, Verify integrity of game files.",
                    "Clear the BioRand cache from Setup Status and patch again. If it still fails, send a bug report zip (the Generate Bug Report button, bottom right of the launcher).",
                ],
                new ExceptionEvidence(Type: null, Message: markerLine),
                exitCode);
        }

        if (exception is not null)
        {
            // A real exception the launcher does not recognize. Quote it whole:
            // an accurate unknown beats a friendly wrong guess, and the quoted
            // line is what makes the eventual report diagnosable.
            return BuildReport(
                AreaFailure,
                "generation stopped on an error that is not one of the known player-fixable classes.",
                [
                    "Send a bug report zip (the Generate Bug Report button, bottom right of the launcher). The launcher log inside it carries the full stack trace.",
                ],
                exception,
                exitCode);
        }

        if (exitCode < 0)
        {
            // A negative exit is a Windows crash status. Every crash of this
            // class this project has diagnosed (access violations, the live
            // 2026-08-02 stack overflow) came from parsing damaged or
            // leftover-pak input, and a hard crash prints no evidence at all,
            // so it is classified as input on the exit code alone.
            return BuildReport(
                AreaCrash,
                $"BioRand crashed without printing an error. Every crash of this kind we have diagnosed came from damaged game files or leftover mod paks rather than anything set wrong.",
                [
                    "Check your RE4R folder for patch paks above patch_006 that the launcher did not install, and delete them.",
                    "Verify your game files in Steam, then clear the BioRand cache from Setup Status.",
                    "Patch again. If it still crashes, send a bug report zip (the Generate Bug Report button, bottom right of the launcher).",
                ],
                evidence: null,
                exitCode);
        }

        return BuildReport(
            AreaFailure,
            "BioRand stopped without a recognizable error.",
            [
                "Send a bug report zip (the Generate Bug Report button, bottom right of the launcher). The captured [BioRand] output inside it shows where it stopped.",
            ],
            evidence: null,
            exitCode);
    }

    private sealed record ExceptionEvidence(string? Type, string Message);

    private static ExceptionEvidence? FindFirstException(IReadOnlyList<string> lines)
    {
        foreach (var line in lines)
        {
            var match = UnhandledExceptionLine.Match(line);
            if (match.Success)
            {
                var type = match.Groups["type"].Value;
                var shortType = type[(type.LastIndexOf('.') + 1)..];
                return new ExceptionEvidence(shortType, match.Groups["message"].Value.Trim());
            }
        }

        return null;
    }

    private static string? FindFirstMarkerLine(
        IReadOnlyList<string> stdoutLines,
        IReadOnlyList<string> stderrLines)
    {
        foreach (var line in stdoutLines.Concat(stderrLines))
        {
            if (InputEvidenceMarkers.Any(marker => line.Contains(marker, StringComparison.OrdinalIgnoreCase)))
            {
                return line;
            }
        }

        return null;
    }

    private static BioRandFailureReport BuildReport(
        string area,
        string headline,
        IReadOnlyList<string> steps,
        ExceptionEvidence? evidence,
        int exitCode)
    {
        var sb = new StringBuilder();
        sb.Append(area).Append(": ").AppendLine(headline);
        for (var i = 0; i < steps.Count; i++)
        {
            sb.Append(i + 1).Append(". ").AppendLine(steps[i]);
        }

        var evidenceText = evidence is null
            ? null
            : evidence.Type is null
                ? Truncate(evidence.Message, 300)
                : $"{evidence.Type}: {Truncate(evidence.Message, 300)}";
        sb.Append(evidenceText is null
            ? $"(exit code {exitCode})"
            : $"(BioRand said: {evidenceText}; exit code {exitCode})");

        return new BioRandFailureReport
        {
            Area = area,
            Message = sb.ToString(),
            Evidence = evidenceText,
        };
    }

    private static string Truncate(string value, int maxLength)
    {
        return value.Length <= maxLength ? value : value[..maxLength] + "...";
    }
}
