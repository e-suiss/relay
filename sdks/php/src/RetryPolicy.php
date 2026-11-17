<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Closure;

/**
 * Exponential backoff with full jitter that never waits less than Retry-After and refuses a Retry-After above its ceiling.
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
        public readonly float $baseDelay = 0.5,
        public readonly float $maxDelay = 8.0,
        public readonly float $maxRetryAfter = 60.0,
        ?Closure $random = null,
    ) {
        $this->random = $random ?? static fn (): float => random_int(0, PHP_INT_MAX - 1) / PHP_INT_MAX;
    }

    // X-29
    /**
     * Seconds to wait before retry number $retryIndex (from 0), or null when the call must not be retried.
     */
    public function delay(int $retryIndex, ?float $retryAfter): ?float
    {
        if ($retryAfter !== null && $retryAfter > $this->maxRetryAfter) {
            return null;
        }
        $ceiling = min($this->maxDelay, $this->baseDelay * (2 ** $retryIndex));
        $jitter = ($this->random)() * $ceiling;

        return $retryAfter === null ? $jitter : max($retryAfter, $jitter);
    }
}
