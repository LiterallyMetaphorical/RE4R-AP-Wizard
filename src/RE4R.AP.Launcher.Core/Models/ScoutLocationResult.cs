namespace RE4R.AP.Launcher.Core.Models;

public sealed class ScoutLocationResult
{
    public long LocationId { get; init; }

    public long ItemId { get; init; }

    public int OwningPlayerSlot { get; init; }

    public int Flags { get; init; }
}
