import { describe, expect, it } from "vitest";
import {
  AuthenticationError,
  IdempotencyError,
  RateLimitError,
  RelayApiError,
  RelayUsageError,
  ServerError,
  ValidationError,
  createApiError,
  errorClassOf,
  parseProblem,
  type ErrorClass,
} from "../src/core/errors.js";
import { Paginator, type Page } from "../src/core/pagination.js";
import {
  backoffDelay,
  decideRetry,
  defaultRetryPolicy,
  type AttemptOutcome,
} from "../src/core/retry.js";
import { Transport } from "../src/core/transport.js";
import { errorCatalog, retryableDefaults } from "../src/generated/errors.js";
import { WebhookVerificationError, verifyWebhook } from "../src/webhooks.js";
import {
  hexToBytes,
  noSleep,
  readRepositoryJson,
  readVector,
  toResponse,
  type NetworkError,
  type VectorResponse,
} from "./helpers.js";

interface ErrorsVector {
  readonly catalog: readonly {
    code: string;
    family: string;
    status: number;
    retryable: boolean;
    class: ErrorClass;
  }[];
  readonly status_defaults: readonly { status: number; code?: string; retryable: boolean }[];
  readonly cases: readonly {
    name: string;
    response: VectorResponse;
    expect: {
      class: ErrorClass;
      code: string | null;
      status: number;
      retryable: boolean;
      retry_after_s?: number;
      request_id?: string;
      field_errors?: number;
    };
  }[];
}

interface RetryVector {
  readonly policy: {
    max_retries: number;
    base_ms: number;
    cap_ms: number;
    max_retry_after_s: number;
  };
  readonly backoff: readonly { retry: number; random: number; max_ms: number; delay_ms: number }[];
  readonly decisions: readonly {
    name: string;
    retry: number;
    random: number;
    now: string;
    response?: VectorResponse;
    network_error?: true;
    expect: { retry: true; delay_ms: number } | { retry: false; reason: string };
  }[];
}

interface IdempotencyVector {
  readonly key_length: { min: number; max: number };
  readonly cases: readonly {
    name: string;
    distinct_keys_across_calls?: boolean;
    calls: readonly {
      method: string;
      path: string;
      takes_idempotency_key: boolean;
      caller_idempotency?: string;
      responses: readonly (VectorResponse | NetworkError)[];
      expect: {
        requests: number;
        key_sent: boolean;
        same_key_on_every_request?: boolean;
        sent_idempotency?: string;
        outcome: "success" | "error";
        replayed?: boolean;
        error_class?: ErrorClass;
        error_code?: string;
      };
    }[];
  }[];
}

interface PaginationVector {
  readonly cases: readonly {
    name: string;
    params: Record<string, string | number>;
    take?: number;
    exchanges: readonly { query: Record<string, string>; page: Page<{ id: string }> }[];
    expect: { items: string[]; requests: number };
  }[];
  readonly rejections: readonly { name: string; params: Record<string, string> }[];
}

interface SignatureVector {
  readonly keys: { ed25519_public_key: string; hmac_secret: string };
  readonly tolerance_s: number;
  readonly cases: readonly {
    name: string;
    webhook_id: string;
    webhook_timestamp: number;
    body_hex: string;
    v1a: string;
    v1: string;
  }[];
  readonly rejections: readonly {
    name: string;
    case: string;
    body_hex?: string;
    webhook_id?: string;
    now?: number;
    swap_versions?: boolean;
  }[];
}

interface WebhooksVector {
  readonly signatures: string;
  readonly cases: readonly {
    name: string;
    base: string;
    keys: readonly ("ed25519_public_key" | "hmac_secret")[];
    now?: number;
    body_hex?: string;
    headers: Record<string, string | null>;
    expect: { ok: true; scheme: "v1a" | "v1" } | { ok: false; error: string };
  }[];
}

