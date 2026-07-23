namespace RE4R.AP.Launcher.Core.Exceptions;

public sealed class YamlInspectionException : Exception
{
    public YamlInspectionException(string message)
        : base(message)
    {
    }

    public YamlInspectionException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
