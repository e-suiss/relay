<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Closure;
use Esuiss\Relay\Exception\WebhookVerificationException;
use InvalidArgumentException;
use JsonException;
use SensitiveParameter;

/**
 * Verifies webhooks of the Suiss webhook profile over the raw body: v1a Ed25519 signatures with whpk_ keys and v1 HMAC-SHA-256 signatures with whsec_ secrets.
 */
final class Webhook
{
    /**
     * @var list<non-empty-string>
     */
    private array $publicKeys = [];

    /**
     * @var list<string>
     */
    private array $secrets = [];

    /**
     * @var Closure(): float
     */
    private readonly Closure $now;

    /**
     * @param string|list<string> $keys whpk_ public keys and whsec_ secrets; several allow rotation
     * @param (Closure(): float)|null $now
     */
    public function __construct(
        #[SensitiveParameter]
        string|array $keys,
        private readonly int $tolerance = 300,
        ?Closure $now = null,
    ) {
        foreach ((array) $keys as $key) {
            if (str_starts_with($key, 'whpk_')) {
                $raw = base64_decode(substr($key, 5), true);
                if ($raw === false || $raw === '' || strlen($raw) !== SODIUM_CRYPTO_SIGN_PUBLICKEYBYTES) {
                    throw new InvalidArgumentException('a whpk_ key must hold a base64 Ed25519 public key');
                }
                $this->publicKeys[] = $raw;
            } elseif (str_starts_with($key, 'whsec_')) {
                $raw = base64_decode(substr($key, 6), true);
                if ($raw === false || $raw === '') {
                    throw new InvalidArgumentException('a whsec_ secret must hold base64 bytes');
                }
                $this->secrets[] = $raw;
            } else {
                throw new InvalidArgumentException('webhook keys start with whpk_ or whsec_');
            }
        }
        if ($this->publicKeys === [] && $this->secrets === []) {
            throw new InvalidArgumentException('at least one webhook key is needed');
        }
        $this->now = $now ?? static fn (): float => microtime(true);
    }

    // X-29
    // WH-7
    /**
     * Verifies the raw body against the webhook-id, webhook-timestamp and webhook-signature headers.
     *
     * @param array<string, string|list<string>> $headers
     * @throws WebhookVerificationException
     */
    public function verify(string $body, array $headers): void
    {
        $id = self::header($headers, 'webhook-id');
        $timestamp = self::header($headers, 'webhook-timestamp');
        $signatures = self::header($headers, 'webhook-signature');
        if ($id === null || $timestamp === null || $signatures === null) {
            throw new WebhookVerificationException('the webhook headers are missing');
        }
        if (preg_match('/^\d{1,15}$/', $timestamp) !== 1) {
            throw new WebhookVerificationException('the webhook timestamp is not a number');
        }
        if (abs(($this->now)() - (int) $timestamp) > $this->tolerance) {
            throw new WebhookVerificationException('the webhook timestamp is outside the tolerance');
        }

        $content = $id . '.' . $timestamp . '.' . $body;
        foreach (explode(' ', $signatures) as $entry) {
            $parts = explode(',', $entry, 2);
            if (count($parts) !== 2) {
                continue;
            }
            $signature = base64_decode($parts[1], true);
            if ($signature === false) {
                continue;
            }
            if ($parts[0] === 'v1a' && $this->ed25519($signature, $content)) {
                return;
            }
            if ($parts[0] === 'v1' && $this->hmac($signature, $content)) {
                return;
            }
        }

        throw new WebhookVerificationException('no webhook signature matched');
    }

    /**
     * Verifies the webhook and decodes its JSON body.
     *
     * @param array<string, string|list<string>> $headers
     * @return array<mixed>
     * @throws WebhookVerificationException
     */
    public function verifyAndDecode(string $body, array $headers): array
    {
        $this->verify($body, $headers);
        try {
            $decoded = json_decode($body, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException $e) {
            throw new WebhookVerificationException('the webhook body is not JSON', 0, $e);
        }
        if (!is_array($decoded)) {
            throw new WebhookVerificationException('the webhook body is not a JSON object');
        }

        return $decoded;
    }

    /**
     * @return array<string, mixed>
     */
    public function __debugInfo(): array
    {
        return ['tolerance' => $this->tolerance];
    }

    private function ed25519(string $signature, string $content): bool
    {
        if ($signature === '' || strlen($signature) !== SODIUM_CRYPTO_SIGN_BYTES) {
            return false;
        }
        foreach ($this->publicKeys as $key) {
            if (sodium_crypto_sign_verify_detached($signature, $content, $key)) {
                return true;
            }
        }

        return false;
    }

    private function hmac(string $signature, string $content): bool
    {
        foreach ($this->secrets as $secret) {
            if (hash_equals(hash_hmac('sha256', $content, $secret, true), $signature)) {
                return true;
            }
        }

        return false;
    }

    /**
     * @param array<string, string|list<string>> $headers
     */
    private static function header(array $headers, string $name): ?string
    {
        foreach ($headers as $key => $value) {
            if (strcasecmp((string) $key, $name) === 0) {
                $value = is_array($value) ? ($value[0] ?? null) : $value;

                return $value === null || $value === '' ? null : trim($value);
            }
        }

        return null;
    }
}
