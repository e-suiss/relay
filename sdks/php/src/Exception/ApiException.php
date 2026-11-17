<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * An RFC 9457 problem answered by Relay, with its status, code, retryable flag and the full problem body.
 */
class ApiException extends RelayException
{
    public readonly ?string $title;

    public readonly ?string $detail;

    public readonly ?string $type;

    public readonly bool $retryable;

    public readonly ?string $requestId;

    /**
     * @param array<mixed> $problem
     * @param array<string, string> $headers
     */
    public function __construct(
        public readonly int $status,
        public readonly ?string $errorCode,
        public readonly array $problem = [],
        public readonly array $headers = [],
        public readonly ?float $retryAfter = null,
    ) {
        $this->title = self::text($problem, 'title');
        $this->detail = self::text($problem, 'detail');
        $this->type = self::text($problem, 'type');
        $this->retryable = ($problem['retryable'] ?? false) === true;
        $this->requestId = self::text($problem, 'request_id') ?? ($headers['request-id'] ?? null);

        $message = 'Relay answered HTTP ' . $status;
        if ($errorCode !== null) {
            $message .= ' ' . $errorCode;
        }
        $summary = $this->detail ?? $this->title;
        if ($summary !== null) {
            $message .= ': ' . $summary;
        }
        parent::__construct($message);
    }

    /**
     * @param array<mixed> $problem
     */
    private static function text(array $problem, string $key): ?string
    {
        $value = $problem[$key] ?? null;

        return is_string($value) ? $value : null;
    }
}
