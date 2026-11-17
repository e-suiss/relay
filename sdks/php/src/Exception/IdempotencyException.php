<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * A missing, invalid, reused or in-progress Idempotency-Key (error family idempotency).
 */
class IdempotencyException extends ApiException
{
}
