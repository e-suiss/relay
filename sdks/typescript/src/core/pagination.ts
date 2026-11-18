import { RelayUsageError } from "./errors.js";

/** One page of a cursor list. */
export interface Page<T> {
  readonly object?: string;
  readonly data: readonly T[];
  readonly has_more: boolean;
  readonly next_cursor: string | null;
  readonly previous_cursor?: string | null;
}

/** Pagination parameters of a list operation. */
export interface PageParams {
  readonly limit?: number;
  readonly starting_after?: string;
  readonly ending_before?: string;
}

/** Query values a list request sends. */
export type QueryValue = string | number | boolean | readonly (string | number | boolean)[];

/** Fetches one page for a query. */
export type PageFetcher<T> = (query: Readonly<Record<string, QueryValue>>) => Promise<Page<T>>;

/**
 * Lazy iterator over a cursor list (X-29). Pages are fetched only when an item beyond the current page is asked for. Without a cursor or with `starting_after` it walks forward; with `ending_before` it walks backward and yields each page in reverse order.
 */
export class Paginator<T> implements AsyncIterable<T> {
  readonly #fetch: PageFetcher<T>;
  readonly #query: Readonly<Record<string, QueryValue>>;
  readonly #backward: boolean;

  constructor(fetch: PageFetcher<T>, params: Readonly<Record<string, unknown>> = {}) {
    if (params.starting_after !== undefined && params.ending_before !== undefined) {
      throw new RelayUsageError("both_cursors", "Use starting_after or ending_before, not both.");
    }
    const query: Record<string, QueryValue> = {};
    for (const [name, value] of Object.entries(params)) {
      if (value === undefined || value === null) continue;
      query[name] = Array.isArray(value) ? (value as (string | number | boolean)[]) : String(value);
    }
    this.#fetch = fetch;
    this.#query = query;
    this.#backward = params.ending_before !== undefined;
  }

  /** Iterates over the pages themselves. */
  async *pages(): AsyncGenerator<Page<T>, void, undefined> {
    let query: Readonly<Record<string, QueryValue>> | null = this.#query;
    while (query !== null) {
      const page: Page<T> = await this.#fetch(query);
      yield page;
      const cursor = this.#backward ? (page.previous_cursor ?? null) : page.next_cursor;
      if (cursor === null) {
        query = null;
      } else {
        const next: Record<string, QueryValue> = { ...query };
        delete next.starting_after;
        delete next.ending_before;
        next[this.#backward ? "ending_before" : "starting_after"] = cursor;
        query = next;
      }
    }
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<T, void, undefined> {
    for await (const page of this.pages()) {
      const data = this.#backward ? [...page.data].reverse() : page.data;
      for (const item of data) yield item;
    }
  }

  /** Collects at most `count` items, fetching no page beyond the one that holds the last of them. */
  async take(count: number): Promise<T[]> {
    const items: T[] = [];
    if (count <= 0) return items;
    for await (const item of this) {
      items.push(item);
      if (items.length >= count) break;
    }
    return items;
  }

  /** Collects every item of the list. */
  async toArray(): Promise<T[]> {
    const items: T[] = [];
    for await (const item of this) items.push(item);
    return items;
  }
}
