/** Returns a Relay subscriber token, the narrow-scoped token of the subscriber (never a secret credential). */
export type SubscriberTokenProvider = () => Promise<string> | string;

/** Reads the `exp` claim of a JWT in milliseconds, or null. */
export function tokenExpiry(token: string): number | null {
  const part = token.split(".")[1];
  if (part === undefined) return null;
  try {
    const padded = part
      .replace(/-/g, "+")
      .replace(/_/g, "/")
      .padEnd(Math.ceil(part.length / 4) * 4, "=");
    const claims = JSON.parse(atob(padded)) as { exp?: unknown };
    return typeof claims.exp === "number" ? claims.exp * 1000 : null;
  } catch {
    return null;
  }
}

/**
 * Caches the subscriber token and renews it before it expires (IN-42). The provider is the application's own path to a subscriber token, the RFC 8693 exchange of its Access token.
 */
export class SubscriberTokenSource {
  readonly #provider: SubscriberTokenProvider;
  readonly #refreshBeforeMs: number;
  readonly #now: () => number;
  #token: string | null = null;
  #pending: Promise<string> | null = null;

  constructor(
    provider: SubscriberTokenProvider,
    options: { refreshBeforeMs?: number; now?: () => number } = {},
  ) {
    this.#provider = provider;
    this.#refreshBeforeMs = options.refreshBeforeMs ?? 60_000;
    this.#now = options.now ?? Date.now;
  }

  /** A token valid for at least the refresh margin. */
  async get(): Promise<string> {
    if (this.#token !== null) {
      const expiry = tokenExpiry(this.#token);
      if (expiry === null || expiry - this.#refreshBeforeMs > this.#now()) return this.#token;
    }
    this.#pending ??= Promise.resolve(this.#provider()).then(
      (token) => {
        this.#token = token;
        this.#pending = null;
        return token;
      },
      (error: unknown) => {
        this.#pending = null;
        throw error;
      },
    );
    return this.#pending;
  }

  /** Milliseconds until the cached token should be renewed, or null when unknown. */
  renewInMs(): number | null {
    if (this.#token === null) return null;
    const expiry = tokenExpiry(this.#token);
    return expiry === null ? null : Math.max(0, expiry - this.#refreshBeforeMs - this.#now());
  }

  /** Drops the cached token, for example after `auth_expired_token`. */
  invalidate(): void {
    this.#token = null;
  }
}
