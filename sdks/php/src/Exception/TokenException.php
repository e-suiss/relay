<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * Discovery or the Access token request failed; the code names the OAuth error or the failed step.
 */
class TokenException extends RelayException
{
    public function __construct(
        public readonly string $errorCode,
        string $message,
    ) {
        parent::__construct($message);
    }
}
