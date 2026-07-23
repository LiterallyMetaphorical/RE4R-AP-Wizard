using RE4R.AP.Launcher.Core.Models;

namespace RE4R.AP.Launcher.Core.Exceptions;

public sealed class WorkflowException : Exception
{
    public WorkflowException(WorkflowStep step, string message)
        : base(message)
    {
        Step = step;
    }

    public WorkflowException(WorkflowStep step, string message, Exception innerException)
        : base(message, innerException)
    {
        Step = step;
    }

    public WorkflowStep Step { get; }
}
