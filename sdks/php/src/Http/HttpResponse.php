<?php

declare(strict_types=1);

namespace Esuiss\Relay\Http;

/**
 * An HTTP response: status, headers with lowercase names and the raw body.
 */
final class HttpResponse
{
    /**
     * @var array<string, string>
     */
    public readonly array $headers;

    /**
     * @param array<string, string> $headers
     */
    public function __construct(
        public readonly int $status,
        array $headers = [],
        public readonly string $body = '',
    ) {
        $normalized = [];
        foreach ($headers as $name => $value) {
            $normalized[strtolower($name)] = $value;
        }
        $this->headers = $normalized;
    }

    /**
     * The value of a header, looked up without regard to case.
     */
    public function header(string $name): ?string
    {
        return $this->headers[strtolower($name)] ?? null;
    }

    /**
     * Whether Relay answered with the stored first response of this Idempotency-Key (Idempotency-Replayed: true).
     */
    public function replayed(): bool
    {
        return strtolower(trim((string) $this->header('idempotency-replayed'))) === 'true';
    }
}
