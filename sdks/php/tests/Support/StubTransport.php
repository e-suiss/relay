<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests\Support;

use Esuiss\Relay\Http\HttpRequest;
use Esuiss\Relay\Http\HttpResponse;
use Esuiss\Relay\Http\Transport;
use LogicException;
use Throwable;

final class StubTransport implements Transport
{
    /**
     * @var list<HttpRequest>
     */
    public array $requests = [];

    /**
     * @var list<HttpResponse|Throwable>
     */
    private array $queue;

    public function __construct(HttpResponse|Throwable ...$responses)
    {
        $this->queue = array_values($responses);
    }

    public function push(HttpResponse|Throwable ...$responses): void
    {
        foreach ($responses as $response) {
            $this->queue[] = $response;
        }
    }

    public function send(HttpRequest $request, float $timeout): HttpResponse
    {
        $this->requests[] = $request;
        $next = array_shift($this->queue);
        if ($next === null) {
            throw new LogicException('no stubbed response left for ' . $request->method . ' ' . $request->url);
        }
        if ($next instanceof Throwable) {
            throw $next;
        }

        return $next;
    }

    /**
     * @param array<mixed> $body
     * @param array<string, string> $headers
     */
    public static function json(int $status, array $body, array $headers = []): HttpResponse
    {
        $type = $status >= 400 ? 'application/problem+json' : 'application/json';

        return new HttpResponse(
            $status,
            $headers + ['Content-Type' => $type],
            json_encode($body, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES),
        );
    }

    /**
     * @param array<string, mixed> $extra
     * @param array<string, string> $headers
     */
    public static function problem(int $status, string $code, bool $retryable, array $extra = [], array $headers = []): HttpResponse
    {
        return self::json($status, [
            'type' => 'https://relay.test/v1/errors/' . $code,
            'title' => 'Problem ' . $code,
            'status' => $status,
            'code' => $code,
            'retryable' => $retryable,
            'request_id' => 'req_test',
        ] + $extra, $headers);
    }
}
