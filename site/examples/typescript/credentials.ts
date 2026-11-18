import { createECDH, createHash } from "node:crypto";

const curve = { name: "ECDSA", namedCurve: "P-256" } as const;

const seed = createHash("sha256").update("relay-dev-dpop-es256").digest();
const ecdh = createECDH("prime256v1");
ecdh.setPrivateKey(seed);
const point = ecdh.getPublicKey();
const publicJwk = {
  kty: "EC",
  crv: "P-256",
  x: point.subarray(1, 33).toString("base64url"),
  y: point.subarray(33, 65).toString("base64url"),
};

export const keyPair: CryptoKeyPair = {
  privateKey: await crypto.subtle.importKey(
    "jwk",
    { ...publicJwk, d: seed.toString("base64url") },
    curve,
    false,
    ["sign"],
  ),
  publicKey: await crypto.subtle.importKey("jwk", publicJwk, curve, true, ["verify"]),
};

export const relayUrl = process.env.RELAY ?? "http://localhost:4000";

export function getAccessToken(): string {
  const token = process.env.TOKEN;
  if (!token) throw new Error("TOKEN is not set: run `export TOKEN=$(mix relay.dev.token)`");
  return token;
}