const errors = readVector<ErrorsVector>("errors");
const retry = readVector<RetryVector>("retry");
const idempotency = readVector<IdempotencyVector>("idempotency");
const pagination = readVector<PaginationVector>("pagination");
const webhooks = readVector<WebhooksVector>("webhooks");
const signatures = readRepositoryJson<SignatureVector>(webhooks.signatures);

const classes: Record<ErrorClass, typeof RelayApiError> = {
  auth: AuthenticationError,
  validation: ValidationError,
  rate_limit: RateLimitError,
  idempotency: IdempotencyError,
  server: ServerError,
};

function outcomeOf(response: VectorResponse | undefined): AttemptOutcome {
  if (response === undefined) return { kind: "network" };
  return {
    kind: "response",
    status: response.status,
    retryAfter: response.headers["retry-after"] ?? null,
    problem: parseProblem(response.body),
  };
}

describe("X-29 error hierarchy against conformance/sdk errors", () => {
  it("X-29: the generated catalog is the vector catalog, code by code", () => {
    expect(Object.keys(errorCatalog).sort()).toEqual(
      errors.catalog.map((entry) => entry.code).sort(),
    );
    for (const entry of errors.catalog) {
      expect(errorCatalog[entry.code]).toEqual({
        family: entry.family,
        status: entry.status,
        retryable: entry.retryable,
      });
      expect(errorClassOf(entry.status, entry.code), entry.code).toBe(entry.class);
    }
  });

  it("API-38: the generated status defaults are the vector status defaults", () => {
    expect(retryableDefaults).toEqual(
      errors.status_defaults.map((entry) => ({
        status: entry.status,
        code: entry.code ?? null,
        retryable: entry.retryable,
      })),
    );
  });

  for (const vector of errors.cases) {
    it(`X-29: ${vector.name}`, () => {
      const retryAfter = vector.response.headers["retry-after"];
      const error = createApiError({
        status: vector.response.status,
        body: vector.response.body,
        requestId: null,
        retryAfterSeconds: retryAfter === undefined ? null : Number(retryAfter),
      });
      expect(error).toBeInstanceOf(classes[vector.expect.class]);
      expect(error).toBeInstanceOf(RelayApiError);
      expect(error.errorClass).toBe(vector.expect.class);
      expect(error.code).toBe(vector.expect.code);
      expect(error.status).toBe(vector.expect.status);
      expect(error.retryable).toBe(vector.expect.retryable);
      if (vector.expect.retry_after_s !== undefined) {
        expect(error.retryAfterSeconds).toBe(vector.expect.retry_after_s);
      }
      if (vector.expect.request_id !== undefined)
        expect(error.requestId).toBe(vector.expect.request_id);
      if (vector.expect.field_errors !== undefined) {
        expect(error.fieldErrors).toHaveLength(vector.expect.field_errors);
      }
    });
  }
});

describe("X-29 retry decisions against conformance/sdk retry", () => {
  const policy = {
    maxRetries: retry.policy.max_retries,
    baseMs: retry.policy.base_ms,
    capMs: retry.policy.cap_ms,
    maxRetryAfterS: retry.policy.max_retry_after_s,
  };

  it("X-29: the default policy is the vector policy", () => {
    expect(defaultRetryPolicy).toEqual(policy);
  });

  it("X-29: backoff is full jitter within the policy bounds", () => {
    for (const vector of retry.backoff) {
      const delay = backoffDelay(vector.retry, vector.random, policy);
      expect(delay).toBe(vector.delay_ms);
      expect(backoffDelay(vector.retry, 0.999999, policy)).toBeLessThan(vector.max_ms);
    }
  });

  for (const vector of retry.decisions) {
    it(`X-29: ${vector.name}`, () => {
      const outcome = vector.network_error ? outcomeOf(undefined) : outcomeOf(vector.response);
      const decision = decideRetry(
        outcome,
        vector.retry,
        policy,
        Date.parse(vector.now),
        vector.random,
      );
      if (vector.expect.retry) {
        expect(decision).toEqual({ retry: true, delayMs: vector.expect.delay_ms });
      } else {
        expect(decision).toEqual({ retry: false, reason: vector.expect.reason });
      }
    });
  }
});

