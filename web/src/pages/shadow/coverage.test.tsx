import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { ShadowCoverage, ShadowCoverageRow } from "../../api/pending";
import { I18nProvider } from "../../i18n/i18n";
import {
  criteria,
  expiresSoon,
  expiryAfter,
  needsAttention,
  orderRows,
  validDays,
  type RowOrder,
} from "./coverage";
import { CoverageSummary, ShadowScopeNotice } from "./Shadow";

function row(overrides: Partial<ShadowCoverageRow>): ShadowCoverageRow {
  return {
    template: "welcome",
    locale: "tr-TR",
    channel: "email",
    observed: 120,
    decision_differences: 0,
    explained: 0,
    unexplained: 0,
    content_differences: 0,
    routing_differences: 0,
    sufficient: true,
    ...overrides,
  };
}

function coverage(overrides: Partial<ShadowCoverage>): ShadowCoverage {
  return {
    object: "shadow_coverage",
    window_days: 14,
    first_observed_at: "2026-11-01T09:00:00Z",
    days_observed: 17,
    cycles_met: true,
    unexplained_decision_differences: 0,
    active_intentional_differences: 1,
    exit_criteria_met: true,
    rows: [row({})],
    ...overrides,
  };
}

describe("OP-79 shadow exit criteria", () => {
  it("meets every criterion when all combinations are sufficient, the cycles passed and nothing is unexplained", () => {
    expect(criteria(coverage({}))).toEqual({
      combinations: true,
      days: true,
      unexplained: true,
      sufficient: 1,
      total: 1,
    });
  });

  it("fails the coverage criterion for an insufficient or missing combination", () => {
    const partial = coverage({
      rows: [row({}), row({ template: "reset", sufficient: false })],
    });
    expect(criteria(partial).combinations).toBe(false);
    expect(criteria(partial).sufficient).toBe(1);
    expect(criteria(coverage({ rows: [] })).combinations).toBe(false);
  });

  it("fails on too few days and on unexplained decision differences", () => {
    const failing = criteria(
      coverage({ cycles_met: false, unexplained_decision_differences: 2 }),
    );
    expect(failing.days).toBe(false);
    expect(failing.unexplained).toBe(false);
  });

  it("flags insufficient rows and rows with unexplained differences", () => {
    expect(needsAttention(row({}))).toBe(false);
    expect(needsAttention(row({ sufficient: false }))).toBe(true);
    expect(needsAttention(row({ unexplained: 1 }))).toBe(true);
  });

  it("keeps the received order or orders by attention", () => {
    const rows = [
      row({ template: "b", observed: 300 }),
      row({ template: "a", observed: 5, unexplained: 1 }),
      row({ template: "c", observed: 40, unexplained: 3 }),
    ];
    const templates = (order: RowOrder) =>
      orderRows(rows, order).map((item) => item.template);
    expect(templates("received")).toEqual(["b", "a", "c"]);
    expect(templates("unexplained")).toEqual(["c", "a", "b"]);
    expect(templates("observed")).toEqual(["a", "c", "b"]);
    expect(templates("combination")).toEqual(["a", "b", "c"]);
    expect(rows.map((item) => item.template)).toEqual(["b", "a", "c"]);
  });
});

describe("OP-79 intentional difference expiry", () => {
  const now = new Date("2026-11-18T10:00:00Z");

  it("hints an expiry under three days ahead", () => {
    expect(expiresSoon("2026-11-20T10:00:00Z", now)).toBe(true);
    expect(expiresSoon("2026-11-21T11:00:00Z", now)).toBe(false);
    expect(expiresSoon("2026-11-18T09:00:00Z", now)).toBe(false);
  });

  it("accepts at most thirty whole days", () => {
    expect(validDays(1)).toBe(true);
    expect(validDays(30)).toBe(true);
    expect(validDays(0)).toBe(false);
    expect(validDays(31)).toBe(false);
    expect(validDays(2.5)).toBe(false);
    expect(validDays(Number.NaN)).toBe(false);
    expect(expiryAfter(now, 30)).toBe("2026-12-18T10:00:00.000Z");
  });
});

describe("OP-52 shadow summary", () => {
  it("names each criterion with a text verdict and the agreement-only scope", () => {
    render(
      <I18nProvider locale="en">
        <ShadowScopeNotice />
        <CoverageSummary
          coverage={coverage({
            exit_criteria_met: false,
            unexplained_decision_differences: 2,
          })}
        />
      </I18nProvider>,
    );
    expect(screen.getByText("Exit criteria not met")).toBeDefined();
    expect(screen.getAllByText("Met")).toHaveLength(2);
    expect(screen.getAllByText("Not met")).toHaveLength(1);
    expect(
      screen.getByText("No unexplained decision differences (2 now)."),
    ).toBeDefined();
    expect(screen.getByRole("note").textContent).toMatch(
      /agreement with the existing system, not delivery quality/,
    );
  });
});
