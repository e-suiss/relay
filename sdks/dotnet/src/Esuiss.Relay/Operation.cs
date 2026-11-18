namespace Esuiss.Relay;

/// <summary>Whether an operation takes an Idempotency-Key.</summary>
public enum IdempotencyMode
{
    /// <summary>The operation takes no key.</summary>
    None,

    /// <summary>The operation requires a key; the SDK generates one when none is given.</summary>
    Required,

    /// <summary>The operation accepts a key; the SDK generates one when none is given.</summary>
    Optional,
}

/// <summary>Whether an operation takes an If-Match header.</summary>
public enum IfMatchMode
{
    /// <summary>The operation takes no If-Match header.</summary>
    None,

    /// <summary>The operation requires If-Match.</summary>
    Required,

    /// <summary>The operation accepts If-Match.</summary>
    Optional,
}

/// <summary>Whether an operation takes a request body.</summary>
public enum BodyMode
{
    /// <summary>No body.</summary>
    None,

    /// <summary>A body is required.</summary>
    Required,

    /// <summary>A body is optional.</summary>
    Optional,
}

/// <summary>The kind of a successful response body.</summary>
public enum ResponseKind
{
    /// <summary>No body.</summary>
    None,

    /// <summary>A JSON document.</summary>
    Json,

    /// <summary>Plain text.</summary>
    Text,
}

/// <summary>One operation of the Relay server API, as the contract describes it.</summary>
/// <param name="Id">The contract's operationId.</param>
/// <param name="Method">The HTTP method.</param>
/// <param name="Path">The path template, with parameters in braces.</param>
/// <param name="Idempotency">Whether the operation takes an Idempotency-Key.</param>
/// <param name="IfMatch">Whether the operation takes If-Match.</param>
/// <param name="Body">Whether the operation takes a body.</param>
/// <param name="ContentType">The content type of the body, when it takes one.</param>
/// <param name="Response">The kind of the successful response body.</param>
public sealed record Operation(
    string Id,
    string Method,
    string Path,
    IdempotencyMode Idempotency,
    IfMatchMode IfMatch,
    BodyMode Body,
    string? ContentType,
    ResponseKind Response);
