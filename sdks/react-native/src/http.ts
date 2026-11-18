import { fullJitter, sleep } from './backoff';
import { allowedOperation, type HttpMethod } from './boundary';
import {
  boundaryError,
  errorFromProblem,
  networkError,
  parseRetryAfter,
  type Problem,
} from './errors';
import {
  API_VERSION,
  type Clock,
  type FetchLike,
  type Logger,
  type Random,
  type SubscriberToken,
  type TokenProvider,
} from './ports';

const EXPIRY_MARGIN_MS = 30_000;

/** Caches the host's subscriber token and asks for a new one near expiry or after a 401. */
export class TokenManager {
  private current: SubscriberToken | null = null;
  private pending: Promise<SubscriberToken> | null = null;

  constructor(
    private readonly provider: TokenProvider,
    private readonly clock: Clock,
  ) {}

  async get(forceRefresh = false): Promise<SubscriberToken> {
    const cached = this.current;
    if (!forceRefresh && cached && !this.expiring(cached)) return cached;
    if (this.pending && !forceRefresh) return this.pending;
    const request = this.provider({ forceRefresh }).then(
      (token) => {
        this.current = token;
        this.pending = null;
        return token;
      },
      (error: unknown) => {
        this.pending = null;
        throw error;
      },
    );
    this.pending = request;
    return request;
  }

  clear(): void {
    this.current = null;
  }

  private expiring(token: SubscriberToken): boolean {
    return token.expiresAt !== undefined && token.expiresAt - EXPIRY_MARGIN_MS <= this.clock.now();
  }
}

export interface HttpConfig {
  readonly baseUrl: string;
  readonly tokens: TokenManager;
  readonly fetch: FetchLike;
  readonly clock: Clock;
  readonly random: Random;
  readonly logger: Logger;
  readonly maxRetries?: number;
}

export interface RequestOptions {
  readonly method: HttpMethod;
  readonly path: string;
  readonly params?: Readonly<Record<string, string>>;
  readonly query?: Readonly<Record<string, string | number | undefined>>;
  readonly body?: unknown;
  readonly idempotencyKey?: string;
  readonly retry?: boolean;
}

export interface HttpResult<T> {
  readonly status: number;
  readonly body: T;
  readonly headers: Headers;
  readonly idempotencyKey: string | null;
}

const AUTH_REFRESH_CODES = new Set(['auth_expired_token', 'auth_invalid_token']);

/** The one HTTP path of the SDK: boundary check, subscriber token, Relay-Version, Idempotency-Key reuse and retries of retryable errors only. */
export class RelayHttp {
  private readonly maxRetries: number;

  constructor(private readonly config: HttpConfig) {
    this.maxRetries = config.maxRetries ?? 3;
  }

  get baseUrl(): string {
    return this.config.baseUrl.replace(/\/+$/, '');
  }

  url(path: string, params?: Readonly<Record<string, string>>, query?: RequestOptions['query']) {
    const filled = path.replace(/\{([a-z_]+)\}/g, (_match, name: string) => {
      const value = params?.[name];
      if (value === undefined) throw new Error(`missing path parameter ${name}`);
      return encodeURIComponent(value);
    });
    const search = Object.entries(query ?? {})
      .filter((entry): entry is [string, string | number] => entry[1] !== undefined)
      .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`)
      .join('&');
    return `${this.baseUrl}${filled}${search ? `?${search}` : ''}`;
  }

  // X-31
  // X-29
  async request<T>(options: RequestOptions): Promise<HttpResult<T>> {
    const operation = allowedOperation(options.method, options.path);
    if (!operation) throw boundaryError(options.method, options.path);
    const url = this.url(options.path, options.params, options.query);
    const idempotencyKey = operation.idempotencyKey
      ? (options.idempotencyKey ?? this.config.random.uuid())
      : null;
    const retries = options.retry === false ? 0 : this.maxRetries;
    let refreshed = false;
    let attempt = 0;
    for (;;) {
      const token = await this.config.tokens.get(false);
      let response: Response;
      try {
        response = await this.config.fetch(url, {
          method: options.method,
          headers: this.headers(token.token, idempotencyKey, options.body !== undefined),
          ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
        });
      } catch {
        const error = networkError();
        if (attempt < retries) {
          await sleep(this.config.clock, fullJitter(attempt, this.config.random));
          attempt += 1;
          continue;
        }
        throw error;
      }
      if (response.ok) {
        const body = (await readJson(response)) as T;
        return { status: response.status, body, headers: response.headers, idempotencyKey };
      }
      const problem = (await readJson(response)) as Problem | null;
      const retryAfterMs = parseRetryAfter(
        response.headers.get('Retry-After'),
        this.config.clock.now(),
      );
      const error = errorFromProblem(
        response.status,
        problem,
        response.headers.get('Request-Id'),
        retryAfterMs,
      );
      if (response.status === 401 && !refreshed && AUTH_REFRESH_CODES.has(error.code ?? '')) {
        refreshed = true;
        await this.config.tokens.get(true);
        continue;
      }
      if (error.retryable && attempt < retries) {
        this.config.logger.debug('relay.http.retry', {
          status: response.status,
          code: error.code,
          attempt,
        });
        await sleep(this.config.clock, retryAfterMs ?? fullJitter(attempt, this.config.random));
        attempt += 1;
        continue;
      }
      throw error;
    }
  }

  private headers(token: string, idempotencyKey: string | null, hasBody: boolean) {
    const headers: Record<string, string> = {
      Accept: 'application/json',
      Authorization: `Bearer ${token}`,
      'Relay-Version': API_VERSION,
    };
    if (hasBody) headers['Content-Type'] = 'application/json';
    if (idempotencyKey !== null) headers['Idempotency-Key'] = idempotencyKey;
    return headers;
  }
}

async function readJson(response: Response): Promise<unknown> {
  if (response.status === 204) return null;
  const text = await response.text();
  if (text === '') return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return null;
  }
}
