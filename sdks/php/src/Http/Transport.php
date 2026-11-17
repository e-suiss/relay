<?php

declare(strict_types=1);

namespace Esuiss\Relay\Http;

use Esuiss\Relay\Exception\ConnectionException;

/**
 * Sends one HTTP request and returns its response, whatever the status.
 */
interface Transport
{
    /**
     * @throws ConnectionException when no response was received
     */
    public function send(HttpRequest $request, float $timeout): HttpResponse;
}
