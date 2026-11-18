import type { Authenticate } from "./core/transport.js";

/** Options of the DPoP authenticator. */
export interface DpopAuthenticatorOptions {
  /** Returns a current Access access token bound to `keyPair` (client credentials at Access). */
  readonly accessToken: () => Promise<string> | string;
  /** The ES256 (P-256) key pair the access token is bound to. */
  readonly keyPair: CryptoKeyPair;
  readonly now?: () => number;
}

const encoder = new TextEncoder();

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlJson(value: unknown): string {
  return base64url(encoder.encode(JSON.stringify(value)));
}

/**
 * Authorization for the server API: `Authorization: DPoP <token>` and a fresh RFC 9449 proof (`htm`, `htu` without query and fragment, `ath`, `jti`, `iat`) for every attempt, signed with ES256.
 */
export function dpopAuthenticator(options: DpopAuthenticatorOptions): Authenticate {
  const subtle = globalThis.crypto.subtle;
  let jwk: Promise<JsonWebKey> | null = null;

  return async ({ method, url }) => {
    jwk ??= subtle.exportKey("jwk", options.keyPair.publicKey);
    const publicJwk = await jwk;
    const token = await options.accessToken();
    const target = new URL(url);
    const htu = `${target.origin}${target.pathname}`;
    const ath = base64url(new Uint8Array(await subtle.digest("SHA-256", encoder.encode(token))));
    const header = {
      typ: "dpop+jwt",
      alg: "ES256",
      jwk: { kty: publicJwk.kty, crv: publicJwk.crv, x: publicJwk.x, y: publicJwk.y },
    };
    const claims = {
      htm: method.toUpperCase(),
      htu,
      ath,
      jti: globalThis.crypto.randomUUID(),
      iat: Math.floor((options.now ?? Date.now)() / 1000),
    };
    const input = `${base64urlJson(header)}.${base64urlJson(claims)}`;
    const signature = await subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      options.keyPair.privateKey,
      encoder.encode(input),
    );
    return {
      authorization: `DPoP ${token}`,
      dpop: `${input}.${base64url(new Uint8Array(signature))}`,
    };
  };
}
