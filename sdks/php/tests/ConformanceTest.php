<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests;

use DateTimeImmutable;
use Esuiss\Relay\Call;
use Esuiss\Relay\Errors;
use Esuiss\Relay\Exception\ApiException;
use Esuiss\Relay\Exception\AuthenticationException;
use Esuiss\Relay\Exception\ConnectionException;
use Esuiss\Relay\Exception\IdempotencyException;
use Esuiss\Relay\Exception\RateLimitException;
use Esuiss\Relay\Exception\ServerException;
use Esuiss\Relay\Exception\ValidationException;
use Esuiss\Relay\Exception\WebhookVerificationException;
use Esuiss\Relay\Generated\ErrorTable;
use Esuiss\Relay\Http\HttpRequest;
use Esuiss\Relay\Http\HttpResponse;
use Esuiss\Relay\RetryPolicy;
use Esuiss\Relay\Tests\Support\Harness;
use Esuiss\Relay\Webhook;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class ConformanceTest extends TestCase
{
    public function testX29ErrorsFollowTheErrorVectors(): void
    {
        $vectors = self::vectors('errors');
        foreach (self::listOf($vectors['catalog']) as $entry) {
            $code = self::str($entry['code']);
            self::assertSame($entry['class'], self::classKey(Errors::classFor(self::int($entry['status']), $code)), $code);
            self::assertArrayHasKey($code, ErrorTable::CODES);
            self::assertSame($entry['retryable'], ErrorTable::CODES[$code]['retryable'], $code);
        }
        $defaults = [];
        foreach (self::listOf($vectors['status_defaults']) as $row) {
            $defaults[] = ['status' => $row['status'], 'code' => $row['code'] ?? null, 'retryable' => $row['retryable']];
        }
        self::assertSame($defaults, ErrorTable::RETRYABLE_DEFAULTS);

        foreach (self::listOf($vectors['cases']) as $case) {
            $name = self::str($case['name']);
            $error = Errors::fromResponse(self::response(self::map($case['response'])), 0.0);
            $expect = self::map($case['expect']);
            self::assertSame($expect['class'], self::classKey($error::class), $name);
            self::assertSame($expect['code'], $error->errorCode, $name);
            self::assertSame($expect['status'], $error->status, $name);
            self::assertSame($expect['retryable'], $error->retryable, $name);
            if (array_key_exists('request_id', $expect)) {
                self::assertSame($expect['request_id'], $error->requestId, $name);
            }
            if (array_key_exists('field_errors', $expect)) {
                self::assertCount(self::int($expect['field_errors']), $error->fieldErrors, $name);
            }
            if (array_key_exists('retry_after_s', $expect)) {
                self::assertSame((float) self::int($expect['retry_after_s']), $error->retryAfter, $name);
            }
        }
    }

    public function testX29RetriesFollowTheRetryVectors(): void
    {
        $vectors = self::vectors('retry');
        $policy = self::map($vectors['policy']);
        $max = self::int($policy['max_retries']);
        $make = static fn (float $random): RetryPolicy => new RetryPolicy(
            self::int($policy['base_ms']),
            self::int($policy['cap_ms']),
            (float) self::int($policy['max_retry_after_s']),
            static fn (): float => $random,
        );

        foreach (self::listOf($vectors['backoff']) as $row) {
            $random = self::num($row['random']);
            self::assertSame($row['delay_ms'], $make($random)->backoffMs(self::int($row['retry'])));
        }

        foreach (self::listOf($vectors['decisions']) as $case) {
            $name = self::str($case['name']);
            $retry = self::int($case['retry']);
            $policyFor = $make(self::num($case['random']));
            if (($case['network_error'] ?? false) === true) {
                $decision = $policyFor->decide($retry, $max, true, null);
            } else {
                $now = (float) (new DateTimeImmutable(self::str($case['now'])))->getTimestamp();
                $error = Errors::fromResponse(self::response(self::map($case['response'])), $now);
                $decision = $policyFor->decide($retry, $max, $error->retryable, $error->retryAfter);
            }
            $expect = self::map($case['expect']);
            self::assertSame($expect['retry'], $decision->retry, $name);
            if ($expect['retry'] === true) {
                self::assertNotNull($decision->delay, $name);
                self::assertSame($expect['delay_ms'], (int) round($decision->delay * 1000), $name);
            } else {
                self::assertSame($expect['reason'], $decision->reason, $name);
            }
        }
    }

    public function testX29IdempotencyFollowsTheIdempotencyVectors(): void
    {
        $vectors = self::vectors('idempotency');
        $length = self::map($vectors['key_length']);
        foreach (self::listOf($vectors['cases']) as $case) {
            $name = self::str($case['name']);
            $h = new Harness();
            $keys = [];
            foreach (self::listOf($case['calls']) as $call) {
                foreach (self::listOf($call['responses']) as $response) {
                    $h->transport->push(
                        ($response['network_error'] ?? false) === true
                            ? new ConnectionException('no response')
                            : self::response($response),
                    );
                }
                $before = count($h->transport->requests);
                $method = self::str($call['method']);
                $expect = self::map($call['expect']);
                $outcome = 'success';
                $replayed = false;
                try {
                    $result = $h->client->send(new Call(
                        method: $method,
                        path: self::str($call['path']),
                        body: $method === 'GET' ? null : ['n' => 1],
                        contentType: $method === 'GET' ? null : 'application/json',
                        idempotent: $call['takes_idempotency_key'] === true,
                        idempotencyKey: isset($call['caller_idempotency']) ? self::str($call['caller_idempotency']) : null,
                    ));
                    $replayed = $result->replayed();
                } catch (ApiException $e) {
                    $outcome = 'error';
                    self::assertSame($expect['error_class'], self::classKey($e::class), $name);
                    self::assertSame($expect['error_code'], $e->errorCode, $name);
                }
                self::assertSame($expect['outcome'], $outcome, $name);
                if ($outcome === 'success') {
                    self::assertSame($expect['replayed'], $replayed, $name);
                }
                $sent = array_slice($h->transport->requests, $before);
                self::assertCount(self::int($expect['requests']), $sent, $name);
                $callKeys = array_map(static fn (HttpRequest $r): ?string => $r->header('Idempotency-Key'), $sent);
                if ($expect['key_sent'] === true) {
                    self::assertNotContains(null, $callKeys, $name);
                    self::assertCount(1, array_unique($callKeys), $name);
                    $key = (string) $callKeys[0];
                    self::assertGreaterThanOrEqual(self::int($length['min']), strlen($key), $name);
                    self::assertLessThanOrEqual(self::int($length['max']), strlen($key), $name);
                    if (array_key_exists('sent_idempotency', $expect)) {
                        self::assertSame($expect['sent_idempotency'], $key, $name);
                    }
                    $keys[] = $key;
                } else {
                    self::assertSame(array_fill(0, count($sent), null), $callKeys, $name);
                }
            }
            if (($case['distinct_keys_across_calls'] ?? false) === true) {
                self::assertSame($keys, array_values(array_unique($keys)), $name);
            }
        }
    }

    public function testAPI56PaginationFollowsThePaginationVectors(): void
    {
        $vectors = self::vectors('pagination');
        foreach (self::listOf($vectors['cases']) as $case) {
            $name = self::str($case['name']);
            $h = new Harness();
            $exchanges = self::listOf($case['exchanges']);
            foreach ($exchanges as $exchange) {
                $h->transport->push(self::response([
                    'status' => 200,
                    'headers' => ['content-type' => 'application/json'],
                    'body' => $exchange['page'],
                ]));
            }
            $params = self::map($case['params']);
            $page = $h->client->listNotifications(
                limit: isset($params['limit']) ? self::int($params['limit']) : null,
                startingAfter: isset($params['starting_after']) ? self::str($params['starting_after']) : null,
                endingBefore: isset($params['ending_before']) ? self::str($params['ending_before']) : null,
            );
            $take = isset($case['take']) ? self::int($case['take']) : null;
            $items = [];
            foreach ($page as $item) {
                if ($take !== null && count($items) >= $take) {
                    break;
                }
                $items[] = $item['id'];
                if ($take !== null && count($items) >= $take) {
                    break;
                }
            }
            $expect = self::map($case['expect']);
            self::assertSame($expect['items'], $items, $name);
            self::assertCount(self::int($expect['requests']), $h->transport->requests, $name);
            foreach ($h->transport->requests as $index => $request) {
                parse_str((string) parse_url($request->url, PHP_URL_QUERY), $query);
                $wanted = self::map(self::map($exchanges[$index])['query']);
                ksort($query);
                ksort($wanted);
                self::assertSame($wanted, $query, $name . ' request ' . $index);
            }
        }

        foreach (self::listOf($vectors['rejections']) as $rejection) {
            $h = new Harness();
            $params = self::map($rejection['params']);
            try {
                $h->client->listNotifications(
                    startingAfter: self::str($params['starting_after']),
                    endingBefore: self::str($params['ending_before']),
                );
                self::fail('both cursors were accepted');
            } catch (InvalidArgumentException $e) {
                self::assertSame(self::map($rejection['expect'])['error'], explode(':', $e->getMessage(), 2)[0]);
            }
            self::assertCount(0, $h->transport->requests);
        }
    }

    public function testWH7WebhooksFollowTheWebhookVectors(): void
    {
        $vectors = self::vectors('webhooks');
        $raw = file_get_contents(Harness::root() . '/' . self::str($vectors['signatures']));
        self::assertIsString($raw);
        $signatures = self::map(json_decode($raw, true, 512, JSON_THROW_ON_ERROR));
        $keys = self::map($signatures['keys']);
        $tolerance = self::int($signatures['tolerance_s']);
        $bases = [];
        foreach (self::listOf($signatures['cases']) as $base) {
            $bases[self::str($base['name'])] = $base;
        }

        foreach (self::listOf($vectors['cases']) as $case) {
            $name = self::str($case['name']);
            $base = $bases[self::str($case['base'])];
            $timestamp = self::int($base['webhook_timestamp']);
            $headers = [
                'webhook-id' => self::str($base['webhook_id']),
                'webhook-timestamp' => (string) $timestamp,
            ];
            foreach (self::map($case['headers']) as $header => $value) {
                if ($value === null) {
                    unset($headers[$header]);
                } else {
                    $headers[$header] = str_replace(
                        ['{v1a}', '{v1}'],
                        [self::str($base['v1a']), self::str($base['v1'])],
                        self::str($value),
                    );
                }
            }
            $configured = array_map(static fn ($key): string => self::str($keys[self::str($key)]), self::listOf($case['keys'], false));
            $now = (float) self::int($case['now'] ?? $timestamp);
            $body = hex2bin(self::str($case['body_hex'] ?? $base['body_hex']));
            self::assertIsString($body);
            $webhook = new Webhook($configured, $tolerance, static fn (): float => $now);
            $expect = self::map($case['expect']);
            try {
                $scheme = $webhook->verify($body, $headers);
                self::assertTrue($expect['ok'], $name);
                self::assertSame($expect['scheme'], $scheme, $name);
            } catch (WebhookVerificationException $e) {
                self::assertFalse($expect['ok'], $name . ': ' . $e->reason);
                self::assertSame($expect['error'], $e->reason, $name);
            }
        }
    }

    /**
     * @param array<string, mixed> $spec
     */
    private static function response(array $spec): HttpResponse
    {
        $headers = [];
        foreach (self::map($spec['headers'] ?? []) as $name => $value) {
            $headers[$name] = self::str($value);
        }
        $body = $spec['body'] ?? null;
        $raw = match (true) {
            $body === null => '',
            is_string($body) => $body,
            default => json_encode($body, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES),
        };

        return new HttpResponse(self::int($spec['status']), $headers, $raw);
    }

    /**
     * @param class-string $class
     */
    private static function classKey(string $class): string
    {
        return match (true) {
            is_a($class, AuthenticationException::class, true) => 'auth',
            is_a($class, ValidationException::class, true) => 'validation',
            is_a($class, RateLimitException::class, true) => 'rate_limit',
            is_a($class, IdempotencyException::class, true) => 'idempotency',
            is_a($class, ServerException::class, true) => 'server',
            default => 'unclassified',
        };
    }

    /**
     * @return array<string, mixed>
     */
    private static function vectors(string $name): array
    {
        $path = Harness::root() . '/conformance/sdk/vectors/1/' . $name . '.json';
        if (!is_file($path)) {
            self::markTestSkipped('conformance/sdk/vectors/1 is not present yet');
        }
        $raw = file_get_contents($path);
        self::assertIsString($raw);

        return self::map(json_decode($raw, true, 512, JSON_THROW_ON_ERROR));
    }

    /**
     * @return array<string, mixed>
     */
    private static function map(mixed $value): array
    {
        self::assertIsArray($value);

        /** @var array<string, mixed> $value */
        return $value;
    }

    /**
     * @return ($maps is true ? list<array<string, mixed>> : list<mixed>)
     */
    private static function listOf(mixed $value, bool $maps = true): array
    {
        self::assertIsArray($value);
        $out = [];
        foreach ($value as $item) {
            $out[] = $maps ? self::map($item) : $item;
        }

        return $out;
    }

    private static function str(mixed $value): string
    {
        self::assertIsString($value);

        return $value;
    }

    private static function int(mixed $value): int
    {
        self::assertIsInt($value);

        return $value;
    }

    private static function num(mixed $value): float
    {
        self::assertTrue(is_int($value) || is_float($value));

        return (float) $value;
    }
}
