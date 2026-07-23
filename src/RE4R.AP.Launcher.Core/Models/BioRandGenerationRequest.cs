namespace RE4R.AP.Launcher.Core.Models;

public sealed class BioRandGenerationRequest
{
    public int Seed { get; set; }

    public string ConfigJson { get; set; } = string.Empty;
}
