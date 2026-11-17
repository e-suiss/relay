namespace Esuiss.Relay;

internal static class RetryPolicy
{
    internal static TimeSpan Backoff(int retryIndex, double random, TimeSpan baseDelay, TimeSpan maxDelay)
    {
        var ceiling = baseDelay.TotalSeconds * Math.Pow(2, retryIndex);
        var capped = Math.Min(maxDelay.TotalSeconds, ceiling);
        return TimeSpan.FromSeconds(capped * Math.Clamp(random, 0, 1));
    }

    internal static TimeSpan? Delay(
        int retryIndex,
        TimeSpan? retryAfter,
        double random,
        TimeSpan baseDelay,
        TimeSpan maxDelay,
        TimeSpan maxRetryAfter)
    {
        if (retryAfter is { } wait)
        {
            return wait > maxRetryAfter ? null : wait;
        }

        return Backoff(retryIndex, random, baseDelay, maxDelay);
    }

    internal static bool TransportRetryable(string method, string? idempotencyKey) =>
        method == "GET" || idempotencyKey is not null;
}
