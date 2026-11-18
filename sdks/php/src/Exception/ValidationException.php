<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * A request Relay refused as malformed or invalid; the field errors are in the problem's errors member.
 */
class ValidationException extends ApiException
{
}
