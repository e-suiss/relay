import { parseProblem, RelayError } from "../core/errors.js";
import { parseRetryAfter } from "../core/retry.js";
import { readSse } from "../core/sse.js";
import { API_VERSION } from "../generated/meta.js";
import type { FetchLike } from "../core/transport.js";
import type { SubscriberTokenSource } from "./token.js";

/** The absolute inbox counters every envelope carries (IN-19). */
export interface InboxCounters {
  readonly unseen: number;
  readonly unread: number;
  readonly total: number;
  readonly version: number;
}

/** A realtime envelope `{t, v, ts, d}` with counters and the resume cursor `id` (IN-26). */
export interface RealtimeEnvelope {
  readonly t: string;
  readonly v: number;
  readonly ts: string;
  readonly d: Readonly<Record<string, unknown>>;
  readonly counters: InboxCounters;
  readonly id?: string;
}

/** The transports, in the order the web SDK tries them (IN-23). */
export type RealtimeTransportKind = "websocket" | "sse" | "poll";

/** The state of the connection. */
export interface RealtimeStatus {
  readonly state: "connecting" | "open" | "waiting" | "closed";
  readonly transport: RealtimeTransportKind | null;
  readonly attempt: number;
  readonly delayMs?: number;
}

/** The connection was refused for good; `reason` is the error code or close reason. */
export class RealtimeError extends RelayError {
  readonly reason: string;

  constructor(reason: string) {
    super(`Realtime connection refused: ${reason}`);
    this.reason = reason;
  }
}

