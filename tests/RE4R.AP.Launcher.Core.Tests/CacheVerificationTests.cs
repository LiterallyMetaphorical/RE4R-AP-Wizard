using System.Diagnostics;
using RE4R.AP.Launcher.Core.Models;
using RE4R.AP.Launcher.Core.Services;
using Xunit;

namespace RE4R.AP.Launcher.Core.Tests;

/// <summary>
/// What the bundled cache fingerprint is allowed to do to a patch.
///
/// The fingerprint describes ONE reference install. RE4R's optional DLC ships
/// as paks the harvest reads, and they override base-game paths, so a player
/// who owns a different set of packs legitimately harvests different bytes.
/// On 2026-09-09 that hard-blocked a player of the published v0.6.0-beta with
/// a message telling them to delete mod paks their folder did not contain, and
/// reinstalling the game could not help. These tests pin the rule that came
/// out of it: differences are recorded, the DLC-independent sentinel scenes
/// decide.
/// </summary>
public sealed class CacheVerificationTests : IDisposable
{
    private const string GameVersion = "31 Mar 2026";

    // The sentinel scenes BioRand's own start-up patches read, copied from
    // BioRandProcessRunner. A cache that fails these is genuinely unusable.
    private static readonly (string RelativePath, Guid ObjectGuid)[] Sentinels =
    [
        (Path.Combine("natives", "stm", "_chainsaw", "leveldesign", "chapter", "cp10_chp1_1", "level_cp10_chp1_1_010.scn.20"),
            new Guid("9fc712ca-478c-45b5-be12-5233edf4fe95")),
        (Path.Combine("natives", "stm", "_chainsaw", "environment", "scene", "gimmick", "st43", "gimmick_st43_900.scn.20"),
            new Guid("7a2d6128-79f7-0a71-388f-0ea0a80ce6e7")),
        (Path.Combine("natives", "stm", "_chainsaw", "environment", "scene", "gimmick", "st43", "gimmick_st43_301_p000.scn.20"),
            new Guid("3e5c7e73-fd33-49b6-b4ac-bba642abb1fc")),
        (Path.Combine("natives", "stm", "_chainsaw", "environment", "scene", "gimmick", "st40", "gimmick_st40_903_p000.scn.20"),
            new Guid("9a8b310d-6521-4905-bf55-fd1aeefbf2a3")),
    ];

    // The path the live report tripped on: a DLC message file that an optional
    // pack overrides.
    private static readonly string DlcTextFile =
        Path.Combine("natives", "stm", "_chainsaw", "message", "dlc", "ch_mes_dlc_1101.msg.22");

