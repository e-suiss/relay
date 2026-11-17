<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Esuiss\Relay\Exception\ApiException;
use Esuiss\Relay\Exception\AuthenticationException;
use Esuiss\Relay\Exception\ConflictException;
use Esuiss\Relay\Exception\IdempotencyException;
use Esuiss\Relay\Exception\NotFoundException;
use Esuiss\Relay\Exception\RateLimitException;
use Esuiss\Relay\Exception\ServerException;
use Esuiss\Relay\Exception\ValidationException;
use Esuiss\Relay\Generated\ErrorTable;
use Esuiss\Relay\Http\HttpResponse;
use JsonException;

/**
 * Turns an error response into the typed exception of its code and reads its Retry-After.
 */
final class Errors
{
    // X-29
    // API-65
    /**
     * The exception for a non-2xx response.
     */
    public static function fromResponse(HttpResponse $response, float $now): ApiException
    {
        $problem = [];
        if ($response->body !== '') {
            try {
                $decoded = json_decode($response->body, true, 512, JSON_THROW_ON_ERROR);
                if (is_array($decoded)) {
                    $problem = $decoded;
                }
            } catch (JsonException) {
                $problem = [];
            }
        }
        $code = is_string($problem['code'] ?? null) ? $problem['code'] : null;
        $class = self::classFor($response->status, $code);

        return new $class(
            $response->status,
            $code,
            $problem,
            $response->headers,
            self::retryAfter($response, $problem, $now),
        );
    }

    /**
     * The exception class of a status and error code: the code's family first, then the status.
     *
     * @return class-string<ApiException>
     */
    public static function classFor(int $status, ?string $code): string
    {
        $family = $code === null ? null : (ErrorTable::CODES[$code]['family'] ?? null);

        return match (true) {
            $family === 'idempotency' => IdempotencyException::class,
            $family === 'auth' => AuthenticationException::class,
            $family === 'quota' => RateLimitException::class,
            $status >= 500 => ServerException::class,
            $status === 401, $status === 403 => AuthenticationException::class,
            $status === 429 => RateLimitException::class,
            $status === 404 => NotFoundException::class,
            $status === 409, $status === 412, $status === 428 => ConflictException::class,
            default => ValidationException::class,
        };
    }

    /**
     * Seconds to wait from the Retry-After header (seconds or HTTP date), else the problem's retry_after.
     *
     * @param array<mixed> $problem
     */
    public static function retryAfter(HttpResponse $response, array $problem, float $now): ?float
    {
        $header = $response->header('retry-after');
        if ($header !== null) {
            $header = trim($header);
            if (preg_match('/^\d+$/', $header) === 1) {
                return (float) $header;
            }
            $date = strtotime($header);
            if ($date !== false) {
                return max(0.0, $date - $now);
            }
        }
        $body = $problem['retry_after'] ?? null;
        if (is_int($body) && $body >= 0) {
            return (float) $body;
        }

        return null;
    }
}
