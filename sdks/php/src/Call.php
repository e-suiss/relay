<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use JsonException;

/**
 * One API call as the generated operations describe it: method, path template, parameters, body and options.
 */
final class Call
{
    /**
     * @param array<string, string|int> $pathParams
     * @param array<string, mixed> $query
     * @param list<string> $explode
     * @param array<string, string|int|float|bool|null> $headers
     * @param array<mixed>|null $body
     */
    public function __construct(
        public readonly string $method,
        public readonly string $path,
        public readonly array $pathParams = [],
        public readonly array $query = [],
        public readonly array $explode = [],
        public readonly array $headers = [],
        public readonly ?array $body = null,
        public readonly ?string $contentType = null,
        public readonly bool $bodyIsList = false,
        public readonly bool $idempotent = false,
        public readonly ?string $idempotencyKey = null,
        public readonly bool $authenticated = true,
        public readonly ?RequestOptions $options = null,
    ) {
    }

    /**
     * Returns the same call with the given query parameters replaced; a null value removes a parameter.
     *
     * @param array<string, mixed> $query
     */
    public function withQuery(array $query): self
    {
        return new self(
            method: $this->method,
            path: $this->path,
            pathParams: $this->pathParams,
            query: array_merge($this->query, $query),
            explode: $this->explode,
            headers: $this->headers,
            body: $this->body,
            contentType: $this->contentType,
            bodyIsList: $this->bodyIsList,
            idempotent: $this->idempotent,
            idempotencyKey: $this->idempotencyKey,
            authenticated: $this->authenticated,
            options: $this->options,
        );
    }

    /**
     * The path with its parameters filled in and the query string, relative to the base URL.
     */
    public function target(): string
    {
        $path = $this->path;
        foreach ($this->pathParams as $name => $value) {
            $path = str_replace('{' . $name . '}', rawurlencode((string) $value), $path);
        }
        $pairs = [];
        foreach ($this->query as $name => $value) {
            foreach ($this->queryValues($name, $value) as $encoded) {
                $pairs[] = rawurlencode($name) . '=' . rawurlencode($encoded);
            }
        }

        return $pairs === [] ? $path : $path . '?' . implode('&', $pairs);
    }

    /**
     * The JSON body of the call, or null without one.
     *
     * @throws JsonException
     */
    public function encodedBody(): ?string
    {
        if ($this->body === null) {
            return null;
        }
        if ($this->body === [] && !$this->bodyIsList) {
            return '{}';
        }

        return json_encode(
            $this->body,
            JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION,
        );
    }

    /**
     * @return list<string>
     */
    private function queryValues(string $name, mixed $value): array
    {
        if ($value === null) {
            return [];
        }
        if (is_array($value)) {
            $values = array_map(fn (mixed $item): string => $this->scalar($item), array_values($value));
            if (in_array($name, $this->explode, true)) {
                return $values;
            }

            return $values === [] ? [] : [implode(',', $values)];
        }

        return [$this->scalar($value)];
    }

    private function scalar(mixed $value): string
    {
        return match (true) {
            $value === true => 'true',
            $value === false => 'false',
            is_int($value), is_float($value), is_string($value) => (string) $value,
            $value instanceof \Stringable => (string) $value,
            default => throw new \InvalidArgumentException('query values must be scalars'),
        };
    }
}
