using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

/// <summary>
/// Room reachability and address healing for archipelago.gg's port churn.
/// Rooms pause after inactivity and can wake on a DIFFERENT port, and the old
/// port gets recycled to strangers' rooms - so "the port answered" proves
/// nothing. <see cref="ProbeRoomAsync"/> reads the server's unsolicited
/// RoomInfo packet and reports its seed_name so callers can verify the room
/// really is this session's. <see cref="HealAsync"/> re-derives the current
/// address from the recorded room page (fetching the page also wakes the
/// room), verifies the seed, and rewrites the session record plus both
/// ap_connection.json copies - no re-patch involved.
/// </summary>
public sealed class RoomAddressHealService
{
    private static readonly HttpClient PageClient = new()
    {
        Timeout = TimeSpan.FromSeconds(15),
    };

    // The room page renders the current address as "/connect host:port".
    private static readonly Regex ConnectLineRegex = new(
        @"/connect\s+([A-Za-z0-9][A-Za-z0-9_.-]*):(\d{1,5})",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly JsonSerializerOptions ConnectionFileOptions = new()
    {
        WriteIndented = true,
    };

    private readonly SettingsStore _settingsStore;
    private readonly SessionRecordStore _sessionRecordStore;

    public event Action<string>? LogMessage;

    public RoomAddressHealService(SettingsStore settingsStore, SessionRecordStore sessionRecordStore)
    {
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        _sessionRecordStore = sessionRecordStore ?? throw new ArgumentNullException(nameof(sessionRecordStore));
    }

    /// <summary>
    /// Connects to the address (trying the same ws/wss candidates the scout
    /// uses) and reads RoomInfo. Never throws; an unusable address is simply
    /// "did not answer".
    /// </summary>
    public async Task<RoomProbeResult> ProbeRoomAsync(string serverAddress, CancellationToken cancellationToken = default)
    {
        IReadOnlyList<string> candidates;
        try
        {
            candidates = ArchipelagoScoutClient.BuildCandidateServerAddresses(serverAddress);
        }
        catch
        {
            return new RoomProbeResult();
        }

        foreach (var candidate in candidates)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return new RoomProbeResult();
            }

            var result = await ProbeSingleCandidateAsync(candidate, cancellationToken);
            if (result.Answered)
            {
                return result;
            }
        }

