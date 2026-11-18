package app.suiss.relay;

import com.fasterxml.jackson.databind.node.ObjectNode;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.interfaces.EdECPrivateKey;
import java.time.Instant;
import java.util.Arrays;
import java.util.Base64;

/**
 * The Ed25519 key an Access access token is bound to, and the RFC 9449 proofs it signs. Every
 * request carries a fresh proof.
 */
public final class DpopKey {
  private static final Base64.Encoder B64URL = Base64.getUrlEncoder().withoutPadding();

  private final PrivateKey privateKey;
  private final byte[] publicKey;

  private DpopKey(KeyPair pair) {
    if (!(pair.getPrivate() instanceof EdECPrivateKey key)
        || !"Ed25519".equalsIgnoreCase(key.getParams().getName())) {
      throw new IllegalArgumentException("a DPoP key is an Ed25519 key pair");
    }
    byte[] encoded = pair.getPublic().getEncoded();
    this.privateKey = pair.getPrivate();
    this.publicKey = Arrays.copyOfRange(encoded, encoded.length - 32, encoded.length);
  }

  /**
   * Generates a new key.
   *
   * @return the key
   */
  public static DpopKey generate() {
    try {
      return new DpopKey(KeyPairGenerator.getInstance("Ed25519").generateKeyPair());
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException("Ed25519 is not available", e);
    }
  }

  /**
   * Uses an existing Ed25519 key pair, for example one loaded from a key store.
   *
   * @param pair the key pair
   * @return the key
   */
  public static DpopKey of(KeyPair pair) {
    return new DpopKey(pair);
  }

  /**
   * The public key as a JWK.
   *
   * @return a new JWK object
   */
  public ObjectNode jwk() {
    ObjectNode jwk = Json.object();
    jwk.put("kty", "OKP");
    jwk.put("crv", "Ed25519");
    jwk.put("x", B64URL.encodeToString(publicKey));
    return jwk;
  }

  /**
   * The raw 32-byte public key.
   *
   * @return a copy of the public key
   */
  public byte[] publicKey() {
    return publicKey.clone();
  }

  /**
   * Signs a proof for one request.
   *
   * @param method the HTTP method
   * @param url the request URL; query and fragment are left out of {@code htu}
   * @param accessToken the access token the request carries, or null at the token endpoint
   * @param nonce the server nonce, or null
   * @param issuedAt the proof time
   * @param jti 16 or more random bytes, never reused
   * @return the compact JWS
   */
  public String proof(
      String method, URI url, String accessToken, String nonce, Instant issuedAt, byte[] jti) {
    ObjectNode header = Json.object();
    header.put("typ", "dpop+jwt");
    header.put("alg", "Ed25519");
    header.set("jwk", jwk());
    ObjectNode claims = Json.object();
    claims.put("htm", method);
    claims.put("htu", htu(url));
    claims.put("iat", issuedAt.getEpochSecond());
    claims.put("jti", B64URL.encodeToString(jti));
    if (accessToken != null) {
      claims.put("ath", B64URL.encodeToString(sha256(accessToken)));
    }
    if (nonce != null) {
      claims.put("nonce", nonce);
    }
    String input =
        B64URL.encodeToString(Json.writeString(header).getBytes(StandardCharsets.UTF_8))
            + "."
            + B64URL.encodeToString(Json.writeString(claims).getBytes(StandardCharsets.UTF_8));
    try {
      Signature signer = Signature.getInstance("Ed25519");
      signer.initSign(privateKey);
      signer.update(input.getBytes(StandardCharsets.US_ASCII));
      return input + "." + B64URL.encodeToString(signer.sign());
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException("the DPoP proof cannot be signed", e);
    }
  }

  static String htu(URI url) {
    String text = url.toString();
    int cut = text.length();
    int query = text.indexOf('?');
    int fragment = text.indexOf('#');
    if (query >= 0) {
      cut = query;
    }
    if (fragment >= 0 && fragment < cut) {
      cut = fragment;
    }
    return text.substring(0, cut);
  }

  private static byte[] sha256(String value) {
    try {
      return MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.US_ASCII));
    } catch (GeneralSecurityException e) {
      throw new IllegalStateException("SHA-256 is not available", e);
    }
  }
}
