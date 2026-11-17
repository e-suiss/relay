<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests;

use Esuiss\Relay\Errors;
use Esuiss\Relay\Exception\AuthenticationException;
use Esuiss\Relay\Exception\ConflictException;
use Esuiss\Relay\Exception\IdempotencyException;
use Esuiss\Relay\Exception\NotFoundException;
use Esuiss\Relay\Exception\RateLimitException;
use Esuiss\Relay\Exception\ServerException;
use Esuiss\Relay\Exception\ValidationException;
use Esuiss\Relay\Generated\ErrorTable;
use Esuiss\Relay\Http\HttpResponse;
use Esuiss\Relay\RetryPolicy;
use Esuiss\Relay\Tests\Support\Harness;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Yaml\Yaml;

final class ErrorsTest extends TestCase
{
    /**
     * @return array<string, array{int, string|null, class-string}>
     */
    public static function classes(): array
    {
        return [
            'auth 401' => [401, 'auth_invalid_token', AuthenticationException::class],
            'auth 403' => [403, 'auth_insufficient_scope', AuthenticationException::class],
            'idempotency reuse' => [422, 'idempotency_key_reuse', IdempotencyException::class],
            'idempotency in progress' => [409, 'idempotency_key_in_progress', IdempotencyException::class],
            'rate limited' => [429, 'rate_limited', RateLimitException::class],
            'quota exhausted' => [429, 'quota_exhausted', RateLimitException::class],
            'batch too large' => [413, 'batch_too_large', RateLimitException::class],
            'internal error' => [500, 'internal_error', ServerException::class],
            'unavailable' => [503, 'service_unavailable', ServerException::class],
            'validation' => [422, 'validation_failed', ValidationException::class],
            'malformed' => [400, 'malformed_request', ValidationException::class],
            'resource conflict' => [409, 'resource_conflict', ConflictException::class],
            'unknown 404' => [404, null, NotFoundException::class],
            'unknown 429' => [429, 'some_new_code', RateLimitException::class],
            'unknown 502' => [502, null, ServerException::class],
        ];
    }

    /**
     * @param class-string $expected
     */
    #[DataProvider('classes')]
    public function testX29MapsCodesToTypedExceptions(int $status, ?string $code, string $expected): void
    {
        self::assertSame($expected, Errors::classFor($status, $code));
    }

    public function testX29ErrorTableMatchesTheErrorCatalog(): void
    {
        $catalog = Yaml::parseFile(Harness::root() . '/contracts/errors.yaml');
        self::assertIsArray($catalog);
        self::assertIsArray($catalog['codes']);
        $seen = [];
        foreach ($catalog['codes'] as $entry) {
            self::assertIsArray($entry);
            $code = $entry['code'];
            self::assertIsString($code);
            self::assertArrayHasKey($code, ErrorTable::CODES);
            self::assertSame($entry['family'], ErrorTable::CODES[$code]['family']);
            self::assertSame($entry['status'], ErrorTable::CODES[$code]['status']);
            self::assertSame($entry['retryable'], ErrorTable::CODES[$code]['retryable']);
            $seen[] = $code;
        }
        self::assertCount(count($seen), ErrorTable::CODES);
    }

    public function testX29ReadsRetryAfterAsSecondsOrDate(): void
    {
        $now = 1_793_784_600.0;
        $seconds = new HttpResponse(503, ['Retry-After' => '7']);
        $date = new HttpResponse(503, ['Retry-After' => gmdate('D, d M Y H:i:s', (int) $now + 12) . ' GMT']);
        $body = new HttpResponse(429);

        self::assertSame(7.0, Errors::retryAfter($seconds, [], $now));
        self::assertSame(12.0, Errors::retryAfter($date, [], $now));
        self::assertSame(4.0, Errors::retryAfter($body, ['retry_after' => 4], $now));
        self::assertNull(Errors::retryAfter($body, [], $now));
    }

    public function testX29ExceptionsCarryTheProblem(): void
    {
        $response = new HttpResponse(
            429,
            ['Retry-After' => '5', 'Request-Id' => 'req_h'],
            '{"type":"t","title":"Rate limit exceeded","status":429,"code":"rate_limited","retryable":true,"limit_name":"api.rate"}',
        );

        $error = Errors::fromResponse($response, 0.0);

        self::assertInstanceOf(RateLimitException::class, $error);
        self::assertTrue($error->retryable);
        self::assertSame(5.0, $error->retryAfter);
        self::assertSame('req_h', $error->requestId);
        self::assertSame('api.rate', $error->problem['limit_name']);
        self::assertSame('Relay answered HTTP 429 rate_limited: Rate limit exceeded', $error->getMessage());
    }

    public function testX29AnswersThatAreNotProblemsAreNotRetryable(): void
    {
        $error = Errors::fromResponse(new HttpResponse(502, [], '<html>bad gateway</html>'), 0.0);

        self::assertInstanceOf(ServerException::class, $error);
        self::assertFalse($error->retryable);
    }

    public function testX29JitterStaysWithinItsBounds(): void
    {
        $low = new RetryPolicy(random: static fn (): float => 0.0);
        $high = new RetryPolicy(random: static fn (): float => 0.999999);

        for ($retry = 0; $retry < 8; ++$retry) {
            $ceiling = min(8.0, 0.5 * (2 ** $retry));
            self::assertSame(0.0, $low->delay($retry, null));
            $delay = $high->delay($retry, null);
            self::assertNotNull($delay);
            self::assertLessThan($ceiling, $delay);
            self::assertGreaterThan($ceiling * 0.99, $delay);
        }
        self::assertSame(30.0, $high->delay(0, 30.0));
        self::assertSame(60.0, $high->delay(0, 60.0));
        self::assertNull($high->delay(0, 60.5));
    }
}
