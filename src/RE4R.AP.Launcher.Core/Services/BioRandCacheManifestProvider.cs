using System.Collections.Concurrent;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Loads and checks the bundled clean-game cache manifest: path, size and
/// SHA-256 of every file a correct BioRand harvest of a clean install
/// produces, keyed per game version.
///
/// This is the one mechanism that covers the whole cache-integrity surface.
/// A missing entry means the player's install could not provide the file
/// (Blue 08-26: vanilla patch paks deleted; OHMACS 08-28: a corrupt pak
/// region). A hash mismatch means non-vanilla content was harvested (the
/// 08-02 Berserker case: leftover mod paks; also a harvest read through our
/// own patch pak). Both used to surface hours later as an unexplained
/// BioRand exit code; against the manifest they are named at setup time.
///
/// The manifest ships in assets/Data next to the other bundled data and MUST
/// be regenerated whenever the bundled BioRand's pak list changes or a game
/// title update lands: tools/cache_manifest_tool does that from a verified
/// clean cache. A game version without a bundled manifest degrades to the
/// four-scene sentinel check in BioRandProcessRunner, never to a hard stop.
/// </summary>
public sealed class BioRandCacheManifestProvider
{
    public BioRandCacheManifestProvider(string? assetsDataDirectoryPath = null)
    {
        AssetsDataDirectoryPath = assetsDataDirectoryPath
            ?? Path.Combine(AppContext.BaseDirectory, "assets", "Data");
    }

    public string AssetsDataDirectoryPath { get; }

    public event Action<string>? LogMessage;

    /// <summary>"31 Mar 2026" -> "biorand-cache-manifest-31mar2026.txt.gz".</summary>
    public static string FileNameForGameVersion(string gameVersion)
    {
        var slug = new string(gameVersion
            .ToLowerInvariant()
            .Where(char.IsLetterOrDigit)
            .ToArray());
        return $"biorand-cache-manifest-{slug}.txt.gz";
    }

    public string ManifestPathForGameVersion(string gameVersion)
    {
        return Path.Combine(AssetsDataDirectoryPath, FileNameForGameVersion(gameVersion));
    }

    /// <summary>
    /// The bundled manifest for this game version, or null when the version is
    /// unknown, no manifest ships for it, or the file is unreadable. Null means
    /// "verify some other way", never "fail the workflow".
    /// </summary>
    public BioRandCacheManifest? TryLoadForGameVersion(string? gameVersion)
    {
        if (string.IsNullOrWhiteSpace(gameVersion))
        {
            return null;
        }

        var manifestPath = ManifestPathForGameVersion(gameVersion);
        if (!File.Exists(manifestPath))
        {
            Log($"No clean-game cache manifest is bundled for game version {gameVersion} (looked for {Path.GetFileName(manifestPath)}). Falling back to the sentinel checks.");
            return null;
        }

        try
        {
            using var fileStream = File.OpenRead(manifestPath);
            var manifest = BioRandCacheManifest.Load(fileStream);
            if (!string.Equals(manifest.GameVersion, gameVersion, StringComparison.OrdinalIgnoreCase))
            {
                // A manifest for the wrong version would flag every updated
                // file as damage; no manifest is strictly safer.
                Log($"The bundled cache manifest {Path.GetFileName(manifestPath)} declares game version '{manifest.GameVersion}' but '{gameVersion}' was requested. Ignoring it.");
                return null;
            }

            return manifest;
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            Log($"Could not read the bundled cache manifest at {manifestPath}: {ex.Message}. Falling back to the sentinel checks.");
            return null;
        }
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}

/// <summary>
/// The parsed manifest: every file a clean harvest produces, with size and
/// SHA-256. Verification is split so the cheap pass can run on every patch:
/// <see cref="VerifyQuick"/> is existence and size only (a directory walk),
/// <see cref="VerifyFullAsync"/> also hashes every file (seconds, parallel)
/// and is run right after a fresh setup.
/// </summary>
public sealed class BioRandCacheManifest
{
    private const string FormatHeader = "# biorand-cache-manifest 1";

