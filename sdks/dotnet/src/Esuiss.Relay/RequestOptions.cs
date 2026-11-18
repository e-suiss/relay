namespace Esuiss.Relay;

/// <summary>Options of a single call.</summary>
public sealed class RequestOptions
{
    /// <summary>The Idempotency-Key to send instead of a generated one; it is kept on every retry.</summary>
    public string? IdempotencyKey { get; init; }

    /// <summary>The ETag of the version being updated.</summary>
    public string? IfMatch { get; init; }

    /// <summary>Beta features to enable, sent as Relay-Beta.</summary>
    public string? Beta { get; init; }

    /// <summary>The content type of the body instead of the operation's own, for example application/cloudevents+json.</summary>
    public string? ContentType { get; init; }

    /// <summary>Further headers, such as traceparent.</summary>
    public IReadOnlyDictionary<string, string>? Headers { get; init; }

    /// <summary>The number of retries instead of the client's.</summary>
    public int? MaxRetries { get; init; }

    /// <summary>The time limit of one attempt instead of the client's.</summary>
    public TimeSpan? Timeout { get; init; }
}
