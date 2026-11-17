<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Closure;

/**
 * When a call is retried and how long it waits: only retryable errors and requests without a response, Retry-After exactly when given, else exponential backoff with full jitter.
 */
final class RetryPolicy
{
    /**
     * @var Closure(): float
     */
    private readonly Closure $random;

    /**
     * @param (Closure(): float)|null $random returns a number in [0, 1)
     */
    public function __construct(
        public readonly int $baseMs = 500,
        public readonly int $capMs = 8000,
        public readonly float $maxRetryAfter = 60.0,
        ?Closure $random = null,
    ) {
        $this->random = $random ?? static fn (): float => random_int(0, PHP_INT_MAX - 1) / PHP_INT_MAX;
    }

    // X-29
    // API-65
    /**
     * The decision for retry number $retry (counted from 1) of a call allowed $maxRetries retries.
     */
    public function decide(int $retry, int $maxRetries, bool $retryable, ?float $retryAfter): RetryDecision
    {
        if (!$retryable) {
            return new RetryDecision(false, null, 'not_retryable');
        }
        if ($retry > $maxRetries) {
            return new RetryDecision(false, null, 'retries_exhausted');
        }
        if ($retryAfter !== null) {
            if ($retryAfter > $this->maxRetryAfter) {
                return new RetryDecision(false, null, 'retry_after_too_long');
            }

            return new RetryDecision(true, $retryAfter, null);
        }

        return new RetryDecision(true, $this->backoffMs($retry) / 1000, null);
    }

    /**
     * Full-jitter backoff in milliseconds for retry number $retry (counted from 1).
     */
    public function backoffMs(int $retry): int
    {
        $ceiling = min($this->capMs, $this->baseMs * (2 ** min(max($retry - 1, 0), 30)));

        return (int) floor(($this->random)() * $ceiling);
    }
}
