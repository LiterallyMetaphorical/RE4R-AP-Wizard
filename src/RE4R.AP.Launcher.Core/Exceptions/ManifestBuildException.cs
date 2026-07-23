namespace RE4R.AP.Launcher.Core.Exceptions;

public sealed class ManifestBuildException : Exception
{
    public ManifestBuildException(string message)
        : base(message)
    {
    }

    public ManifestBuildException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
