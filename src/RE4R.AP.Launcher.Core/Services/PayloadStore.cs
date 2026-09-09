using System.IO.Compression;
using System.Text.Json;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Where the live Lua payload comes from. The bundled assets folder is the
/// baseline every install ships with; a payload UPDATE lands in the app-data
/// store instead, which is per-user writable and never fights the install
/// folder for locks or permissions. The store wins only while it is strictly
/// newer than the bundle for the SAME world data - after a full launcher
/// update the bundle usually leapfrogs the store, and the bundle silently
/// takes over again.
/// </summary>
public sealed class PayloadStore
{
    private readonly string _bundledLuaDirectoryPath;
    private readonly string _bundledStampFilePath;

    public PayloadStore(
        string appDataRootPath,
        string? bundledLuaDirectoryPath = null,
        string? bundledStampFilePath = null)
    {
        if (string.IsNullOrWhiteSpace(appDataRootPath))
        {
            throw new ArgumentException("The app data root path is required.", nameof(appDataRootPath));
        }

        _bundledLuaDirectoryPath = bundledLuaDirectoryPath
            ?? LuaInstallService.ResolveAssetsDirectory("Lua");
        _bundledStampFilePath = bundledStampFilePath
            ?? Path.Combine(
                Path.GetDirectoryName(_bundledLuaDirectoryPath) ?? _bundledLuaDirectoryPath,
                "PAYLOAD_STAMP.json");
        StoreDirectoryPath = Path.Combine(appDataRootPath, "payload");
    }

    public string StoreDirectoryPath { get; }

    public string StoreLuaDirectoryPath => Path.Combine(StoreDirectoryPath, "Lua");

    public string StoreStampFilePath => Path.Combine(StoreDirectoryPath, "PAYLOAD_STAMP.json");

    public event Action<string>? LogMessage;

    /// <summary>
    /// The payload the launcher should use right now. Resolved fresh on every
    /// call, so an update taking effect never needs a restart.
    /// </summary>
    public EffectivePayload GetEffectivePayload()
    {
        var bundledStamp = TryReadStamp(_bundledStampFilePath);
        var storeStamp = Directory.Exists(StoreLuaDirectoryPath)
            ? TryReadStamp(StoreStampFilePath)
            : null;

        // Both stamps must be readable and agree on the world data, and the
        // store must be strictly newer - anything else is the bundle. A store
        // that lost the comparison is stale by definition and stays ignored.
        if (bundledStamp is not null
            && storeStamp is not null
            && string.Equals(
                storeStamp.Payload.WorldVersion,
                bundledStamp.Payload.WorldVersion,
                StringComparison.Ordinal)
            && CompareModVersions(storeStamp.Payload.ModVersion, bundledStamp.Payload.ModVersion) > 0)
        {
            return new EffectivePayload(StoreLuaDirectoryPath, storeStamp, PayloadOrigin.Store);
        }

        return new EffectivePayload(_bundledLuaDirectoryPath, bundledStamp, PayloadOrigin.Bundled);
    }

    /// <summary>
    /// Installs a payload zip into the store: validate, extract to a sibling
    /// temp folder, then swap. The zip must carry PAYLOAD_STAMP.json at its
    /// root and a Lua/ tree; its world_version must MATCH the bundle (that is
    /// the machine-checked definition of a Lua-only update) and its
    /// mod_version must be strictly newer than whatever is currently
    /// effective. Failure at any point leaves the previous payload in place.
    /// </summary>
    public async Task<PayloadStampFile> InstallFromZipAsync(
        string zipFilePath,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(zipFilePath))
        {
            throw new InstallException($"The payload zip was not found at {zipFilePath}.");
        }

        var bundledStamp = TryReadStamp(_bundledStampFilePath)
            ?? throw new InstallException(
                "The launcher's own payload stamp is missing or unreadable, so an update cannot be validated against it.");

        PayloadStampFile candidateStamp;
        using (var archive = ZipFile.OpenRead(zipFilePath))
        {
            var stampEntry = archive.GetEntry("PAYLOAD_STAMP.json")
                ?? throw new InstallException(
                    "This zip does not carry PAYLOAD_STAMP.json at its root, so it is not a payload update.");

            using var stampStream = stampEntry.Open();
            candidateStamp = ParseStamp(stampStream)
                ?? throw new InstallException("The payload zip's stamp could not be read.");

            foreach (var entry in archive.Entries)
            {
                var name = entry.FullName.Replace('\\', '/');
                if (name.Contains("..", StringComparison.Ordinal) || Path.IsPathRooted(name))
                {
                    throw new InstallException($"The payload zip contains an unsafe path: {entry.FullName}");
                }

                if (name is not "PAYLOAD_STAMP.json"
                    && !name.StartsWith("Lua/", StringComparison.OrdinalIgnoreCase))
                {
                    throw new InstallException(
                        $"The payload zip contains {entry.FullName}, which is outside the Lua payload. Refusing it whole.");
                }
            }

            if (archive.GetEntry("Lua/ArchipelagoRE4R.lua") is null)
            {
                throw new InstallException(
                    "The payload zip is missing Lua/ArchipelagoRE4R.lua - it is not a complete payload.");
            }
        }

