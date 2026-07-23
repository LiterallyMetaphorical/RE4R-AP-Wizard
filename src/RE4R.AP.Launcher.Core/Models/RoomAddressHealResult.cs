namespace RE4R.AP.Launcher.Core.Models;

/// <summary>Outcome of the room-page-driven address heal.</summary>
public sealed class RoomAddressHealResult
{
    public bool Succeeded { get; init; }

    /// <summary>The verified, normalized address now written everywhere.</summary>
    public string HealedServer { get; init; } = string.Empty;

    /// <summary>False when the recorded address was already correct.</summary>
    public bool AddressChanged { get; init; }

    /// <summary>Player-facing reason when <see cref="Succeeded"/> is false.</summary>
    public string FailureReason { get; init; } = string.Empty;
}
