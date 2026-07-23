namespace RE4R.AP.Launcher.Core.Exceptions;

public sealed class StaticGameDataException : Exception
{
    public StaticGameDataException(string message)
        : base(message)
    {
    }

    public StaticGameDataException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
