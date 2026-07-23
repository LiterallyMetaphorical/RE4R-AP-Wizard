namespace RE4R.AP.Launcher.Core.Exceptions;

public sealed class InstallException : Exception
{
    public InstallException(string message)
        : base(message)
    {
    }

    public InstallException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
