<?php

declare(strict_types=1);

namespace Esuiss\Relay;

use Closure;
use Generator;
use IteratorAggregate;

/**
 * One page of a cursor-paginated list; iterating it yields every item of this and the following pages, fetching each next page only when it is reached.
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
    ) {
    }

    // API-56
    /**
     * The next page, or null on the last page.
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
            foreach ($page->data as $item) {
                yield $item;
            }
        }
    }
}
