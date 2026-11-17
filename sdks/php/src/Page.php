<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Closure;
use Generator;
use IteratorAggregate;

/**
 * One page of a cursor-paginated list; iterating it yields every item of this and the following pages, fetching each next page only when it is reached.
 *
 * A list read backwards (started with ending_before) follows previous_cursor and yields each page's items in reverse order.
 *
 * @template T
 * @implements IteratorAggregate<int, T>
 */
final class Page implements IteratorAggregate
{
    /**
     * @param list<T> $data
     * @param array<string, mixed> $raw
     * @param (Closure(): Page<T>)|null $fetchNext
     */
    public function __construct(
        public readonly array $data,
        public readonly bool $hasMore,
        public readonly ?string $nextCursor,
        public readonly ?string $previousCursor,
        public readonly array $raw = [],
        private readonly ?Closure $fetchNext = null,
        public readonly bool $backward = false,
    ) {
    }

    // API-56
    /**
     * The following page in the direction of reading, or null on the last one.
     *
     * @return Page<T>|null
     */
    public function nextPage(): ?self
    {
        return $this->fetchNext === null ? null : ($this->fetchNext)();
    }

    /**
     * This page and the following ones, lazily.
     *
     * @return Generator<int, Page<T>>
     */
    public function pages(): Generator
    {
        $page = $this;
        while ($page !== null) {
            yield $page;
            $page = $page->nextPage();
        }
    }

    /**
     * @return Generator<int, T>
     */
    public function getIterator(): Generator
    {
        foreach ($this->pages() as $page) {
            foreach ($page->backward ? array_reverse($page->data) : $page->data as $item) {
                yield $item;
            }
        }
    }
}
