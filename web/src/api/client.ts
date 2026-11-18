import type { Environment, Problem } from "./types";

export type Method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

export type QueryValue = string | number | boolean | null | undefined;

export interface RequestContext {
  tenant: string | null;
  environment: Environment | null;
  csrf: string | null;
}

export interface RequestOptions {
  query?: Record<string, QueryValue>;
  body?: unknown;
  idempotencyKey?: string;
  signal?: AbortSignal;
  context?: RequestContext;
}

/** An API answer that is not a success, carrying the RFC 9457 problem when the server sent one. */
export class ApiError extends Error {
  readonly status: number;
  readonly problem: Problem | null;

  constructor(status: number, problem: Problem | null) {
    super(problem?.title ?? `HTTP ${status}`);
    this.name = "ApiError";
    this.status = status;
    this.problem = problem;
  }

  get code(): string | null {
    return this.problem?.code ?? null;
  }
}

const mutating: readonly Method[] = ["POST", "PUT", "PATCH", "DELETE"];

/** A fresh Idempotency-Key for one user action; a retry of the same action reuses it. */
export function idempotencyKey(): string {
  return crypto.randomUUID();
}

export function buildUrl(
  path: string,
  query: Record<string, QueryValue> = {},
): string {
  const params = new URLSearchParams();
  for (const [name, value] of Object.entries(query)) {
    if (value !== undefined && value !== null && value !== "") {
      params.append(name, String(value));
    }
  }
  const search = params.toString();
  return search === "" ? path : `${path}?${search}`;
}

export function buildHeaders(
  method: Method,
  context: RequestContext | undefined,
  hasBody: boolean,
  key: string | undefined,
): Headers {
  const headers = new Headers({ accept: "application/json" });
  if (hasBody) headers.set("content-type", "application/json");
  if (context?.tenant) headers.set("relay-tenant", context.tenant);
  if (context?.environment)
    headers.set("relay-environment", context.environment);
  if (mutating.includes(method)) {
    if (context?.csrf) headers.set("relay-csrf-token", context.csrf);
    headers.set("idempotency-key", key ?? idempotencyKey());
  }
  return headers;
}

async function readProblem(response: Response): Promise<Problem | null> {
  const type = response.headers.get("content-type") ?? "";
  if (!type.includes("json")) return null;
  try {
    return (await response.json()) as Problem;
  } catch {
    return null;
  }
}

/** Calls the Relay API from the console origin with the operator session cookie. */
export async function request<T>(
  method: Method,
  path: string,
  options: RequestOptions = {},
): Promise<T> {
  const hasBody = options.body !== undefined;
  const init: RequestInit = {
    method,
    credentials: "same-origin",
    headers: buildHeaders(
      method,
      options.context,
      hasBody,
      options.idempotencyKey,
    ),
  };
  if (hasBody) init.body = JSON.stringify(options.body);
  if (options.signal) init.signal = options.signal;

  const response = await fetch(buildUrl(path, options.query), init);
  if (!response.ok)
    throw new ApiError(response.status, await readProblem(response));
  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

export const loginPath = "/v1/operator/session/login";

export function loginUrl(returnTo: string): string {
  return buildUrl(loginPath, { return_to: returnTo });
}
