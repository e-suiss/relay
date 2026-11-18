import { durationSeconds } from "../../lib/duration";

export interface TierLike {
  after: string;
  repeat?: number;
}

export interface TierSpan {
  tier: number;
  repeat: number;
  opensAt: number;
}

// AG-17
/** When each tier and each of its repeats opens, in seconds from the start: a tier waits its `after` from the previous one, and a repeat waits the same interval again. Null when a duration is not valid. */
export function tierSpans(tiers: readonly TierLike[]): TierSpan[] | null {
  const spans: TierSpan[] = [];
  let clock = 0;
  for (const [index, tier] of tiers.entries()) {
    const seconds = durationSeconds(tier.after);
    if (seconds === null) return null;
    for (let repeat = 0; repeat <= (tier.repeat ?? 0); repeat += 1) {
      clock += seconds;
      spans.push({ tier: index, repeat, opensAt: clock });
    }
  }
  return spans;
}
