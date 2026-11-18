import {
  InboxClient,
  RelaySubscriberClient,
  type FetchLike,
  type InboxClientOptions,
  type InboxSnapshot,
  type StorageLike,
} from "@esuiss/relay/browser";
import { apiDisplayedSender, DisplayedReporter } from "./displayed.js";
import type { PendingMarkAllRead } from "./inbox/mark-all-read.js";
import { narrowTokenProvider, type TokenProvider } from "./tokens.js";

/** Options of a runtime: where Relay is and how the narrow tokens are obtained. */
export interface RelayRuntimeOptions {
  /** Region base address, for example `https://relay.example.com`. */
  readonly baseUrl: string;
  /** Returns a Relay subscriber token (X-32); needed by the inbox, toast and preference center. */
  readonly token?: TokenProvider;
  /** Returns a webhook portal token minted by the tenant backend (WH-47); needed by the portal. */
  readonly portalToken?: TokenProvider;
  readonly fetch?: FetchLike;
  readonly realtime?: InboxClientOptions["realtime"];
  readonly tabs?: InboxClientOptions["tabs"];
  /** How long an undoable action waits before it is sent, in milliseconds (IN-15). */
  readonly undoWindowMs?: number;
  readonly storage?: StorageLike | null;
  /** Reports digests of the identifiers of displayed notifications to Relay, which measures duplicate displays with them; off by default. */
  readonly reportDisplayedNotifications?: boolean;
}

/** The inbox state components render. */
export interface InboxState {
  readonly snapshot: InboxSnapshot | null;
  readonly error: unknown;
  /** A "mark all as read" waiting in its undo window (X-17). */
  readonly pendingMarkAllRead: PendingMarkAllRead | null;
}

/**
 * The clients behind the components: one subscriber client, one inbox and one portal client per runtime, shared by every component that uses it. The inbox starts when the first component needs it and stops when the last one goes away.
 */
export class RelayRuntime {
  readonly options: RelayRuntimeOptions;
  readonly subscriber: RelaySubscriberClient | null;
  readonly portal: RelaySubscriberClient | null;
  readonly inbox: InboxClient | null;
  /** The reporter of displayed notifications; null unless `reportDisplayedNotifications` is on and a subscriber token is given. */
  readonly displayed: DisplayedReporter | null;
  #state: InboxState = { snapshot: null, error: null, pendingMarkAllRead: null };
  readonly #listeners = new Set<() => void>();
  #users = 0;
  #unsubscribe: (() => void) | null = null;

  constructor(options: RelayRuntimeOptions) {
    this.options = options;
    const shared = {
      baseUrl: options.baseUrl,
      ...(options.fetch === undefined ? {} : { fetch: options.fetch }),
    };
    this.subscriber =
      options.token === undefined
        ? null
        : new RelaySubscriberClient({
            ...shared,
            token: narrowTokenProvider("subscriber", options.token),
          });
    this.portal =
      options.portalToken === undefined
        ? null
        : new RelaySubscriberClient({
            ...shared,
            token: narrowTokenProvider("portal", options.portalToken),
          });
    this.inbox =
      this.subscriber === null
        ? null
        : new InboxClient({
            client: this.subscriber,
            ...(options.realtime === undefined ? {} : { realtime: options.realtime }),
            ...(options.tabs === undefined ? {} : { tabs: options.tabs }),
            ...(options.undoWindowMs === undefined ? {} : { undoWindowMs: options.undoWindowMs }),
            ...(options.storage === undefined ? {} : { storage: options.storage }),
          });
    this.displayed =
      options.reportDisplayedNotifications === true && this.subscriber !== null
        ? new DisplayedReporter({ send: apiDisplayedSender(this.subscriber) })
        : null;
  }

  /** The undo window of the runtime in milliseconds. */
  get undoWindowMs(): number {
    return this.options.undoWindowMs ?? 5000;
  }

  /** Reports that the app displayed a notification itself, by its Relay identifier; does nothing while reporting is off. */
  reportDisplayed(id: string): void {
    this.displayed?.report(id).catch(() => undefined);
  }

  /** The current inbox state. */
  inboxState(): InboxState {
    return this.#state;
  }

  /** Subscribes to inbox state changes; returns an unsubscribe function. */
  subscribeInbox(listener: () => void): () => void {
    this.#listeners.add(listener);
    return () => {
      this.#listeners.delete(listener);
    };
  }

  /** Marks one component as using the inbox; returns the release function. */
  acquireInbox(): () => void {
    const inbox = this.inbox;
    if (inbox === null) return () => undefined;
    this.#users += 1;
    if (this.#users === 1) {
      this.#unsubscribe = inbox.subscribe((snapshot) =>
        this.#set({ ...this.#state, snapshot, error: null }),
      );
      inbox.start().catch((error: unknown) => this.#set({ ...this.#state, error }));
    }
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.#users -= 1;
      if (this.#users === 0) {
        this.#unsubscribe?.();
        this.#unsubscribe = null;
        inbox.stop();
      }
    };
  }

  /** Sets or clears the pending "mark all as read" every component shows. */
  setPendingMarkAllRead(pending: PendingMarkAllRead | null): void {
    this.#set({ ...this.#state, pendingMarkAllRead: pending });
  }

  /** Restarts a failed inbox. */
  retryInbox(): void {
    const inbox = this.inbox;
    if (inbox === null) return;
    this.#set({ ...this.#state, error: null });
    inbox.stop();
    inbox.start().catch((error: unknown) => this.#set({ ...this.#state, error }));
  }

  #set(state: InboxState): void {
    this.#state = state;
    for (const listener of this.#listeners) listener();
  }
}
