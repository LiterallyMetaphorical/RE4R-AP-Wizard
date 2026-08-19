using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using RE4R.AP.Launcher.Core.Exceptions;
using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Services;

public sealed class ArchipelagoScoutClient
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = false,
    };

    private static readonly object ProtocolVersion = new
    {
        @class = "Version",
        major = 0,
        minor = 6,
        build = 7,
    };

    private const int ItemsHandling = 0b111;

    public event Action<string>? LogMessage;

    public async Task<ArchipelagoScoutSessionResult> ScoutLocationsAsync(
        ArchipelagoScoutRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (string.IsNullOrWhiteSpace(request.ServerAddress))
        {
            throw new ArchipelagoConnectionException("AP scouting could not start because the AP server address is empty.");
        }

        if (string.IsNullOrWhiteSpace(request.SlotName))
        {
            throw new ArchipelagoAuthenticationException("AP scouting could not start because the slot name is empty.");
        }

        var requestedLocationIds = request.LocationIds
            .Distinct()
            .OrderBy(locationId => locationId)
            .ToArray();
        if (requestedLocationIds.Length == 0)
        {
            throw new ArchipelagoProtocolException("AP scouting could not start because no RE4R location IDs were supplied.");
        }

        var candidateServers = BuildCandidateServerAddresses(request.ServerAddress);
        ClientWebSocket? connectedSocket = null;
        var normalizedServer = candidateServers[0];
        Exception? lastConnectFailure = null;

        foreach (var candidate in candidateServers)
        {
            var attemptSocket = new ClientWebSocket();
            attemptSocket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
            try
            {
                Log($"Connecting to AP server at {candidate}");
                await ExecuteWithTimeoutAsync(
                    connectToken => attemptSocket.ConnectAsync(new Uri(candidate), connectToken),
                    request.ConnectTimeout,
                    cancellationToken,
                    $"Timed out connecting to AP server at {candidate}. Check the address and try again.");
                connectedSocket = attemptSocket;
                normalizedServer = candidate;
                break;
            }
            catch (Exception ex)
            {
                attemptSocket.Dispose();
                if (ex is OperationCanceledException && cancellationToken.IsCancellationRequested)
                {
                    throw;
                }

                lastConnectFailure = ex;
                if (candidateServers.Count > 1)
                {
                    Log($"Could not connect via {candidate}: {ex.Message}");
                }
            }
        }

        if (connectedSocket is null)
        {
            // Wrap the raw socket failure (WebSocketException, timeout, DNS...)
            // so the workflow shows a translated, actionable error instead of
            // "failed unexpectedly". A sleeping archipelago.gg room is by far
            // the most common cause of an unreachable server.
            var failureDetail = lastConnectFailure is null ? string.Empty : $" ({lastConnectFailure.Message})";
            var friendlyMessage =
                $"Could not reach your AP room at {request.ServerAddress}.{failureDetail} "
                + "archipelago.gg rooms fall asleep after about 2 hours of inactivity - open your Room Page to wake the room, "
                + "check the address still matches it (a re-woken room can move to a new port), then try again.";
            throw lastConnectFailure is null
                ? new ArchipelagoConnectionException(friendlyMessage)
                : new ArchipelagoConnectionException(friendlyMessage, lastConnectFailure);
        }

        using var socket = connectedSocket;

        var packetBuffer = new Queue<JsonElement>();
        string seedName = string.Empty;

        try
        {
            Log("Connected to AP server; waiting for RoomInfo");
            var roomInfoPacket = await ReceiveUntilCommandAsync(
                socket,
                packetBuffer,
                new HashSet<string>(StringComparer.Ordinal) { "RoomInfo", "ConnectionRefused" },
                request.ReceiveTimeout,
                cancellationToken);
            ThrowIfConnectionRefused(roomInfoPacket);

            seedName = GetOptionalString(roomInfoPacket, "seed_name");
            var roomGame = GetOptionalString(roomInfoPacket, "game");
            var roomSummaryParts = new List<string>();
            if (!string.IsNullOrWhiteSpace(roomGame))
            {
                roomSummaryParts.Add($"game {roomGame}");
            }

            if (!string.IsNullOrWhiteSpace(seedName))
            {
                roomSummaryParts.Add($"seed {seedName}");
            }

            Log(roomSummaryParts.Count == 0
                ? "Received RoomInfo from the AP server."
                : $"Received RoomInfo from the AP server for {string.Join(", ", roomSummaryParts)}.");

            Log($"Authenticating with AP server as slot {request.SlotName}");
            await SendMessagesAsync(
                socket,
                new object[]
                {
                    new
                    {
                        cmd = "Connect",
                        password = request.Password ?? string.Empty,
                        name = request.SlotName,
                        version = ProtocolVersion,
                        tags = new[] { "AP" },
                        items_handling = ItemsHandling,
                        uuid = request.ClientUuid.ToString(),
                        game = request.GameName,
                        slot_data = true,
                    },
                },
                request.ReceiveTimeout,
                cancellationToken);

            var connectedPacket = await ReceiveUntilCommandAsync(
                socket,
                packetBuffer,
                new HashSet<string>(StringComparer.Ordinal) { "Connected", "ConnectionRefused" },
                request.ReceiveTimeout,
                cancellationToken);
            ThrowIfConnectionRefused(connectedPacket);

            var team = GetRequiredInt32(connectedPacket, "team");
            var connectedSlot = GetRequiredInt32(connectedPacket, "slot");
            var playerCount = GetOptionalArrayCount(connectedPacket, "players");
            Log(playerCount > 0
                ? $"Authenticated with the AP server as team {team}, slot {connectedSlot}. Room currently lists {playerCount} player entries."
                : $"Authenticated with the AP server as team {team}, slot {connectedSlot}.");

            var randomEvents = ParseRandomEventsSlotData(connectedPacket);
            if (randomEvents.Enabled)
            {
                Log($"This room uses AP-authored Random Events: {randomEvents.ChosenEvents.Count} events chosen, "
                    + $"{randomEvents.RemovedLocationCodes.Count} checks removed by events.");
            }

            var gameMode = ParseGameModeSlotData(connectedPacket);
            Log($"Room game mode: {gameMode}");

            // Since apworld 0.4.0 the room's location count varies with the
            // RandomizeGatedKeys option, so scout exactly what the room
            // declares (missing + checked from Connected) instead of the full
            // bundled list - the server rejects unknown location ids.
            var roomLocationIds = GetRoomLocationIds(connectedPacket, requestedLocationIds);
            Log(roomLocationIds.Length == requestedLocationIds.Length
                ? $"Scouting {roomLocationIds.Length} locations"
                : $"Scouting {roomLocationIds.Length} of {requestedLocationIds.Length} bundled locations (the rest are vanilla/preserved spots that are not part of this multiworld).");
            await SendMessagesAsync(
                socket,
                new object[]
                {
                    new
                    {
                        cmd = "LocationScouts",
                        locations = roomLocationIds,
                        create_as_hint = 0,
                    },
                },
                request.ReceiveTimeout,
                cancellationToken);

            var locationInfoPacket = await ReceiveUntilCommandAsync(
                socket,
                packetBuffer,
                new HashSet<string>(StringComparer.Ordinal) { "LocationInfo" },
                request.ReceiveTimeout,
                cancellationToken);
            var locations = ParseLocationInfo(locationInfoPacket, roomLocationIds.Length);

            Log($"Received {locations.Count} location assignments from the AP server.");

            return new ArchipelagoScoutSessionResult
            {
                NormalizedServer = normalizedServer,
                SeedName = seedName,
                Team = team,
                ConnectedPlayerSlot = connectedSlot,
                Locations = locations,
                RoomLocationIds = roomLocationIds,
                RandomEvents = randomEvents,
                GameMode = gameMode,
            };
        }
        catch (ArchipelagoScoutException)
        {
            throw;
        }
        catch (WebSocketException ex)
        {
            throw new ArchipelagoConnectionException($"The launcher lost its websocket connection while talking to {normalizedServer}. Check the server address and your network connection, then try again.", ex);
        }
        catch (JsonException ex)
        {
            throw new ArchipelagoProtocolException("The AP server returned malformed JSON during scouting. Try again, and if it persists, check the server version.", ex);
        }
        finally
        {
            Log($"Disconnecting from AP server at {normalizedServer}");
            await CloseQuietlyAsync(socket, request.CloseTimeout, cancellationToken);
            Log("Disconnected from AP server");
        }
    }

    /// <summary>
    /// Builds normalized websocket candidates for an address. Explicit
    /// schemes are honored as-is; scheme-less addresses try wss:// first for
    /// public hosts (archipelago.gg rooms are TLS-only) and ws:// first for
    /// local or private-network hosts (a plain MultiServer).
    /// </summary>
    public static IReadOnlyList<string> BuildCandidateServerAddresses(string serverAddress, int defaultPort = 38281)
    {
        var trimmed = (serverAddress ?? string.Empty).Trim();

        // A bare number is the port off an archipelago.gg room page (the page
        // shouts the port far louder than the host, and players paste exactly
        // that). Digits alone can never name a real host - Uri would treat
        // "62495" as a HOSTNAME and fail DNS - so default the host instead of
        // failing. Self-hosters write host:port and are unaffected.
        if (trimmed.Length > 0
            && trimmed.All(char.IsAsciiDigit)
            && int.TryParse(trimmed, out var barePort)
            && barePort is > 0 and <= 65535)
        {
            trimmed = "archipelago.gg:" + trimmed;
        }

        var hasExplicitScheme = trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("ws://", StringComparison.OrdinalIgnoreCase)
            || trimmed.StartsWith("wss://", StringComparison.OrdinalIgnoreCase);

        if (hasExplicitScheme)
        {
            return [NormalizeServerAddress(trimmed, defaultPort)];
        }

        var plaintextAddress = NormalizeServerAddress("ws://" + trimmed, defaultPort);
        var secureAddress = NormalizeServerAddress("wss://" + trimmed, defaultPort);
        var host = new Uri(plaintextAddress).Host;

        return PrefersPlaintextFirst(host)
            ? [plaintextAddress, secureAddress]
            : [secureAddress, plaintextAddress];
    }

    private static bool PrefersPlaintextFirst(string host)
    {
        if (string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (!IPAddress.TryParse(host, out var address))
        {
            return false;
        }

        if (IPAddress.IsLoopback(address))
        {
            return true;
        }

        var bytes = address.GetAddressBytes();
        if (bytes.Length != 4)
        {
            return false;
        }

        // RFC1918, CGNAT/Tailscale (100.64/10), and link-local ranges - the
        // places a plain ws:// MultiServer realistically lives.
        return bytes[0] == 10
            || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31)
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127)
            || (bytes[0] == 169 && bytes[1] == 254);
    }

    public static string NormalizeServerAddress(string serverAddress, int defaultPort = 38281)
    {
        if (string.IsNullOrWhiteSpace(serverAddress))
        {
            throw new ArchipelagoConnectionException("AP server address is empty.");
        }

        var trimmed = serverAddress.Trim();
        if (trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
        {
            trimmed = "ws://" + trimmed[7..];
        }
        else if (trimmed.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            trimmed = "wss://" + trimmed[8..];
        }
        else if (!trimmed.StartsWith("ws://", StringComparison.OrdinalIgnoreCase)
                 && !trimmed.StartsWith("wss://", StringComparison.OrdinalIgnoreCase))
        {
            trimmed = "ws://" + trimmed;
        }

        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri))
        {
            throw new ArchipelagoConnectionException($"AP server address '{serverAddress}' is not a valid websocket URI.");
        }

        if (!string.Equals(uri.Scheme, "ws", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(uri.Scheme, "wss", StringComparison.OrdinalIgnoreCase))
        {
            throw new ArchipelagoConnectionException($"AP server URI '{serverAddress}' must use ws:// or wss://.");
        }

        var builder = new UriBuilder(uri)
        {
            Host = uri.Host.ToLowerInvariant(),
            Port = uri.IsDefaultPort ? defaultPort : uri.Port,
        };

        if (builder.Path == "/")
        {
            builder.Path = string.Empty;
        }
        else if (!string.IsNullOrEmpty(builder.Path))
        {
            builder.Path = builder.Path.TrimEnd('/');
        }

        var authority = builder.Uri.Authority;
        var path = builder.Path;
        var query = builder.Query;

        if ((string.IsNullOrEmpty(path) || path == "/") && string.IsNullOrEmpty(query))
        {
            return $"{builder.Scheme}://{authority}";
        }

        return $"{builder.Scheme}://{authority}{path}{query}";
    }

    private static List<ScoutLocationResult> ParseLocationInfo(JsonElement packet, int expectedLocationCount)
    {
        if (!TryGetProperty(packet, "locations", out var rawLocations)
            && !TryGetProperty(packet, "items", out rawLocations))
        {
            throw new ArchipelagoProtocolException("LocationInfo packet did not contain a locations list.");
        }

        if (rawLocations.ValueKind != JsonValueKind.Array)
        {
            throw new ArchipelagoProtocolException("LocationInfo packet locations field was not an array.");
        }

        var results = new List<ScoutLocationResult>();
        foreach (var entry in rawLocations.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.Object)
            {
                continue;
            }

            results.Add(
                new ScoutLocationResult
                {
                    LocationId = GetRequiredInt64(entry, "location"),
                    ItemId = GetRequiredInt64(entry, "item"),
                    OwningPlayerSlot = GetRequiredInt32(entry, "player"),
                    Flags = GetOptionalInt32(entry, "flags", GetOptionalInt32(entry, "item_flags", 0)),
                });
        }

        if (results.Count != expectedLocationCount)
        {
            throw new ArchipelagoProtocolException(
                $"LocationInfo packet contained {results.Count} entries; expected {expectedLocationCount}.");
        }

        return results.OrderBy(result => result.LocationId).ToList();
    }

    private static void ThrowIfConnectionRefused(JsonElement packet)
    {
        if (!string.Equals(GetCommand(packet), "ConnectionRefused", StringComparison.Ordinal))
        {
            return;
        }

        if (TryGetProperty(packet, "errors", out var errorsElement)
            && errorsElement.ValueKind == JsonValueKind.Array)
        {
            var reasons = errorsElement.EnumerateArray()
                .Where(item => item.ValueKind == JsonValueKind.String)
                .Select(item => item.GetString())
                .Where(item => !string.IsNullOrWhiteSpace(item))
                .ToArray();
            if (reasons.Length > 0)
            {
                throw new ArchipelagoAuthenticationException(
                    $"The AP server refused the connection: {string.Join(", ", reasons)}");
            }
        }

        throw new ArchipelagoAuthenticationException("The AP server refused the connection. Check the slot name and password, then try again.");
    }

    private async Task<JsonElement> ReceiveUntilCommandAsync(
        ClientWebSocket socket,
        Queue<JsonElement> packetBuffer,
        ISet<string> expectedCommands,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            if (packetBuffer.Count == 0)
            {
                var packets = await ReceivePacketsAsync(socket, timeout, cancellationToken);
                foreach (var bufferedPacket in packets)
                {
                    packetBuffer.Enqueue(bufferedPacket);
                }
            }

            if (packetBuffer.Count == 0)
            {
                throw new ArchipelagoProtocolException("AP server returned an empty packet frame.");
            }

            var packet = packetBuffer.Dequeue();
            var command = GetCommand(packet);
            if (expectedCommands.Contains(command))
            {
                return packet;
            }

            if (string.Equals(command, "ConnectionRefused", StringComparison.Ordinal))
            {
                ThrowIfConnectionRefused(packet);
            }

            HandleSidePacket(packet);
        }
    }

    private void HandleSidePacket(JsonElement packet)
    {
        var command = GetCommand(packet);
        if (string.Equals(command, "Print", StringComparison.Ordinal))
        {
            var text = GetOptionalString(packet, "text");
            if (!string.IsNullOrWhiteSpace(text))
            {
                Log($"AP server says: {text}");
            }
            return;
        }

        if (string.Equals(command, "PrintJSON", StringComparison.Ordinal))
        {
            Log("Received a PrintJSON message from the AP server during scouting.");
            return;
        }

        Log($"Ignoring unexpected AP packet '{command}' during the scout handshake.");
    }

    private static async Task<IReadOnlyList<JsonElement>> ReceivePacketsAsync(
        ClientWebSocket socket,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var rawMessage = await ReceiveTextMessageAsync(socket, timeout, cancellationToken);

        using var document = JsonDocument.Parse(rawMessage);
        if (document.RootElement.ValueKind == JsonValueKind.Object)
        {
            return new[] { document.RootElement.Clone() };
        }

        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new ArchipelagoProtocolException(
                $"Unexpected AP packet payload type: {document.RootElement.ValueKind}.");
        }

        var packets = new List<JsonElement>();
        foreach (var packet in document.RootElement.EnumerateArray())
        {
            if (packet.ValueKind == JsonValueKind.Object)
            {
                packets.Add(packet.Clone());
            }
        }

        return packets;
    }

    private static async Task<string> ReceiveTextMessageAsync(
        ClientWebSocket socket,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var stream = new MemoryStream();
        var buffer = new byte[8192];

        while (true)
        {
            var result = await ExecuteWithTimeoutAsync(
                receiveToken => socket.ReceiveAsync(new ArraySegment<byte>(buffer), receiveToken),
                timeout,
                cancellationToken,
                "Timed out waiting for AP server data.");

            if (result.MessageType == WebSocketMessageType.Close)
            {
                throw new ArchipelagoConnectionException("AP server closed the websocket unexpectedly.");
            }

            if (result.MessageType != WebSocketMessageType.Text
                && result.MessageType != WebSocketMessageType.Binary)
            {
                throw new ArchipelagoProtocolException(
                    $"Unsupported AP websocket message type: {result.MessageType}.");
            }

            stream.Write(buffer, 0, result.Count);

            if (result.EndOfMessage)
            {
                return Encoding.UTF8.GetString(stream.ToArray());
            }
        }
    }

    private static async Task SendMessagesAsync(
        ClientWebSocket socket,
        IReadOnlyList<object> messages,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var payload = JsonSerializer.Serialize(messages, SerializerOptions);
        var bytes = Encoding.UTF8.GetBytes(payload);

        await ExecuteWithTimeoutAsync(
            sendToken => socket.SendAsync(
                new ArraySegment<byte>(bytes),
                WebSocketMessageType.Text,
                true,
                sendToken),
            timeout,
            cancellationToken,
                "Timed out sending data to the AP server. Check the server connection and try again.");
    }

    private static async Task CloseQuietlyAsync(
        ClientWebSocket socket,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        if (socket.State is not WebSocketState.Open and not WebSocketState.CloseReceived)
        {
            return;
        }

        try
        {
            await ExecuteWithTimeoutAsync(
                closeToken => socket.CloseAsync(
                    WebSocketCloseStatus.NormalClosure,
                    "Scout complete",
                    closeToken),
                timeout,
                cancellationToken,
                "Timed out closing the AP websocket.");
        }
        catch (ArchipelagoScoutException)
        {
        }
        catch (WebSocketException)
        {
        }
    }

    private static async Task ExecuteWithTimeoutAsync(
        Func<CancellationToken, Task> action,
        TimeSpan timeout,
        CancellationToken cancellationToken,
        string timeoutMessage)
    {
        using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linkedSource.CancelAfter(timeout);

        try
        {
            await action(linkedSource.Token);
        }
        catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new ArchipelagoTimeoutException(timeoutMessage, ex);
        }
    }

    private static async Task<T> ExecuteWithTimeoutAsync<T>(
        Func<CancellationToken, Task<T>> action,
        TimeSpan timeout,
        CancellationToken cancellationToken,
        string timeoutMessage)
    {
        using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linkedSource.CancelAfter(timeout);

        try
        {
            return await action(linkedSource.Token);
        }
        catch (OperationCanceledException ex) when (!cancellationToken.IsCancellationRequested)
        {
            throw new ArchipelagoTimeoutException(timeoutMessage, ex);
        }
    }

    /// <summary>
    /// Reads slot_data.random_events from the Connected packet. Absent or
    /// malformed blocks read as disabled: rooms from older apworlds simply
    /// have no block, and a malformed one must not brick scouting - the
    /// ManifestBuilder count check still catches a world that removed
    /// locations without telling us.
    /// </summary>
    private static RandomEventsSlotData ParseRandomEventsSlotData(JsonElement connectedPacket)
    {
        if (!TryGetProperty(connectedPacket, "slot_data", out var slotData)
            || slotData.ValueKind != JsonValueKind.Object
            || !slotData.TryGetProperty("random_events", out var block)
            || block.ValueKind != JsonValueKind.Object
            || !block.TryGetProperty("enabled", out var enabled)
            || enabled.ValueKind != JsonValueKind.True)
        {
            return RandomEventsSlotData.Disabled;
        }

        var chosen = new List<string>();
        if (block.TryGetProperty("chosen", out var chosenElement)
            && chosenElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var element in chosenElement.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.String
                    && element.GetString() is { Length: > 0 } name)
                {
                    chosen.Add(name);
                }
            }
        }

        string? eventDataHash = null;
        if (block.TryGetProperty("event_data_hash", out var hashElement)
            && hashElement.ValueKind == JsonValueKind.String)
        {
            eventDataHash = hashElement.GetString();
        }

        var removed = new List<long>();
        if (block.TryGetProperty("removed_checks", out var removedElement)
            && removedElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var element in removedElement.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.Number && element.TryGetInt64(out var code))
                {
                    removed.Add(code);
                }
                else if (element.ValueKind == JsonValueKind.String
                    && long.TryParse(element.GetString(), out code))
                {
                    removed.Add(code);
                }
            }
        }

        return new RandomEventsSlotData
        {
            Enabled = true,
            ChosenEvents = chosen,
            EventDataHash = eventDataHash,
            RemovedLocationCodes = removed,
        };
    }

    private static string ParseGameModeSlotData(JsonElement connectedPacket)
    {
        if (TryGetProperty(connectedPacket, "slot_data", out var slotData)
            && slotData.ValueKind == JsonValueKind.Object
            && slotData.TryGetProperty("game_mode", out var gameModeElement))
        {
            if (gameModeElement.ValueKind == JsonValueKind.String)
            {
                return gameModeElement.GetString() ?? "campaign";
            }

            if (gameModeElement.ValueKind == JsonValueKind.Number && gameModeElement.TryGetInt32(out var modeInt))
            {
                return modeInt switch
                {
                    1 => "campaign_and_mercenaries",
                    2 => "mercenaries_only",
                    _ => "campaign"
                };
            }
        }

        return "campaign";
    }

    private static long[] GetRoomLocationIds(JsonElement connectedPacket, long[] knownLocationIds)

    {
        var roomIds = new SortedSet<long>();
        foreach (var propertyName in new[] { "missing_locations", "checked_locations" })
        {
            if (!TryGetProperty(connectedPacket, propertyName, out var property)
                || property.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (var element in property.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.Number && element.TryGetInt64(out var locationId))
                {
                    roomIds.Add(locationId);
                }
            }
        }

        if (roomIds.Count == 0)
        {
            // Defensive: an empty set means the packet shape changed - fall
            // back to the full bundled list (pre-0.4.0 behavior).
            return knownLocationIds;
        }

        var knownIds = new HashSet<long>(knownLocationIds);
        var unknownIds = roomIds.Where(locationId => !knownIds.Contains(locationId)).ToList();
        if (unknownIds.Count > 0)
        {
            throw new ArchipelagoScoutException(
                $"The room contains {unknownIds.Count} RE4R location id(s) this launcher's bundled world data does not know (first: {unknownIds[0]}). " +
                "The room was probably generated with a newer RE4R.apworld than this launcher bundles - update the launcher and re-check.");
        }

        return roomIds.ToArray();
    }

    private static int GetOptionalArrayCount(JsonElement packet, string propertyName)
    {
        if (!TryGetProperty(packet, propertyName, out var property) || property.ValueKind != JsonValueKind.Array)
        {
            return 0;
        }

        return property.GetArrayLength();
    }

    private static string GetCommand(JsonElement packet)
    {
        if (!TryGetProperty(packet, "cmd", out var command)
            || command.ValueKind != JsonValueKind.String)
        {
            throw new ArchipelagoProtocolException("AP packet did not contain a string cmd field.");
        }

        var value = command.GetString();
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArchipelagoProtocolException("AP packet cmd field was empty.");
        }

        return value;
    }

    private static string GetOptionalString(JsonElement packet, string propertyName)
    {
        if (!TryGetProperty(packet, propertyName, out var property)
            || property.ValueKind != JsonValueKind.String)
        {
            return string.Empty;
        }

        return property.GetString() ?? string.Empty;
    }

    private static int GetRequiredInt32(JsonElement packet, string propertyName)
    {
        if (!TryGetProperty(packet, propertyName, out var property))
        {
            throw new ArchipelagoProtocolException($"AP packet did not contain required integer field '{propertyName}'.");
        }

        if (property.ValueKind == JsonValueKind.Number && property.TryGetInt32(out var intValue))
        {
            return intValue;
        }

        if (property.ValueKind == JsonValueKind.String
            && int.TryParse(property.GetString(), out intValue))
        {
            return intValue;
        }

        throw new ArchipelagoProtocolException($"AP packet field '{propertyName}' was not a valid integer.");
    }

    private static int GetOptionalInt32(JsonElement packet, string propertyName, int defaultValue)
    {
        if (!TryGetProperty(packet, propertyName, out var property))
        {
            return defaultValue;
        }

        if (property.ValueKind == JsonValueKind.Number && property.TryGetInt32(out var intValue))
        {
            return intValue;
        }

        if (property.ValueKind == JsonValueKind.String
            && int.TryParse(property.GetString(), out intValue))
        {
            return intValue;
        }

        return defaultValue;
    }

    private static long GetRequiredInt64(JsonElement packet, string propertyName)
    {
        if (!TryGetProperty(packet, propertyName, out var property))
        {
            throw new ArchipelagoProtocolException($"AP packet did not contain required integer field '{propertyName}'.");
        }

        if (property.ValueKind == JsonValueKind.Number && property.TryGetInt64(out var longValue))
        {
            return longValue;
        }

        if (property.ValueKind == JsonValueKind.String
            && long.TryParse(property.GetString(), out longValue))
        {
            return longValue;
        }

        throw new ArchipelagoProtocolException($"AP packet field '{propertyName}' was not a valid integer.");
    }

    private static bool TryGetProperty(JsonElement element, string propertyName, out JsonElement property)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(propertyName, out property))
        {
            return true;
        }

        property = default;
        return false;
    }

    private void Log(string message)
    {
        LogMessage?.Invoke(message);
    }
}
