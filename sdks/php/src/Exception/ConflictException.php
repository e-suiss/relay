<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * A resource conflict or a failed or missing precondition (409, 412, 428).
 */
class ConflictException extends ValidationException
{
}
