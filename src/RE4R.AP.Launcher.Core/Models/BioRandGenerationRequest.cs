namespace RE4R.AP.Launcher.Core.Models;

public sealed class BioRandGenerationRequest
{
    public string Re4rInstallPath { get; set; } = string.Empty;

    public int Seed { get; set; }

    public string ConfigJson { get; set; } = string.Empty;
}
