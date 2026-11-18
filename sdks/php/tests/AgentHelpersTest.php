<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests;

use Esuiss\Relay\Duration;
use Esuiss\Relay\Exception\WaitTimeoutException;
use Esuiss\Relay\Http\HttpRequest;
use Esuiss\Relay\Stream;
use Esuiss\Relay\Tests\Support\Harness;
use Esuiss\Relay\Tests\Support\StubTransport;
use PHPUnit\Framework\TestCase;
use RuntimeException;

final class AgentHelpersTest extends TestCase
{
    public function testX30OpensAWaitpointWithAKeptKey(): void
    {
        $h = new Harness();
        $h->transport->push(StubTransport::json(201, ['object' => 'waitpoint', 'id' => 'wp_1', 'state' => 'open']));

        $opened = $h->client->openWaitpoint(['kind' => 'event']);

        self::assertSame($opened->idempotencyKey, $h->transport->requests[0]->header('Idempotency-Key'));
        self::assertSame('wp_1', $opened->waitpoint['id']);
    }

    public function testX30AwaitsAWaitpointAndHeartbeats(): void
    {
        $h = new Harness();
        $open = ['object' => 'waitpoint', 'id' => 'wp_1', 'state' => 'open', 'heartbeat_interval' => 'PT10S'];
        $h->transport->push(
            StubTransport::json(200, $open),
            StubTransport::json(200, $open),
            StubTransport::json(200, $open),
            StubTransport::json(200, $open),
            StubTransport::json(200, $open),
            StubTransport::json(200, ['state' => 'resolved', 'id' => 'wp_1']),
        );

        $waitpoint = $h->client->awaitWaitpoint('wp_1', timeout: 60.0, pollInterval: 3.0);

        self::assertSame('resolved', $waitpoint['state']);
        $calls = array_map(
            static fn (HttpRequest $r): string => $r->method . ' ' . parse_url($r->url, PHP_URL_PATH),
            $h->transport->requests,
        );
        self::assertSame([
            'GET /v1/waitpoints/wp_1',
            'POST /v1/waitpoints/wp_1/heartbeat',
            'GET /v1/waitpoints/wp_1',
            'GET /v1/waitpoints/wp_1',
            'POST /v1/waitpoints/wp_1/heartbeat',
            'GET /v1/waitpoints/wp_1',
        ], $calls);
        self::assertSame([3.0, 3.0, 3.0], $h->sleeps);
    }

    public function testX30StopsWaitingAtTheTimeout(): void
    {
        $h = new Harness();
        $open = ['object' => 'waitpoint', 'id' => 'wp_1', 'state' => 'stalled'];
        for ($i = 0; $i < 3; ++$i) {
            $h->transport->push(StubTransport::json(200, $open));
        }

        try {
            $h->client->awaitWaitpoint('wp_1', timeout: 3.0, pollInterval: 2.0, heartbeat: false);
            self::fail('no exception');
        } catch (WaitTimeoutException) {
            self::assertSame([2.0, 1.0], $h->sleeps);
        }
        self::assertCount(3, $h->transport->requests);
    }

    public function testX30ReadsLeasesAndAcknowledgesTheMailbox(): void
    {
        $h = new Harness();
        $h->transport->push(
            StubTransport::json(200, ['object' => 'mailbox_records', 'records' => [], 'cursor' => 'c', 'has_more' => false, 'resync_required' => false]),
            StubTransport::json(200, [
                'object' => 'mailbox_lease',
                'lease_id' => 'lease_1',
                'lease_expires_at' => '2026-11-18T10:00:00Z',
                'records' => [['id' => 'mbr_1', 'seq' => 1], ['id' => 'mbr_2', 'seq' => 2]],
            ]),
            StubTransport::json(200, ['object' => 'mailbox_ack']),
        );

        $h->client->readMailbox(since: 'cur_9', limit: 10);
        $seen = [];
        try {
            $h->client->consumeMailbox(static function (array $record) use (&$seen): void {
                $seen[] = $record['id'];
                if ($record['id'] === 'mbr_2') {
                    throw new RuntimeException('handler failed');
                }
            }, max: 5);
            self::fail('no exception');
        } catch (RuntimeException $e) {
            self::assertSame('handler failed', $e->getMessage());
        }

        self::assertSame(['mbr_1', 'mbr_2'], $seen);
        self::assertSame('https://relay.test/v1/mailbox/records?since=cur_9&limit=10', $h->transport->requests[0]->url);
        self::assertSame('{"max":5}', $h->transport->requests[1]->body);
        self::assertSame('{"lease_id":"lease_1","record_ids":["mbr_1"]}', $h->transport->requests[2]->body);
    }

    public function testIN28OpensTheStreamFirstAndDropsWhatWasAlreadySeen(): void
    {
        $order = [];
        $merged = Stream::merge(
            static function () use (&$order): array {
                $order[] = 'stream';

                return [['id' => 'a', 'seq' => 1], ['id' => 'c', 'seq' => 3], ['id' => 'b', 'seq' => 2], ['id' => 'b', 'seq' => 4]];
            },
            static function () use (&$order): array {
                $order[] = 'history';

                return [['id' => 'a', 'seq' => 1], ['id' => 'b', 'seq' => 2]];
            },
        );

        $items = iterator_to_array($merged, false);

        self::assertSame(['stream', 'history'], $order);
        self::assertSame(
            [['id' => 'a', 'seq' => 1], ['id' => 'b', 'seq' => 2], ['id' => 'c', 'seq' => 3], ['id' => 'b', 'seq' => 4]],
            $items,
        );
    }

    public function testX30ParsesHeartbeatDurations(): void
    {
        self::assertSame(30.0, Duration::seconds('PT30S'));
        self::assertSame(1800.0, Duration::seconds('PT30M'));
        self::assertSame(86400.0, Duration::seconds('P1D'));
        self::assertSame(90061.0, Duration::seconds('P1DT1H1M1S'));
        self::assertNull(Duration::seconds('P1M'));
        self::assertNull(Duration::seconds('PT'));
        self::assertNull(Duration::seconds('soon'));
    }
}
