import { describe, expect, it, vi } from "vitest";
import { ApiError, buildHeaders, buildUrl, loginUrl, request } from "./client";

const context = {
  tenant: "ten_01hzx3k5v7m9p2q4r6s8t0w2y4",
  environment: "test" as const,
  csrf: "c".repeat(43),
};

describe("X-47 API client", () => {
  it("sends the tenant and environment context on every request", () => {
    const headers = buildHeaders("GET", context, false, undefined);
    expect(headers.get("relay-tenant")).toBe(context.tenant);
    expect(headers.get("relay-environment")).toBe("test");
    expect(headers.get("relay-csrf-token")).toBeNull();
    expect(headers.get("idempotency-key")).toBeNull();
  });

  it("adds the CSRF token and an Idempotency-Key to mutating requests", () => {
    const headers = buildHeaders("POST", context, true, "key-12345678");
    expect(headers.get("relay-csrf-token")).toBe(context.csrf);
    expect(headers.get("idempotency-key")).toBe("key-12345678");
    expect(headers.get("content-type")).toBe("application/json");
  });

  it("drops empty query values", () => {
    expect(buildUrl("/v1/notifications", { limit: 20, cursor: "" })).toBe(
      "/v1/notifications?limit=20",
    );
  });

  it("returns to the console path after the Access sign-in", () => {
    expect(loginUrl("/console/why")).toBe(
      "/v1/operator/session/login?return_to=%2Fconsole%2Fwhy",
    );
  });

  it("keeps the same Idempotency-Key when an action is retried", async () => {
    const seen: (string | null)[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((_url: string, init: RequestInit) => {
        seen.push(new Headers(init.headers).get("idempotency-key"));
        return Promise.resolve(
          new Response(
            JSON.stringify({
              type: "https://relay.example/v1/errors/internal_error",
              title: "Internal error",
              status: 503,
              code: "service_unavailable",
              retryable: true,
            }),
            {
              status: 503,
              headers: { "content-type": "application/problem+json" },
            },
          ),
        );
      }),
    );
    const options = { body: {}, idempotencyKey: "retry-key-1", context };
    await expect(request("POST", "/v1/events", options)).rejects.toThrow(
      ApiError,
    );
    await expect(request("POST", "/v1/events", options)).rejects.toThrow(
      ApiError,
    );
    expect(seen).toEqual(["retry-key-1", "retry-key-1"]);
  });
});
