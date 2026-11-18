using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Esuiss.Relay.Tests;

public sealed class CredentialsTests
{
    private static byte[] B64(string text)
    {
        var padded = text.Replace('-', '+').Replace('_', '/');
        padded += (padded.Length % 4) switch { 2 => "==", 3 => "=", _ => "" };
        return Convert.FromBase64String(padded);
    }

    private static (JsonNode Header, JsonNode Claims) Decode(string proof, byte[] publicKey)
    {
        var parts = proof.Split('.');
        Assert.Equal(3, parts.Length);
        var verifier = new Ed25519Signer();
        verifier.Init(false, new Ed25519PublicKeyParameters(publicKey, 0));
        var input = Encoding.ASCII.GetBytes(parts[0] + "." + parts[1]);
        verifier.BlockUpdate(input, 0, input.Length);
        Assert.True(verifier.VerifySignature(B64(parts[2])));
        return (JsonNode.Parse(B64(parts[0]))!, JsonNode.Parse(B64(parts[1]))!);
    }

    [Fact]
    public void X_29_a_dpop_proof_is_signed_and_names_the_request()
    {
        var key = DpopKey.FromSeed(Enumerable.Range(0, 32).Select(i => (byte)i).ToArray());
        var now = DateTimeOffset.FromUnixTimeSeconds(1_793_784_600);

        var proof = key.CreateProof("POST", new Uri("https://relay.example.com/v1/events?x=1#f"), "token-1", now, "n-1");
        var (header, claims) = Decode(proof, key.PublicKey);

        Assert.Equal("dpop+jwt", header["typ"]!.GetValue<string>());
        Assert.Equal("Ed25519", header["alg"]!.GetValue<string>());
        Assert.Equal("OKP", header["jwk"]!["kty"]!.GetValue<string>());
        Assert.Equal(key.PublicKey, B64(header["jwk"]!["x"]!.GetValue<string>()));
        Assert.Equal("POST", claims["htm"]!.GetValue<string>());
        Assert.Equal("https://relay.example.com/v1/events", claims["htu"]!.GetValue<string>());
        Assert.Equal(1_793_784_600, claims["iat"]!.GetValue<long>());
        Assert.Equal(16, B64(claims["jti"]!.GetValue<string>()).Length);
        Assert.Equal(SHA256.HashData(Encoding.ASCII.GetBytes("token-1")), B64(claims["ath"]!.GetValue<string>()));
        Assert.Equal("n-1", claims["nonce"]!.GetValue<string>());

        var second = key.CreateProof("POST", new Uri("https://relay.example.com/v1/events"), "token-1", now);
        Assert.NotEqual(claims["jti"]!.GetValue<string>(), Decode(second, key.PublicKey).Claims["jti"]!.GetValue<string>());
    }

    [Fact]
    public async Task X_29_access_client_credentials_follow_the_dpop_nonce_and_cache_the_token()
    {
        using var handler = new StubHandler();
        handler
            .Json(400, """{"error":"use_dpop_nonce"}""", ("DPoP-Nonce", "nonce-1"))
            .Json(200, """{"access_token":"at-1","token_type":"DPoP","expires_in":600}""");
        using var http = new HttpClient(handler);
        var key = DpopKey.Generate();
        using var credentials = new AccessClientCredentials(
            new Uri("https://access.example.com/oauth2/token"), "cli id", "secret", "relay-client", key, "read", http);

        var first = await credentials.AuthorizeAsync("GET", new Uri("https://relay.example.com/v1/waitpoints"), CancellationToken.None);
        var second = await credentials.AuthorizeAsync("GET", new Uri("https://relay.example.com/v1/waitpoints"), CancellationToken.None);

        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("DPoP at-1", first.Single(h => h.Key == "Authorization").Value);
        Assert.Equal("DPoP at-1", second.Single(h => h.Key == "Authorization").Value);
        var token = handler.Requests[1];
        Assert.Equal("grant_type=client_credentials&resource=relay-client&scope=read", token.Body);
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("cli%20id:secret")), token.Headers["Authorization"]);
        var (_, claims) = Decode(token.Headers["DPoP"], key.PublicKey);
        Assert.Equal("nonce-1", claims["nonce"]!.GetValue<string>());
        Assert.Null(claims["ath"]);

        var (_, requestClaims) = Decode(first.Single(h => h.Key == "DPoP").Value, key.PublicKey);
        Assert.Equal("https://relay.example.com/v1/waitpoints", requestClaims["htu"]!.GetValue<string>());
    }

    [Fact]
    public async Task X_29_a_bearer_token_from_access_is_refused()
    {
        using var handler = new StubHandler();
        handler.Json(200, """{"access_token":"at-1","token_type":"Bearer","expires_in":600}""");
        using var http = new HttpClient(handler);
        using var credentials = new AccessClientCredentials(
            new Uri("https://access.example.com/oauth2/token"), "cli", "secret", "relay-client", DpopKey.Generate(), null, http);

        await Assert.ThrowsAsync<RelayAuthenticationException>(async () =>
            await credentials.AuthorizeAsync("GET", new Uri("https://relay.example.com/v1/waitpoints"), CancellationToken.None));
    }
}