        return new RoomProbeResult();
    }

    /// <summary>
    /// Re-derives the session's current server address from its recorded room
    /// page, verifies the answering room's seed, then rewrites the record and
    /// both ap_connection.json files. Returns a failure result (never throws)
    /// so callers can surface the reason verbatim.
    /// </summary>
    public async Task<RoomAddressHealResult> HealAsync(
        SessionRecord record,
        string fallbackInstallPath,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(record);

        var roomUrl = (record.RoomUrl ?? string.Empty).Trim();
        if (roomUrl.Length == 0)
        {
            return Fail("This session has no room page link recorded. Use Reconnect / Update Address and paste the room's current address by hand.");
        }

        if (!Uri.TryCreate(roomUrl, UriKind.Absolute, out var pageUri)
            || (!string.Equals(pageUri.Scheme, "http", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(pageUri.Scheme, "https", StringComparison.OrdinalIgnoreCase)))
        {
            return Fail($"The recorded room link is not a web page: {roomUrl}");
        }

        var expectedSeed = (record.SeedName ?? string.Empty).Trim();

        const int MaxAttempts = 4;
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            Log(attempt == 1
                ? "Reading your room page (this also wakes a sleeping room)..."
                : $"Reading your room page again (try {attempt} of {MaxAttempts})...");

            string pageHtml;
            try
            {
                pageHtml = await PageClient.GetStringAsync(pageUri, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return Fail("Cancelled.");
            }
            catch (Exception ex)
            {
                return Fail($"Could not fetch the room page ({ex.Message}). Check your internet connection and that the room link still opens in a browser.");
            }

            var match = ConnectLineRegex.Match(pageHtml);
            if (!match.Success)
            {
                return Fail("The room page did not show a /connect address. Open the room link in a browser to check the room still exists.");
            }

            var host = match.Groups[1].Value;
            var port = int.Parse(match.Groups[2].Value);
            Log($"The room page says the room lives at {host}:{port}. Checking who answers there...");

            var probe = await ProbeRoomAsync($"{host}:{port}", cancellationToken);
            if (probe.Answered)
            {
                if (expectedSeed.Length > 0
                    && probe.SeedName.Length > 0
                    && !string.Equals(probe.SeedName, expectedSeed, StringComparison.Ordinal))
                {
                    return Fail(
                        $"The room at {host}:{port} hosts seed {probe.SeedName}, but this session is seed {expectedSeed}. "
                        + "The recorded room link does not belong to this multiworld - re-check the link with your organizer.");
                }

                if (expectedSeed.Length > 0 && probe.SeedName.Length == 0)
                {
                    return Fail(
                        $"Something answered at {host}:{port} but it did not identify itself as an Archipelago room, "
                        + "so the address was left unchanged. Try again in a moment.");
                }

                var healedServer = probe.NormalizedServer;
                var addressChanged = !string.Equals(healedServer, record.NormalizedServer, StringComparison.OrdinalIgnoreCase);

                try
                {
                    await RewriteConnectionFilesAsync(record, healedServer, fallbackInstallPath, cancellationToken);
                    record.NormalizedServer = healedServer;
                    await _sessionRecordStore.SaveAsync(record, cancellationToken);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    return Fail($"The room was verified at {healedServer}, but writing the connection files failed: {ex.Message}");
                }

                Log(addressChanged
                    ? $"Room verified (seed {probe.SeedName}). Connection updated to {healedServer}."
                    : $"Room verified (seed {probe.SeedName}). The recorded address {healedServer} was already current.");
                return new RoomAddressHealResult
                {
                    Succeeded = true,
                    HealedServer = healedServer,
                    AddressChanged = addressChanged,
                };
            }

            if (attempt < MaxAttempts)
            {
                Log("The room has not answered yet - rooms take a few seconds to wake. Waiting...");
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
                }
                catch (OperationCanceledException)
                {
                    return Fail("Cancelled.");
                }
            }
        }

        return Fail(
            "The room did not wake up after several tries. Open the room page in your browser, wait until it shows the room as running, then try again.");
    }

    private async Task<RoomProbeResult> ProbeSingleCandidateAsync(string candidate, CancellationToken cancellationToken)
    {
        using var socket = new ClientWebSocket();
        socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(TimeSpan.FromSeconds(6));

        try
        {
            await socket.ConnectAsync(new Uri(candidate), timeoutSource.Token);

            // The AP server pushes RoomInfo unsolicited right after the
            // handshake. Read a few frames in case chat/banner packets arrive
            // first; missing RoomInfo still counts as "answered" (SeedName
            // stays empty and the caller treats the room as unverified).
            var buffer = new byte[16384];
            for (var frame = 0; frame < 4; frame++)
            {
                using var messageStream = new MemoryStream();
                WebSocketReceiveResult receiveResult;
                do
                {
                    receiveResult = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), timeoutSource.Token);
                    if (receiveResult.MessageType == WebSocketMessageType.Close)
                    {
                        return new RoomProbeResult { Answered = true, NormalizedServer = candidate };
                    }

                    messageStream.Write(buffer, 0, receiveResult.Count);
                }
                while (!receiveResult.EndOfMessage);

                var seedName = TryReadRoomInfoSeed(Encoding.UTF8.GetString(messageStream.ToArray()));
                if (seedName is not null)
                {
                    return new RoomProbeResult
                    {
                        Answered = true,
                        SeedName = seedName,
                        NormalizedServer = candidate,
                    };
                }
            }

            return new RoomProbeResult { Answered = true, NormalizedServer = candidate };
        }
        catch
        {
            return new RoomProbeResult();
        }
        finally
        {
            if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
            {
                try
                {
                    using var closeSource = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                    await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Probe complete", closeSource.Token);
                }
                catch
                {
                    // Best-effort close; the probe result is already decided.
                }
            }
        }
    }

    /// <summary>
    /// Returns the RoomInfo seed_name found in the frame (possibly empty when
    /// RoomInfo carries none), or null when the frame held no RoomInfo packet.
    /// </summary>
    private static string? TryReadRoomInfoSeed(string rawMessage)
    {
        try
        {
            using var document = JsonDocument.Parse(rawMessage);
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Object)
            {
                return ReadSeedIfRoomInfo(root);
            }

            if (root.ValueKind == JsonValueKind.Array)
            {
                foreach (var packet in root.EnumerateArray())
                {
                    if (packet.ValueKind != JsonValueKind.Object)
                    {
                        continue;
                    }

                    var seedName = ReadSeedIfRoomInfo(packet);
                    if (seedName is not null)
                    {
                        return seedName;
                    }
                }
            }
        }
        catch (JsonException)
        {
        }

        return null;
    }

    private static string? ReadSeedIfRoomInfo(JsonElement packet)
    {
        if (!packet.TryGetProperty("cmd", out var command)
            || command.ValueKind != JsonValueKind.String
            || !string.Equals(command.GetString(), "RoomInfo", StringComparison.Ordinal))
        {
            return null;
        }

        if (packet.TryGetProperty("seed_name", out var seed) && seed.ValueKind == JsonValueKind.String)
        {
            return seed.GetString() ?? string.Empty;
        }

        return string.Empty;
    }

    private async Task RewriteConnectionFilesAsync(
        SessionRecord record,
        string healedServer,
        string fallbackInstallPath,
        CancellationToken cancellationToken)
    {
        // Slot comes from the session record (authoritative for the healed
        // session); the password only lives in the existing connection file,
        // so preserve it from there.
        var connectionInfo = new ApConnectionInfo
        {
            ServerAddress = healedServer,
            SlotName = record.SlotName,
            Password = string.Empty,
        };

        var appDataConnectionPath = Path.Combine(_settingsStore.AppDataRootPath, "ap_connection.json");
        if (File.Exists(appDataConnectionPath))
        {
            try
            {
                var existing = JsonSerializer.Deserialize<ApConnectionInfo>(
                    await File.ReadAllTextAsync(appDataConnectionPath, cancellationToken));
                if (existing is not null)
                {
                    connectionInfo.Password = existing.Password ?? string.Empty;
                }
            }
            catch (JsonException)
            {
                // Unreadable existing file: rewrite it cleanly with an empty password.
            }
        }

        var json = JsonSerializer.Serialize(connectionInfo, ConnectionFileOptions);
        Directory.CreateDirectory(_settingsStore.AppDataRootPath);
        await File.WriteAllTextAsync(appDataConnectionPath, json, cancellationToken);
        Log($"Updated {appDataConnectionPath}.");

        var installPath = !string.IsNullOrWhiteSpace(record.InstallPathAtPatch)
            ? record.InstallPathAtPatch
            : (fallbackInstallPath ?? string.Empty).Trim();
        if (!string.IsNullOrWhiteSpace(installPath))
        {
            var gameDataDirectoryPath = Path.Combine(installPath, "reframework", "data", "ArchipelagoRE4R");
            Directory.CreateDirectory(gameDataDirectoryPath);
            var gameConnectionPath = Path.Combine(gameDataDirectoryPath, "ap_connection.json");
            await File.WriteAllTextAsync(gameConnectionPath, json, cancellationToken);
            Log($"Updated {gameConnectionPath} for the in-game mod.");
        }
        else
        {
            Log("No game install path is recorded, so only the launcher-side connection file was updated.");
        }
    }

    private RoomAddressHealResult Fail(string reason)
    {
        Log(reason);
        return new RoomAddressHealResult { FailureReason = reason };
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
