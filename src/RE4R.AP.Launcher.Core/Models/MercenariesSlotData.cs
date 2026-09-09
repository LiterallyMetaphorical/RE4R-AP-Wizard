namespace RE4R.AP.Launcher.Core.Models;

/// <summary>
/// slot_data.mercenaries from the Connected packet (apworld 0.7.2): whether
/// the slot plays The Mercenaries, which ranks count, what it starts with,
/// and the rank-check location ids flattened out of the character -> stage
/// -> rank map. Absent or disabled reads as <see cref="Disabled"/>.
/// </summary>
public sealed class MercenariesSlotData
{
    public static readonly MercenariesSlotData Disabled = new();

    public bool Enabled { get; init; }

    /// <summary>"a_only", "standard" or "full".</summary>
    public string ScoreChecks { get; init; } = string.Empty;

    public string StartingCharacter { get; init; } = string.Empty;

    public string StartingStage { get; init; } = string.Empty;

    public IReadOnlyList<long> LocationIds { get; init; } = Array.Empty<long>();
}
