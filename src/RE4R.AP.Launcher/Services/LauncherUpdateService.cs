using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using RE4R.AP.Launcher.Models;

namespace RE4R.AP.Launcher.Services;

/// <summary>
/// Checks GitHub for a newer wizard release and reports it. It never downloads
/// or replaces anything: the distributable is the exe PLUS 38 asset files
/// (the Lua mod, the apworld, re4r_ap_static.json, the BioRand binary), and
/// swapping only the exe would leave those out of step with each other, which
/// is the exact drift that desyncs a multiworld. Telling the player to grab the
/// new zip prevents the failure we actually care about, which is someone
/// quietly playing an old build against a new room.
/// </summary>
public sealed class LauncherUpdateService
{
    // Deliberately /releases and not /releases/latest. GitHub defines "latest"
    // as the newest NON-prerelease, so the moment a release is tagged as a
    // pre-release - which every -alpha build should be - /releases/latest either
    // 404s or silently answers with an older stable one. The list endpoint
    // returns newest first and includes prereleases.
    private const string ReleasesApiUrl =
        "https://api.github.com/repos/LiterallyMetaphorical/RE4R-AP-Wizard/releases?per_page=10";

    private static readonly HttpClient HttpClient = CreateHttpClient();

    public event Action<string>? LogMessage;

    public async Task<LauncherUpdateInfo?> CheckAsync(CancellationToken cancellationToken = default)
    {
        var running = GetRunningVersion();
        if (string.IsNullOrWhiteSpace(running))
        {
            return null;
        }

        using var response = await HttpClient.GetAsync(ReleasesApiUrl, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            Log($"Update check skipped: GitHub answered {(int)response.StatusCode}.");
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

            var tag = release.TryGetProperty("tag_name", out var t) ? t.GetString() ?? string.Empty : string.Empty;
            if (string.IsNullOrWhiteSpace(tag))
            {
                continue;
            }

            var name = release.TryGetProperty("name", out var n) ? n.GetString() : null;
            var url = release.TryGetProperty("html_url", out var u) ? u.GetString() ?? string.Empty : string.Empty;

            var isNewer = Compare(tag, running) > 0;
            Log(isNewer
                ? $"A newer wizard release is available: {tag} (running {running})."
                : $"The wizard is up to date (running {running}, newest release {tag}).");

            return new LauncherUpdateInfo
            {
                TagName = tag,
                DisplayName = string.IsNullOrWhiteSpace(name) ? tag : name,
                ReleaseUrl = url,
                RunningVersion = running,
                IsNewer = isNewer,
            };
        }

        return null;
    }

    /// <summary>
    /// The running version, e.g. "0.3.1-alpha". Prefers the informational
    /// version the build stamps, dropping the "+commit" suffix SourceLink adds.
    /// </summary>
    public static string GetRunningVersion()
    {
        var assembly = Assembly.GetEntryAssembly();
        var informational = assembly?
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;

        if (string.IsNullOrWhiteSpace(informational))
        {
            var location = Environment.ProcessPath;
            if (!string.IsNullOrWhiteSpace(location) && File.Exists(location))
            {
                informational = FileVersionInfo.GetVersionInfo(location).ProductVersion;
            }
        }

        if (string.IsNullOrWhiteSpace(informational))
        {
            return string.Empty;
        }

        var plus = informational.IndexOf('+');
        return (plus >= 0 ? informational[..plus] : informational).Trim();
    }

    /// <summary>
    /// Compares "v0.3.1-alpha" style versions. Numeric parts win first; when
    /// those tie, a release with no prerelease tag beats one that has a tag
    /// (0.3.1 &gt; 0.3.1-alpha), matching semver. Returns &gt;0 when left is newer.
    /// </summary>
    internal static int Compare(string left, string right)
    {
        var (leftNumbers, leftTag) = Split(left);
        var (rightNumbers, rightTag) = Split(right);

        for (var i = 0; i < Math.Max(leftNumbers.Length, rightNumbers.Length); i++)
        {
            var l = i < leftNumbers.Length ? leftNumbers[i] : 0;
            var r = i < rightNumbers.Length ? rightNumbers[i] : 0;
            if (l != r)
            {
                return l.CompareTo(r);
            }
        }

        if (string.IsNullOrEmpty(leftTag) && string.IsNullOrEmpty(rightTag))
        {
            return 0;
        }

        if (string.IsNullOrEmpty(leftTag))
        {
            return 1;
        }

        if (string.IsNullOrEmpty(rightTag))
        {
            return -1;
        }

        return string.Compare(leftTag, rightTag, StringComparison.OrdinalIgnoreCase);
    }

    private static (int[] Numbers, string Tag) Split(string version)
    {
        var text = version.Trim();
        if (text.StartsWith("v", StringComparison.OrdinalIgnoreCase))
        {
            text = text[1..];
        }

        var match = Regex.Match(text, @"^(?<nums>\d+(\.\d+)*)(?<rest>.*)$");
        if (!match.Success)
        {
            return (Array.Empty<int>(), text);
        }

        var numbers = match.Groups["nums"].Value
            .Split('.', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => int.TryParse(part, out var value) ? value : 0)
            .ToArray();

        var tag = match.Groups["rest"].Value.TrimStart('-', '.', '+');
        return (numbers, tag);
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient
        {
            // A stuck update check must never hold up startup.
            Timeout = TimeSpan.FromSeconds(10),
        };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("RE4R-AP-Wizard", "1.0"));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    private void Log(string message) => LogMessage?.Invoke(message);
}
