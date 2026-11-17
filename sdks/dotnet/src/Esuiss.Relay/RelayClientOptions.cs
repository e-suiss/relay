namespace Esuiss.Relay;

/// <summary>Settings of a <see cref="RelayClient"/>.</summary>
public sealed class RelayClientOptions
{
    /// <summary>The base address of the Relay region, for example https://relay.example.com.</summary>
    public required Uri BaseUrl { get; init; }

    /// <summary>The credentials that authorize every request.</summary>
    public required IRelayCredentials Credentials { get; init; }

    /// <summary>How many times a retryable failure is retried. Defaults to 3.</summary>
    public int MaxRetries { get; init; } = 3;

    /// <summary>The first backoff ceiling; it doubles on every retry. Defaults to 0.5 seconds.</summary>
    public TimeSpan BaseDelay { get; init; } = TimeSpan.FromMilliseconds(500);

    /// <summary>The largest backoff ceiling. Defaults to 20 seconds.</summary>
    public TimeSpan MaxDelay { get; init; } = TimeSpan.FromSeconds(20);

    /// <summary>The longest Retry-After the client waits; a longer one surfaces the error. Defaults to 60 seconds.</summary>
    public TimeSpan MaxRetryAfter { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>The time limit of one attempt. Defaults to 30 seconds.</summary>
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>The HTTP client to send requests with, or null for a client the SDK owns.</summary>
    public HttpClient? HttpClient { get; init; }

    /// <summary>Waits between attempts; replace it to observe or skip the waits.</summary>
    public Func<TimeSpan, CancellationToken, Task>? Delay { get; init; }

    /// <summary>Returns a uniform random number in [0, 1) for the backoff jitter.</summary>
    public Func<double>? Random { get; init; }
}
