import { describe, expect, it } from "vitest";
import {
  applyPatch,
  categoryRows,
  cellState,
  cellWrite,
  channelColumns,
  digestChoiceWrite,
  needsDigestStep,
  normaliseCell,
  normalisePreferences,
  rowOffWrite,
  validRange,
} from "../src/preferences/model.js";

const base = {
  category: "orders",
  channel: "email",
  value: "unset",
  effective: true,
  source: "class_default",
};

describe("X-51 preference cells", () => {
  it("X-51 reads the lock beneficiary and the administrator's and device settings' states", () => {
    const cell = normaliseCell(
      {
        ...base,
        category_name: "Orders",
        locked: true,
        lock_beneficiary: "tenant",
        digest_allowed: false,
        disabled_by_admin: false,
        disabled_in_device_settings: true,
      },
      {},
    );
    expect(cell).toMatchObject({ category_name: "Orders", locked: true, lock_beneficiary: "tenant", disabled_in_device_settings: true });
  });

  it("X-51 falls back to the source before the cell carries the new fields", () => {
    expect(normaliseCell({ ...base, source: "locked" }, {})).toMatchObject({ locked: true, lock_beneficiary: null, category_name: "orders" });
    expect(normaliseCell({ ...base, source: "tenant", effective: false }, {})).toMatchObject({ disabled_by_admin: true });
    expect(normaliseCell({ ...base, category: "social" }, { social: "instant" })).toMatchObject({ digest_allowed: true });
  });
});

describe("PC-6 PC-15 PC-16 cell states", () => {
  const view = (cell: Record<string, unknown>) => normaliseCell({ ...base, ...cell }, {});
  const plain = { marketing: false, consents: null };

  it("PC-6 a locked cell is a label, not a switch", () => {
    expect(cellState(view({ locked: true }), plain)).toEqual({ kind: "locked", on: true });
  });

  it("PC-15 a cell the administrator turned off cannot be turned on", () => {
    expect(cellState(view({ disabled_by_admin: true, effective: false }), plain)).toEqual({ kind: "admin_off" });
  });

  it("PC-16 a cell off in device settings keeps its switch and its preference", () => {
    expect(cellState(view({ disabled_in_device_settings: true }), plain)).toEqual({
      kind: "switch",
      on: true,
      deviceOff: true,
      digestAllowed: false,
    });
  });

  it("X-18 a missing cell is shown as unavailable", () => {
    expect(cellState(undefined, plain)).toEqual({ kind: "unavailable" });
  });

  it("X-44 a marketing cell without an active consent shows Permission pending", () => {
    const consents = [{ channel: "email", status: "none" as const }];
    expect(cellState(view({}), { marketing: true, consents })).toEqual({ kind: "permission_pending" });
    expect(cellState(view({}), { marketing: true, consents: [{ channel: "email", status: "active" as const }] }).kind).toBe("switch");
    expect(cellState(view({}), { marketing: true, consents: null }).kind).toBe("switch");
  });
});

describe("PC-17 three choices", () => {
  const digestible = normaliseCell({ ...base, category: "social", digest_allowed: true }, {});

  it("PC-17 turning off a digestible cell asks first; turning it on does not", () => {
    expect(needsDigestStep(cellState(digestible, { marketing: false, consents: null }))).toBe(true);
    expect(needsDigestStep(cellState({ ...digestible, value: "opt_out", effective: false }, { marketing: false, consents: null }))).toBe(false);
    expect(needsDigestStep(cellState(normaliseCell(base, {}), { marketing: false, consents: null }))).toBe(false);
  });

  it("PC-17 Instant and Digest keep the cell on, Never turns it off", () => {
    expect(digestChoiceWrite(digestible, "digest", { other: "instant" })).toEqual({ profile: { digest: { other: "instant", social: "digest" } } });
    expect(digestChoiceWrite(digestible, "instant", {})).toEqual({ profile: { digest: { social: "instant" } } });
    expect(digestChoiceWrite(digestible, "never", {})).toEqual({
      preferences: [{ level: "category_channel", category: "social", channel: "email", value: "opt_out" }],
    });
  });
});

describe("X-20 X-22 writes", () => {
  const prefs = normalisePreferences({
    subscriber_id: "sub_1",
    cells: [
      { ...base, channel: "push" },
      { ...base, channel: "web_push" },
      { ...base, channel: "email" },
      { ...base, channel: "sms", value: "opt_out", effective: false },
      { ...base, category: "security", channel: "email", source: "locked", locked: true, lock_beneficiary: "subscriber" },
      { ...base, category: "news", channel: "email", disabled_by_admin: true, effective: false },
    ],
    channels: [],
    workflows: [],
    scope_keys: [],
    profile: { quiet_hours: [], schedule: [], dnd_until: null, quiet_hours_email: false, digest: {} },
  });

  it("X-20 a switch turns on and off with one write each", () => {
    expect(cellWrite({ category: "orders", channel: "email" }, false).preferences).toHaveLength(1);
    expect(cellWrite({ category: "orders", channel: "email" }, true).preferences).toEqual([
      { level: "category_channel", category: "orders", channel: "email", value: "opt_in" },
    ]);
  });

  it("X-22 a row turns off only its open, switchable cells", () => {
    const rows = categoryRows(prefs);
    const orders = rows.find((row) => row.category === "orders");
    const security = rows.find((row) => row.category === "security");
    const news = rows.find((row) => row.category === "news");
    expect(orders === undefined ? null : rowOffWrite(prefs, orders, null)?.preferences?.map((write) => write.channel)).toEqual([
      "push",
      "web_push",
      "email",
    ]);
    expect(security === undefined ? "missing" : rowOffWrite(prefs, security, null)).toBeNull();
    expect(news === undefined ? "missing" : rowOffWrite(prefs, news, null)).toBeNull();
    expect(security?.beneficiary).toBe("subscriber");
  });

  it("X-18 web push and voice get no column of their own", () => {
    expect(channelColumns(prefs)).toEqual(["push", "email", "sms"]);
  });

  it("X-17 applies a write at once", () => {
    const next = applyPatch(prefs, cellWrite({ category: "orders", channel: "email" }, false));
    expect(next.cells.find((cell) => cell.category === "orders" && cell.channel === "email")).toMatchObject({ value: "opt_out", effective: false });
    expect(applyPatch(prefs, { profile: { quiet_hours_email: true } }).profile.quiet_hours_email).toBe(true);
  });

  it("X-18 a time range needs different start and end", () => {
    expect(validRange({ day: "mon", start: "22:00", end: "07:00" })).toBe(true);
    expect(validRange({ day: "mon", start: "09:00", end: "09:00" })).toBe(false);
    expect(validRange({ day: "mon", start: "9:00", end: "10:00" })).toBe(false);
  });
});
