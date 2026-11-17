<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * A wait helper reached its timeout before the awaited state.
 */
class WaitTimeoutException extends RelayException
{
}
