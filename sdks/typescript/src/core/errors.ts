import { errorCatalog, retryableDefaults } from "../generated/errors.js";

/** The five classes of the typed error hierarchy. */
export type ErrorClass = "auth" | "validation" | "rate_limit" | "idempotency" | "server";

/** One field error of a validation problem. */
export interface FieldError {
  readonly pointer: string;
  readonly code: string;
  readonly detail?: string;
}

/** An RFC 9457 problem document as Relay sends it. */
export interface Problem {
  readonly type: string;
  readonly title: string;
  readonly status: number;
  readonly code: string;
  readonly retryable: boolean;
  readonly detail?: string;
  readonly instance?: string;
  readonly request_id?: string;
  readonly retry_after?: number;
  readonly errors?: readonly FieldError[];
  readonly [extension: string]: unknown;
}

const familyClasses: Readonly<Record<string, ErrorClass>> = {
  auth: "auth",
  quota: "rate_limit",
  idempotency: "idempotency",
  platform: "server",
};

/** The class of an error response: by the catalog family of its code, else by its status. */
export function errorClassOf(status: number, code: string | null): ErrorClass {
  const entry = code === null ? undefined : errorCatalog[code];
  if (entry !== undefined) {
    return familyClasses[entry.family] ?? (entry.status >= 500 ? "server" : "validation");
  }
  if (status === 401 || status === 403) return "auth";
  if (status === 429) return "rate_limit";
  if (status >= 500) return "server";
  return "validation";
}

/** Whether an error response may be retried: the problem's own `retryable`, else the status default. */
export function retryableOf(status: number, problem: Problem | null): boolean {
  if (problem !== null) return problem.retryable;
  const entry = retryableDefaults.find((item) => item.status === status && item.code === null);
  return entry?.retryable ?? false;
}

/** Reads a problem document from a response body; anything else gives null. */
export function parseProblem(body: unknown): Problem | null {
  let value = body;
  if (typeof value === "string") {
    try {
      value = JSON.parse(value);
    } catch {
      return null;
    }
  }
  if (typeof value !== "object" || value === null) return null;
  const candidate = value as Record<string, unknown>;
  if (typeof candidate.code !== "string" || typeof candidate.retryable !== "boolean") return null;
  return candidate as unknown as Problem;
}

/** Base class of every error the SDK throws. */
export class RelayError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = new.target.name;
  }
}

/** The API answered with an error status. */
export class RelayApiError extends RelayError {
  readonly status: number;
  readonly code: string | null;
  readonly errorClass: ErrorClass;
  readonly retryable: boolean;
  readonly retryAfterSeconds: number | null;
  readonly requestId: string | null;
  readonly problem: Problem | null;
  readonly fieldErrors: readonly FieldError[];

  constructor(init: {
    status: number;
    problem: Problem | null;
    requestId: string | null;
    retryAfterSeconds: number | null;
  }) {
    const { status, problem } = init;
    super(problem?.detail ?? problem?.title ?? `Relay answered ${status}`);
    this.status = status;
    this.code = problem?.code ?? null;
    this.errorClass = errorClassOf(status, this.code);
    this.retryable = retryableOf(status, problem);
    this.retryAfterSeconds = init.retryAfterSeconds;
    this.requestId = problem?.request_id ?? init.requestId;
    this.problem = problem;
    this.fieldErrors = problem?.errors ?? [];
  }
}

/** Credentials are missing, invalid, expired or lack a scope. */
export class AuthenticationError extends RelayApiError {}

/** The request is invalid, names something missing or conflicts with the current state. */
export class ValidationError extends RelayApiError {}

/** A rate limit or a quota was exceeded. */
export class RateLimitError extends RelayApiError {}

/** The Idempotency-Key is missing, invalid, reused with another body or still in progress. */
export class IdempotencyError extends RelayApiError {}

/** Relay or a dependency failed. */
export class ServerError extends RelayApiError {}

/** The request never got a response: network failure or timeout. */
export class RelayConnectionError extends RelayError {}

/** The SDK was called in a way it cannot serve. */
export class RelayUsageError extends RelayError {
  readonly reason: string;

  constructor(reason: string, message: string) {
    super(message);
    this.reason = reason;
  }
}

/** Builds the typed error of an error response. */
export function createApiError(init: {
  status: number;
  body: unknown;
  requestId: string | null;
  retryAfterSeconds: number | null;
}): RelayApiError {
  const problem = parseProblem(init.body);
  const args = {
    status: init.status,
    problem,
    requestId: init.requestId,
    retryAfterSeconds: init.retryAfterSeconds ?? problem?.retry_after ?? null,
  };
  switch (errorClassOf(init.status, problem?.code ?? null)) {
    case "auth":
      return new AuthenticationError(args);
    case "rate_limit":
      return new RateLimitError(args);
    case "idempotency":
      return new IdempotencyError(args);
    case "server":
      return new ServerError(args);
    case "validation":
      return new ValidationError(args);
  }
}