    private readonly string _root = Path.Combine(
        Path.GetTempPath(), "re4r-ap-cache-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_root))
            {
                Directory.Delete(_root, recursive: true);
            }
        }
        catch
        {
            // A leftover temp directory must never fail a test run.
        }
    }

    [Fact]
    public async Task AnInstallWithDifferentDlcStillPatches()
    {
        var harness = await BuildHarnessAsync();

        // The optional-DLC difference: same path, different bytes.
        File.WriteAllText(Path.Combine(harness.CacheDirectory, DlcTextFile), "base-game text, not the DLC override");

        var result = await harness.Runner.RunSetupAsync(harness.Request);

        Assert.True(result.Success, result.ErrorMessage);
        Assert.Contains(harness.Log, line => line.Contains("Cache fingerprint note", StringComparison.Ordinal));
    }

    [Fact]
    public async Task TheNoteNamesTheFilesInsteadOfAccusingThePlayer()
    {
        var harness = await BuildHarnessAsync();
        File.WriteAllText(Path.Combine(harness.CacheDirectory, DlcTextFile), "different");

        await harness.Runner.RunSetupAsync(harness.Request);

        var note = Assert.Single(harness.Log, line => line.Contains("Cache fingerprint note", StringComparison.Ordinal));
        Assert.Contains("optional DLC", note, StringComparison.OrdinalIgnoreCase);
        // The wording that sent the live player hunting for paks they did not have.
        Assert.DoesNotContain("poisoned", note, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("delete", note, StringComparison.OrdinalIgnoreCase);
        // The evidence a bug report needs: the differing path, not just a count.
        Assert.Contains(
            harness.Log,
            line => line.Contains("cache differs:", StringComparison.Ordinal)
                && line.Contains("ch_mes_dlc_1101", StringComparison.Ordinal));
    }

    [Fact]
    public async Task AHarvestReadThroughAModPakIsStillRefused()
    {
        var harness = await BuildHarnessAsync();

        // A sentinel scene without its object GUID is what a harvest taken
        // through an installed patch pak looks like. This must keep blocking.
        File.WriteAllBytes(
            Path.Combine(harness.CacheDirectory, Sentinels[0].RelativePath),
            "a mod rewrote this scene"u8.ToArray());

        var result = await harness.Runner.RunSetupAsync(harness.Request);

        Assert.False(result.Success);
        Assert.Contains("MODIFIED game", result.ErrorMessage, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AnAbsentFileIsReportedWithItsRepairButDoesNotBlock()
    {
        var harness = await BuildHarnessAsync();

        // Blue (08-26) and OHMACS (08-28): the game could not provide a file.
        // Generation names it precisely when it fails, so setup records it and
        // lets the patch proceed rather than risk refusing a healthy install.
        File.Delete(Path.Combine(harness.CacheDirectory, DlcTextFile));

        var result = await harness.Runner.RunSetupAsync(harness.Request);

        Assert.True(result.Success, result.ErrorMessage);
        var note = Assert.Single(harness.Log, line => line.Contains("Cache fingerprint note", StringComparison.Ordinal));
        Assert.Contains("absent", note, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("verify the game files in Steam", note, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AMatchingCacheSaysSoAndPatches()
    {
        var harness = await BuildHarnessAsync();

        var result = await harness.Runner.RunSetupAsync(harness.Request);

        Assert.True(result.Success, result.ErrorMessage);
        Assert.Contains(harness.Log, line => line.Contains("Cache verified clean", StringComparison.Ordinal));
        Assert.DoesNotContain(harness.Log, line => line.Contains("Cache fingerprint note", StringComparison.Ordinal));
    }

    /// <summary>
    /// A runner wired to temp directories, with a cache that matches its own
    /// freshly generated fingerprint. Tests then damage one thing and assert.
    /// </summary>
    private async Task<Harness> BuildHarnessAsync()
    {
        var appData = Path.Combine(_root, "appdata");
        var localAppData = Path.Combine(_root, "local");
        var assetsBioRand = Path.Combine(_root, "assets", "BioRand");
        var assetsData = Path.Combine(_root, "assets", "Data");
        var gameDirectory = Path.Combine(_root, "game");
        var cacheDirectory = Path.Combine(localAppData, "biorand-cache");

        foreach (var directory in new[] { appData, assetsBioRand, assetsData, gameDirectory, cacheDirectory })
        {
            Directory.CreateDirectory(directory);
        }

        // ResolveBioRandCommand only needs the file to be there.
        File.WriteAllText(Path.Combine(assetsBioRand, "biorand-re4r.exe"), "not a real executable");

        foreach (var (relativePath, guid) in Sentinels)
        {
            WriteCacheFile(cacheDirectory, relativePath, guid.ToByteArray());
        }

        WriteCacheFile(cacheDirectory, DlcTextFile, "the DLC override text"u8.ToArray());

        // The fingerprint of this cache, bundled the way a release bundles it.
        var manifest = await BioRandCacheManifest.GenerateAsync(cacheDirectory, GameVersion, "test fixture");
        manifest.Save(Path.Combine(assetsData, BioRandCacheManifestProvider.FileNameForGameVersion(GameVersion)));

        var log = new List<string>();
        var runner = new BioRandProcessRunner(
            appDataRootPath: appData,
            tempRootPath: Path.Combine(_root, "temp"),
            assetsBioRandDirectoryPath: assetsBioRand,
            processExecutor: (ProcessStartInfo _, Action<string> _, Action<string> _, CancellationToken _)
                => Task.FromResult(0),
            localAppDataRootPath: localAppData,
            cacheManifestProvider: new BioRandCacheManifestProvider(assetsData));
        runner.LogMessage += log.Add;

        return new Harness(
            runner,
            new BioRandSetupRequest
            {
                Re4rInstallPath = gameDirectory,
                DetectedGameVersion = GameVersion,
            },
            cacheDirectory,
            log);
    }

    private static void WriteCacheFile(string cacheDirectory, string relativePath, byte[] contents)
    {
        var fullPath = Path.Combine(cacheDirectory, relativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
        File.WriteAllBytes(fullPath, contents);
    }

    private sealed record Harness(
        BioRandProcessRunner Runner,
        BioRandSetupRequest Request,
        string CacheDirectory,
        List<string> Log);
}
