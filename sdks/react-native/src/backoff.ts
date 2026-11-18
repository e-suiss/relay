import type { Random } from './ports';

export const BACKOFF_BASE_MS = 1_000;
export const BACKOFF_CAP_MS = 60_000;

// IN-34
// IN-52
/** Full-jitter exponential backoff: a uniform delay between zero and min(cap, base * 2^attempt). */
export function fullJitter(
  attempt: number,
  random: Random,
  baseMs: number = BACKOFF_BASE_MS,
  capMs: number = BACKOFF_CAP_MS,
): number {
  const ceiling = Math.min(capMs, baseMs * 2 ** Math.max(0, attempt));
  return Math.floor(random.float() * ceiling);
}

/** Resolves after `ms` on the given clock. */
export function sleep(
  clock: { setTimeout(callback: () => void, ms: number): unknown },
  ms: number,
): Promise<void> {
  return new Promise((resolve) => {
    clock.setTimeout(resolve, ms);
  });
}
