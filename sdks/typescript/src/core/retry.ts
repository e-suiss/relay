import { retryableOf, type Problem } from "./errors.js";

/** When and how long the SDK retries. */
export interface RetryPolicy {
  /** Retries after the first attempt. */
  readonly maxRetries: number;
  /** First backoff ceiling in milliseconds; it doubles per retry. */
  readonly baseMs: number;
  /** Highest backoff ceiling in milliseconds. */
  readonly capMs: number;
  /** A Retry-After longer than this is not waited for; the error is surfaced. */
  readonly maxRetryAfterS: number;
}

/** The default policy, shared by every Relay SDK through the conformance vectors. */
export const defaultRetryPolicy: RetryPolicy = Object.freeze({
  maxRetries: 3,
  baseMs: 500,
  capMs: 8000,
  maxRetryAfterS: 60,
});

/** What one attempt produced. */
export type AttemptOutcome =
  | { readonly kind: "network" }
  | {
      readonly kind: "response";
      readonly status: number;
      readonly retryAfter: string | null;
      readonly problem: Problem | null;
    };

/** Whether to retry, and after how long. */
export type RetryDecision =
  | { readonly retry: true; readonly delayMs: number }
  | {
      readonly retry: false;
      readonly reason: "not_retryable" | "retries_exhausted" | "retry_after_too_long";
    };

const imfFixdate = /^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$/;

/** Exponential backoff with full jitter for the given retry (counted from 1). */
export function backoffDelay(retry: number, random: number, policy: RetryPolicy): number {
  const ceiling = Math.min(policy.capMs, policy.baseMs * 2 ** (retry - 1));
  return Math.floor(random * ceiling);
}

/** Parses a Retry-After value (delta seconds or HTTP-date) into milliseconds; null when unparseable. */
export function parseRetryAfter(value: string | null, nowMs: number): number | null {
  if (value === null) return null;
  const text = value.trim();
  if (/^\d+$/.test(text)) return Number(text) * 1000;
  if (imfFixdate.test(text)) {
    const at = Date.parse(text);
    if (Number.isNaN(at)) return null;
    return Math.max(0, at - nowMs);
  }
  return null;
}

/** Decides whether the attempt that produced `outcome` is followed by retry number `retry`. */
export function decideRetry(
  outcome: AttemptOutcome,
  retry: number,
  policy: RetryPolicy,
  nowMs: number,
  random: number,
): RetryDecision {
  if (outcome.kind === "response" && !retryableOf(outcome.status, outcome.problem)) {
    return { retry: false, reason: "not_retryable" };
  }
  if (retry > policy.maxRetries) return { retry: false, reason: "retries_exhausted" };
  if (outcome.kind === "network") {
    return { retry: true, delayMs: backoffDelay(retry, random, policy) };
  }
  const header = parseRetryAfter(outcome.retryAfter, nowMs);
  const body =
    typeof outcome.problem?.retry_after === "number" ? outcome.problem.retry_after * 1000 : null;
  const wait = header ?? body;
  if (wait === null) return { retry: true, delayMs: backoffDelay(retry, random, policy) };
  if (wait > policy.maxRetryAfterS * 1000) return { retry: false, reason: "retry_after_too_long" };
  return { retry: true, delayMs: wait };
}
