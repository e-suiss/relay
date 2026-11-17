import { RelayError, RelayUsageError } from "./core/errors.js";

/** Why a webhook message was refused. */
export type WebhookRejection =
  | "missing_header"
  | "duplicate_header"
  | "malformed_header"
  | "timestamp_out_of_tolerance"
  | "no_matching_signature";

/** A webhook message failed verification; `reason` names the check. */
export class WebhookVerificationError extends RelayError {
  readonly reason: WebhookRejection;

  constructor(reason: WebhookRejection) {
    super(`Webhook verification failed: ${reason}`);
    this.reason = reason;
  }
}

/** Request headers as they arrived: a Headers object, a plain object or name/value pairs. */
export type HeadersInput =
  | Headers
  | Readonly<Record<string, string | readonly string[] | undefined>>
  | Iterable<readonly [string, string]>;

/** The raw request body: the bytes that arrived, never a body parsed and serialised again. */
export type RawBody = Uint8Array | ArrayBuffer | string;

/** A verified message. */
export interface VerifiedWebhook {
  readonly id: string;
  readonly timestamp: number;
  readonly scheme: "v1a" | "v1";
}

/** Options of the verifier. */
export interface VerifyWebhookOptions {
  /** Current time in Unix seconds; defaults to the clock. */
  readonly now?: number;
  /** Allowed distance between now and webhook-timestamp, in seconds. */
  readonly toleranceS?: number;
}

type Token = { readonly scheme: "v1a" | "v1"; readonly signature: Uint8Array<ArrayBuffer> };

type ParsedKey =
  | { readonly kind: "ed25519"; readonly bytes: Uint8Array<ArrayBuffer> }
  | { readonly kind: "hmac"; readonly bytes: Uint8Array<ArrayBuffer> };

const idSyntax = /^[\x21-\x7E]{1,256}$/;
const timestampSyntax = /^(?:0|[1-9][0-9]{0,14})$/;
const otherScheme = /^v[0-9][0-9a-z]{0,7},[A-Za-z0-9+/=_-]+$/;
const base64Syntax = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const encoder = new TextEncoder();

/** Default timestamp tolerance of the Suiss webhook profile, in seconds. */
export const DEFAULT_WEBHOOK_TOLERANCE_S = 300;

