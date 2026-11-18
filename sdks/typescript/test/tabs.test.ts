import { describe, expect, it } from "vitest";
import {
  badgeFromPayload,
  formatBadge,
  handleNotificationClick,
  handlePush,
  type ServiceWorkerScopeLike,
  type WindowClientLike,
} from "../src/browser/service-worker.js";
import {
  TabCoordinator,
  type BroadcastChannelLike,
  type LockManagerLike,
} from "../src/browser/tabs.js";

class FakeLocks implements LockManagerLike {
  readonly #queues = new Map<string, (() => void)[]>();
  readonly #held = new Set<string>();

  request(
    name: string,
    options: { signal?: AbortSignal },
    callback: (lock: unknown) => Promise<void>,
  ): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const run = () => {
        this.#held.add(name);
        void callback({}).then(() => {
          this.#held.delete(name);
          resolve(undefined);
          this.#queues.get(name)?.shift()?.();
        });
      };
      if (!this.#held.has(name)) {
        run();
        return;
      }
      const queue = this.#queues.get(name) ?? [];
      queue.push(run);
      this.#queues.set(name, queue);
      options.signal?.addEventListener("abort", () => {
        const index = queue.indexOf(run);
        if (index !== -1) queue.splice(index, 1);
        reject(new Error("aborted"));
      });
    });
  }
}

class FakeHub {
  readonly channels: FakeChannel[] = [];
  create = (name: string): BroadcastChannelLike => {
    const channel = new FakeChannel(name, this);
    this.channels.push(channel);
    return channel;
  };
}

class FakeChannel implements BroadcastChannelLike {
  onmessage: ((event: { readonly data: unknown }) => void) | null = null;

  constructor(
    readonly name: string,
    readonly hub: FakeHub,
  ) {}

  postMessage(message: unknown): void {
    for (const channel of this.hub.channels) {
      if (channel !== this && channel.name === this.name) channel.onmessage?.({ data: message });
    }
  }

  close(): void {
    const index = this.hub.channels.indexOf(this);
    if (index !== -1) this.hub.channels.splice(index, 1);
  }
}

const settle = async (): Promise<void> => {
  for (let index = 0; index < 10; index++) await new Promise((resolve) => setTimeout(resolve, 0));
};

function tab(locks: LockManagerLike, hub: FakeHub, log: string[], label: string): TabCoordinator {
  return new TabCoordinator({
    name: "inbox",
    locks,
    createChannel: hub.create,
    onLeader: () => log.push(`${label}:leader`),
    onFollower: () => log.push(`${label}:follower`),
    onMessage: (message) => log.push(`${label}:got:${String(message)}`),
  });
}

describe("IN-36 multi-tab", () => {
  it("IN-36: one tab leads and shares its stream; another takes over when it steps down", async () => {
    const locks = new FakeLocks();
    const hub = new FakeHub();
    const log: string[] = [];
    const first = tab(locks, hub, log, "a");
    const second = tab(locks, hub, log, "b");
    first.start();
    await settle();
    second.start();
    await settle();
    expect(first.leader).toBe(true);
    expect(second.leader).toBe(false);
    first.publish("e1");
    second.publish("ignored");
    expect(log).toContain("b:got:e1");
    expect(log).not.toContain("a:got:ignored");
    first.release();
    await settle();
    expect(second.leader).toBe(true);
    expect(first.leader).toBe(false);
    second.publish("e2");
    expect(log).toContain("a:got:e2");
    first.stop();
    second.stop();
  });

  it("IN-36: without Web Locks every tab leads alone", () => {
    const log: string[] = [];
    const solo = new TabCoordinator({
      name: "inbox",
      locks: null,
      createChannel: null,
      onLeader: () => log.push("leader"),
      onFollower: () => log.push("follower"),
      onMessage: () => undefined,
    });
    solo.start();
    expect(solo.leader).toBe(true);
    expect(log).toEqual(["leader"]);
  });
});

describe("IN-20 IN-36 service worker helpers", () => {
  function scope(windows: WindowClientLike[]) {
    const calls: string[] = [];
    const value: ServiceWorkerScopeLike = {
      location: { origin: "https://app.example.com" },
      registration: {
        showNotification: async (title, options) => {
          calls.push(`show:${title}:${JSON.stringify(options)}`);
        },
      },
      clients: {
        matchAll: async () => windows,
        openWindow: async (url) => {
          calls.push(`open:${url}`);
        },
      },
      navigator: {
        setAppBadge: async (count) => {
          calls.push(`badge:${count}`);
        },
        clearAppBadge: async () => {
          calls.push("badge:clear");
        },
      },
      addEventListener: () => undefined,
    };
    return { value, calls };
  }

  it("IN-20: the badge is the absolute count of the push and the in-app badge caps at 99+", () => {
    expect(
      badgeFromPayload({
        web_push: 8030,
        notification: { title: "t", navigate: "https://x", app_badge: "12" },
      }),
    ).toBe(12);
    expect(badgeFromPayload({ counters: { unseen: 3 } })).toBe(3);
    expect(badgeFromPayload({ notification: { app_badge: "-1" } })).toBeNull();
    expect(badgeFromPayload(null)).toBeNull();
    expect(formatBadge(100)).toBe("99+");
    expect(formatBadge(7)).toBe("7");
  });

  it("IN-36: a push updates the badge and shows its notification", async () => {
    const { value, calls } = scope([]);
    await handlePush(value, {
      web_push: 8030,
      notification: { title: "Hello", navigate: "https://app.example.com/inbox", app_badge: "0" },
    });
    expect(calls[0]).toBe("badge:clear");
    expect(calls[1]).toContain("show:Hello");
    expect(calls[1]).toContain("https://app.example.com/inbox");
  });

  it("IN-36: a click focuses an open tab of the app instead of opening another", async () => {
    const focused: string[] = [];
    const windows: WindowClientLike[] = [
      {
        url: "https://app.example.com/home",
        focus: async () => focused.push("focus"),
        navigate: async (url) => focused.push(`navigate:${url}`),
      },
    ];
    const { value, calls } = scope(windows);
    let closed = false;
    await handleNotificationClick(value, {
      data: { navigate: "https://app.example.com/inbox/inb_1" },
      close: () => {
        closed = true;
      },
    });
    expect(closed).toBe(true);
    expect(focused).toEqual(["navigate:https://app.example.com/inbox/inb_1", "focus"]);
    expect(calls).toEqual([]);
    const empty = scope([]);
    await handleNotificationClick(empty.value, {
      data: { navigate: "/inbox" },
      close: () => undefined,
    });
    expect(empty.calls).toEqual(["open:https://app.example.com/inbox"]);
  });
});