    private BioRandCacheManifest(
        string gameVersion,
        string note,
        IReadOnlyDictionary<string, BioRandCacheManifestEntry> entries)
    {
        GameVersion = gameVersion;
        Note = note;
        Entries = entries;
    }

    public string GameVersion { get; }

    /// <summary>Free-form provenance line (generating BioRand build, date).</summary>
    public string Note { get; }

    /// <summary>Keyed by normalized relative path: forward slashes, lower case.</summary>
    public IReadOnlyDictionary<string, BioRandCacheManifestEntry> Entries { get; }

    public static string NormalizePath(string relativePath)
    {
        return relativePath.Replace('\\', '/').ToLowerInvariant();
    }

    public static BioRandCacheManifest Load(Stream gzipStream)
    {
        using var gzip = new GZipStream(gzipStream, CompressionMode.Decompress);
        using var reader = new StreamReader(gzip, Encoding.UTF8);

        var firstLine = reader.ReadLine();
        if (firstLine is null || !firstLine.StartsWith(FormatHeader, StringComparison.Ordinal))
        {
            throw new InvalidDataException("The cache manifest does not start with the expected format header.");
        }

        var gameVersion = string.Empty;
        var note = string.Empty;
        var entries = new Dictionary<string, BioRandCacheManifestEntry>(StringComparer.Ordinal);

        while (reader.ReadLine() is { } line)
        {
            if (line.Length == 0)
            {
                continue;
            }

            if (line[0] == '#')
            {
                if (line.StartsWith("# game-version: ", StringComparison.Ordinal))
                {
                    gameVersion = line["# game-version: ".Length..].Trim();
                }
                else if (line.StartsWith("# note: ", StringComparison.Ordinal))
                {
                    note = line["# note: ".Length..].Trim();
                }

                continue;
            }

            // "<sha256hex> <size> <path>"; the path may contain spaces, so
            // split only the first two fields.
            var firstSpace = line.IndexOf(' ');
            var secondSpace = firstSpace < 0 ? -1 : line.IndexOf(' ', firstSpace + 1);
            if (firstSpace != 64 || secondSpace < 0
                || !long.TryParse(line.AsSpan(firstSpace + 1, secondSpace - firstSpace - 1), out var size))
            {
                throw new InvalidDataException($"The cache manifest contains a malformed line: {line[..Math.Min(line.Length, 120)]}");
            }

            var path = NormalizePath(line[(secondSpace + 1)..]);
            entries[path] = new BioRandCacheManifestEntry(line[..64], size);
        }

        if (string.IsNullOrWhiteSpace(gameVersion))
        {
            throw new InvalidDataException("The cache manifest does not declare a game version.");
        }

        if (entries.Count == 0)
        {
            throw new InvalidDataException("The cache manifest contains no file entries.");
        }

        return new BioRandCacheManifest(gameVersion, note, entries);
    }

    /// <summary>
    /// Hash every file in a verified-clean cache into a manifest. Dev-side
    /// (tools/cache_manifest_tool); players only ever load and verify.
    /// </summary>
    public static async Task<BioRandCacheManifest> GenerateAsync(
        string cacheDirectoryPath,
        string gameVersion,
        string note,
        CancellationToken cancellationToken = default)
    {
        var files = Directory.EnumerateFiles(cacheDirectoryPath, "*", SearchOption.AllDirectories).ToList();
        var entries = new ConcurrentDictionary<string, BioRandCacheManifestEntry>(StringComparer.Ordinal);

        await Parallel.ForEachAsync(
            files,
            new ParallelOptions
            {
                MaxDegreeOfParallelism = Environment.ProcessorCount,
                CancellationToken = cancellationToken,
            },
            async (filePath, ct) =>
            {
                var relative = NormalizePath(Path.GetRelativePath(cacheDirectoryPath, filePath));
                var stream = File.OpenRead(filePath);
                await using (stream.ConfigureAwait(false))
                {
                    var hash = await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false);
                    entries[relative] = new BioRandCacheManifestEntry(
                        Convert.ToHexStringLower(hash),
                        stream.Length);
                }
            });