function decodeBase64(text: string): Uint8Array<ArrayBuffer> | null {
  if (!base64Syntax.test(text)) return null;
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function parseKey(text: string): ParsedKey {
  if (text.startsWith("whpk_")) {
    const bytes = decodeBase64(text.slice(5));
    if (bytes !== null && bytes.length === 32) return { kind: "ed25519", bytes };
  } else if (text.startsWith("whsec_")) {
    const bytes = decodeBase64(text.slice(6));
    if (bytes !== null && bytes.length >= 24) return { kind: "hmac", bytes };
  }
  throw new RelayUsageError("invalid_webhook_key", "A webhook key is whpk_<base64> or whsec_<base64>.");
}

function headerValues(headers: HeadersInput, name: string): string[] {
  if (typeof Headers !== "undefined" && headers instanceof Headers) {
    const value = headers.get(name);
    return value === null ? [] : [value];
  }
  const values: string[] = [];
  const entries: Iterable<readonly [string, unknown]> =
    Symbol.iterator in headers
      ? (headers as Iterable<readonly [string, string]>)
      : Object.entries(headers as Record<string, unknown>);
  for (const [key, value] of entries) {
    if (key.toLowerCase() !== name) continue;
    if (Array.isArray(value)) values.push(...(value as string[]));
    else if (typeof value === "string") values.push(value);
  }
  return values;
}

function header(headers: HeadersInput, name: string): string {
  const values = headerValues(headers, name);
  if (values.length === 0) throw new WebhookVerificationError("missing_header");
  if (values.length > 1) throw new WebhookVerificationError("duplicate_header");
  return values[0] as string;
}

/** Parses a webhook-signature value. Tokens of unknown schemes are skipped; a malformed token refuses the header. */
export function parseSignatureHeader(value: string): Token[] {
  const parts = value.split(" ").filter((part) => part !== "");
  if (parts.length === 0) throw new WebhookVerificationError("malformed_header");
  const tokens: Token[] = [];
  for (const part of parts) {
    let scheme: "v1a" | "v1" | null = null;
    let encoded = "";
    let size = 0;
    if (part.startsWith("v1a,")) {
      scheme = "v1a";
      encoded = part.slice(4);
      size = 64;
    } else if (part.startsWith("v1,")) {
      scheme = "v1";
      encoded = part.slice(3);
      size = 32;
    }
    if (scheme === null) {
      if (otherScheme.test(part)) continue;
      throw new WebhookVerificationError("malformed_header");
    }
    const signature = decodeBase64(encoded);
    if (signature === null || signature.length !== size) {
      throw new WebhookVerificationError("malformed_header");
    }
    tokens.push({ scheme, signature });
  }
  return tokens;
}

function bodyBytes(body: RawBody): Uint8Array {
  if (typeof body === "string") return encoder.encode(body);
  if (body instanceof ArrayBuffer) return new Uint8Array(body);
  return body;
}

/** The signed content of a message: `<id>.<timestamp>.<raw body>`. */
export function signedContent(id: string, timestamp: number, body: RawBody): Uint8Array<ArrayBuffer> {
  const prefix = encoder.encode(`${id}.${timestamp}.`);
  const raw = bodyBytes(body);
  const content = new Uint8Array(prefix.length + raw.length);
  content.set(prefix, 0);
  content.set(raw, prefix.length);
  return content;
}

async function valid(token: Token, key: ParsedKey, content: Uint8Array<ArrayBuffer>): Promise<boolean> {
  const subtle = globalThis.crypto.subtle;
  if (token.scheme === "v1a" && key.kind === "ed25519") {
    const cryptoKey = await subtle.importKey("raw", key.bytes, { name: "Ed25519" }, false, ["verify"]);
    return subtle.verify({ name: "Ed25519" }, cryptoKey, token.signature, content);
  }
  if (token.scheme === "v1" && key.kind === "hmac") {
    const cryptoKey = await subtle.importKey(
      "raw",
      key.bytes,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return subtle.verify("HMAC", cryptoKey, token.signature, content);
  }
  return false;
}

/**
 * Verifies a message of the Suiss webhook profile shared by Access and Relay (X-29, WH-4): `webhook-id`, `webhook-timestamp` and `webhook-signature` over the raw body, `v1a` (Ed25519, the default) or `v1` (HMAC-SHA-256). Keys are `whpk_…` public keys or `whsec_…` secrets; during a rotation pass every key. Accepts when any signature verifies against any key; throws `WebhookVerificationError` otherwise.
 */
export async function verifyWebhook(
  headers: HeadersInput,
  rawBody: RawBody,
  keys: string | readonly string[],
  options: VerifyWebhookOptions = {},
): Promise<VerifiedWebhook> {
  const parsedKeys = (typeof keys === "string" ? [keys] : keys).map(parseKey);
  const id = header(headers, "webhook-id");
  const timestampText = header(headers, "webhook-timestamp");
  const signatureText = header(headers, "webhook-signature");
  if (!idSyntax.test(id) || !timestampSyntax.test(timestampText)) {
    throw new WebhookVerificationError("malformed_header");
  }
  const timestamp = Number(timestampText);
  const tokens = parseSignatureHeader(signatureText);
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const tolerance = options.toleranceS ?? DEFAULT_WEBHOOK_TOLERANCE_S;
  if (Math.abs(now - timestamp) > tolerance) {
    throw new WebhookVerificationError("timestamp_out_of_tolerance");
  }
  const content = signedContent(id, timestamp, rawBody);
  for (const token of tokens) {
    for (const key of parsedKeys) {
      if (await valid(token, key, content)) return { id, timestamp, scheme: token.scheme };
    }
  }
  throw new WebhookVerificationError("no_matching_signature");
}
