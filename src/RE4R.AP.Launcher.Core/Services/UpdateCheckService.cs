using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Answers one question: does the newest GitHub release carry a Lua-only
/// payload this launcher can take? The launcher-update question lives in
/// LauncherUpdateService; this service only looks for the release's
/// update-manifest.json asset and gates what it finds. Origin is hardcoded
/// to this repo over HTTPS and the download must hash-match the manifest -
/// this path installs code that runs inside people's games, so it follows
/// nothing it did not expect. Every failure is a quiet no-update answer.
/// </summary>
public sealed class UpdateCheckService
{
    // The list endpoint, NOT /releases/latest: GitHub defines "latest" as the
    // newest non-prerelease, and every -alpha build is a prerelease, so
    // "latest" would skip exactly the releases this project ships. Same
    // reasoning (and endpoint) as LauncherUpdateService.
    private const string ReleasesApiUrl =
        "https://api.github.com/repos/LiterallyMetaphorical/RE4R-AP-Wizard/releases?per_page=10";

    public const string AllowedDownloadPrefix =
        "https://github.com/LiterallyMetaphorical/RE4R-AP-Wizard/releases/download/";

    private const string ManifestAssetName = "update-manifest.json";

    private static readonly HttpClient Http = CreateClient();

    public event Action<string>? LogMessage;

    private static HttpClient CreateClient()
    {
        var client = new HttpClient
        {
            // A stuck update check must never hold up startup.
            Timeout = TimeSpan.FromSeconds(15),
        };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("RE4R-AP-Wizard", "1.0"));
        return client;
    }

    /// <summary>
    /// Fetch, gate, report. Null means "offer nothing" - offline, no
    /// manifest on the newest release, malformed content, wrong world data,
    /// or simply nothing newer all land there on purpose.
    /// </summary>
    public async Task<UpdateManifestPayload?> CheckAsync(
        string? bundledWorldVersion,
        string? effectiveModVersion,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(bundledWorldVersion))
        {
            return null;
        }

        UpdateManifestPayload? payload;
        try
        {
            var manifestUrl = await FindManifestAssetUrlAsync(cancellationToken);
            if (manifestUrl is null)
            {
                Log("Mod update check: the newest release carries no update manifest.");
                return null;
            }

            var manifestJson = await Http.GetStringAsync(manifestUrl, cancellationToken);
            payload = JsonSerializer.Deserialize<UpdateManifest>(manifestJson)?.Payload;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            Log($"Mod update check skipped: {ex.Message}");
            return null;
        }

        if (payload is null)
        {
            return null;
        }

        if (!string.Equals(payload.WorldVersion, bundledWorldVersion, StringComparison.Ordinal))
        {
            // A payload for other world data is a launcher update's job.
            Log($"Mod update {payload.ModVersion} belongs to world data {payload.WorldVersion}; this launcher bundles {bundledWorldVersion}. Not offering it.");
            return null;
        }

        if (PayloadStore.CompareModVersions(payload.ModVersion, effectiveModVersion) <= 0)
        {
            Log($"Mod payload is current ({effectiveModVersion}; newest published {payload.ModVersion}).");
            return null;
        }

        if (!payload.Url.StartsWith(AllowedDownloadPrefix, StringComparison.OrdinalIgnoreCase)
            || payload.Sha256.Length != 64)
        {
            Log("Mod update manifest failed validation (download origin or hash shape). Not offering it.");
            return null;
        }

        Log($"Mod update available: {payload.ModVersion} (installed {effectiveModVersion}).");
        return payload;
    }

    /// <summary>
    /// Downloads the payload zip and verifies it against the manifest's
    /// sha256 before anyone gets to open it. A mismatch deletes the file and
    /// throws - a partially trusted zip does not get to exist on disk.
    /// </summary>
    public async Task DownloadPayloadAsync(
        UpdateManifestPayload payload,
        string destinationZipPath,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destinationZipPath)!);
        try
        {
            await using (var response = await Http.GetStreamAsync(payload.Url, cancellationToken))
            await using (var file = File.Create(destinationZipPath))
            {
                await response.CopyToAsync(file, cancellationToken);
            }

            string actualHash;
            await using (var verifyStream = File.OpenRead(destinationZipPath))
            {
                var hash = await SHA256.HashDataAsync(verifyStream, cancellationToken);
                actualHash = Convert.ToHexString(hash);
            }

            if (!string.Equals(actualHash, payload.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new InstallException(
                    $"The downloaded payload's hash does not match the manifest ({actualHash[..8].ToLowerInvariant()} vs "
                    + $"{payload.Sha256[..8].ToLowerInvariant()}). Nothing was installed.");
            }
        }
        catch
        {
            try { if (File.Exists(destinationZipPath)) { File.Delete(destinationZipPath); } } catch { }
            throw;
        }
    }

    private async Task<string?> FindManifestAssetUrlAsync(CancellationToken cancellationToken)
    {
        using var response = await Http.GetAsync(ReleasesApiUrl, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            Log($"Mod update check skipped: GitHub answered {(int)response.StatusCode}.");
            return null;
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var json = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
        if (json.RootElement.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        foreach (var release in json.RootElement.EnumerateArray())
        {
            if (release.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True)
            {
                continue;
            }

            // Only the newest non-draft release is consulted; an older
            // release's manifest is by definition not an update.
            if (!release.TryGetProperty("assets", out var assets)
                || assets.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            foreach (var asset in assets.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var n) ? n.GetString() : null;
                if (!string.Equals(name, ManifestAssetName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var url = asset.TryGetProperty("browser_download_url", out var u) ? u.GetString() : null;
                return url is not null
                    && url.StartsWith(AllowedDownloadPrefix, StringComparison.OrdinalIgnoreCase)
                    ? url
                    : null;
            }

            return null;
        }

        return null;
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
