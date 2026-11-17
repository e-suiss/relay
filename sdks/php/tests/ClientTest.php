<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests;

use Esuiss\Relay\Exception\AuthenticationException;
use Esuiss\Relay\Exception\ConnectionException;
use Esuiss\Relay\Exception\RateLimitException;
use Esuiss\Relay\Exception\ServerException;
use Esuiss\Relay\Exception\ValidationException;
use Esuiss\Relay\Generated\Meta;
use Esuiss\Relay\Http\HttpRequest;
use Esuiss\Relay\Http\HttpResponse;
use Esuiss\Relay\RequestOptions;
use Esuiss\Relay\Tests\Support\Harness;
use Esuiss\Relay\Tests\Support\StubTransport;
use PHPUnit\Framework\TestCase;

final class ClientTest extends TestCase
{
    private const UUID = '/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/';

    private const WAITPOINT = ['object' => 'waitpoint', 'id' => 'wp_1', 'state' => 'open'];

    public function testAPI55SendsThePinnedVersionOnEveryRequest(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::json(200, self::WAITPOINT));

        $waitpoint = $h->client->getWaitpoint('wp_1', options: new RequestOptions(headers: ['Relay-Version' => '1999-01-01']));

        self::assertSame('wp_1', $waitpoint['id']);
        $request = $h->transport->requests[0];
        self::assertSame('GET', $request->method);
        self::assertSame('https://relay.test/v1/waitpoints/wp_1', $request->url);
        self::assertSame(Meta::API_VERSION, $request->header('Relay-Version'));
        self::assertStringStartsWith('esuiss-relay-php/', (string) $request->header('User-Agent'));
        self::assertNull($request->header('Idempotency-Key'));
        self::assertSame('DPoP token-0', $request->header('Authorization'));
    }

    public function testX29KeepsTheGeneratedIdempotencyKeyAcrossRetries(): void
    {
        $h = new Harness();
        $h->transport->push(
            StubTransport::problem(503, 'service_unavailable', true),
            StubTransport::problem(409, 'idempotency_key_in_progress', true, [], ['Retry-After' => '1']),
            StubTransport::json(201, self::WAITPOINT),
        );

        $h->client->createWaitpoint(['kind' => 'event']);

        self::assertCount(3, $h->transport->requests);
        $keys = array_map(static fn (HttpRequest $r): ?string => $r->header('Idempotency-Key'), $h->transport->requests);
        self::assertMatchesRegularExpression(self::UUID, (string) $keys[0]);
        self::assertSame([$keys[0], $keys[0], $keys[0]], $keys);
        $proofs = array_map(static fn (HttpRequest $r): ?string => $r->header('DPoP'), $h->transport->requests);
        self::assertSame(['proof-1', 'proof-2', 'proof-3'], $proofs);
        self::assertSame('{"kind":"event"}', $h->transport->requests[0]->body);
        self::assertSame('application/json', $h->transport->requests[0]->header('Content-Type'));
        self::assertSame([0.25, 1.0], $h->sleeps);
    }

    public function testX29UsesTheCallersIdempotencyKey(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::json(201, self::WAITPOINT));

        $h->client->createWaitpoint(['kind' => 'event'], idempotencyKey: 'order-4821-wait');

        self::assertSame('order-4821-wait', $h->transport->requests[0]->header('Idempotency-Key'));
    }

    public function testX29GivesEachCallItsOwnKey(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::json(201, self::WAITPOINT), StubTransport::json(201, self::WAITPOINT));

        $h->client->createWaitpoint(['kind' => 'event']);
        $h->client->createWaitpoint(['kind' => 'event']);

        self::assertNotSame(
            $h->transport->requests[0]->header('Idempotency-Key'),
            $h->transport->requests[1]->header('Idempotency-Key'),
        );
    }

    public function testX29NeverRetriesAProblemThatIsNotRetryable(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::problem(422, 'validation_failed', false, [
            'errors' => [['pointer' => '/kind', 'code' => 'required']],
        ]));

        try {
            $h->client->createWaitpoint([]);
            self::fail('no exception');
        } catch (ValidationException $e) {
            self::assertSame(422, $e->status);
            self::assertSame('validation_failed', $e->errorCode);
            self::assertFalse($e->retryable);
            self::assertSame('req_test', $e->requestId);
            self::assertIsArray($e->problem['errors']);
        }
        self::assertCount(1, $h->transport->requests);
        self::assertSame('{}', $h->transport->requests[0]->body);
        self::assertSame([], $h->sleeps);
    }

    public function testX29WaitsForRetryAfter(): void
    {
        $h = new Harness();
        $h->transport->push(
            StubTransport::problem(429, 'rate_limited', true, ['retry_after' => 3], ['Retry-After' => '3']),
            StubTransport::json(200, self::WAITPOINT),
        );

        $h->client->getWaitpoint('wp_1');

        self::assertSame([3.0], $h->sleeps);
    }

    public function testX29UsesTheProblemRetryAfterWithoutTheHeader(): void
    {
        $h = new Harness();
        $h->transport->push(
            StubTransport::problem(429, 'rate_limited', true, ['retry_after' => 2]),
            StubTransport::json(200, self::WAITPOINT),
        );

        $h->client->getWaitpoint('wp_1');

        self::assertSame([2.0], $h->sleeps);
    }

    public function testX29BacksOffExponentiallyAndStopsAfterTheLimit(): void
    {
        $h = new Harness();
        for ($i = 0; $i < 4; ++$i) {
            $h->transport->push(StubTransport::problem(500, 'internal_error', true));
        }

        try {
            $h->client->getWaitpoint('wp_1');
            self::fail('no exception');
        } catch (ServerException $e) {
            self::assertTrue($e->retryable);
        }
        self::assertCount(4, $h->transport->requests);
        self::assertSame([0.25, 0.5, 1.0], $h->sleeps);
    }

    public function testX29RefusesToWaitForALongRetryAfter(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::problem(503, 'service_unavailable', true, [], ['Retry-After' => '120']));

        $this->expectException(ServerException::class);
        try {
            $h->client->getWaitpoint('wp_1');
        } finally {
            self::assertCount(1, $h->transport->requests);
        }
    }

    public function testX29RequestOptionsOverrideTheRetryLimit(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::problem(500, 'internal_error', true));

        $this->expectException(ServerException::class);
        $h->client->getWaitpoint('wp_1', options: new RequestOptions(maxRetries: 0));
    }

    public function testX29QuotaExhaustionIsARateLimitErrorThatIsNotRetried(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::problem(429, 'quota_exhausted', false));

        try {
            $h->client->getWaitpoint('wp_1');
            self::fail('no exception');
        } catch (RateLimitException $e) {
            self::assertFalse($e->retryable);
        }
        self::assertCount(1, $h->transport->requests);
    }

    public function testX29RenewsAnExpiredTokenOnce(): void
    {
        $h = new Harness();
        $h->transport->push(
            StubTransport::problem(401, 'auth_expired_token', false),
            StubTransport::json(200, self::WAITPOINT),
            StubTransport::problem(401, 'auth_expired_token', false),
            StubTransport::problem(401, 'auth_expired_token', false),
        );

        $h->client->getWaitpoint('wp_1');
        self::assertSame(1, $h->auth->invalidations);
        self::assertSame('DPoP token-1', $h->transport->requests[1]->header('Authorization'));

        $this->expectException(AuthenticationException::class);
        $h->client->getWaitpoint('wp_1');
    }

    public function testX29RetriesTransportFailuresWithTheSameKey(): void
    {
        $h = new Harness();
        $h->transport->push(new ConnectionException('down'), StubTransport::json(201, self::WAITPOINT));

        $h->client->createWaitpoint(['kind' => 'event']);

        self::assertCount(2, $h->transport->requests);
        self::assertSame(
            $h->transport->requests[0]->header('Idempotency-Key'),
            $h->transport->requests[1]->header('Idempotency-Key'),
        );
        self::assertSame([0.25], $h->sleeps);
    }

    public function testX29GivesUpOnTransportFailuresAfterTheLimit(): void
    {
        $h = new Harness();
        for ($i = 0; $i < 4; ++$i) {
            $h->transport->push(new ConnectionException('down'));
        }

        $this->expectException(ConnectionException::class);
        try {
            $h->client->getWaitpoint('wp_1');
        } finally {
            self::assertCount(4, $h->transport->requests);
        }
    }

    public function testAPI10SendsNoKeyWhereTheOperationTakesNone(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::json(202, ['object' => 'opaque_event']));

        $h->client->publishAgUiEvent(['recipient_id' => 'sub_1', 'payload' => 'x']);

        self::assertNull($h->transport->requests[0]->header('Idempotency-Key'));
    }

    public function testAPI56IteratesPagesLazily(): void
    {
        $h = new Harness();
        $h->transport->push(
            StubTransport::json(200, [
                'object' => 'list',
                'data' => [['id' => 'ntf_a'], ['id' => 'ntf_b']],
                'has_more' => true,
                'next_cursor' => 'cur_1',
                'previous_cursor' => null,
            ]),
            StubTransport::json(200, [
                'object' => 'list',
                'data' => [['id' => 'ntf_c']],
                'has_more' => false,
                'next_cursor' => null,
                'previous_cursor' => 'cur_0',
            ]),
        );

        $page = $h->client->listNotifications(limit: 2, isTest: true);
        self::assertCount(1, $h->transport->requests);
        self::assertSame('https://relay.test/v1/notifications?limit=2&is_test=true', $h->transport->requests[0]->url);
        self::assertTrue($page->hasMore);
        self::assertSame('cur_1', $page->nextCursor);

        $ids = [];
        foreach ($page as $notification) {
            $ids[] = $notification['id'];
            if (count($ids) === 2) {
                self::assertCount(1, $h->transport->requests);
            }
        }

        self::assertSame(['ntf_a', 'ntf_b', 'ntf_c'], $ids);
        self::assertCount(2, $h->transport->requests);
        self::assertSame('https://relay.test/v1/notifications?limit=2&starting_after=cur_1&is_test=true', $h->transport->requests[1]->url);
    }

    public function testAPI56JoinsNonExplodedArrayQueryValues(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::json(200, ['object' => 'notification', 'id' => 'ntf_a']));

        $h->client->getNotification('ntf_a', expand: ['deliveries']);

        self::assertSame('https://relay.test/v1/notifications/ntf_a?expand=deliveries', $h->transport->requests[0]->url);
    }

    public function testPublicOperationsCarryNoCredentials(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::json(200, ['access_client_id' => 'relay']));

        $h->client->getRelayConfiguration();

        self::assertSame(0, $h->auth->authorizations);
        self::assertNull($h->transport->requests[0]->header('Authorization'));
    }

    public function testRawRequestsGetKeysAndVersions(): void
    {
        $h = new Harness();
        $h->transport->push(new HttpResponse(204));

        $response = $h->client->request('post', '/v1/anything', ['a' => 'b c'], ['x' => 1]);

        self::assertSame(204, $response->status);
        $request = $h->transport->requests[0];
        self::assertSame('POST', $request->method);
        self::assertSame('https://relay.test/v1/anything?a=b%20c', $request->url);
        self::assertMatchesRegularExpression(self::UUID, (string) $request->header('Idempotency-Key'));
    }
}
