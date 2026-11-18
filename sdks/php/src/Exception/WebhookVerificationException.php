<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

use Throwable;

/**
 * A webhook that did not verify; the body must not be used. The reason is missing_header, duplicate_header, malformed_header, timestamp_out_of_tolerance, no_matching_signature or malformed_body.
 */
class WebhookVerificationException extends RelayException
{
    public function __construct(
        public readonly string $reason,
        string $message,
        ?Throwable $previous = null,
    ) {
        parent::__construct($message, 0, $previous);
    }
}
