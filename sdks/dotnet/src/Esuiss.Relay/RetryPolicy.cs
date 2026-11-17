using System.Globalization;

namespace Esuiss.Relay;

internal enum RetryVerdict
{
    Retry,
    NotRetryable,
    RetriesExhausted,
    RetryAfterTooLong,
}

internal readonly record struct RetryDecision(RetryVerdict Verdict, TimeSpan Delay)
{
    internal bool ShouldRetry => Verdict == RetryVerdict.Retry;
}

internal static class RetryPolicy
{
    internal static TimeSpan Backoff(int retry, double random, TimeSpan baseDelay, TimeSpan maxDelay)
    {
        var ceiling = baseDelay.TotalMilliseconds * Math.Pow(2, Math.Max(retry, 1) - 1);
        var capped = Math.Min(maxDelay.TotalMilliseconds, ceiling);
        return TimeSpan.FromMilliseconds(Math.Floor(capped * Math.Clamp(random, 0, 1)));
    }

    internal static RetryDecision Decide(
        int retry,
        int maxRetries,
        bool retryable,
        TimeSpan? retryAfter,
        double random,
        TimeSpan baseDelay,
        TimeSpan maxDelay,
        TimeSpan maxRetryAfter)
    {
        if (!retryable)
        {
            return new RetryDecision(RetryVerdict.NotRetryable, TimeSpan.Zero);
        }

        if (retry > maxRetries)
        {
            return new RetryDecision(RetryVerdict.RetriesExhausted, TimeSpan.Zero);
        }

        if (retryAfter is { } wait)
        {
            return wait > maxRetryAfter
                ? new RetryDecision(RetryVerdict.RetryAfterTooLong, TimeSpan.Zero)
                : new RetryDecision(RetryVerdict.Retry, wait);
        }

        return new RetryDecision(RetryVerdict.Retry, Backoff(retry, random, baseDelay, maxDelay));
    }

    internal static TimeSpan? ParseRetryAfter(string? value, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var text = value.Trim();
        if (long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var seconds))
        {
            return TimeSpan.FromSeconds(seconds);
        }

        if (DateTimeOffset.TryParseExact(text, "r", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date))
        {
            var delay = date - now;
            return delay < TimeSpan.Zero ? TimeSpan.Zero : delay;
        }

        return null;
    }

    internal static bool TransportRetryable(string method, string? idempotencyKey) =>
        method == "GET" || idempotencyKey is not null;
}
