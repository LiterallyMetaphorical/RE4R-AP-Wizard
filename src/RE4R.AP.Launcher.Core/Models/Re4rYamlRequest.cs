namespace RE4R.AP.Launcher.Core.Models;

public sealed class Re4rYamlRequest
{
    public string SlotName { get; set; } = string.Empty;

    public string Difficulty { get; set; } = "standard";

    public bool DeathLink { get; set; }

    public bool AllowMissableLocations { get; set; }

    public bool RandomizeGatedKeys { get; set; }

    public IReadOnlyCollection<string> UnlockedTypewriterStageIds { get; set; } = Array.Empty<string>();
}
