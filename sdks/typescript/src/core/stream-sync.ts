/**
 * Keeps the highest version seen per key and refuses anything not newer (IN-27): out-of-order, duplicate and replayed events are dropped by one rule.
 */
export class VersionedDeduper<T> {
  readonly #versions = new Map<string, number>();
  readonly #key: (item: T) => string;
  readonly #version: (item: T) => number;

  constructor(key: (item: T) => string, version: (item: T) => number) {
    this.#key = key;
    this.#version = version;
  }

  /** Records the item and returns true when its version is newer than any seen for its key. */
  accept(item: T): boolean {
    const key = this.#key(item);
    const version = this.#version(item);
    const known = this.#versions.get(key);
    if (known !== undefined && version <= known) return false;
    this.#versions.set(key, version);
    return true;
  }

  /** The highest version seen for a key. */
  known(key: string): number | undefined {
    return this.#versions.get(key);
  }

  /** Forgets every key, for a cold resynchronisation. */
  clear(): void {
    this.#versions.clear();
  }
}

/** Options of `openThenList`. */
export interface OpenThenListOptions<T> {
  /** Opens the live stream; events that arrive before the history is read are buffered. Returns a close function. */
  readonly open: (push: (item: T) => void) => Promise<() => void> | (() => void);
  /** Lists the snapshot or history, after the stream is open. */
  readonly history: () => AsyncIterable<T> | Iterable<T> | Promise<Iterable<T>>;
  readonly key: (item: T) => string;
  readonly version: (item: T) => number;
  /** Receives every item that is newer than what was already seen, history first, then buffered and live events. */
  readonly onItem: (item: T) => void;
}

/** A running open-then-list subscription. */
export interface StreamSubscription<T> {
  readonly close: () => void;
  readonly deduper: VersionedDeduper<T>;
}

/**
 * The client pattern (IN-28, AG-21): open the stream first and buffer it, then list the history, then apply the buffer, deduplicating by key and version. Listing before the stream is open loses what changes between the two steps.
 */
export async function openThenList<T>(options: OpenThenListOptions<T>): Promise<StreamSubscription<T>> {
  const deduper = new VersionedDeduper<T>(options.key, options.version);
  const buffer: T[] = [];
  let live = false;
  const deliver = (item: T) => {
    if (deduper.accept(item)) options.onItem(item);
  };
  const close = await options.open((item) => {
    if (live) deliver(item);
    else buffer.push(item);
  });
  try {
    const history = await options.history();
    for await (const item of history) deliver(item);
  } catch (error) {
    close();
    throw error;
  }
  for (const item of buffer.splice(0)) deliver(item);
  live = true;
  return { close, deduper };
}
