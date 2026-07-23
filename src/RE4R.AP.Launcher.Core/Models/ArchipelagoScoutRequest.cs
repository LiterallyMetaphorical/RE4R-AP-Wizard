namespace RE4R.AP.Launcher.Core.Models;

public sealed class ArchipelagoScoutRequest
{
    public string ServerAddress { get; set; } = string.Empty;

    public string SlotName { get; set; } = string.Empty;

    public string? Password { get; set; }

    public string GameName { get; set; } = "Resident Evil 4 Remake";

    public IReadOnlyList<long> LocationIds { get; set; } = Array.Empty<long>();

    public TimeSpan ConnectTimeout { get; set; } = TimeSpan.FromSeconds(10);

    public TimeSpan ReceiveTimeout { get; set; } = TimeSpan.FromSeconds(10);

    public TimeSpan CloseTimeout { get; set; } = TimeSpan.FromSeconds(5);

    public Guid ClientUuid { get; set; } = Guid.NewGuid();
}
