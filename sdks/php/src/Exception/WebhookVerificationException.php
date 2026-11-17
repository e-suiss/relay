<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * A webhook whose headers, timestamp or signature did not verify; the body must not be used.
 */
class WebhookVerificationException extends RelayException
{
}
