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

            // The YAML's weapon-randomization choice (absent on older rooms).
            // Two booleans, one per BioRand switch: stats, and upgrades for
            // rooms new enough to carry the three-way.
            bool? randomWeaponStats = null;
            bool? randomWeaponUpgrades = null;
            if (TryGetProperty(connectedPacket, "slot_data", out var weaponStatsSlotData)
                && weaponStatsSlotData.ValueKind == JsonValueKind.Object)
            {
                if (weaponStatsSlotData.TryGetProperty("random_weapon_stats", out var weaponStatsElement)
                    && weaponStatsElement.ValueKind is JsonValueKind.True or JsonValueKind.False)
                {
                    randomWeaponStats = weaponStatsElement.ValueKind == JsonValueKind.True;
                }
                if (weaponStatsSlotData.TryGetProperty("random_weapon_upgrades", out var weaponUpgradesElement)
                    && weaponUpgradesElement.ValueKind is JsonValueKind.True or JsonValueKind.False)
                {
                    randomWeaponUpgrades = weaponUpgradesElement.ValueKind == JsonValueKind.True;
                }
            }

            // [Bonus Weapons] The YAML's consent to the permanent profile
            // unlock the Extra Content trio needs. False when absent (older
            // rooms, or no consent) - the mod then leaves the profile alone.
            var bonusWeaponsConsented = false;
            if (TryGetProperty(connectedPacket, "slot_data", out var bonusSlotData)
                && bonusSlotData.ValueKind == JsonValueKind.Object
                && bonusSlotData.TryGetProperty("bonus_weapons", out var bonusElement)
                && bonusElement.ValueKind is JsonValueKind.True or JsonValueKind.False)
            {
                bonusWeaponsConsented = bonusElement.ValueKind == JsonValueKind.True;
            }

            // [Mercenaries] What the slot plays, and the rank checks it carries.
            var gameMode = ParseGameModeSlotData(connectedPacket);
            var mercenaries = ParseMercenariesSlotData(connectedPacket);
            if (mercenaries.Enabled)
            {
                Log($"This room plays {DescribeGameMode(gameMode)}: {mercenaries.LocationIds.Count} Mercenaries rank check(s), {DescribeRank(mercenaries.RankFloor)} through {DescribeRank(mercenaries.RankCeiling)}.");
            }

            var merchantShop = ParseMerchantShopSlotData(connectedPacket);
            if (merchantShop.Enabled)
            {
                var scatterSuffix = merchantShop.ScatteredItemIds.Count > 0
                    ? $" {merchantShop.ScatteredItemIds.Count} piece(s) of his gear are scattered into the multiworld."
                    : string.Empty;
                Log($"The merchant sells {merchantShop.Slots.Count} Archipelago check(s) in this room.{scatterSuffix}");
            }

            var tradeShop = ParseTradeShopSlotData(connectedPacket);
            if (tradeShop.Enabled)
            {
                var stripSuffix = tradeShop.ShuffledTradeItemIds.Count > 0
                    ? $" {tradeShop.ShuffledTradeItemIds.Count} piece(s) of his trade stock are shuffled into the multiworld."
                    : string.Empty;
                Log($"The merchant trades {tradeShop.Checks.Count} Archipelago check(s) for spinel in this room.{stripSuffix}");
            }

            // Since apworld 0.4.0 the room's location count varies with the
            // RandomizeGatedKeys option, so scout exactly what the room
            // declares (missing + checked from Connected) instead of the full
            // bundled list - the server rejects unknown location ids.
            var extraKnownIds = new HashSet<long>(request.ShopSlotLocationIds);
            extraKnownIds.UnionWith(request.TradeCheckLocationIds);
            extraKnownIds.UnionWith(request.MercenariesLocationIds);
            var roomLocationIds = GetRoomLocationIds(
                connectedPacket, requestedLocationIds, extraKnownIds);
            var knownShopSlotIds = new HashSet<long>(request.ShopSlotLocationIds);
            var knownTradeCheckIds = new HashSet<long>(request.TradeCheckLocationIds);
            var roomShopSlotCount = roomLocationIds.Count(knownShopSlotIds.Contains);
            var roomTradeCheckCount = roomLocationIds.Count(knownTradeCheckIds.Contains);
            var knownMercenariesIds = new HashSet<long>(request.MercenariesLocationIds);
            var roomMercenariesCount = roomLocationIds.Count(knownMercenariesIds.Contains);
            var roomWorldCount = roomLocationIds.Length - roomShopSlotCount - roomTradeCheckCount - roomMercenariesCount;
            var scoutingMessage = roomWorldCount == requestedLocationIds.Length
                ? $"Scouting {roomWorldCount} locations"
                : $"Scouting {roomWorldCount} of {requestedLocationIds.Length} bundled locations (the rest are vanilla/preserved spots that are not part of this multiworld).";
            if (roomShopSlotCount > 0)
            {
                scoutingMessage += $" Plus {roomShopSlotCount} merchant shop check(s).";
            }
            if (roomTradeCheckCount > 0)
            {
                scoutingMessage += $" Plus {roomTradeCheckCount} trade check(s).";
            }
            if (roomMercenariesCount > 0)
            {
                scoutingMessage += $" Plus {roomMercenariesCount} Mercenaries rank check(s).";
            }

            Log(scoutingMessage);
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
                SlotName = request.SlotName,
                Locations = locations,
                RoomLocationIds = roomLocationIds,
                RandomEvents = randomEvents,
                SlotDifficulty = ParseSlotDifficulty(connectedPacket),
                MerchantShop = merchantShop,
                TradeShop = tradeShop,
                RandomWeaponStats = randomWeaponStats,
                RandomWeaponUpgrades = randomWeaponUpgrades,
                BonusWeaponsConsented = bonusWeaponsConsented,
                GameMode = gameMode,
                Mercenaries = mercenaries,
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

    /// <summary>
    /// Strip what a copy-paste from an Archipelago room page brings with it:
    /// the /connect verb, wrapping quotes, and any invisible character the
    /// HTML carried. Deliberately conservative - it removes decoration, never
    /// anything that could be part of a real host or port.
    /// </summary>
    private static string CleanPastedServerAddress(string serverAddress)
    {
        var value = serverAddress.Trim();

        // Quotes THEN verb THEN quotes again, because the room page renders
        // the whole command inside quotes - '/connect archipelago.gg:49239' -
        // so one pass in either order leaves the other wrapper behind.
        // Stripping the verb first and the quotes second failed on exactly
        // the string the page displays, which is the likeliest paste there
        // is. Caught by the test, not by reading it.
        const string connectVerb = "/connect";
        char[] quoteChars =
        {
            '\'', '\"', '`',
            '\u2018', '\u2019',
            '\u201c', '\u201d',
        };
        for (var pass = 0; pass < 2; pass++)
        {
            value = value.Trim(quoteChars).Trim();
            if (value.StartsWith(connectVerb, StringComparison.OrdinalIgnoreCase))
            {
                value = value[connectVerb.Length..].Trim();
            }
        }

        // Zero-width and non-breaking characters survive Trim() and are
        // invisible in the error message, which is what made this so
        // confusing to diagnose.
        var builder = new System.Text.StringBuilder(value.Length);
        foreach (var c in value)
        {
            if (char.IsControl(c) || c == '\u200b' || c == '\u200c' || c == '\u200d'
                || c == '\u00a0' || c == '\ufeff')
            {
                continue;
            }
            builder.Append(c);
        }

        return builder.ToString().Trim();
    }

    public static string NormalizeServerAddress(string serverAddress, int defaultPort = 38281)
    {
        if (string.IsNullOrWhiteSpace(serverAddress))
        {
            throw new ArchipelagoConnectionException("AP server address is empty.");
        }

        // Players get this address by copying it off the room page, and that
        // page renders it as: You can connect to this room by using
        // '/connect archipelago.gg:49239' in the client. So the paste arrives
        // wrapped in quotes, carrying the /connect verb, or with an invisible
        // character the HTML brought along - and Uri.TryCreate rejects ALL of
        // those while the string still looks perfect in an error message.
        // Cam hit exactly that on 2026-09-01: the wizard said
        // "'ws://archipelago.gg:49239' is not a valid websocket URI" about an
        // address that reads as valid, because the junk was unprintable.
        //
        // So clean the paste instead of blaming it.
        var trimmed = CleanPastedServerAddress(serverAddress);
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
            // Say WHICH character is the problem. An address that looks right
            // and is refused anyway is the worst kind of error to be handed,
            // and unprintable junk is the usual cause.
            var offenders = trimmed
                .Where(c => char.IsControl(c) || c > 126)
                .Select(c => $"U+{(int)c:X4}")
                .Distinct()
                .ToArray();
            var detail = offenders.Length > 0
                ? $" It contains {string.Join(", ", offenders)}, which usually means it was pasted from a web page."
                : " Expected something like archipelago.gg:38281.";
            throw new ArchipelagoConnectionException(
                $"AP server address '{serverAddress}' is not a valid websocket URI.{detail}");
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
    internal static RandomEventsSlotData ParseRandomEventsSlotData(JsonElement connectedPacket)
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

    /// <summary>
    /// Reads slot_data.merchant_shop from the Connected packet (D4). The
    /// apworld resolves slots after fill, so this block already names each
    /// slot's item and owner. Absent or malformed reads as disabled - older
    /// rooms have no block, and the merchant then behaves exactly as before.
    /// A slot missing its price tier is dropped rather than guessed at: the
    /// fork refuses a manifest whose slot has no tier, so a half-parsed block
    /// must not reach it.
    /// </summary>
    /// <summary>
    /// slot_data.trade_shop -> model. Absent/malformed reads as Disabled,
    /// which leaves the Trade tab exactly as BioRand made it (older rooms).
    /// A check missing its price is dropped rather than guessed: the fork
    /// refuses a manifest slot with no price, so a half-parsed check must
    /// not reach it.
    /// </summary>
    internal static TradeShopSlotData ParseTradeShopSlotData(JsonElement connectedPacket)
    {
        if (!TryGetProperty(connectedPacket, "slot_data", out var slotData)
            || slotData.ValueKind != JsonValueKind.Object
            || !slotData.TryGetProperty("trade_shop", out var block)
            || block.ValueKind != JsonValueKind.Object
            || !block.TryGetProperty("enabled", out var enabled)
            || enabled.ValueKind != JsonValueKind.True)
        {
            return TradeShopSlotData.Disabled;
        }

        var checks = new List<TradeShopCheck>();
        if (block.TryGetProperty("checks", out var checksElement)
            && checksElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var element in checksElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object
                    || !element.TryGetProperty("code", out var codeElement)
                    || !codeElement.TryGetInt64(out var locationCode)
                    || !element.TryGetProperty("release_index", out var releaseElement)
                    || !releaseElement.TryGetInt32(out var releaseIndex)
                    || !element.TryGetProperty("chapter", out var chapterElement)
                    || !chapterElement.TryGetInt32(out var chapter)
                    || !element.TryGetProperty("price_spinel", out var priceElement)
                    || !priceElement.TryGetInt32(out var priceSpinel)
                    || priceSpinel < 1)
                {
                    continue;
                }

                checks.Add(new TradeShopCheck
                {
                    LocationCode = locationCode,
                    ReleaseIndex = releaseIndex,
                    Chapter = chapter,
                    PriceSpinel = priceSpinel,
                    Identity = element.TryGetProperty("identity", out var identityElement)
                        && identityElement.ValueKind == JsonValueKind.String
                        && !string.IsNullOrWhiteSpace(identityElement.GetString())
                            ? identityElement.GetString()!
                            : $"trade:release:{releaseIndex}",
                    ChapterOrdinal = element.TryGetProperty("chapter_ordinal", out var ordinalElement)
                        && ordinalElement.TryGetInt32(out var parsedOrdinal)
                        && parsedOrdinal > 0
                            ? parsedOrdinal
                            : 1,
                    Tier = element.TryGetProperty("tier", out var tierElement)
                        && tierElement.ValueKind == JsonValueKind.String
                            ? tierElement.GetString() ?? "FILLER"
                            : "FILLER",
                    CumulativeSpinel = element.TryGetProperty("cumulative_spinel", out var cumulativeElement)
                        && cumulativeElement.TryGetInt32(out var parsedCumulative)
                        && parsedCumulative > 0
                            ? parsedCumulative
                            : priceSpinel,
                    ItemId = element.TryGetProperty("item_id", out var itemIdElement)
                        && itemIdElement.TryGetInt32(out var parsedItemId)
                        && parsedItemId > 0
                            ? parsedItemId
                            : 0,
                    ItemStack = element.TryGetProperty("item_stack", out var stackElement)
                        && stackElement.TryGetInt32(out var parsedStack)
                        && parsedStack > 0
                            ? parsedStack
                            : 0,
                    DisplayName = element.TryGetProperty("display_name", out var nameElement)
                        && nameElement.ValueKind == JsonValueKind.String
                            ? nameElement.GetString() ?? string.Empty
                            : string.Empty,
                    PlayerName = element.TryGetProperty("player_name", out var playerElement)
                        && playerElement.ValueKind == JsonValueKind.String
                            ? playerElement.GetString() ?? string.Empty
                            : string.Empty,
                    Remote = element.TryGetProperty("remote", out var remoteElement)
                        && remoteElement.ValueKind == JsonValueKind.True,
                });
            }
        }

        var gems = new Dictionary<string, TradeShopGem>(StringComparer.OrdinalIgnoreCase);
        if (block.TryGetProperty("gems", out var gemsElement)
            && gemsElement.ValueKind == JsonValueKind.Object)
        {
            foreach (var gemProperty in gemsElement.EnumerateObject())
            {
                var gem = gemProperty.Value;
                if (gem.ValueKind != JsonValueKind.Object
                    || !gem.TryGetProperty("item_id", out var gemIdElement)
                    || !gemIdElement.TryGetInt32(out var gemItemId)
                    || !gem.TryGetProperty("spinel", out var gemSpinelElement)
                    || !gemSpinelElement.TryGetInt32(out var gemSpinel)
                    || gemSpinel < 1)
                {
                    continue;
                }

                gems[gemProperty.Name] = new TradeShopGem(gemItemId, gemSpinel);
            }
        }

        var shuffledTradeItemIds = new List<int>();
        if (block.TryGetProperty("shuffled_trade_item_ids", out var shuffledElement)
            && shuffledElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var element in shuffledElement.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.Number
                    && element.TryGetInt32(out var itemId)
                    && itemId > 0)
                {
                    shuffledTradeItemIds.Add(itemId);
                }
            }
        }

        return new TradeShopSlotData
        {
            Enabled = true,
            Checks = checks,
            Gems = gems,
            ShuffledTradeItemIds = shuffledTradeItemIds,
            VelvetBlueSpinel = block.TryGetProperty("velvet_blue_spinel", out var vbElement)
                && vbElement.TryGetInt32(out var vbSpinel)
                && vbSpinel > 0
                    ? vbSpinel
                    : 2,
            SpinelItemId = block.TryGetProperty("spinel_item_id", out var spinelIdElement)
                && spinelIdElement.TryGetInt32(out var spinelItemId)
                    ? spinelItemId
                    : 0,
            SpinelPoolTotal = block.TryGetProperty("spinel_pool_total", out var spinelTotalElement)
                && spinelTotalElement.TryGetInt32(out var spinelTotal)
                    ? spinelTotal
                    : 0,
        };
    }

    /// <summary>
    /// slot_data.game_mode: "campaign" (also when absent),
    /// "campaign_and_mercenaries" or "mercenaries_only".
    /// </summary>
    internal static string ParseGameModeSlotData(JsonElement connectedPacket)
    {
        if (TryGetProperty(connectedPacket, "slot_data", out var slotData)
            && slotData.ValueKind == JsonValueKind.Object
            && slotData.TryGetProperty("game_mode", out var modeElement)
            && modeElement.ValueKind == JsonValueKind.String)
        {
            var mode = (modeElement.GetString() ?? string.Empty).Trim().ToLowerInvariant();
            if (mode is "campaign" or "campaign_and_mercenaries" or "mercenaries_only")
            {
                return mode;
            }
        }

        return "campaign";
    }

    /// <summary>The room's difficulty as the game numbers it; 20 when unsaid.</summary>
    internal static int ParseSlotDifficulty(JsonElement connectedPacket)
    {
        if (!TryGetProperty(connectedPacket, "slot_data", out var slotData)
            || slotData.ValueKind != JsonValueKind.Object
            || !slotData.TryGetProperty("difficulty", out var value)
            || value.ValueKind != JsonValueKind.String)
        {
            return 20;
        }

        return (value.GetString() ?? string.Empty).Trim().ToLowerInvariant() switch
        {
            "assisted" => 10,
            "hardcore" => 30,
            "professional" => 40,
            _ => 20,
        };
    }

    private static string DescribeRank(string rank) => rank switch
    {
        "c" => "C",
        "b" => "B",
        "a" => "A",
        "s" => "S",
        "s_plus" => "S+",
        "s_plus_plus" => "S++",
        _ => string.IsNullOrWhiteSpace(rank) ? "?" : rank,
    };

    private static string DescribeGameMode(string gameMode) => gameMode switch
    {
        "mercenaries_only" => "The Mercenaries only",
        "campaign_and_mercenaries" => "the campaign and The Mercenaries",
        _ => "the campaign",
    };

    /// <summary>
    /// slot_data.mercenaries -> model. Absent, disabled or malformed reads as
    /// Disabled; the ids come from the character -> stage -> rank map.
    /// </summary>
    internal static MercenariesSlotData ParseMercenariesSlotData(JsonElement connectedPacket)
    {
        if (!TryGetProperty(connectedPacket, "slot_data", out var slotData)
            || slotData.ValueKind != JsonValueKind.Object
            || !slotData.TryGetProperty("mercenaries", out var block)
            || block.ValueKind != JsonValueKind.Object
            || !block.TryGetProperty("enabled", out var enabledElement)
            || enabledElement.ValueKind != JsonValueKind.True)
        {
            return MercenariesSlotData.Disabled;
        }

        var ids = new List<long>();
        if (block.TryGetProperty("locations", out var byCharacter) && byCharacter.ValueKind == JsonValueKind.Object)
        {
            foreach (var character in byCharacter.EnumerateObject())
            {
                if (character.Value.ValueKind != JsonValueKind.Object)
                {
                    continue;
                }

                foreach (var stage in character.Value.EnumerateObject())
                {
                    if (stage.Value.ValueKind != JsonValueKind.Object)
                    {
                        continue;
                    }

                    foreach (var rank in stage.Value.EnumerateObject())
                    {
                        if (rank.Value.ValueKind == JsonValueKind.Number
                            && rank.Value.TryGetInt64(out var id)
                            && id > 0)
                        {
                            ids.Add(id);
                        }
                    }
                }
            }
        }

        static string ReadString(JsonElement element, string name) =>
            element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString() ?? string.Empty
                : string.Empty;

        return new MercenariesSlotData
        {
            Enabled = true,
            RankFloor = ReadString(block, "rank_floor"),
            RankCeiling = ReadString(block, "rank_ceiling"),
            StartingCharacter = ReadString(block, "starting_character"),
            StartingStage = ReadString(block, "starting_stage"),
            LocationIds = ids.Distinct().OrderBy(id => id).ToArray(),
        };
    }

    internal static MerchantShopSlotData ParseMerchantShopSlotData(JsonElement connectedPacket)
    {
        if (!TryGetProperty(connectedPacket, "slot_data", out var slotData)
            || slotData.ValueKind != JsonValueKind.Object
            || !slotData.TryGetProperty("merchant_shop", out var block)
            || block.ValueKind != JsonValueKind.Object
            || !block.TryGetProperty("enabled", out var enabled)
            || enabled.ValueKind != JsonValueKind.True)
        {
            return MerchantShopSlotData.Disabled;
        }

        var tiers = new Dictionary<string, MerchantShopTier>(StringComparer.OrdinalIgnoreCase);
        if (block.TryGetProperty("tiers", out var tiersElement)
            && tiersElement.ValueKind == JsonValueKind.Object)
        {
            foreach (var tierProperty in tiersElement.EnumerateObject())
            {
                var tier = tierProperty.Value;
                if (tier.ValueKind != JsonValueKind.Object
                    || !tier.TryGetProperty("price", out var priceElement)
                    || !priceElement.TryGetInt32(out var price)
                    || price < 1)
                {
                    continue;
                }

                var refundItemId = 0;
                if (tier.TryGetProperty("refund_item_id", out var refundIdElement))
                {
                    refundIdElement.TryGetInt32(out refundItemId);
                }

                var refundItemName = string.Empty;
                if (tier.TryGetProperty("refund_item_name", out var refundNameElement)
                    && refundNameElement.ValueKind == JsonValueKind.String)
                {
                    refundItemName = refundNameElement.GetString() ?? string.Empty;
                }

                // Rooms from before the spinel refund carry no count: one gem.
                var refundCount = 1;
                if (tier.TryGetProperty("refund_count", out var refundCountElement)
                    && refundCountElement.TryGetInt32(out var parsedCount)
                    && parsedCount > 0)
                {
                    refundCount = parsedCount;
                }

                tiers[tierProperty.Name] = new MerchantShopTier(price, refundItemId, refundItemName, refundCount);
            }
        }

        var slots = new List<MerchantShopSlot>();
        if (block.TryGetProperty("slots", out var slotsElement)
            && slotsElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var element in slotsElement.EnumerateArray())
            {
                if (element.ValueKind != JsonValueKind.Object
                    || !element.TryGetProperty("code", out var codeElement)
                    || !codeElement.TryGetInt64(out var locationCode)
                    || !element.TryGetProperty("index", out var indexElement)
                    || !indexElement.TryGetInt32(out var index)
                    || !element.TryGetProperty("unlock_chapter", out var chapterElement)
                    || !chapterElement.TryGetInt32(out var unlockChapter))
                {
                    continue;
                }

                var classification = element.TryGetProperty("classification", out var classElement)
                    && classElement.ValueKind == JsonValueKind.String
                        ? classElement.GetString() ?? "FILLER"
                        : "FILLER";
                if (!tiers.ContainsKey(classification))
                {
                    continue;
                }

                // Rotation rooms key on the check; pre-rotation rooms had one
                // check per row and acked on the row number, so that is the
                // honest fallback rather than a guess.
                var identity = element.TryGetProperty("identity", out var identityElement)
                    && identityElement.ValueKind == JsonValueKind.String
                    && !string.IsNullOrWhiteSpace(identityElement.GetString())
                        ? identityElement.GetString()!
                        : $"shop:slot:{index}";

                var chapterOrdinal = element.TryGetProperty("chapter_ordinal", out var ordinalElement)
                    && ordinalElement.TryGetInt32(out var parsedOrdinal)
                    && parsedOrdinal > 0
                        ? parsedOrdinal
                        : 1;

                var itemId = element.TryGetProperty("item_id", out var itemIdElement)
                    && itemIdElement.TryGetInt32(out var parsedItemId)
                    && parsedItemId > 0
                        ? parsedItemId
                        : 0;

                var itemStack = element.TryGetProperty("item_stack", out var stackElement)
                    && stackElement.TryGetInt32(out var parsedStack)
                    && parsedStack > 0
                        ? parsedStack
                        : 0;

                slots.Add(new MerchantShopSlot
                {
                    LocationCode = locationCode,
                    Index = index,
                    Identity = identity,
                    ChapterOrdinal = chapterOrdinal,
                    ItemId = itemId,
                    ItemStack = itemStack,
                    UnlockChapter = unlockChapter,
                    Classification = classification,
                    DisplayName = element.TryGetProperty("display_name", out var nameElement)
                        && nameElement.ValueKind == JsonValueKind.String
                            ? nameElement.GetString() ?? string.Empty
                            : string.Empty,
                    PlayerName = element.TryGetProperty("player_name", out var playerElement)
                        && playerElement.ValueKind == JsonValueKind.String
                            ? playerElement.GetString() ?? string.Empty
                            : string.Empty,
                    Remote = element.TryGetProperty("remote", out var remoteElement)
                        && remoteElement.ValueKind == JsonValueKind.True,
                });
            }
        }

        // [D10] Gear the multiworld holds instead of the shelf. Present
        // (possibly empty) whenever the apworld emits the section.
        var scatteredItemIds = new List<int>();
        if (block.TryGetProperty("scattered_item_ids", out var scatteredElement)
            && scatteredElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var element in scatteredElement.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.Number
                    && element.TryGetInt32(out var itemId)
                    && itemId > 0)
                {
                    scatteredItemIds.Add(itemId);
                }
            }
        }

        // [Starting Arsenal] The engine ids the player begins with; the fork
        // paces their ammo from chapter zero. Absent in older rooms.
        var startingWeaponIds = new List<int>();
        if (block.TryGetProperty("starting_weapon_ids", out var startingElement)
            && startingElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var element in startingElement.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.Number
                    && element.TryGetInt32(out var itemId)
                    && itemId > 0)
                {
                    startingWeaponIds.Add(itemId);
                }
            }
        }

        // [Starting attachments] Null when the key is absent (an apworld
        // that predates the roll); present-but-empty means the generator
        // rolled and granted nothing. The distinction reaches the fork,
        // which keeps its legacy arsenal-aimed roll only for null.
        List<int>? startingAttachmentIds = null;
        if (block.TryGetProperty("starting_attachment_ids", out var attachmentElement)
            && attachmentElement.ValueKind == JsonValueKind.Array)
        {
            startingAttachmentIds = new List<int>();
            foreach (var element in attachmentElement.EnumerateArray())
            {
                if (element.ValueKind == JsonValueKind.Number
                    && element.TryGetInt32(out var attachmentId)
                    && attachmentId > 0)
                {
                    startingAttachmentIds.Add(attachmentId);
                }
            }
        }

        if (slots.Count == 0 && scatteredItemIds.Count == 0)
        {
            return MerchantShopSlotData.Disabled;
        }

        return new MerchantShopSlotData
        {
            Enabled = true,
            Slots = slots,
            Tiers = tiers,
            ScatteredItemIds = scatteredItemIds,
            StartingWeaponIds = startingWeaponIds,
            StartingAttachmentIds = startingAttachmentIds,
        };
    }

    private static long[] GetRoomLocationIds(
        JsonElement connectedPacket,
        long[] knownLocationIds,
        IReadOnlyCollection<long> shopSlotLocationIds)
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

        // Shop slots are known ids too, but only for recognising what the
        // room declares - the fallback above never requests them.
        var knownIds = new HashSet<long>(knownLocationIds);
        knownIds.UnionWith(shopSlotLocationIds);
        var unknownIds = roomIds.Where(locationId => !knownIds.Contains(locationId)).ToList();
        if (unknownIds.Count > 0)
        {
            // Direction is UNKNOWABLE from here. All this comparison proves is
            // that the two sets differ; it cannot tell which side moved. The
            // old wording asserted the room was NEWER and told the player to
            // update the launcher, which is exactly backwards when the launcher
            // is the fresh side - and it was, the day four cosmetic accessory
            // locations left the pool and every room generated before that
            // tripped this (Cam, live 2026-08-21). Name both remedies, rank
            // neither.
            throw new ArchipelagoScoutException(
                $"The room contains {unknownIds.Count} RE4R location id(s) this launcher's bundled world data does not know (first: {unknownIds[0]}). " +
                "The room and this launcher were built from different versions of RE4R.apworld; which one is older cannot be told from here. " +
                "Either regenerate the room with the apworld this launcher ships, or update the launcher to match the one the room was generated with.");
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
