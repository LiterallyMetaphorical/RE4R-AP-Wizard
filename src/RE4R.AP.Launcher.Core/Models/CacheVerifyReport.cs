namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// Result of checking the BioRand cache against the bundled clean-game
/// manifest. Missing files mean the player's game install could not provide
/// them (incomplete or damaged game data); mismatched files mean the cache
/// holds content that differs from a clean install (leftover mod paks, or a
/// harvest read through a patch pak).
/// </summary>
public sealed class CacheVerifyReport
{
    /// <summary>Manifest paths with no file in the cache.</summary>
    public IReadOnlyList<string> MissingFiles { get; init; } = Array.Empty<string>();

    /// <summary>Cache files whose size differs from the manifest.</summary>
    public IReadOnlyList<string> SizeMismatchedFiles { get; init; } = Array.Empty<string>();

    /// <summary>Cache files whose SHA-256 differs from the manifest. Empty when only the quick (size) pass ran.</summary>
    public IReadOnlyList<string> HashMismatchedFiles { get; init; } = Array.Empty<string>();

    /// <summary>Cache files the manifest does not list. Harmless to generation; counted for the log.</summary>
    public int ExtraFileCount { get; init; }

    /// <summary>How many manifest entries were checked.</summary>
    public int CheckedFileCount { get; init; }

    /// <summary>True when the full hash pass ran, false for the quick existence-and-size sweep.</summary>
    public bool HashesChecked { get; init; }

    public bool IsClean =>
        MissingFiles.Count == 0
        && SizeMismatchedFiles.Count == 0
        && HashMismatchedFiles.Count == 0;

    /// <summary>All mismatched (not missing) paths, for message composition.</summary>
    public IReadOnlyList<string> ModifiedFiles =>
        SizeMismatchedFiles.Concat(HashMismatchedFiles).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
}
