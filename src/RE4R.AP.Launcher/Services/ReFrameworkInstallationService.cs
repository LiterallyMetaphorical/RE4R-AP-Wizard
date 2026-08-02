using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using RE4R.AP.Launcher.Models;

namespace RE4R.AP.Launcher.Services;

public sealed class ReFrameworkInstallationService
{
    private const string LatestReleaseApiUrl = "https://api.github.com/repos/praydog/REFramework/releases/latest";
    private static readonly HttpClient HttpClient = CreateHttpClient();

    public event Action<string>? LogMessage;

    public async Task<ReFrameworkInstallResult> InstallLatestAsync(
        string re4rInstallPath,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(re4rInstallPath) || !Directory.Exists(re4rInstallPath))
        {
            throw new DirectoryNotFoundException("REFramework install could not start because the selected RE4R install path was not found.");
        }

        Log("Checking the latest REFramework release on GitHub.");
        using var releaseResponse = await HttpClient.GetAsync(LatestReleaseApiUrl, cancellationToken);
        releaseResponse.EnsureSuccessStatusCode();

        await using var releaseStream = await releaseResponse.Content.ReadAsStreamAsync(cancellationToken);
        using var releaseJson = await JsonDocument.ParseAsync(releaseStream, cancellationToken: cancellationToken);

        var root = releaseJson.RootElement;
        var releaseTag = root.TryGetProperty("tag_name", out var tagElement) ? tagElement.GetString() ?? string.Empty : string.Empty;
        var asset = SelectRe4Asset(root);
        if (asset is null)
        {
            throw new InvalidOperationException("The latest REFramework release did not contain a Resident Evil 4 asset. Check the upstream release page and try again later.");
        }

