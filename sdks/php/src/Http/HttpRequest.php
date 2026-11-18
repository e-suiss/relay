<?php

declare(strict_types=1);

namespace Esuiss\Relay\Http;

/**
 * An HTTP request: method, absolute URL, headers and an optional body.
 */
final class HttpRequest
{
    /**
     * @param array<string, string> $headers
     */
    public function __construct(
        public readonly string $method,
        public readonly string $url,
        public readonly array $headers = [],
        public readonly ?string $body = null,
    ) {
    }

    /**
     * The value of a header, looked up without regard to case.
     */
    public function header(string $name): ?string
    {
        foreach ($this->headers as $key => $value) {
            if (strcasecmp($key, $name) === 0) {
                return $value;
            }
        }

        return null;
    }

    /**
     * @return array<string, string>
     */
    public function __debugInfo(): array
    {
        return ['method' => $this->method, 'url' => $this->url];
    }
}