/** A WebSocket as the connection uses it. */
export interface WebSocketLike {
  readonly readyState: number;
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { readonly data: unknown }) => void) | null;
  onclose: ((event: { readonly code: number; readonly reason: string }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

/** Creates WebSockets. */
export type WebSocketFactory = (url: string, protocols: string[]) => WebSocketLike;

/** What the connection needs from its environment; every member can be replaced in tests. */
export interface RealtimeEnvironment {
  readonly webSocket: WebSocketFactory | null;
  readonly fetch: FetchLike;
  readonly setTimeout: (callback: () => void, ms: number) => unknown;
  readonly clearTimeout: (handle: unknown) => void;
  readonly random: () => number;
}

/** Options of the realtime connection. */
export interface RealtimeOptions {
  readonly baseUrl: string;
  readonly tokens: SubscriberTokenSource;
  readonly onEnvelope: (envelope: RealtimeEnvelope) => void;
  readonly onStatus?: (status: RealtimeStatus) => void;
  readonly onError?: (error: RealtimeError) => void;
  readonly stream?: "inbox" | "ag_ui";
  readonly deviceId?: string;
  readonly cursor?: string | null;
  readonly transports?: readonly RealtimeTransportKind[];
  /** Reconnect backoff: first ceiling and highest ceiling in milliseconds (IN-52: 1 s and 60 s). */
  readonly reconnect?: { readonly baseMs?: number; readonly capMs?: number };
  readonly env?: Partial<RealtimeEnvironment>;
}

type End =
  | { readonly type: "dropped"; readonly opened: boolean; readonly retryAfterMs?: number }
  | { readonly type: "unavailable" }
  | { readonly type: "fatal"; readonly reason: string };

const HEARTBEAT_MS = 30_000;
const retryReasons = new Set(["auth_expired_token"]);

/** Reconnect delay of the given attempt (counted from 1): exponential backoff with full jitter (IN-34). */
export function reconnectDelay(attempt: number, random: number, baseMs = 1000, capMs = 60_000): number {
  return Math.floor(random * Math.min(capMs, baseMs * 2 ** (attempt - 1)));
}

function base64url(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function defaultEnvironment(): RealtimeEnvironment {
  const WebSocketClass = (globalThis as { WebSocket?: new (url: string, protocols: string[]) => WebSocketLike })
    .WebSocket;
  return {
    webSocket: WebSocketClass === undefined ? null : (url, protocols) => new WebSocketClass(url, protocols),
    fetch: (input, init) => globalThis.fetch(input, init),
    setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
    clearTimeout: (handle) => globalThis.clearTimeout(handle as ReturnType<typeof globalThis.setTimeout>),
    random: Math.random,
  };
}

/**
 * The subscriber's realtime stream (IN-23): WebSocket (Phoenix Channels) first, then SSE, then long-poll. A transport that never opens hands over to the next; a connection that drops reconnects with exponential backoff and full jitter, or after the server's Retry-After (IN-34, IN-52). It resumes after the last envelope id, so a reconnect loses nothing (IN-22). The stream is read-only; writes go through REST (IN-31).
 */
export class RealtimeConnection {
  readonly #options: RealtimeOptions;
  readonly #env: RealtimeEnvironment;
  readonly #transports: readonly RealtimeTransportKind[];
  #index = 0;
  #attempt = 0;
  #running = false;
  #cursor: string | null;
  #closeCurrent: (() => void) | null = null;
  #wake: (() => void) | null = null;
  #transport: RealtimeTransportKind | null = null;

  constructor(options: RealtimeOptions) {
    this.#options = options;
    this.#env = { ...defaultEnvironment(), ...options.env };
    const transports = options.transports ?? ["websocket", "sse", "poll"];
    this.#transports = transports.filter((kind) => kind !== "websocket" || this.#env.webSocket !== null);
    this.#cursor = options.cursor ?? null;
  }

  /** The resume cursor: the id of the last envelope received. */
  get cursor(): string | null {
    return this.#cursor;
  }

  /** The transport in use. */
  get transport(): RealtimeTransportKind | null {
    return this.#transport;
  }

  /** Opens the connection; it keeps itself open until `stop()`. */
  start(): void {
    if (this.#running) return;
    this.#running = true;
    void this.#run();
  }

  /** Closes the connection and stops reconnecting. */
  stop(): void {
    this.#running = false;
    this.#closeCurrent?.();
    this.#closeCurrent = null;
    this.#wake?.();
    this.#status({ state: "closed", transport: this.#transport, attempt: this.#attempt });
  }

  #status(status: RealtimeStatus): void {
    this.#options.onStatus?.(status);
  }

  #deliver(envelope: RealtimeEnvelope): void {
    if (typeof envelope.id === "string") this.#cursor = envelope.id;
    this.#options.onEnvelope(envelope);
  }

  #opened(kind: RealtimeTransportKind): void {
    this.#attempt = 0;
    this.#status({ state: "open", transport: kind, attempt: 0 });
  }

  async #run(): Promise<void> {
    while (this.#running) {
      const kind = this.#transports[this.#index];
      if (kind === undefined) return;
      this.#transport = kind;
      this.#status({ state: "connecting", transport: kind, attempt: this.#attempt });
      let end: End;
      try {
        end = await this.#connect(kind);
      } catch {
        end = { type: "unavailable" };
      }
      if (!this.#running) return;
      if (end.type === "fatal") {
        if (retryReasons.has(end.reason)) {
          this.#options.tokens.invalidate();
          end = { type: "dropped", opened: false };
        } else {
          this.#running = false;
          this.#status({ state: "closed", transport: kind, attempt: this.#attempt });
          this.#options.onError?.(new RealtimeError(end.reason));
          return;
        }
      }
      if (end.type === "unavailable") {
        if (this.#index < this.#transports.length - 1) {
          this.#index++;
          continue;
        }
        this.#index = 0;
      }
      this.#attempt++;
      const retryAfter = end.type === "dropped" ? end.retryAfterMs : undefined;
      const delayMs =
        retryAfter ??
        reconnectDelay(
          this.#attempt,
          this.#env.random(),
          this.#options.reconnect?.baseMs,
          this.#options.reconnect?.capMs,
        );
      this.#status({ state: "waiting", transport: kind, attempt: this.#attempt, delayMs });
      await new Promise<void>((resolve) => {
        const handle = this.#env.setTimeout(() => {
          this.#wake = null;
          resolve();
        }, delayMs);
        this.#wake = () => {
          this.#env.clearTimeout(handle);
          this.#wake = null;
          resolve();
        };
      });
    }
  }

  #connect(kind: RealtimeTransportKind): Promise<End> {
    switch (kind) {
      case "websocket":
        return this.#connectWebSocket();
      case "sse":
        return this.#connectSse();
      case "poll":
        return this.#connectPoll();
    }
  }

  #url(path: string, query: Record<string, string | null | undefined>): URL {
    const url = new URL(this.#options.baseUrl.replace(/\/+$/, "") + path);
    for (const [name, value] of Object.entries(query)) {
      if (value !== null && value !== undefined) url.searchParams.set(name, value);
    }
    return url;
  }

  async #connectWebSocket(): Promise<End> {
    const factory = this.#env.webSocket;
    if (factory === null) return { type: "unavailable" };
    const token = await this.#options.tokens.get();
    const topic = this.#options.stream ?? "inbox";
    const url = this.#url("/v1/realtime/websocket", { vsn: "2.0.0", device_id: this.#options.deviceId });
    url.protocol = url.protocol === "http:" ? "ws:" : "wss:";
    const socket = factory(url.toString(), ["phoenix", `base64url.bearer.phx.${base64url(token)}`]);

    return new Promise<End>((resolve) => {
      let ref = 0;
      const joinRef = "1";
      let joinMessageRef = "";
      let joined = false;
      let socketOpened = false;
      let done = false;
      let heartbeat: unknown = null;
      let refresh: unknown = null;
      const send = (message: unknown[]) => socket.send(JSON.stringify(message));
      const finish = (end: End) => {
        if (done) return;
        done = true;
        if (heartbeat !== null) this.#env.clearTimeout(heartbeat);
        if (refresh !== null) this.#env.clearTimeout(refresh);
        this.#closeCurrent = null;
        resolve(end);
      };
      const beat = () => {
        heartbeat = this.#env.setTimeout(() => {
          send([null, String(++ref), "phoenix", "heartbeat", {}]);
          beat();
        }, HEARTBEAT_MS);
      };
      const scheduleRefresh = () => {
        const wait = this.#options.tokens.renewInMs();
        if (wait === null) return;
        refresh = this.#env.setTimeout(() => {
          this.#options.tokens.invalidate();
          void this.#options.tokens.get().then((fresh) => {
            if (done) return;
            send([joinRef, String(++ref), topic, "auth.refresh", { token: fresh }]);
            scheduleRefresh();
          });
        }, wait);
      };
      this.#closeCurrent = () => {
        socket.close(1000);
        finish({ type: "dropped", opened: joined });
      };
      socket.onopen = () => {
        socketOpened = true;
        joinMessageRef = String(++ref);
        send([joinRef, joinMessageRef, topic, "phx_join", this.#cursor === null ? {} : { cursor: this.#cursor }]);
        beat();
      };
      socket.onmessage = (event) => {
        if (typeof event.data !== "string") return;
        let message: unknown;
        try {
          message = JSON.parse(event.data);
        } catch {
          return;
        }
        if (!Array.isArray(message) || message.length !== 5) return;
        const [, messageRef, messageTopic, name, payload] = message as [unknown, unknown, unknown, string, unknown];
        if (name === "phx_reply" && messageRef === joinMessageRef) {
          const reply = payload as { status?: string; response?: { reason?: string } };
          if (reply.status === "ok") {
            joined = true;
            this.#opened("websocket");
            scheduleRefresh();
          } else {
            socket.close(1000);
            finish({ type: "fatal", reason: reply.response?.reason ?? "join_refused" });
          }
          return;
        }
        if (name === "phx_error" || name === "phx_close") {
          socket.close(1000);
          finish({ type: "dropped", opened: joined });
          return;
        }
        if (messageTopic === topic && typeof name === "string" && !name.startsWith("phx_")) {
          this.#deliver(payload as RealtimeEnvelope);
        }
      };
      socket.onerror = () => undefined;
      socket.onclose = (event) => {
        if (event.code === 1008) {
          finish({ type: "fatal", reason: event.reason === "" ? "policy_violation" : event.reason });
        } else if (event.code === 1013) {
          const seconds = /retry-after=(\d+)/.exec(event.reason)?.[1];
          finish({ type: "dropped", opened: joined, ...(seconds ? { retryAfterMs: Number(seconds) * 1000 } : {}) });
        } else if (!socketOpened) {
          finish({ type: "unavailable" });
        } else {
          finish({ type: "dropped", opened: joined });
        }
      };
    });
  }

  async #authorizedFetch(url: URL, headers: Record<string, string>, signal: AbortSignal): Promise<Response> {
    const token = await this.#options.tokens.get();
    return this.#env.fetch(url.toString(), {
      method: "GET",
      headers: { authorization: `Bearer ${token}`, "relay-version": API_VERSION, ...headers },
      signal,
    });
  }

  async #refused(response: Response): Promise<End> {
    const retryAfter = parseRetryAfter(response.headers.get("retry-after"), Date.now());
    if (response.status === 429 || response.status === 503) {
      return { type: "dropped", opened: false, ...(retryAfter === null ? {} : { retryAfterMs: retryAfter }) };
    }
    if (response.status === 401 || response.status === 403) {
      const problem = parseProblem(await response.text().catch(() => ""));
      return { type: "fatal", reason: problem?.code ?? `http_${response.status}` };
    }
    if (response.status >= 500) return { type: "dropped", opened: false };
    return { type: "unavailable" };
  }

  async #connectSse(): Promise<End> {
    const controller = new AbortController();
    this.#closeCurrent = () => controller.abort();
    const url = this.#url("/v1/realtime/events", {
      stream: this.#options.stream,
      device_id: this.#options.deviceId,
    });
    const headers: Record<string, string> = { accept: "text/event-stream" };
    if (this.#cursor !== null) headers["last-event-id"] = this.#cursor;
    let response: Response;
    try {
      response = await this.#authorizedFetch(url, headers, controller.signal);
    } catch {
      return { type: "unavailable" };
    }
    if (!response.ok) return this.#refused(response);
    if (response.body === null) return { type: "unavailable" };
    this.#opened("sse");
    try {
      for await (const event of readSse(response.body)) {
        try {
          this.#deliver(JSON.parse(event.data) as RealtimeEnvelope);
        } catch {
          continue;
        }
      }
    } catch {
      return { type: "dropped", opened: true };
    } finally {
      this.#closeCurrent = null;
    }
    return { type: "dropped", opened: true };
  }

  async #connectPoll(): Promise<End> {
    const controller = new AbortController();
    this.#closeCurrent = () => controller.abort();
    let opened = false;
    try {
      while (this.#running) {
        const url = this.#url("/v1/realtime/poll", { stream: this.#options.stream, cursor: this.#cursor });
        let response: Response;
        try {
          response = await this.#authorizedFetch(url, { accept: "application/json" }, controller.signal);
        } catch {
          return { type: "dropped", opened };
        }
        if (!response.ok) {
          const end = await this.#refused(response);
          return end.type === "unavailable" ? { type: "dropped", opened } : end;
        }
        const body = (await response.json()) as { events: RealtimeEnvelope[]; cursor: string };
        if (!opened) {
          opened = true;
          this.#opened("poll");
        }
        for (const envelope of body.events) this.#deliver(envelope);
        this.#cursor = body.cursor;
      }
      return { type: "dropped", opened };
    } finally {
      this.#closeCurrent = null;
    }
  }
}
