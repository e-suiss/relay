import { describe, expect, it } from "vitest";
import type { InboxItem } from "../src/browser/inbox.js";
import { RelaySubscriberClient } from "../src/browser/subscriber.js";
import { noSleep } from "./helpers.js";

function client(answer: (url: URL) => { status: number; body: unknown }, seen: URL[]) {
  return new RelaySubscriberClient({
    baseUrl: "https://relay.example.com",
    token: () => "subscriber-token",
    sleep: noSleep,
    fetch: (input) => {
      const url = new URL(input);
      seen.push(url);
      const { status, body } = answer(url);
      return Promise.resolve(
        new Response(JSON.stringify(body), {
          status,
          headers: {
            "content-type": status >= 400 ? "application/problem+json" : "application/json",
          },
        }),
      );
    },
  });
}

const consent = (id: string, channel: string, status: string) => ({
  object: "consent",
  id,
  brand: null,
  channel,
  status,
  consent_kind: null,
  recipient_type: null,
  source: "access",
  occurred_at: "2026-11-01T09:00:00Z",
});

describe("X-44 CH-33 subscriber operations", () => {
  it("X-44 lists every page of the subscriber's consents read-only", async () => {
    const seen: URL[] = [];
    const relay = client(
      (url) =>
        url.searchParams.get("starting_after") === "c1"
          ? {
              status: 200,
              body: {
                object: "list",
                data: [consent("cns_2", "sms", "revoked")],
                has_more: false,
                next_cursor: null,
              },
            }
          : {
              status: 200,
              body: {
                object: "list",
                data: [consent("cns_1", "email", "active")],
                has_more: true,
                next_cursor: "c1",
              },
            },
      seen,
    );
    const consents = (await relay.paginate("listMyConsents").toArray()) as {
      channel: string;
      status: string;
    }[];
    expect(consents.map((entry) => [entry.channel, entry.status])).toEqual([
      ["email", "active"],
      ["sms", "revoked"],
    ]);
    expect(seen.every((url) => url.pathname === "/v1/subscriber/consents")).toBe(true);
  });

  it("CH-33 fetches the content of a content-free push by its delivery id", async () => {
    const seen: URL[] = [];
    const relay = client(
      () => ({
        status: 200,
        body: {
          object: "push_content",
          delivery_id: "dlv_1",
          notification_id: "ntf_1",
          channel: "web_push",
          locale: "en",
          content: { title: "Hello" },
        },
      }),
      seen,
    );
    const content = await relay.call("getMyPushContent", { path: { delivery_id: "dlv_1" } });
    expect(content.content).toEqual({ title: "Hello" });
    expect(seen[0]?.pathname).toBe("/v1/subscriber/push_content/dlv_1");
  });

  it("AG-35 an inbox item carries its sender type, approval flag and waitpoint typed", () => {
    const item: InboxItem = {
      id: "inb_1",
      state_version: 1,
      seen: false,
      read: false,
      archived: false,
      hidden: false,
      expired: false,
      snoozed_until: null,
      sender_type: "agent",
      approval: false,
      waitpoint: {
        id: "wp_1",
        kind: "response",
        status: "awaiting",
        subject_digest: "d1",
        options: [{ label: "Yes", value: "yes" }],
        responder: null,
        responded_at: null,
        approval_url: null,
      },
    };
    expect(item.waitpoint?.options[0]?.value).toBe("yes");
    expect(item.sender_type).toBe("agent");
  });
});