        if (!string.Equals(
                candidateStamp.Payload.WorldVersion,
                bundledStamp.Payload.WorldVersion,
                StringComparison.Ordinal))
        {
            throw new InstallException(
                $"This payload belongs to world data {candidateStamp.Payload.WorldVersion}, but this launcher bundles "
                + $"{bundledStamp.Payload.WorldVersion}. It needs the full launcher release, not a mod update.");
        }

        var currentVersion = GetEffectivePayload().Stamp?.Payload.ModVersion ?? string.Empty;
        if (CompareModVersions(candidateStamp.Payload.ModVersion, currentVersion) <= 0)
        {
            throw new InstallException(
                $"The payload zip is {candidateStamp.Payload.ModVersion}, which is not newer than the installed "
                + $"{currentVersion}. Nothing to do.");
        }

        var tempDirectoryPath = StoreDirectoryPath + ".tmp";
        var retiredDirectoryPath = StoreDirectoryPath + ".old";
        DeleteDirectoryIfExists(tempDirectoryPath);
        DeleteDirectoryIfExists(retiredDirectoryPath);

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(tempDirectoryPath)!);
            await Task.Run(
                () => ZipFile.ExtractToDirectory(zipFilePath, tempDirectoryPath),
                cancellationToken);

            if (Directory.Exists(StoreDirectoryPath))
            {
                Directory.Move(StoreDirectoryPath, retiredDirectoryPath);
            }

            Directory.Move(tempDirectoryPath, StoreDirectoryPath);
            DeleteDirectoryIfExists(retiredDirectoryPath);
        }
        catch
        {
            // Put the previous store back if the swap died mid-flight; the
            // effective-payload resolution falls back to the bundle anyway
            // if this best-effort restore also fails.
            if (!Directory.Exists(StoreDirectoryPath) && Directory.Exists(retiredDirectoryPath))
            {
                try { Directory.Move(retiredDirectoryPath, StoreDirectoryPath); } catch { }
            }

            DeleteDirectoryIfExists(tempDirectoryPath);
            throw;
        }

        Log($"Payload store updated to {candidateStamp.Payload.ModVersion} at {StoreDirectoryPath}.");
        return candidateStamp;
    }

    /// <summary>
    /// Orders mod versions of the shape "YYYY.MM.DD-rev". The date part is
    /// zero-padded so it compares ordinally; the revision compares as a
    /// number so -9 never beats -10. Unrecognized shapes fall back to an
    /// ordinal string compare rather than guessing.
    /// </summary>
    public static int CompareModVersions(string? left, string? right)
    {
        var a = (left ?? string.Empty).Trim();
        var b = (right ?? string.Empty).Trim();
        if (TryParseModVersion(a, out var aDate, out var aRev)
            && TryParseModVersion(b, out var bDate, out var bRev))
        {
            var dateCompare = string.CompareOrdinal(aDate, bDate);
            return dateCompare != 0 ? dateCompare : aRev.CompareTo(bRev);
        }

        return string.CompareOrdinal(a, b);
    }

    private static bool TryParseModVersion(string value, out string datePart, out int revision)
    {
        datePart = string.Empty;
        revision = 0;
        var separator = value.LastIndexOf('-');
        if (separator <= 0 || separator == value.Length - 1)
        {
            return false;
        }

        datePart = value[..separator];
        return int.TryParse(value[(separator + 1)..], out revision);
    }

    private static PayloadStampFile? TryReadStamp(string stampFilePath)
    {
        try
        {
            if (!File.Exists(stampFilePath))
            {
                return null;
            }

            using var stream = File.OpenRead(stampFilePath);
            return ParseStamp(stream);
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static PayloadStampFile? ParseStamp(Stream stream)
    {
        try
        {
            var stamp = JsonSerializer.Deserialize<PayloadStampFile>(stream);
            return stamp is not null
                && !string.IsNullOrWhiteSpace(stamp.Payload.ModVersion)
                && !string.IsNullOrWhiteSpace(stamp.Payload.WorldVersion)
                ? stamp
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static void DeleteDirectoryIfExists(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Leftover .tmp/.old folders are harmless; the next install
            // clears them before it starts.
        }
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}

public enum PayloadOrigin
{
    Bundled,
    Store,
}

/// <summary>The payload the launcher is actually using right now.</summary>
public sealed record EffectivePayload(
    string LuaDirectoryPath,
    PayloadStampFile? Stamp,
    PayloadOrigin Origin);
