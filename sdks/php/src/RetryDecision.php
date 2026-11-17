<?php

declare(strict_types=1);

namespace Esuiss\Relay;

/**
 * Whether a call is retried, after how many seconds, or why not (not_retryable, retries_exhausted, retry_after_too_long).
 */
final class RetryDecision
{
    public function __construct(
        public readonly bool $retry,
        public readonly ?float $delay,
        public readonly ?string $reason,
    ) {
    }
}
