<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * A rate limit or quota was reached (error family quota); only a retryable one is retried.
 */
class RateLimitException extends ApiException
{
}
