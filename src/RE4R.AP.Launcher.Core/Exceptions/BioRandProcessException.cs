namespace RE4R.AP.Launcher.Core.Exceptions;

public sealed class BioRandProcessException : Exception
{
    public BioRandProcessException(string message)
        : base(message)
    {
    }

    public BioRandProcessException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
