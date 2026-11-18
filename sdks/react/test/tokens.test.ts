import { RelayUsageError } from "@esuiss/relay/browser";
import { describe, expect, it } from "vitest";
import { RelayRuntime } from "../src/runtime.js";
import { createFakeRelay, fakeToken } from "../src/testing/index.js";
import { assertNarrowToken, tokenType } from "../src/tokens.js";

describe("X-32 narrow tokens only", () => {
  it("X-32 accepts the subscriber and the portal token", () => {
    const subscriber = fakeToken("relay-subscriber+jwt");
    const portal = fakeToken("relay-webhook-portal+jwt");
    expect(tokenType(subscriber)).toBe("relay-subscriber+jwt");
    expect(assertNarrowToken("subscriber", subscriber)).toBe(subscriber);
    expect(assertNarrowToken("portal", portal)).toBe(portal);
  });

  it("X-32 refuses an Access token, a secret and the other narrow token", () => {
    expect(() => assertNarrowToken("subscriber", fakeToken("at+jwt"))).toThrow(RelayUsageError);
    expect(() => assertNarrowToken("subscriber", "whsec_c2VjcmV0")).toThrow(RelayUsageError);
    expect(() => assertNarrowToken("subscriber", fakeToken("relay-webhook-portal+jwt"))).toThrow(RelayUsageError);
    expect(() => assertNarrowToken("portal", fakeToken("relay-subscriber+jwt"))).toThrow(RelayUsageError);
  });

  it("X-32 a wide token never leaves the browser", async () => {
    const relay = createFakeRelay();
    const runtime = new RelayRuntime({
      baseUrl: "https://relay.example.com",
      token: () => fakeToken("at+jwt"),
      fetch: relay.fetch,
      realtime: false,
      storage: null,
    });
    await expect(runtime.subscriber?.call("getMyPreferences")).rejects.toThrow(RelayUsageError);
    expect(relay.requests).toHaveLength(0);
  });

  it("WH-47 the portal client sends the portal token", async () => {
    const relay = createFakeRelay();
    const runtime = new RelayRuntime({
      baseUrl: "https://relay.example.com",
      portalToken: relay.portalToken,
      fetch: relay.fetch,
    });
    await runtime.portal?.call("listPortalWebhookEndpoints");
    expect(relay.requests[0]?.authorization).toBe(`Bearer ${relay.portalToken()}`);
    expect(runtime.subscriber).toBeNull();
  });
});
