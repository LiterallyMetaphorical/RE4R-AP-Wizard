namespace RE4R.AP.Launcher.Core.Models;

public sealed class ArchipelagoScoutRequest
{
    public string ServerAddress { get; set; } = string.Empty;

    public string SlotName { get; set; } = string.Empty;

    public string? Password { get; set; }

    public string GameName { get; set; } = "Resident Evil 4 Remake";

    public IReadOnlyList<long> LocationIds { get; set; } = Array.Empty<long>();

    /// <summary>
    /// Merchant shop slot codes the bundled world data knows (D4). A room
    /// carries some prefix of these when shop_checks is on. They ride
    /// separately from <see cref="LocationIds"/> so the degenerate-packet
    /// scouting fallback still requests only real world locations.
    /// </summary>
    public IReadOnlyCollection<long> ShopSlotLocationIds { get; set; } = Array.Empty<long>();

    public TimeSpan ConnectTimeout { get; set; } = TimeSpan.FromSeconds(10);

    public TimeSpan ReceiveTimeout { get; set; } = TimeSpan.FromSeconds(10);

    public TimeSpan CloseTimeout { get; set; } = TimeSpan.FromSeconds(5);

    public Guid ClientUuid { get; set; } = Guid.NewGuid();
}
