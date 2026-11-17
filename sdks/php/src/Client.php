<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Closure;
use Esuiss\Relay\Auth\Authorizer;
use Esuiss\Relay\Exception\RelayException;
use Esuiss\Relay\Generated\Meta;
use Esuiss\Relay\Generated\Operations;
use Esuiss\Relay\Http\CurlTransport;
use Esuiss\Relay\Http\HttpRequest;
use Esuiss\Relay\Http\HttpResponse;
use Esuiss\Relay\Http\Transport;
use InvalidArgumentException;
use JsonException;

/**
 * Client of the Relay server API, pinned to the API version it was generated from.
 *
 * Mutating calls carry an Idempotency-Key that stays the same on every retry; only problems marked retryable are retried, with exponential backoff, full jitter and Retry-After.
 */
final class Client
{
    use Operations;
    use AgentHelpers;

    private const MUTATING = ['POST', 'PUT', 'PATCH', 'DELETE'];

    private readonly string $baseUrl;

    private readonly Transport $transport;

    private readonly RetryPolicy $retry;

    /**
     * @var Closure(float): void
     */
    private readonly Closure $sleep;

    /**
     * @var Closure(): float
     */
    private readonly Closure $now;

    /**
     * @param (Closure(float): void)|null $sleep waits the given seconds
     * @param (Closure(): float)|null $now the current Unix time in seconds
     */
    public function __construct(
        string $baseUrl,
        private readonly Authorizer $auth,
        private readonly int $maxRetries = 3,
        private readonly float $timeout = 30.0,
        ?Transport $transport = null,
        ?RetryPolicy $retry = null,
        ?Closure $sleep = null,
        ?Closure $now = null,
    ) {
        $scheme = parse_url($baseUrl, PHP_URL_SCHEME);
        if ($scheme !== 'https' && $scheme !== 'http') {
            throw new InvalidArgumentException('the base URL must be an http or https URL');
        }
        $this->baseUrl = rtrim($baseUrl, '/');
        $this->transport = $transport ?? new CurlTransport();
        $this->retry = $retry ?? new RetryPolicy();
        $this->sleep = $sleep ?? static function (float $seconds): void {
            if ($seconds > 0) {
                usleep((int) round($seconds * 1_000_000));
            }
        };
        $this->now = $now ?? static fn (): float => microtime(true);
    }

    // API-55
    /**
     * Sends a request to any path of the API with the client's authentication, version pinning, idempotency and retries, and returns the raw response.
     *
     * @param array<string, mixed> $query
     * @param array<mixed>|null $body
     */
    public function request(
        string $method,
        string $path,
        array $query = [],
        ?array $body = null,
        ?string $idempotencyKey = null,
        ?RequestOptions $options = null,
    ): HttpResponse {
        $method = strtoupper($method);

        return $this->execute(new Call(
            method: $method,
            path: $path,
            query: $query,
            body: $body,
            contentType: $body === null ? null : 'application/json',
            bodyIsList: $body !== null && $body !== [] && array_is_list($body),
            idempotent: in_array($method, self::MUTATING, true),
            idempotencyKey: $idempotencyKey,
            options: $options,
        ));
    }

    /**
     * @return array<string, mixed>
     */
    protected function callJson(Call $call): array
    {
        $response = $this->execute($call);
        if ($response->body === '') {
            return [];
        }
        try {
            $decoded = json_decode($response->body, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException $e) {
            throw new RelayException('Relay answered with a body that is not JSON', 0, $e);
        }
        if (!is_array($decoded)) {
            throw new RelayException('Relay answered with an unexpected body');
        }

        /** @var array<string, mixed> $decoded */
        return $decoded;
    }

    protected function callText(Call $call): string
    {
        return $this->execute($call)->body;
    }

    protected function callNone(Call $call): void
    {
        $this->execute($call);
    }

    // API-56
    /**
     * @return Page<array<string, mixed>>
     */
    protected function callPage(Call $call): Page
    {
        $body = $this->callJson($call);
        /** @var list<array<string, mixed>> $items */
        $items = is_array($body['data'] ?? null) ? array_values($body['data']) : [];
        $hasMore = ($body['has_more'] ?? false) === true;
        $next = is_string($body['next_cursor'] ?? null) ? $body['next_cursor'] : null;
        $previous = is_string($body['previous_cursor'] ?? null) ? $body['previous_cursor'] : null;
        $fetch = null;
        if ($hasMore && $next !== null) {
            $following = $call->withQuery(['starting_after' => $next, 'ending_before' => null]);
            $fetch = fn (): Page => $this->callPage($following);
        }

        return new Page($items, $hasMore, $next, $previous, $body, $fetch);
    }

    protected function clock(): float
    {
        return ($this->now)();
    }

    protected function pause(float $seconds): void
    {
        ($this->sleep)($seconds);
    }

    // X-29
    // API-10
    // API-65
    private function execute(Call $call): HttpResponse
    {
        $url = $this->baseUrl . $call->target();
        $key = $call->idempotent ? ($call->idempotencyKey ?? Uuid::v4()) : null;
        $maxRetries = $call->options->maxRetries ?? $this->maxRetries;
        $timeout = $call->options->timeout ?? $this->timeout;
        $body = $call->encodedBody();
        $retries = 0;
        $renewed = false;

        while (true) {
            $headers = $this->headers($call, $key);
            if ($call->authenticated) {
                $headers = array_merge($headers, $this->auth->authorize($call->method, $url));
            }
            $response = $this->transport->send(new HttpRequest($call->method, $url, $headers, $body), $timeout);
            if ($response->status >= 200 && $response->status < 300) {
                return $response;
            }

            $error = Errors::fromResponse($response, ($this->now)());
            if ($call->authenticated && !$renewed && $error->status === 401 && $error->errorCode === 'auth_expired_token') {
                $this->auth->invalidate();
                $renewed = true;

                continue;
            }
            if ($error->retryable && $retries < $maxRetries) {
                $delay = $this->retry->delay($retries, $error->retryAfter);
                if ($delay !== null) {
                    ($this->sleep)($delay);
                    ++$retries;

                    continue;
                }
            }

            throw $error;
        }
    }

    /**
     * @return array<string, string>
     */
    private function headers(Call $call, ?string $key): array
    {
        $headers = [
            'Accept' => 'application/json',
            'Relay-Version' => Meta::API_VERSION,
            'User-Agent' => 'esuiss-relay-php/' . Version::SDK,
        ];
        if ($call->body !== null) {
            $headers['Content-Type'] = $call->contentType ?? 'application/json';
        }
        foreach ($call->headers as $name => $value) {
            if ($value !== null) {
                $headers[$name] = match (true) {
                    $value === true => 'true',
                    $value === false => 'false',
                    default => (string) $value,
                };
            }
        }
        foreach ($call->options->headers ?? [] as $name => $value) {
            $headers[$name] = $value;
        }
        $headers['Relay-Version'] = Meta::API_VERSION;
        if ($key !== null) {
            $headers['Idempotency-Key'] = $key;
        }

        return $headers;
    }
}
