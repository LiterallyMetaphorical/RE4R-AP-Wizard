namespace RE4R.AP.Launcher.Core.Exceptions;

public class ArchipelagoScoutException : Exception
{
    public ArchipelagoScoutException(string message)
        : base(message)
    {
    }

    public ArchipelagoScoutException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class ArchipelagoConnectionException : ArchipelagoScoutException
{
    public ArchipelagoConnectionException(string message)
        : base(message)
    {
    }

    public ArchipelagoConnectionException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class ArchipelagoAuthenticationException : ArchipelagoScoutException
{
    public ArchipelagoAuthenticationException(string message)
        : base(message)
    {
    }

    public ArchipelagoAuthenticationException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class ArchipelagoTimeoutException : ArchipelagoScoutException
{
    public ArchipelagoTimeoutException(string message)
        : base(message)
    {
    }

    public ArchipelagoTimeoutException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class ArchipelagoProtocolException : ArchipelagoScoutException
{
    public ArchipelagoProtocolException(string message)
        : base(message)
    {
    }

    public ArchipelagoProtocolException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
