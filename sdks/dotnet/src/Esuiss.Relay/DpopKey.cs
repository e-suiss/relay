using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Esuiss.Relay;

/// <summary>An Ed25519 key that proves possession of DPoP-bound Access tokens (RFC 9449).</summary>
public sealed class DpopKey
{
    private readonly Ed25519PrivateKeyParameters _privateKey;

    private DpopKey(byte[] seed)
    {
        _privateKey = new Ed25519PrivateKeyParameters(seed, 0);
        PublicKey = _privateKey.GeneratePublicKey().GetEncoded();
    }

    /// <summary>The raw 32-byte public key.</summary>
    public byte[] PublicKey { get; }

    /// <summary>The public key as a JWK.</summary>
    public JsonObject Jwk => new()
    {
        ["kty"] = "OKP",
        ["crv"] = "Ed25519",
        ["x"] = Base64Url.Encode(PublicKey),
    };

    /// <summary>Generates a new key.</summary>
    public static DpopKey Generate() => new(RandomNumberGenerator.GetBytes(32));

    /// <summary>Restores a key from its 32-byte seed.</summary>
    public static DpopKey FromSeed(ReadOnlySpan<byte> seed)
    {
        if (seed.Length != 32)
        {
            throw new ArgumentException("an Ed25519 seed is 32 bytes", nameof(seed));
        }

        return new DpopKey(seed.ToArray());
    }

    /// <summary>Creates a DPoP proof for one request.</summary>
    /// <param name="method">The HTTP method of the request.</param>
    /// <param name="url">The request URL; its query and fragment are left out of the proof.</param>
    /// <param name="accessToken">The access token the request carries, or null at the token endpoint.</param>
    /// <param name="now">The current time.</param>
    /// <param name="nonce">A nonce the server asked for, or null.</param>
    public string CreateProof(string method, Uri url, string? accessToken, DateTimeOffset now, string? nonce = null)
    {
        ArgumentNullException.ThrowIfNull(method);
        ArgumentNullException.ThrowIfNull(url);

        var header = new JsonObject
        {
            ["typ"] = "dpop+jwt",
            ["alg"] = "Ed25519",
            ["jwk"] = Jwk,
        };
        var claims = new JsonObject
        {
            ["htm"] = method,
            ["htu"] = url.GetLeftPart(UriPartial.Path),
            ["iat"] = now.ToUnixTimeSeconds(),
            ["jti"] = Base64Url.Encode(RandomNumberGenerator.GetBytes(16)),
        };
        if (accessToken is not null)
        {
            claims["ath"] = Base64Url.Encode(SHA256.HashData(Encoding.ASCII.GetBytes(accessToken)));
        }

        if (nonce is not null)
        {
            claims["nonce"] = nonce;
        }

        var input = Base64Url.Encode(Encoding.UTF8.GetBytes(header.ToJsonString())) + "." +
            Base64Url.Encode(Encoding.UTF8.GetBytes(claims.ToJsonString()));
        return input + "." + Base64Url.Encode(Sign(Encoding.ASCII.GetBytes(input)));
    }

    private byte[] Sign(byte[] message)
    {
        var signer = new Ed25519Signer();
        signer.Init(true, _privateKey);
        signer.BlockUpdate(message, 0, message.Length);
        return signer.GenerateSignature();
    }
}

internal static class Base64Url
{
    internal static string Encode(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    internal static byte[] Decode(string text)
    {
        var padded = text.Replace('-', '+').Replace('_', '/');
        padded += (padded.Length % 4) switch
        {
            2 => "==",
            3 => "=",
            _ => "",
        };
        return Convert.FromBase64String(padded);
    }
}
