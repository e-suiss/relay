import type { ShadowCoverage, ShadowCoverageRow } from "../../api/pending";

export const maxExpiryDays = 30;
export const soonDays = 3;

const dayMs = 24 * 60 * 60 * 1000;

export type RowOrder = "received" | "observed" | "unexplained" | "combination";

export const rowOrders: readonly RowOrder[] = [
  "received",
  "unexplained",
  "observed",
  "combination",
];

export interface Criteria {
  combinations: boolean;
  days: boolean;
  unexplained: boolean;
  sufficient: number;
  total: number;
}

// OP-52
// OP-79
export function criteria(coverage: ShadowCoverage): Criteria {
  const sufficient = coverage.rows.filter((row) => row.sufficient).length;
  return {
    combinations:
      coverage.rows.length > 0 && sufficient === coverage.rows.length,
    days: coverage.cycles_met,
    unexplained: coverage.unexplained_decision_differences === 0,
    sufficient,
    total: coverage.rows.length,
  };
}

export function combination(row: ShadowCoverageRow): string {
  return `${row.template}/${row.locale}/${row.channel}`;
}

export function orderRows(
  rows: readonly ShadowCoverageRow[],
  order: RowOrder,
): ShadowCoverageRow[] {
  const copy = [...rows];
  switch (order) {
    case "received":
      return copy;
    case "observed":
      return copy.sort((a, b) => a.observed - b.observed);
    case "unexplained":
      return copy.sort(
        (a, b) =>
          b.unexplained - a.unexplained ||
          b.decision_differences - a.decision_differences,
      );
    case "combination":
      return copy.sort((a, b) => combination(a).localeCompare(combination(b)));
  }
}

export function needsAttention(row: ShadowCoverageRow): boolean {
  return !row.sufficient || row.unexplained > 0;
}

// OP-79
export function expiresSoon(expiresAt: string, now: Date): boolean {
  const left = new Date(expiresAt).getTime() - now.getTime();
  return left > 0 && left < soonDays * dayMs;
}

// OP-79
export function validDays(days: number): boolean {
  return Number.isInteger(days) && days >= 1 && days <= maxExpiryDays;
}

// OP-79
export function expiryAfter(now: Date, days: number): string {
  return new Date(now.getTime() + days * dayMs).toISOString();
}
