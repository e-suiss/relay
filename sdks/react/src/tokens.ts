import { RelayUsageError } from "@esuiss/relay/browser";

/** A function that returns a narrow Relay token. */
export type TokenProvider = () => Promise<string> | string;

/** The two narrow token kinds the components accept (X-32, WH-47). */
export type NarrowTokenKind = "subscriber" | "portal";

const expectedTyp: Readonly<Record<NarrowTokenKind, string>> = {
  subscriber: "relay-subscriber+jwt",
  portal: "relay-webhook-portal+jwt",
};

function decodeSegment(segment: string): unknown {
  const padded = segment
    .replace(/-/g, "+")
    .replace(/_/g, "/")
    .padEnd(Math.ceil(segment.length / 4) * 4, "=");
  return JSON.parse(atob(padded)) as unknown;
}

/** The `typ` of a JWT's protected header, or null when the value is not a JWT. */
export function tokenType(token: string): string | null {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[0] === undefined) return null;
  try {
    const header = decodeSegment(parts[0]);
    if (typeof header !== "object" || header === null) return null;
    const typ = (header as { typ?: unknown }).typ;
    return typeof typ === "string" ? typ : null;
  } catch {
    return null;
  }
}

/**
 * Checks that a token is the narrow token of its kind (X-32): a subscriber token from the token exchange or a webhook portal token minted by the tenant backend. Anything else, such as an Access token or a secret, is refused before it is sent.
 */
export function assertNarrowToken(kind: NarrowTokenKind, token: string): string {
  if (tokenType(token) !== expectedTyp[kind]) {
    throw new RelayUsageError(
      "narrow_token_required",
      kind === "subscriber"
        ? "The components take only a Relay subscriber token; never pass an Access token or a secret."
        : "The webhook portal takes only a Relay portal token minted by your backend; never pass an Access token or a secret.",
    );
  }
  return token;
}

/** Wraps a provider so every token it returns is checked with {@link assertNarrowToken}. */
export function narrowTokenProvider(kind: NarrowTokenKind, provider: TokenProvider): TokenProvider {
  return async () => assertNarrowToken(kind, await provider());
}