        Log($"Selected REFramework release {releaseTag}, asset {asset.Value.Name} ({FormatSize(asset.Value.SizeBytes)}).");
        Log($"Downloading REFramework asset {asset.Value.Name} from GitHub.");
        var tempZipPath = Path.Combine(Path.GetTempPath(), $"reframework_{Guid.NewGuid():N}.zip");
        try
        {
            using (var assetResponse = await HttpClient.GetAsync(asset.Value.DownloadUrl, cancellationToken))
            {
                assetResponse.EnsureSuccessStatusCode();
                await using var assetStream = await assetResponse.Content.ReadAsStreamAsync(cancellationToken);
                await using var fileStream = File.Create(tempZipPath);
                await CopyToWithProgressAsync(assetStream, fileStream, asset.Value.SizeBytes, cancellationToken);
            }
            Log($"Download complete. Temporary archive saved to {tempZipPath}.");

            var filesWritten = 0;
            using var archive = ZipFile.OpenRead(tempZipPath);
            Log($"Extracting REFramework into {re4rInstallPath}.");
            var containmentRoot = Path.GetFullPath(re4rInstallPath + Path.DirectorySeparatorChar);
            foreach (var entry in archive.Entries)
            {
                var normalizedEntryPath = entry.FullName.Replace('\\', '/');
                if (string.IsNullOrWhiteSpace(normalizedEntryPath) || normalizedEntryPath.EndsWith("/", StringComparison.Ordinal))
                {
                    continue;
                }

                if (!ShouldExtractEntry(normalizedEntryPath))
                {
                    continue;
                }

                var destinationPath = Path.Combine(
                    re4rInstallPath,
                    normalizedEntryPath.Replace('/', Path.DirectorySeparatorChar));
                // Zip-slip containment (audit launcherui-16): an archive entry
                // like ..\..\evil.dll must never escape the game folder.
                if (!Path.GetFullPath(destinationPath).StartsWith(containmentRoot, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        $"The REFramework archive contains an unsafe path ({entry.FullName}); nothing outside the game folder was written.");
                }

                Directory.CreateDirectory(Path.GetDirectoryName(destinationPath)!);
                entry.ExtractToFile(destinationPath, overwrite: true);
                filesWritten += 1;
                Log($"Installed REFramework file {normalizedEntryPath}.");
            }

            if (filesWritten == 0)
            {
                throw new InvalidOperationException("The downloaded REFramework archive did not contain dinput8.dll or the reframework folder.");
            }

            Log($"REFramework install complete. Wrote {filesWritten} files into {re4rInstallPath}.");
            return new ReFrameworkInstallResult
            {
                Success = true,
                ReleaseTag = releaseTag,
                AssetName = asset.Value.Name,
                FilesWrittenCount = filesWritten,
            };
        }
        catch (HttpRequestException ex)
        {
            throw new InvalidOperationException("The launcher could not download the latest REFramework release from GitHub. Check your internet connection and try again.", ex);
        }
        catch (InvalidDataException ex)
        {
            throw new InvalidOperationException("The downloaded REFramework archive was invalid or corrupted. Try the download again.", ex);
        }
        catch (IOException ex)
        {
            throw new InvalidOperationException("The launcher could not write REFramework files into your RE4R install. Check that the folder is writable and try again.", ex);
        }
        catch (UnauthorizedAccessException ex)
        {
            throw new InvalidOperationException("The launcher does not have permission to write REFramework files into your RE4R install. Run the launcher with the needed permissions and try again.", ex);
        }
        finally
        {
            if (File.Exists(tempZipPath))
            {
                File.Delete(tempZipPath);
            }
        }
    }

    private static bool ShouldExtractEntry(string normalizedEntryPath)
    {
        return string.Equals(normalizedEntryPath, "dinput8.dll", StringComparison.OrdinalIgnoreCase)
            || normalizedEntryPath.StartsWith("reframework/", StringComparison.OrdinalIgnoreCase);
    }

    private async Task CopyToWithProgressAsync(
        Stream source,
        Stream destination,
        long declaredSizeBytes,
        CancellationToken cancellationToken)
    {
        var buffer = new byte[81920];
        long copiedBytes = 0;
        var nextProgressThreshold = 10;

        if (declaredSizeBytes > 0)
        {
            Log($"Download progress: 0% (0 B of {FormatSize(declaredSizeBytes)})");
        }

        while (true)
        {
            var read = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken);
            if (read == 0)
            {
                break;
            }

            await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            copiedBytes += read;

            if (declaredSizeBytes > 0)
            {
                var percent = (int)((copiedBytes * 100L) / declaredSizeBytes);
                while (percent >= nextProgressThreshold && nextProgressThreshold <= 100)
                {
                    Log($"Download progress: {nextProgressThreshold}% ({FormatSize(copiedBytes)} of {FormatSize(declaredSizeBytes)})");
                    nextProgressThreshold += 10;
                }
            }
        }

        if (declaredSizeBytes > 0 && nextProgressThreshold <= 100)
        {
            Log($"Download progress: 100% ({FormatSize(copiedBytes)} of {FormatSize(declaredSizeBytes)})");
        }
    }

    private static (string Name, string DownloadUrl, long SizeBytes)? SelectRe4Asset(JsonElement releaseRoot)
    {
        if (!releaseRoot.TryGetProperty("assets", out var assetsElement) || assetsElement.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        string[] preferredNames =
        {
            "RE4R.zip",
            "RE4.zip",
        };

        foreach (var preferredName in preferredNames)
        {
            foreach (var asset in assetsElement.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? string.Empty : string.Empty;
                if (!string.Equals(name, preferredName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var downloadUrl = asset.TryGetProperty("browser_download_url", out var urlElement)
                    ? urlElement.GetString() ?? string.Empty
                    : string.Empty;
                var sizeBytes = asset.TryGetProperty("size", out var sizeElement) && sizeElement.ValueKind == JsonValueKind.Number
                    ? sizeElement.GetInt64()
                    : 0;
                if (!string.IsNullOrWhiteSpace(downloadUrl))
                {
                    return (name, downloadUrl, sizeBytes);
                }
            }
        }

        foreach (var asset in assetsElement.EnumerateArray())
        {
            var name = asset.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? string.Empty : string.Empty;
            var downloadUrl = asset.TryGetProperty("browser_download_url", out var urlElement)
                ? urlElement.GetString() ?? string.Empty
                : string.Empty;
            var sizeBytes = asset.TryGetProperty("size", out var sizeElement) && sizeElement.ValueKind == JsonValueKind.Number
                ? sizeElement.GetInt64()
                : 0;
            if (string.IsNullOrWhiteSpace(downloadUrl))
            {
                continue;
            }

            if (name.Contains("RE4R", StringComparison.OrdinalIgnoreCase)
                || string.Equals(name, "RE4.zip", StringComparison.OrdinalIgnoreCase)
                || string.Equals(name, "RE4R.zip", StringComparison.OrdinalIgnoreCase))
            {
                return (name, downloadUrl, sizeBytes);
            }
        }

        return null;
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient();
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("RE4R-AP-Wizard", "1.0"));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }

    private static string FormatSize(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB"];
        var value = Math.Abs((double)bytes);
        var unitIndex = 0;
        while (value >= 1024 && unitIndex < units.Length - 1)
        {
            value /= 1024;
            unitIndex++;
        }

        return string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:0.##} {1}", value, units[unitIndex]);
    }
}
