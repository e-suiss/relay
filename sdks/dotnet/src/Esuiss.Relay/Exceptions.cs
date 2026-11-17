using System.Text.Json.Nodes;

namespace Esuiss.Relay;

/// <summary>The base of every error the SDK raises.</summary>
public class RelayException : Exception
{
    /// <summary>Creates an error with a message.</summary>
    public RelayException(string message)
        : base(message)
    {
    }

    /// <summary>Creates an error with a message and its cause.</summary>
    public RelayException(string message, Exception? innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>The details of an RFC 9457 problem returned by Relay.</summary>
/// <param name="Status">The HTTP status.</param>
/// <param name="Code">The error code, or null when the response carried no problem document.</param>
/// <param name="Title">The fixed title of the code.</param>
/// <param name="Detail">The explanation of this occurrence.</param>
/// <param name="Type">The URL of the error code page.</param>
/// <param name="RequestId">The Request-Id of the response.</param>
/// <param name="Retryable">Whether the request may be retried.</param>
/// <param name="RetryAfter">How long to wait before retrying, when given.</param>
/// <param name="Problem">The whole problem document.</param>
public sealed record RelayError(
    int Status,
    string? Code,
    string Title,
    string? Detail,
    string? Type,
    string? RequestId,
    bool Retryable,
    TimeSpan? RetryAfter,
    JsonObject? Problem);

/// <summary>An error response of the Relay API.</summary>
public class RelayApiException : RelayException
{
    /// <summary>Creates the error from the problem Relay returned.</summary>
    public RelayApiException(RelayError error)
        : base(Describe(error))
    {
        Error = error;
    }

    /// <summary>The problem Relay returned.</summary>
    public RelayError Error { get; }

    /// <summary>The HTTP status.</summary>
    public int Status => Error.Status;

    /// <summary>The error code, or null when the response carried no problem document.</summary>
    public string? Code => Error.Code;

    /// <summary>Whether Relay said the request may be retried.</summary>
    public bool Retryable => Error.Retryable;

    /// <summary>The Request-Id of the response.</summary>
    public string? RequestId => Error.RequestId;

    private static string Describe(RelayError error) =>
        error.Detail is null
            ? $"{error.Status} {error.Code ?? "error"}: {error.Title}"
            : $"{error.Status} {error.Code ?? "error"}: {error.Title} ({error.Detail})";
}

/// <summary>The credentials are missing, not valid or not allowed to make the request.</summary>
public class RelayAuthenticationException : RelayApiException
{
    /// <summary>Creates the error.</summary>
    public RelayAuthenticationException(RelayError error)
        : base(error)
    {
    }
}

/// <summary>The request is malformed or its content is not valid.</summary>
public class RelayValidationException : RelayApiException
{
    /// <summary>Creates the error.</summary>
    public RelayValidationException(RelayError error)
        : base(error)
    {
    }
}

/// <summary>The request was refused by a rate limit or a quota.</summary>
public class RelayRateLimitException : RelayApiException
{
    /// <summary>Creates the error.</summary>
    public RelayRateLimitException(RelayError error)
        : base(error)
    {
    }
}

/// <summary>The request was refused by a quota, such as an exhausted sending quota or a batch above its limit.</summary>
public class RelayQuotaException : RelayRateLimitException
{
    /// <summary>Creates the error.</summary>
    public RelayQuotaException(RelayError error)
        : base(error)
    {
    }
}

/// <summary>The Idempotency-Key is missing, not valid, reused with another body or still in progress.</summary>
public class RelayIdempotencyException : RelayApiException
{
    /// <summary>Creates the error.</summary>
    public RelayIdempotencyException(RelayError error)
        : base(error)
    {
    }
}

/// <summary>Relay failed or is unavailable.</summary>
public class RelayServerException : RelayApiException
{
    /// <summary>Creates the error.</summary>
    public RelayServerException(RelayError error)
        : base(error)
    {
    }
}

/// <summary>The resource does not exist.</summary>
public class RelayNotFoundException : RelayValidationException
{
    /// <summary>Creates the error.</summary>
    public RelayNotFoundException(RelayError error)
        : base(error)
    {
    }
}

/// <summary>The request conflicts with the state of the resource.</summary>
public class RelayConflictException : RelayValidationException
{
    /// <summary>Creates the error.</summary>
    public RelayConflictException(RelayError error)
        : base(error)
    {
    }
}

/// <summary>Relay could not be reached or did not answer in time.</summary>
public class RelayConnectionException : RelayException
{
    /// <summary>Creates the error.</summary>
    public RelayConnectionException(string message, Exception? innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>A waitpoint was still open when the wait ended.</summary>
public class RelayWaitpointTimeoutException : RelayException
{
    /// <summary>Creates the error.</summary>
    public RelayWaitpointTimeoutException(string waitpointId, JsonNode lastSeen)
        : base($"waitpoint {waitpointId} is still open")
    {
        WaitpointId = waitpointId;
        LastSeen = lastSeen;
    }

    /// <summary>The waitpoint waited on.</summary>
    public string WaitpointId { get; }

    /// <summary>The waitpoint as last read.</summary>
    public JsonNode LastSeen { get; }
}

internal enum ErrorClass
{
    Auth,
    Validation,
    RateLimit,
    Idempotency,
    Server,
}

internal static class ErrorMapping
{
    internal static ErrorClass Classify(int status, string? code)
    {
        switch (ErrorCatalog.Family(code))
        {
            case "auth":
                return ErrorClass.Auth;
            case "quota":
                return ErrorClass.RateLimit;
            case "idempotency":
                return ErrorClass.Idempotency;
            case "platform":
                return ErrorClass.Server;
            case not null:
                return status >= 500 ? ErrorClass.Server : ErrorClass.Validation;
            default:
                return status switch
                {
                    401 or 403 => ErrorClass.Auth,
                    429 => ErrorClass.RateLimit,
                    >= 500 => ErrorClass.Server,
                    _ => ErrorClass.Validation,
                };
        }
    }

    internal static RelayApiException Create(RelayError error) =>
        Classify(error.Status, error.Code) switch
        {
            ErrorClass.Auth => new RelayAuthenticationException(error),
            ErrorClass.RateLimit when error.Code is not null && error.Code != "rate_limited" &&
                ErrorCatalog.Family(error.Code) == "quota" => new RelayQuotaException(error),
            ErrorClass.RateLimit => new RelayRateLimitException(error),
            ErrorClass.Idempotency => new RelayIdempotencyException(error),
            ErrorClass.Server => new RelayServerException(error),
            _ => error.Status switch
            {
                404 => new RelayNotFoundException(error),
                409 or 412 or 428 => new RelayConflictException(error),
                _ => new RelayValidationException(error),
            },
        };
}
