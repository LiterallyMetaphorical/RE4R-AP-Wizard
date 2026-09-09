using System.Text.RegularExpressions;
using RE4R.AP.Launcher.Core.Services;

// See the csproj header for what each command is for. This tool is dev/support
// side only; nothing in the shipped launcher invokes it.

return args switch
{
    ["generate", ..] => await GenerateAsync(args),
    ["verify", ..] => await VerifyAsync(args),
    ["diagnose", ..] => Diagnose(args),
    _ => Usage(),
};

static int Usage()
{
    Console.WriteLine("""
        cache_manifest_tool

        generate -i <cacheDir> -o <manifest.txt.gz> --game-version "31 Mar 2026" [--note "<provenance>"]
            Hash a VERIFIED-CLEAN biorand-cache into a manifest. Point -o at
            assets/Data/biorand-cache-manifest-<slug>.txt.gz to update the
            bundled asset (BioRandCacheManifestProvider.FileNameForGameVersion
            prints the slug it expects).

        verify -i <cacheDir> -m <manifest.txt.gz> [--quick]
            Check a cache against a manifest. --quick is existence+size only,
            the same sweep the launcher runs before every patch.

        diagnose <launcher-log> [-m <manifest.txt.gz>]
            Classify the last BioRand failure in a player's launcher log the
            way the launcher does, and (with -m) list harvest X-lines a clean
            install would not produce.
        """);
    return 2;
}

static string? GetOption(string[] args, string name)
{
    var index = Array.IndexOf(args, name);
    return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
}

static async Task<int> GenerateAsync(string[] args)
{
    var cacheDir = GetOption(args, "-i");
    var output = GetOption(args, "-o");
    var gameVersion = GetOption(args, "--game-version");
    var note = GetOption(args, "--note") ?? $"generated {DateTime.UtcNow:yyyy-MM-dd}";
    if (cacheDir is null || output is null || gameVersion is null || !Directory.Exists(cacheDir))
    {
        Console.Error.WriteLine("generate needs -i <existing cacheDir>, -o <out.txt.gz>, --game-version.");
        return 2;
    }

    Console.WriteLine($"Hashing {cacheDir} ...");
    var manifest = await BioRandCacheManifest.GenerateAsync(cacheDir, gameVersion, note);
    manifest.Save(output);
    Console.WriteLine($"Wrote {manifest.Entries.Count} entries to {output}");
    Console.WriteLine($"Expected bundled name: {BioRandCacheManifestProvider.FileNameForGameVersion(gameVersion)}");
    return 0;
}

static async Task<int> VerifyAsync(string[] args)
{
    var cacheDir = GetOption(args, "-i");
    var manifestPath = GetOption(args, "-m");
    if (cacheDir is null || manifestPath is null || !File.Exists(manifestPath))
    {
        Console.Error.WriteLine("verify needs -i <cacheDir> and -m <existing manifest.txt.gz>.");
        return 2;
    }

    using var stream = File.OpenRead(manifestPath);
    var manifest = BioRandCacheManifest.Load(stream);
    Console.WriteLine($"Manifest: {manifest.Entries.Count} entries, game version {manifest.GameVersion}, note: {manifest.Note}");

    var report = args.Contains("--quick")
        ? manifest.VerifyQuick(cacheDir)
        : await manifest.VerifyFullAsync(cacheDir);

    Console.WriteLine($"Checked {report.CheckedFileCount} entries (hashes {(report.HashesChecked ? "verified" : "skipped")}).");
    Console.WriteLine($"Missing: {report.MissingFiles.Count}  Wrong size: {report.SizeMismatchedFiles.Count}  Wrong hash: {report.HashMismatchedFiles.Count}  Extra: {report.ExtraFileCount}");
    foreach (var path in report.MissingFiles.Take(20))
    {
        Console.WriteLine($"  missing   {path}");
    }

    foreach (var path in report.SizeMismatchedFiles.Concat(report.HashMismatchedFiles).Take(20))
    {
        Console.WriteLine($"  modified  {path}");
    }

    Console.WriteLine(report.IsClean ? "CLEAN" : "NOT CLEAN");
    return report.IsClean ? 0 : 1;
}

static int Diagnose(string[] args)
{
    var logPath = args.Length > 1 ? args[1] : null;
    if (logPath is null || !File.Exists(logPath))
    {
        Console.Error.WriteLine("diagnose needs the path to a launcher-*.log.");
        return 2;
    }

    // Log lines look like "[21:23:10] [BioRand] ..." - strip the timestamp,
    // then split the captured output back into the stdout/stderr streams the
    // classifier sees live. Only the segment after the LAST generation start
    // matters; earlier attempts in the same log are stale copies of the same
    // failure (OHMACS's log held thirteen).
    var timestamp = new Regex(@"^\[\d{2}:\d{2}:\d{2}\] ");
    var stdout = new List<string>();
    var stderr = new List<string>();
    var xLines = new List<string>();
    int? exitCode = null;

    foreach (var rawLine in File.ReadLines(logPath))
    {
        var line = timestamp.Replace(rawLine, string.Empty);
        if (line.StartsWith("BioRand generation started", StringComparison.Ordinal))
        {
            stdout.Clear();
            stderr.Clear();
            exitCode = null;
        }
        else if (line.StartsWith("[BioRand][stderr] ", StringComparison.Ordinal))
        {
            stderr.Add(line["[BioRand][stderr] ".Length..]);
        }
        else if (line.StartsWith("[BioRand] X ", StringComparison.Ordinal))
        {
            xLines.Add(line["[BioRand] X ".Length..]);
        }
        else if (line.StartsWith("[BioRand] ", StringComparison.Ordinal))
        {
            stdout.Add(line["[BioRand] ".Length..]);
        }
        else if (exitCode is null)
        {
            var match = Regex.Match(line, @"exit code (-?\d+)");
            if (match.Success && stderr.Count + stdout.Count > 0)
            {
                exitCode = int.Parse(match.Groups[1].Value);
            }
        }
    }

    if (stdout.Count == 0 && stderr.Count == 0)
    {
        Console.WriteLine("No captured [BioRand] generation output found in this log.");
    }
    else
    {
        var report = BioRandFailureClassifier.Classify(exitCode ?? 0, stdout, stderr);
        Console.WriteLine($"Area: {report.Area}");
        Console.WriteLine();
        Console.WriteLine(report.Message);
    }

    var manifestPath = GetOption(args, "-m");
    if (manifestPath is not null && File.Exists(manifestPath) && xLines.Count > 0)
    {
        using var stream = File.OpenRead(manifestPath);
        var manifest = BioRandCacheManifest.Load(stream);
        // An X-line for a path the manifest carries means a clean install DOES
        // provide that file, so this player's game data could not: the real
        // gap. X-lines absent from the manifest are stale pak-list entries a
        // clean setup also prints (294 of them as of 08-2026), i.e. noise.
        var real = xLines
            .Select(BioRandCacheManifest.NormalizePath)
            .Distinct()
            .Where(manifest.Entries.ContainsKey)
            .OrderBy(path => path, StringComparer.Ordinal)
            .ToList();
        Console.WriteLine();
        Console.WriteLine($"Setup X-lines: {xLines.Count} total, {real.Count} that a clean install provides (the real gap):");
        foreach (var path in real)
        {
            Console.WriteLine($"  {path}");
        }
    }

    return 0;
}