        return new BioRandCacheManifest(gameVersion, note, entries);
    }

    public void Save(string outputPath)
    {
        using var fileStream = File.Create(outputPath);
        using var gzip = new GZipStream(fileStream, CompressionLevel.SmallestSize);
        using var writer = new StreamWriter(gzip, new UTF8Encoding(false));

        writer.WriteLine(FormatHeader);
        writer.WriteLine($"# game-version: {GameVersion}");
        writer.WriteLine($"# note: {Note}");
        foreach (var (path, entry) in Entries.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            writer.WriteLine($"{entry.Sha256} {entry.Size} {path}");
        }
    }

    /// <summary>Existence and size only. Cheap enough to run on every patch.</summary>
    public CacheVerifyReport VerifyQuick(string cacheDirectoryPath)
    {
        return Verify(cacheDirectoryPath, hashSizeMatches: false, CancellationToken.None)
            .GetAwaiter().GetResult();
    }

    /// <summary>Existence, size and SHA-256 of every entry. Run after each fresh setup.</summary>
    public Task<CacheVerifyReport> VerifyFullAsync(
        string cacheDirectoryPath,
        CancellationToken cancellationToken = default)
    {
        return Verify(cacheDirectoryPath, hashSizeMatches: true, cancellationToken);
    }

    private async Task<CacheVerifyReport> Verify(
        string cacheDirectoryPath,
        bool hashSizeMatches,
        CancellationToken cancellationToken)
    {
        var missing = new List<string>();
        var sizeMismatched = new List<string>();
        var toHash = new List<(string FullPath, string RelativePath, string ExpectedSha256)>();

        foreach (var (relativePath, entry) in Entries)
        {
            var fullPath = Path.Combine(cacheDirectoryPath, relativePath.Replace('/', Path.DirectorySeparatorChar));
            var info = new FileInfo(fullPath);
            if (!info.Exists)
            {
                missing.Add(relativePath);
            }
            else if (info.Length != entry.Size)
            {
                sizeMismatched.Add(relativePath);
            }
            else if (hashSizeMatches)
            {
                toHash.Add((fullPath, relativePath, entry.Sha256));
            }
        }

        var hashMismatched = new ConcurrentBag<string>();
        if (toHash.Count > 0)
        {
            await Parallel.ForEachAsync(
                toHash,
                new ParallelOptions
                {
                    MaxDegreeOfParallelism = Environment.ProcessorCount,
                    CancellationToken = cancellationToken,
                },
                async (item, ct) =>
                {
                    var stream = File.OpenRead(item.FullPath);
                    await using (stream.ConfigureAwait(false))
                    {
                        var hash = await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false);
                        if (!string.Equals(Convert.ToHexStringLower(hash), item.ExpectedSha256, StringComparison.Ordinal))
                        {
                            hashMismatched.Add(item.RelativePath);
                        }
                    }
                });
        }

        // Extra files are informational only (an older manifest against a
        // newer fork's larger pak list), so the quick per-patch sweep skips
        // the second directory walk they cost.
        var extraCount = 0;
        if (hashSizeMatches && Directory.Exists(cacheDirectoryPath))
        {
            foreach (var filePath in Directory.EnumerateFiles(cacheDirectoryPath, "*", SearchOption.AllDirectories))
            {
                if (!Entries.ContainsKey(NormalizePath(Path.GetRelativePath(cacheDirectoryPath, filePath))))
                {
                    extraCount++;
                }
            }
        }

        missing.Sort(StringComparer.Ordinal);
        sizeMismatched.Sort(StringComparer.Ordinal);

        return new CacheVerifyReport
        {
            MissingFiles = missing,
            SizeMismatchedFiles = sizeMismatched,
            HashMismatchedFiles = hashMismatched.OrderBy(path => path, StringComparer.Ordinal).ToList(),
            ExtraFileCount = extraCount,
            CheckedFileCount = Entries.Count,
            HashesChecked = hashSizeMatches,
        };
    }
}

/// <summary>One manifest row: lowercase hex SHA-256 and byte size.</summary>
public readonly record struct BioRandCacheManifestEntry(string Sha256, long Size);
