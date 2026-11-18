<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Generator;

/**
 * The open-stream, list-history, deduplicate pattern for at-least-once streams.
 */
final class Stream
{
    // IN-28
    // AG-21
    // X-30
    /**
     * Opens the stream first, then lists the history and yields it, then yields the stream; an item whose version is not above the highest version already yielded for its key is dropped.
     *
     * @template T
     * @param callable(): iterable<T> $openStream
     * @param callable(): iterable<T> $listHistory
     * @param (callable(T): string)|null $key defaults to the item's id
     * @param (callable(T): int)|null $version defaults to the item's seq, else version
     * @return Generator<int, T>
     */
    public static function merge(
        callable $openStream,
        callable $listHistory,
        ?callable $key = null,
        ?callable $version = null,
    ): Generator {
        $key ??= static fn (mixed $item): string => is_array($item) && is_scalar($item['id'] ?? null)
            ? (string) $item['id']
            : '';
        $version ??= static function (mixed $item): int {
            if (!is_array($item)) {
                return 0;
            }
            $value = $item['seq'] ?? $item['version'] ?? 0;

            return is_int($value) ? $value : 0;
        };

        $stream = $openStream();
        $seen = [];
        foreach ([$listHistory(), $stream] as $source) {
            foreach ($source as $item) {
                $id = $key($item);
                $at = $version($item);
                if (isset($seen[$id]) && $at <= $seen[$id]) {
                    continue;
                }
                $seen[$id] = $at;
                yield $item;
            }
        }
    }
}
