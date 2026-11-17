<?php

declare(strict_types=1);

namespace Esuiss\Relay;

/**
 * Per-call options: a timeout in seconds, extra headers and a retry limit that override the client's.
 */
final class RequestOptions
{
    /**
     * @param array<string, string> $headers
     */
    public function __construct(
        public readonly ?float $timeout = null,
        public readonly array $headers = [],
        public readonly ?int $maxRetries = null,
    ) {
    }
}
