import { RelaySubscriberClient } from "@esuiss/relay/browser";
import { describe, expect, it } from "vitest";
import {
  apiDisplayedSender,
  DisplayedReporter,
  notificationDigest,
  type DisplayedBatch,
} from "../src/displayed.js";
import { RelayRuntime } from "../src/runtime.js";
import { createFakeRelay } from "../src/testing/index.js";

const start = Date.parse("2026-11-18T12:00:00Z");

function harness(options: { fail?: () => boolean; gate?: () => Promise<void> } = {}) {
  let now = start;
  let keys = 0;
  const sent: DisplayedBatch[] = [];
  const timers: { callback: () => void; ms: number; cancelled: boolean }[] = [];
  const hidden: (() => void)[] = [];
  const reporter = new DisplayedReporter({
    send: (batch) => {
      sent.push(batch);
      if (options.fail?.() === true) return Promise.reject(new Error("offline"));
      return options.gate?.() ?? Promise.resolve();
    },
    now: () => now,
    newKey: () => `key_${++keys}`,
    digest: (id) => Promise.resolve(`digest:${id}`),
    setTimer: (callback, ms) => {
      const entry = { callback, ms, cancelled: false };
      timers.push(entry);
      return () => {
        entry.cancelled = true;
      };
    },
    onHidden: (callback) => {
      hidden.push(callback);
      return () => undefined;
    },
  });
  const fireTimer = async () => {
    const entry = timers.filter((timer) => !timer.cancelled).at(-1);
    entry?.callback();
    await reporter.flush();
  };
  return {
    reporter,
    sent,
    timers,
    hidden,
    fireTimer,
    advance: (ms: number) => {
      now += ms;
    },
  };
}

describe("OP-54 OP-95 displayed notification digests", () => {
  it("OP-95 digests an identifier as lowercase hex SHA-256 of its UTF-8 bytes", async () => {
    expect(await notificationDigest("abc")).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
    expect(await notificationDigest("ntf_01")).toMatch(/^[0-9a-f]{64}$/);
  });

  it("OP-54 sends a batch once 20 displays are queued", async () => {
    const { reporter, sent } = harness();
    for (let index = 0; index < 19; index++) await reporter.report(`ntf_${index}`);
    expect(sent).toHaveLength(0);
    await reporter.report("ntf_19");
    await reporter.flush();
    expect(sent).toHaveLength(1);
    expect(sent[0]?.notifications).toHaveLength(20);
    expect(sent[0]?.notifications[0]).toEqual({
      digest: "digest:ntf_0",
      displayed_at: "2026-11-18T12:00:00.000Z",
    });
    expect(reporter.queued).toBe(0);
  });

  it("OP-54 sends what is queued 30 seconds later", async () => {
    const { reporter, sent, timers, fireTimer } = harness();
    await reporter.report("ntf_1");
    expect(timers.map((timer) => timer.ms)).toEqual([30_000]);
    await fireTimer();
    expect(sent.map((batch) => batch.notifications.length)).toEqual([1]);
  });

  it("OP-54 sends what is queued when the page becomes hidden", async () => {
    const { reporter, sent, hidden } = harness();
    await reporter.report("ntf_1");
    expect(hidden).toHaveLength(1);
    hidden[0]?.();
    await reporter.flush();
    expect(sent).toHaveLength(1);
  });

  it("OP-54 reports the same identifier displayed twice twice", async () => {
    const { reporter, sent } = harness();
    await reporter.report("ntf_1");
    await reporter.report("ntf_1");
    await reporter.flush();
    expect(sent[0]?.notifications.map((entry) => entry.digest)).toEqual([
      "digest:ntf_1",
      "digest:ntf_1",
    ]);
  });

  it("OP-54 sends at most 100 per request", async () => {
    let release: () => void = () => undefined;
    let held = true;
    const { reporter, sent } = harness({
      gate: () =>
        held
          ? new Promise<void>((resolve) => {
              release = resolve;
            })
          : Promise.resolve(),
    });
    for (let index = 0; index < 20; index++) await reporter.report(`ntf_${index}`);
    const first = reporter.flush();
    for (let index = 20; index < 150; index++) await reporter.report(`ntf_${index}`);
    held = false;
    release();
    await first;
    await reporter.flush();
    expect(sent.map((batch) => batch.notifications.length)).toEqual([20, 100, 30]);
    expect(reporter.queued).toBe(0);
  });

  it("OP-54 a failed batch is sent again with the same Idempotency-Key", async () => {
    let failing = true;
    const { reporter, sent } = harness({ fail: () => failing });
    await reporter.report("ntf_1");
    await reporter.flush();
    await reporter.report("ntf_2");
    failing = false;
    await reporter.flush();
    expect(sent.map((batch) => batch.key)).toEqual(["key_1", "key_1", "key_2"]);
    expect(sent[1]?.notifications).toEqual(sent[0]?.notifications);
    expect(reporter.queued).toBe(0);
  });

  it("OP-54 drops a batch older than 24 hours", async () => {
    let failing = true;
    const { reporter, sent, advance } = harness({ fail: () => failing });
    await reporter.report("ntf_1");
    await reporter.flush();
    advance(86_400_000);
    failing = false;
    await reporter.flush();
    expect(sent).toHaveLength(1);
    expect(reporter.queued).toBe(0);
  });

  it("OP-54 posts the digests with the subscriber token and the batch key", async () => {
    const relay = createFakeRelay();
    const client = new RelaySubscriberClient({
      baseUrl: "https://relay.example.com",
      token: relay.token,
      fetch: relay.fetch,
    });
    const digest = await notificationDigest("ntf_1");
    await apiDisplayedSender(client)({
      key: "6f1c9e0a-1111-4222-8333-944445555666",
      createdAt: start,
      notifications: [{ digest, displayed_at: "2026-11-18T12:00:00.000Z" }],
    });
    const request = relay.requests.at(-1);
    expect(request?.method).toBe("POST");
    expect(request?.path).toBe("/v1/subscriber/displayed_notifications");
    expect(request?.idempotencyKey).toBe("6f1c9e0a-1111-4222-8333-944445555666");
    expect(request?.authorization).toMatch(/^Bearer /);
    expect(request?.body).toEqual({
      notifications: [{ digest, displayed_at: "2026-11-18T12:00:00.000Z" }],
    });
    expect(JSON.stringify(request?.body)).not.toContain("ntf_1");
  });

  it("OP-54 reporting is off unless the runtime turns it on", () => {
    const relay = createFakeRelay();
    const off = new RelayRuntime({ baseUrl: "https://relay.example.com", token: relay.token });
    expect(off.displayed).toBeNull();
    expect(() => off.reportDisplayed("ntf_1")).not.toThrow();
    const on = new RelayRuntime({
      baseUrl: "https://relay.example.com",
      token: relay.token,
      reportDisplayedNotifications: true,
    });
    expect(on.displayed).toBeInstanceOf(DisplayedReporter);
    on.displayed?.stop();
  });
});
