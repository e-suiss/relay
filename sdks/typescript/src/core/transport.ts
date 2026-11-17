import { API_VERSION } from "../generated/meta.js";
import { createApiError, parseProblem, RelayConnectionError } from "./errors.js";
import type { QueryValue } from "./pagination.js";
import {
  decideRetry,
  defaultRetryPolicy,
  parseRetryAfter,
  type AttemptOutcome,
  type RetryPolicy,
} from "./retry.js";

/** Builds the authorization headers of one attempt; called again for every retry. */
export type Authenticate = (request: {
  readonly method: string;
  readonly url: string;
}) => Promise<Readonly<Record<string, string>>> | Readonly<Record<string, string>>;

/** The fetch function the SDK calls; the global `fetch` by default. */
export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

/** How an operation treats the Idempotency-Key header. */
export type IdempotencyMode = "required" | "optional" | "none";

/** Options shared by every client. */
export interface TransportOptions {
  /** Region base address, for example `https://relay.example.com`. */
  readonly baseUrl: string;
  readonly authenticate?: Authenticate;
  readonly fetch?: FetchLike;
  readonly retry?: Partial<RetryPolicy>;
  /** Extra headers sent with every request. */
  readonly headers?: Readonly<Record<string, string>>;
  readonly random?: () => number;
  readonly now?: () => number;
  readonly sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
  readonly idempotencyKey?: () => string;
}

/** One request as the transport sends it. */
export interface RequestSpec {
  readonly method: string;
  readonly path: string;
  readonly query?: Readonly<Record<string, QueryValue | undefined | null>>;
  readonly body?: unknown;
  readonly contentType?: string | null;
  readonly idempotency: IdempotencyMode;
  readonly idempotencyKey?: string;
  readonly headers?: Readonly<Record<string, string>>;
  readonly signal?: AbortSignal;
}

/** A successful response. */
export interface RelayResponse<T> {
  readonly data: T;
  readonly status: number;
  readonly headers: Headers;
  readonly requestId: string | null;
  readonly idempotencyKey: string | null;
  /** The response is a byte-for-byte replay of the first response for the same key and body. */
  readonly replayed: boolean;
}

/** Sleeps for `ms`, ending early with the signal's reason when it aborts. */
export function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason);
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(signal?.reason);
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

/** A new Idempotency-Key: a random UUID, never derived from the request content. */
export function newIdempotencyKey(): string {
  return globalThis.crypto.randomUUID();
}

function isJson(contentType: string | null | undefined): boolean {
  return contentType !== null && contentType !== undefined && /[/+]json\b/i.test(contentType);
}

async function readBody(response: Response): Promise<unknown> {
  if (response.status === 204 || response.status === 205) return undefined;
  const text = await response.text();
  if (text === "") return undefined;
  if (isJson(response.headers.get("content-type"))) {
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }
  return text;
}

/** Sends requests with the Relay-Version pinned to the SDK's API version, the Idempotency-Key kept across retries and retries only on retryable errors (X-29). */
export class Transport {
  readonly baseUrl: string;
  readonly #options: TransportOptions;
  readonly #policy: RetryPolicy;

  constructor(options: TransportOptions) {
    this.baseUrl = options.baseUrl.replace(/\/+$/, "");
    this.#options = options;
    this.#policy = { ...defaultRetryPolicy, ...options.retry };
  }

  /** Builds the absolute URL of a path and query. */
  url(path: string, query?: RequestSpec["query"]): string {
    const url = new URL(this.baseUrl + path);
    for (const [name, value] of Object.entries(query ?? {})) {
      if (value === undefined || value === null) continue;
      if (Array.isArray(value)) {
        for (const item of value) url.searchParams.append(name, String(item));
      } else {
        url.searchParams.set(name, String(value));
      }
    }
    return url.toString();
  }

  /** Sends one logical request, retrying it under the policy. */
  async request<T>(spec: RequestSpec): Promise<RelayResponse<T>> {
    const fetchImpl: FetchLike = this.#options.fetch ?? ((input, init) => globalThis.fetch(input, init));
    const random = this.#options.random ?? Math.random;
    const now = this.#options.now ?? Date.now;
    const wait = this.#options.sleep ?? sleep;
    const url = this.url(spec.path, spec.query);
    const contentType = spec.body === undefined ? null : (spec.contentType ?? "application/json");
    const key = this.#key(spec, contentType);
    const body =
      spec.body === undefined
        ? undefined
        : isJson(contentType)
          ? JSON.stringify(spec.body)
          : (spec.body as BodyInit);

    for (let retry = 1; ; retry++) {
      const headers: Record<string, string> = {
        accept: "application/json",
        "relay-version": API_VERSION,
        ...this.#options.headers,
      };
      if (contentType !== null) headers["content-type"] = contentType;
      if (key !== null) headers["idempotency-key"] = key;
      if (this.#options.authenticate) {
        Object.assign(headers, await this.#options.authenticate({ method: spec.method, url }));
      }
      Object.assign(headers, spec.headers);

      let outcome: AttemptOutcome;
      let failure: Error;
      try {
        const response = await fetchImpl(url, {
          method: spec.method,
          headers,
          body,
          signal: spec.signal,
        });
        const data = await readBody(response);
        const requestId = response.headers.get("request-id");
        if (response.ok) {
          return {
            data: data as T,
            status: response.status,
            headers: response.headers,
            requestId,
            idempotencyKey: response.headers.get("idempotency-key") ?? key,
            replayed: response.headers.get("idempotency-replayed") === "true",
          };
        }
        const retryAfter = response.headers.get("retry-after");
        const retryAfterMs = parseRetryAfter(retryAfter, now());
        outcome = {
          kind: "response",
          status: response.status,
          retryAfter,
          problem: parseProblem(data),
        };
        failure = createApiError({
          status: response.status,
          body: data,
          requestId,
          retryAfterSeconds: retryAfterMs === null ? null : Math.ceil(retryAfterMs / 1000),
        });
      } catch (error) {
        if (spec.signal?.aborted) throw error;
        outcome = { kind: "network" };
        failure = new RelayConnectionError("The request got no response.", { cause: error });
      }

      const decision = decideRetry(outcome, retry, this.#policy, now(), random());
      if (!decision.retry) throw failure;
      await wait(decision.delayMs, spec.signal);
    }
  }

  #key(spec: RequestSpec, contentType: string | null): string | null {
    if (spec.idempotency === "none") return null;
    if (spec.idempotencyKey !== undefined) return spec.idempotencyKey;
    if (spec.idempotency === "optional" && contentType !== null && /cloudevents/i.test(contentType)) {
      return null;
    }
    return (this.#options.idempotencyKey ?? newIdempotencyKey)();
  }
}
