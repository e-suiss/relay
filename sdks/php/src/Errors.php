<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use DateTimeImmutable;
use DateTimeZone;
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
 * Turns an error response into the typed exception of its code, with its retryable flag and Retry-After.
 */
final class Errors
{
    private const FAMILY_CLASSES = [
        'auth' => AuthenticationException::class,
        'quota' => RateLimitException::class,
        'idempotency' => IdempotencyException::class,
        'platform' => ServerException::class,
    ];

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
            self::retryable($response->status, $code, $problem),
        );
    }

    /**
     * The exception class of a status and error code: a known code by its catalog family, an unknown one by its status.
     *
     * @return class-string<ApiException>
     */
    public static function classFor(int $status, ?string $code): string
    {
        $known = $code === null ? null : (ErrorTable::CODES[$code] ?? null);
        if ($known !== null) {
            $class = self::FAMILY_CLASSES[$known['family']] ?? null;
            if ($class !== null) {
                return $class;
            }
            if ($status >= 500) {
                return ServerException::class;
            }

            return self::validation($status);
        }

        return match (true) {
            $status === 401, $status === 403 => AuthenticationException::class,
            $status === 429 => RateLimitException::class,
            $status >= 500 => ServerException::class,
            default => self::validation($status),
        };
    }

    /**
     * The problem's own retryable member, else the status defaults of the error catalog; a status outside them is not retryable.
     *
     * @param array<mixed> $problem
     */
    public static function retryable(int $status, ?string $code, array $problem): bool
    {
        $own = $problem['retryable'] ?? null;
        if (is_bool($own)) {
            return $own;
        }
        foreach (ErrorTable::RETRYABLE_DEFAULTS as $row) {
            if ($row['status'] === $status && ($row['code'] === null || $row['code'] === $code)) {
                return $row['retryable'];
            }
        }

        return false;
    }

    /**
     * Seconds to wait from the Retry-After header (delta seconds or HTTP date, never negative), else the problem's retry_after; null when neither is usable.
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
            $date = DateTimeImmutable::createFromFormat('!D, d M Y H:i:s \G\M\T', $header, new DateTimeZone('UTC'));
            if ($date !== false) {
                return max(0.0, $date->getTimestamp() - $now);
            }
        }
        $body = $problem['retry_after'] ?? null;
        if (is_int($body) && $body >= 0) {
            return (float) $body;
        }

        return null;
    }

    /**
     * @return class-string<ValidationException>
     */
    private static function validation(int $status): string
    {
        return match ($status) {
            404 => NotFoundException::class,
            409, 412, 428 => ConflictException::class,
            default => ValidationException::class,
        };
    }
}
