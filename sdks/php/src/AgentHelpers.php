<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Esuiss\Relay\Exception\WaitTimeoutException;
use Throwable;

/**
 * Helpers for agents: waitpoints, the durable mailbox and its at-least-once reading.
 */
trait AgentHelpers
{
    private const WAITPOINT_SETTLED = ['resolved', 'expired', 'cancelled'];

    abstract protected function clock(): float;

    abstract protected function pause(float $seconds): void;

    // X-30
    /**
     * Opens a waitpoint with an idempotency key that is returned with it, so that a later retry with the same key keeps its deadline.
     *
     * @param array<string, mixed> $body
     */
    public function openWaitpoint(
        array $body,
        ?string $idempotencyKey = null,
        ?RequestOptions $options = null,
    ): OpenedWaitpoint {
        $key = $idempotencyKey ?? Uuid::v4();

        return new OpenedWaitpoint($key, $this->createWaitpoint($body, idempotencyKey: $key, options: $options));
    }

    // X-30
    /**
     * Polls a waitpoint until it is resolved, expired or cancelled, sending heartbeats at half its heartbeat interval while waiting.
     *
     * @return array<string, mixed>
     * @throws WaitTimeoutException
     */
    public function awaitWaitpoint(
        string $waitpointId,
        float $timeout,
        float $pollInterval = 2.0,
        bool $heartbeat = true,
    ): array {
        $deadline = $this->clock() + $timeout;
        $nextBeat = null;
        while (true) {
            $waitpoint = $this->getWaitpoint($waitpointId);
            if (in_array($waitpoint['state'] ?? null, self::WAITPOINT_SETTLED, true)) {
                return $waitpoint;
            }
            $now = $this->clock();
            $interval = is_string($waitpoint['heartbeat_interval'] ?? null)
                ? Duration::seconds($waitpoint['heartbeat_interval'])
                : null;
            if ($heartbeat && $interval !== null && $interval > 0 && ($nextBeat === null || $now >= $nextBeat)) {
                $this->heartbeatWaitpoint($waitpointId);
                $nextBeat = $now + $interval / 2;
            }
            if ($now >= $deadline) {
                throw new WaitTimeoutException('the waitpoint ' . $waitpointId . ' did not settle in time');
            }
            $this->pause(min($pollInterval, $deadline - $now));
        }
    }

    // X-30
    /**
     * Reads mailbox records after a position (the acknowledged position when null), in stream order, without a lease.
     *
     * @return array<string, mixed>
     */
    public function readMailbox(?string $since = null, ?int $limit = null): array
    {
        return $this->listMailboxRecords(since: $since, limit: $limit);
    }

    // X-30
    /**
     * Leases at most $max mailbox records, oldest first.
     *
     * @return array<string, mixed>
     */
    public function leaseMailbox(int $max = 1): array
    {
        return $this->leaseMailboxRecords(['max' => $max]);
    }

    // X-30
    /**
     * Acknowledges records of one lease.
     *
     * @param list<string> $recordIds
     * @return array<string, mixed>
     */
    public function ackMailbox(string $leaseId, array $recordIds): array
    {
        return $this->ackMailboxRecords(['lease_id' => $leaseId, 'record_ids' => array_values($recordIds)]);
    }

    // X-30
    // AG-20
    /**
     * Leases up to $max records, hands each to $handler and acknowledges the ones it accepted; a record whose handler throws stays unacknowledged and is handed out again after its lease.
     *
     * @param callable(array<string, mixed>): void $handler
     * @return int the number of records acknowledged
     */
    public function consumeMailbox(callable $handler, int $max = 10): int
    {
        $lease = $this->leaseMailbox($max);
        $records = is_array($lease['records'] ?? null) ? $lease['records'] : [];
        $leaseId = is_string($lease['lease_id'] ?? null) ? $lease['lease_id'] : null;
        $done = [];
        $failure = null;
        foreach ($records as $record) {
            if (!is_array($record) || !is_string($record['id'] ?? null)) {
                continue;
            }
            try {
                /** @var array<string, mixed> $record */
                $handler($record);
                $done[] = $record['id'];
            } catch (Throwable $e) {
                $failure = $e;

                break;
            }
        }
        if ($done !== [] && $leaseId !== null) {
            $this->ackMailbox($leaseId, $done);
        }
        if ($failure !== null) {
            throw $failure;
        }

        return count($done);
    }
}
