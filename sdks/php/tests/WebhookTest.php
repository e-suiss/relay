<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests;

use Esuiss\Relay\Exception\WebhookVerificationException;
use Esuiss\Relay\Tests\Support\Harness;
use Esuiss\Relay\Webhook;
use InvalidArgumentException;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class WebhookTest extends TestCase
{
    /**
     * @return array<string, mixed>
     */
    private static function vectors(): array
    {
        $raw = file_get_contents(Harness::root() . '/conformance/webhooks/vectors/1/signature.json');
        self::assertIsString($raw);
        $decoded = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
        self::assertIsArray($decoded);

        /** @var array<string, mixed> $decoded */
        return $decoded;
    }

    /**
     * @return array<string, array{array<string, mixed>}>
     */
    public static function cases(): array
    {
        $out = [];
        $vectors = self::vectors();
        self::assertIsArray($vectors['cases']);
        foreach ($vectors['cases'] as $case) {
            self::assertIsArray($case);
            /** @var array<string, mixed> $case */
            $out[(string) $case['name']] = [$case];
        }

        return $out;
    }

    /**
     * @return array<string, array{array<string, mixed>}>
     */
    public static function rejections(): array
    {
        $out = [];
        $vectors = self::vectors();
        self::assertIsArray($vectors['rejections']);
        foreach ($vectors['rejections'] as $rejection) {
            self::assertIsArray($rejection);
            /** @var array<string, mixed> $rejection */
            $out[(string) $rejection['name']] = [$rejection];
        }

        return $out;
    }

    /**
     * @param array<string, mixed> $case
     */
    #[DataProvider('cases')]
    public function testWH7AcceptsEachVectorSignature(array $case): void
    {
        $keys = self::keys();
        $now = (float) self::int($case['webhook_timestamp']);
        $body = self::hex($case['body_hex']);
        $headers = [
            'Webhook-Id' => self::str($case['webhook_id']),
            'Webhook-Timestamp' => (string) self::int($case['webhook_timestamp']),
        ];

        foreach ([[$keys['ed25519_public_key']], [$keys['hmac_secret']], array_values($keys)] as $configured) {
            $webhook = new Webhook($configured, self::tolerance(), static fn (): float => $now);
            $v1a = self::str($case['v1a']);
            $v1 = self::str($case['v1']);
            foreach ([$v1a, $v1, $v1a . ' ' . $v1] as $signature) {
                $usable = str_contains($signature, 'v1a,') && in_array($keys['ed25519_public_key'], $configured, true)
                    || str_contains($signature, 'v1,') && in_array($keys['hmac_secret'], $configured, true);
                $attempt = $headers + ['webhook-signature' => $signature];
                if ($usable) {
                    $webhook->verify($body, $attempt);
                    $this->addToAssertionCount(1);
                } else {
                    $this->assertRejected($webhook, $body, $attempt);
                }
            }
        }
    }

    /**
     * @param array<string, mixed> $rejection
     */
    #[DataProvider('rejections')]
    public function testWH7RejectsTamperedWebhooks(array $rejection): void
    {
        $case = null;
        $vectors = self::vectors();
        self::assertIsArray($vectors['cases']);
        foreach ($vectors['cases'] as $candidate) {
            self::assertIsArray($candidate);
            if ($candidate['name'] === $rejection['case']) {
                $case = $candidate;
            }
        }
        self::assertIsArray($case);

        $id = self::str($rejection['webhook_id'] ?? $case['webhook_id']);
        $body = self::hex($rejection['body_hex'] ?? $case['body_hex']);
        $timestamp = self::int($case['webhook_timestamp']);
        $now = (float) self::int($rejection['now'] ?? $timestamp);
        $v1a = self::str($case['v1a']);
        $v1 = self::str($case['v1']);
        if (($rejection['swap_versions'] ?? false) === true) {
            $signature = 'v1a,' . substr($v1, 3) . ' v1,' . substr($v1a, 4);
        } else {
            $signature = $v1a . ' ' . $v1;
        }

        $webhook = new Webhook(array_values(self::keys()), self::tolerance(), static fn (): float => $now);
        $this->assertRejected($webhook, $body, [
            'webhook-id' => $id,
            'webhook-timestamp' => (string) $timestamp,
            'webhook-signature' => $signature,
        ]);
    }

    public function testWH7RejectsMissingHeaders(): void
    {
        $webhook = new Webhook([self::keys()['hmac_secret']]);
        $this->assertRejected($webhook, '{}', ['webhook-id' => 'msg_1']);
    }

    public function testX29RefusesUnknownKeyKinds(): void
    {
        $this->expectException(InvalidArgumentException::class);
        new Webhook(['whsk_' . base64_encode(str_repeat('a', 32))]);
    }

    /**
     * @param array<string, string> $headers
     */
    private function assertRejected(Webhook $webhook, string $body, array $headers): void
    {
        try {
            $webhook->verify($body, $headers);
            self::fail('the webhook was accepted');
        } catch (WebhookVerificationException) {
            $this->addToAssertionCount(1);
        }
    }

    /**
     * @return array<string, string>
     */
    private static function keys(): array
    {
        $vectors = self::vectors();
        self::assertIsArray($vectors['keys']);

        return [
            'ed25519_public_key' => self::str($vectors['keys']['ed25519_public_key']),
            'hmac_secret' => self::str($vectors['keys']['hmac_secret']),
        ];
    }

    private static function tolerance(): int
    {
        return self::int(self::vectors()['tolerance_s']);
    }

    private static function hex(mixed $value): string
    {
        $bytes = hex2bin(self::str($value));
        self::assertIsString($bytes);

        return $bytes;
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
}
