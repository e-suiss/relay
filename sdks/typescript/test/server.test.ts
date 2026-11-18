import { describe, expect, it } from "vitest";
import { RelayAgent } from "../src/agent.js";
import { dpopAuthenticator } from "../src/dpop.js";
import { API_VERSION } from "../src/generated/meta.js";
import { serverOperations } from "../src/generated/operations.js";
import { RelayServerClient } from "../src/server.js";
import { noSleep } from "./helpers.js";

interface Sent {
  readonly url: string;
  readonly method: string;
  readonly headers: Headers;
  readonly body: unknown;
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function client(responses: Response[], sent: Sent[]): RelayServerClient {
  return new RelayServerClient({
    baseUrl: "https://relay.example.com/",
    authenticate: () => ({ authorization: "DPoP token", dpop: "proof" }),
    sleep: noSleep,
    fetch: async (input, init) => {
      sent.push({
        url: input,
        method: init?.method ?? "GET",
        headers: new Headers(init?.headers),
        body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined,
      });
      const next = responses.shift();
      if (next === undefined) throw new Error("no more responses");
      return next;
    },
  });
}

function base64urlDecode(text: string): Uint8Array<ArrayBuffer> {
  const binary = atob(
    text
      .replace(/-/g, "+")
      .replace(/_/g, "/")
      .padEnd(Math.ceil(text.length / 4) * 4, "="),
  );
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

describe("X-29 server client", () => {
  it("X-48: the operation table holds the contract's operations with their idempotency", () => {
    expect(serverOperations.createEvent.method).toBe("POST");
    expect(serverOperations.createEvent.path).toBe("/v1/events");
    expect(serverOperations.createWaitpoint.idempotency).toBe("required");
    expect(serverOperations.getWaitpoint.idempotency).toBe("none");
    expect(serverOperations.listWaitpoints.paginated).toBe(true);
  });

  it("X-29: a read sends the pinned API version, the authorization and no Idempotency-Key", async () => {
    const sent: Sent[] = [];
    const relay = client([json({ object: "waitpoint", id: "wp_1", state: "open" })], sent);
    const waitpoint = await relay.call("getWaitpoint", { path: { waitpoint_id: "wp_1" } });
    expect((waitpoint as { id: string }).id).toBe("wp_1");
    expect(sent[0]?.url).toBe("https://relay.example.com/v1/waitpoints/wp_1");
    expect(sent[0]?.headers.get("relay-version")).toBe(API_VERSION);
    expect(sent[0]?.headers.get("authorization")).toBe("DPoP token");
    expect(sent[0]?.headers.get("dpop")).toBe("proof");
    expect(sent[0]?.headers.get("idempotency-key")).toBeNull();
  });

  it("X-29: a write gets one generated Idempotency-Key that survives a retryable failure", async () => {
    const sent: Sent[] = [];
    const problem = {
      type: "https://relay.example.com/v1/errors/service_unavailable",
      title: "Service unavailable",
      status: 503,
      code: "service_unavailable",
      retryable: true,
    };
    const relay = client(
      [
        json(problem, 503, { "content-type": "application/problem+json", "retry-after": "5" }),
        json({ object: "waitpoint", id: "wp_2", state: "open" }, 201),
      ],
      sent,
    );
    const agent = new RelayAgent(relay);
    const waitpoint = await agent.createWaitpoint({ kind: "event" } as never);
    expect((waitpoint as { id: string }).id).toBe("wp_2");
    expect(sent).toHaveLength(2);
    const key = sent[0]?.headers.get("idempotency-key");
    expect(key).toBeTruthy();
    expect(sent[1]?.headers.get("idempotency-key")).toBe(key);
    expect(sent[0]?.body).toEqual({ kind: "event" });
  });

  it("X-29: lists iterate lazily over cursors with the query they were given", async () => {
    const sent: Sent[] = [];
    const relay = client(
      [
        json({
          object: "list",
          data: [{ id: "wp_3" }],
          has_more: true,
          next_cursor: "c1",
          previous_cursor: null,
        }),
        json({
          object: "list",
          data: [{ id: "wp_4" }],
          has_more: false,
          next_cursor: null,
          previous_cursor: "c0",
        }),
      ],
      sent,
    );
    const ids: string[] = [];
    for await (const item of relay.paginate("listWaitpoints", { query: { limit: 1 } } as never)) {
      ids.push((item as { id: string }).id);
    }
    expect(ids).toEqual(["wp_3", "wp_4"]);
    expect(new URL(sent[0]?.url ?? "").searchParams.get("limit")).toBe("1");
    expect(new URL(sent[1]?.url ?? "").searchParams.get("starting_after")).toBe("c1");
  });
});

describe("X-29 DPoP authenticator", () => {
  it("X-29: every attempt carries a DPoP token and a fresh ES256 proof for the request", async () => {
    const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
      "sign",
      "verify",
    ]);
    const authenticate = dpopAuthenticator({
      accessToken: () => "access-token",
      keyPair,
      now: () => 1_800_000_000_000,
    });
    const first = await authenticate({
      method: "post",
      url: "https://relay.example.com/v1/events?x=1#y",
    });
    const second = await authenticate({
      method: "post",
      url: "https://relay.example.com/v1/events",
    });
    expect(first.authorization).toBe("DPoP access-token");
    const [header, claims, signature] = (first.dpop ?? "").split(".");
    const decodedHeader = JSON.parse(new TextDecoder().decode(base64urlDecode(header ?? "")));
    const decodedClaims = JSON.parse(new TextDecoder().decode(base64urlDecode(claims ?? "")));
    expect(decodedHeader).toMatchObject({
      typ: "dpop+jwt",
      alg: "ES256",
      jwk: { kty: "EC", crv: "P-256" },
    });
    expect(decodedClaims).toMatchObject({
      htm: "POST",
      htu: "https://relay.example.com/v1/events",
      iat: 1_800_000_000,
    });
    const digest = new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode("access-token")),
    );
    expect(base64urlDecode(decodedClaims.ath)).toEqual(digest);
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      keyPair.publicKey,
      base64urlDecode(signature ?? ""),
      new TextEncoder().encode(`${header}.${claims}`),
    );
    expect(valid).toBe(true);
    const secondClaims = JSON.parse(
      new TextDecoder().decode(base64urlDecode((second.dpop ?? "").split(".")[1] ?? "")),
    );
    expect(secondClaims.jti).not.toBe(decodedClaims.jti);
  });
});
