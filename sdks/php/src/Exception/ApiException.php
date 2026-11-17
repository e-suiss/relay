<?php

declare(strict_types=1);

namespace Esuiss\Relay\Exception;

/**
 * An error answer of Relay with its status, code, retryable flag, field errors and the full RFC 9457 problem body.
 */
class ApiException extends RelayException
{
    public readonly ?string $title;

    public readonly ?string $detail;

    public readonly ?string $type;

    public readonly ?string $requestId;

    /**
     * @var list<array<string, mixed>>
     */
    public readonly array $fieldErrors;

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
        public readonly bool $retryable = false,
    ) {
        $this->title = self::text($problem, 'title');
        $this->detail = self::text($problem, 'detail');
        $this->type = self::text($problem, 'type');
        $this->requestId = self::text($problem, 'request_id') ?? ($headers['request-id'] ?? null);
        $fieldErrors = [];
        foreach (is_array($problem['errors'] ?? null) ? $problem['errors'] : [] as $error) {
            if (is_array($error)) {
                /** @var array<string, mixed> $error */
                $fieldErrors[] = $error;
            }
        }
        $this->fieldErrors = $fieldErrors;

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
