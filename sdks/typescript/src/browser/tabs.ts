/** The part of the Web Locks API the coordinator uses. */
export interface LockManagerLike {
  request(name: string, options: { signal?: AbortSignal }, callback: (lock: unknown) => Promise<void>): Promise<unknown>;
}

/** The part of BroadcastChannel the coordinator uses. */
export interface BroadcastChannelLike {
  postMessage(message: unknown): void;
  close(): void;
  onmessage: ((event: { readonly data: unknown }) => void) | null;
}

/** Options of the tab coordinator. */
export interface TabCoordinatorOptions {
  /** Name of the lock and of the channel; tabs of the same subscriber share it. */
  readonly name: string;
  readonly locks?: LockManagerLike | null;
  readonly createChannel?: ((name: string) => BroadcastChannelLike) | null;
  /** This tab became the leader: it holds the one realtime connection. */
  readonly onLeader: () => void;
  /** This tab is a follower: it receives the leader's events over the channel. */
  readonly onFollower: () => void;
  /** A message the leader published. */
  readonly onMessage: (message: unknown) => void;
}

/**
 * One realtime connection per browser (IN-36): the tab that holds the Web Lock is the leader and shares the stream with the other tabs over a BroadcastChannel. Followers still write over REST themselves, so a change of leader loses nothing. Without Web Locks or BroadcastChannel every tab leads alone.
 */
export class TabCoordinator {
  readonly #options: TabCoordinatorOptions;
  readonly #locks: LockManagerLike | null;
  #channel: BroadcastChannelLike | null = null;
  #release: (() => void) | null = null;
  #abort: AbortController | null = null;
  #leader = false;

  constructor(options: TabCoordinatorOptions) {
    this.#options = options;
    const navigatorLocks = (globalThis as { navigator?: { locks?: LockManagerLike } }).navigator?.locks;
    this.#locks = options.locks === undefined ? (navigatorLocks ?? null) : options.locks;
  }

  /** Whether this tab leads. */
  get leader(): boolean {
    return this.#leader;
  }

  /** Opens the channel and asks for leadership; until it is granted the tab follows. */
  start(): void {
    const create =
      this.#options.createChannel === undefined
        ? typeof BroadcastChannel === "undefined"
          ? null
          : (name: string) => new BroadcastChannel(name) as unknown as BroadcastChannelLike
        : this.#options.createChannel;
    if (this.#channel === null && create !== null) {
      this.#channel = create(this.#options.name);
      this.#channel.onmessage = (event) => {
        if (!this.#leader) this.#options.onMessage(event.data);
      };
    }
    this.request();
  }

  /** Asks for leadership again, for example when a tab that stepped down becomes visible. */
  request(): void {
    if (this.#leader || this.#abort !== null) return;
    if (this.#locks === null || this.#channel === null) {
      this.#becomeLeader();
      return;
    }
    this.#options.onFollower();
    const abort = new AbortController();
    this.#abort = abort;
    this.#locks
      .request(this.#options.name, { signal: abort.signal }, () => {
        this.#abort = null;
        return new Promise<void>((resolve) => {
          this.#release = resolve;
          this.#becomeLeader();
        });
      })
      .catch(() => {
        if (this.#abort === abort) this.#abort = null;
      });
  }

  /** Steps down: releases the lock so another tab can lead, and follows. */
  release(): void {
    this.#abort?.abort();
    this.#abort = null;
    if (this.#leader) {
      this.#leader = false;
      const release = this.#release;
      this.#release = null;
      release?.();
      this.#options.onFollower();
    }
  }

  /** Publishes a message to the followers; only the leader publishes. */
  publish(message: unknown): void {
    if (this.#leader) this.#channel?.postMessage(message);
  }

  /** Steps down and closes the channel. */
  stop(): void {
    this.release();
    this.#channel?.close();
    this.#channel = null;
  }

  #becomeLeader(): void {
    this.#leader = true;
    this.#options.onLeader();
  }
}
