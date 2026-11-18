<?php

declare(strict_types=1);

namespace Esuiss\Relay;

/**
 * A created waitpoint with the idempotency key that is its identity.
 */
final class OpenedWaitpoint
{
    /**
     * @param array<string, mixed> $waitpoint
     */
    public function __construct(
        public readonly string $idempotencyKey,
        public readonly array $waitpoint,
    ) {
    }
}