describe("X-29 Idempotency-Key against conformance/sdk idempotency", () => {
  for (const vector of idempotency.cases) {
    it(`API-10: ${vector.name}`, async () => {
      const keysOfCalls: (string | null)[] = [];
      for (const call of vector.calls) {
        const responses = [...call.responses];
        const sent: (string | null)[] = [];
        const transport = new Transport({
          baseUrl: "https://relay.example.com",
          sleep: noSleep,
          random: () => 0.5,
          fetch: async (_input, init) => {
            sent.push(new Headers(init?.headers).get("idempotency-key"));
            const next = responses.shift();
            if (next === undefined) throw new Error("no more responses");
            if ("network_error" in next) throw new TypeError("network down");
            return toResponse(next);
          },
        });
        let outcome: "success" | "error";
        let replayed = false;
        let failure: unknown = null;
        try {
          const response = await transport.request({
            method: call.method,
            path: call.path,
            idempotency: call.takes_idempotency_key ? "required" : "none",
            ...(call.caller_idempotency === undefined
              ? {}
              : { idempotencyKey: call.caller_idempotency }),
            ...(call.method === "GET" ? {} : { body: {} }),
          });
          outcome = "success";
          replayed = response.replayed;
        } catch (error) {
          outcome = "error";
          failure = error;
        }
        const expected = call.expect;
        expect(sent).toHaveLength(expected.requests);
        expect(outcome).toBe(expected.outcome);
        if (expected.replayed !== undefined) expect(replayed).toBe(expected.replayed);
        if (expected.error_class !== undefined) {
          expect(failure).toBeInstanceOf(RelayApiError);
          expect((failure as RelayApiError).errorClass).toBe(expected.error_class);
          expect((failure as RelayApiError).code).toBe(expected.error_code);
        }
        if (!expected.key_sent) {
          expect(sent.every((key) => key === null)).toBe(true);
        } else {
          const first = sent[0] ?? null;
          expect(first).not.toBeNull();
          expect((first as string).length).toBeGreaterThanOrEqual(idempotency.key_length.min);
          expect((first as string).length).toBeLessThanOrEqual(idempotency.key_length.max);
          if (expected.same_key_on_every_request) expect(new Set(sent).size).toBe(1);
          if (expected.sent_idempotency !== undefined)
            expect(first).toBe(expected.sent_idempotency);
        }
        keysOfCalls.push(sent[0] ?? null);
      }
      if (vector.distinct_keys_across_calls) {
        expect(new Set(keysOfCalls).size).toBe(keysOfCalls.length);
      }
    });
  }
});

describe("X-29 lazy pagination against conformance/sdk pagination", () => {
  for (const vector of pagination.cases) {
    it(`API-56: ${vector.name}`, async () => {
      let requests = 0;
      const paginator = new Paginator<{ id: string }>(async (query) => {
        const exchange = vector.exchanges[requests];
        requests++;
        if (exchange === undefined) throw new Error("unexpected request");
        expect(query).toEqual(exchange.query);
        return exchange.page;
      }, vector.params);
      const items =
        vector.take === undefined ? await paginator.toArray() : await paginator.take(vector.take);
      expect(items.map((item) => item.id)).toEqual(vector.expect.items);
      expect(requests).toBe(vector.expect.requests);
    });
  }

  for (const vector of pagination.rejections) {
    it(`API-56: ${vector.name}`, () => {
      let requests = 0;
      let failure: unknown = null;
      const create = () =>
        new Paginator(async () => {
          requests++;
          return { data: [], has_more: false, next_cursor: null };
        }, vector.params);
      try {
        create();
      } catch (error) {
        failure = error;
      }
      expect(failure).toBeInstanceOf(RelayUsageError);
      expect((failure as RelayUsageError).reason).toBe("both_cursors");
      expect(requests).toBe(0);
    });
  }
});

