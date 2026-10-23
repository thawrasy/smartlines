namespace BankFas.Data.Workflow;

/// <summary>
/// An action the engine refuses, with the HTTP status and the code the API answers (DOC-B04 section 6): 403 for who may
/// not act, 404 for what the actor may not see, 409 for a state that moved, 422 for what is missing. The message
/// names the item, as BR-WFL-014 asks, and never a value the actor may not read.
/// </summary>
public sealed class WorkflowRefusalException : Exception
{
    public WorkflowRefusalException() { }
    public WorkflowRefusalException(string message) : base(message) { }
    public WorkflowRefusalException(string message, Exception inner) : base(message, inner) { }

    public WorkflowRefusalException(int status, string code, string message) : base(message)
    {
        Status = status;
        Code = code;
    }

    public int Status { get; } = 409;
    public string Code { get; } = "INVALID_STATE";

    public static WorkflowRefusalException State(string message) => new(409, "INVALID_STATE", message);
    public static WorkflowRefusalException Forbidden(string message) => new(403, "FORBIDDEN", message);
    public static WorkflowRefusalException Missing(string code, string message) => new(422, code, message);
    public static WorkflowRefusalException NotFound() => new(404, "NOT_FOUND", "The request does not exist or is not visible to you.");
    public static WorkflowRefusalException Conflict() => new(409, "VERSION_CONFLICT", "The request changed meanwhile; reload it and try again.");
}