describe("X-29 raw-body webhook verifier against the shared signature vectors", () => {
  const tolerance = signatures.tolerance_s;

  for (const vector of signatures.cases) {
    it(`WH-4: ${vector.name} verifies with v1a and with v1`, async () => {
      const body = hexToBytes(vector.body_hex);
      const headers = {
        "webhook-id": vector.webhook_id,
        "webhook-timestamp": String(vector.webhook_timestamp),
      };
      const now = vector.webhook_timestamp;
      await expect(
        verifyWebhook(
          { ...headers, "webhook-signature": vector.v1a },
          body,
          signatures.keys.ed25519_public_key,
          {
            now,
            toleranceS: tolerance,
          },
        ),
      ).resolves.toEqual({
        id: vector.webhook_id,
        timestamp: vector.webhook_timestamp,
        scheme: "v1a",
      });
      await expect(
        verifyWebhook(
          { ...headers, "webhook-signature": vector.v1 },
          body,
          signatures.keys.hmac_secret,
          {
            now,
            toleranceS: tolerance,
          },
        ),
      ).resolves.toEqual({
        id: vector.webhook_id,
        timestamp: vector.webhook_timestamp,
        scheme: "v1",
      });
    });
  }

  for (const rejection of signatures.rejections) {
    it(`WH-4: ${rejection.name} is refused with either key`, async () => {
      const base = signatures.cases.find((item) => item.name === rejection.case);
      if (base === undefined) throw new Error(`unknown case ${rejection.case}`);
      const signature = rejection.swap_versions
        ? `v1,${base.v1a.slice(4)} v1a,${base.v1.slice(3)}`
        : `${base.v1a} ${base.v1}`;
      const headers = {
        "webhook-id": rejection.webhook_id ?? base.webhook_id,
        "webhook-timestamp": String(base.webhook_timestamp),
        "webhook-signature": signature,
      };
      const body = hexToBytes(rejection.body_hex ?? base.body_hex);
      for (const key of [signatures.keys.ed25519_public_key, signatures.keys.hmac_secret]) {
        await expect(
          verifyWebhook(headers, body, key, {
            now: rejection.now ?? base.webhook_timestamp,
            toleranceS: tolerance,
          }),
        ).rejects.toBeInstanceOf(WebhookVerificationError);
      }
    });
  }

  for (const vector of webhooks.cases) {
    it(`WH-4: ${vector.name}`, async () => {
      const base = signatures.cases.find((item) => item.name === vector.base);
      if (base === undefined) throw new Error(`unknown case ${vector.base}`);
      const merged: Record<string, string | null> = {
        "webhook-id": base.webhook_id,
        "webhook-timestamp": String(base.webhook_timestamp),
        ...vector.headers,
      };
      const headers: [string, string][] = [];
      for (const [name, value] of Object.entries(merged)) {
        if (value !== null)
          headers.push([name, value.replace("{v1a}", base.v1a).replace("{v1}", base.v1)]);
      }
      const keys = vector.keys.map((name) => signatures.keys[name]);
      const body = hexToBytes(vector.body_hex ?? base.body_hex);
      const result = verifyWebhook(headers, body, keys, {
        now: vector.now ?? base.webhook_timestamp,
        toleranceS: signatures.tolerance_s,
      });
      if (vector.expect.ok) {
        await expect(result).resolves.toMatchObject({ scheme: vector.expect.scheme });
      } else {
        await expect(result).rejects.toMatchObject({ reason: vector.expect.error });
      }
    });
  }

  it("WH-4: a body given as text verifies like its bytes", async () => {
    const base = signatures.cases[0];
    if (base === undefined) throw new Error("no case");
    const text = new TextDecoder().decode(hexToBytes(base.body_hex));
    await expect(
      verifyWebhook(
        {
          "webhook-id": base.webhook_id,
          "webhook-timestamp": String(base.webhook_timestamp),
          "webhook-signature": base.v1a,
        },
        text,
        signatures.keys.ed25519_public_key,
        { now: base.webhook_timestamp },
      ),
    ).resolves.toMatchObject({ scheme: "v1a" });
  });
});
