using System.Text.Json.Nodes;

namespace Esuiss.Relay.Tests;

public sealed class WebhookVerifierTests
{
    private static readonly JsonNode Vectors = Repo.Json("conformance/webhooks/vectors/1/signature.json");

    private static string PublicKey => Vectors["keys"]!["ed25519_public_key"]!.GetValue<string>();

    private static string HmacKey => Vectors["keys"]!["hmac_secret"]!.GetValue<string>();

    private static TimeSpan Tolerance => TimeSpan.FromSeconds(Vectors["tolerance_s"]!.GetValue<int>());

    private static IEnumerable<JsonNode> Cases => Vectors["cases"]!.AsArray().Select(c => c!);

    private static JsonNode Case(string name) => Cases.Single(c => c["name"]!.GetValue<string>() == name);

    private static byte[] Body(string hex) => Convert.FromHexString(hex);

    private static List<KeyValuePair<string, string>> Headers(string id, long timestamp, string signature) =>
    [
        new("Webhook-Id", id),
        new("webhook-timestamp", timestamp.ToString(System.Globalization.CultureInfo.InvariantCulture)),
        new("WEBHOOK-SIGNATURE", signature),
    ];

    private static WebhookVerifier Verifier(params string[] keys) => new(keys, Tolerance);

    [Fact]
    public void WH_4_signed_content_matches_every_vector()
    {
        foreach (var vector in Cases)
        {
            var content = WebhookVerifier.SignedContent(
                vector["webhook_id"]!.GetValue<string>(),
                vector["webhook_timestamp"]!.GetValue<long>(),
                Body(vector["body_hex"]!.GetValue<string>()));
            Assert.Equal(vector["signed_content_hex"]!.GetValue<string>(), Convert.ToHexStringLower(content));
        }
    }

    [Fact]
    public void WH_4_every_vector_verifies_with_its_key_alone_or_together()
    {
        foreach (var vector in Cases)
        {
            var id = vector["webhook_id"]!.GetValue<string>();
            var timestamp = vector["webhook_timestamp"]!.GetValue<long>();
            var body = Body(vector["body_hex"]!.GetValue<string>());
            var v1a = vector["v1a"]!.GetValue<string>();
            var v1 = vector["v1"]!.GetValue<string>();
            var now = DateTimeOffset.FromUnixTimeSeconds(timestamp);

            Assert.Equal(WebhookScheme.V1a, Verifier(PublicKey).Verify(Headers(id, timestamp, v1a), body, now).Scheme);
            Assert.Equal(WebhookScheme.V1, Verifier(HmacKey).Verify(Headers(id, timestamp, v1), body, now).Scheme);

            foreach (var keys in new[] { new[] { PublicKey }, new[] { HmacKey }, new[] { HmacKey, PublicKey } })
            {
                var verified = Verifier(keys).Verify(Headers(id, timestamp, v1 + " " + v1a), body, now);
                Assert.Equal(id, verified.Id);
                Assert.Equal(timestamp, verified.Timestamp);
            }
        }
    }

    [Fact]
    public void WH_4_every_shared_rejection_is_refused_with_either_key()
    {
        foreach (var rejection in Vectors["rejections"]!.AsArray().Select(r => r!))
        {
            var vector = Case(rejection["case"]!.GetValue<string>());
            var id = rejection["webhook_id"]?.GetValue<string>() ?? vector["webhook_id"]!.GetValue<string>();
            var timestamp = vector["webhook_timestamp"]!.GetValue<long>();
            var now = rejection["now"]?.GetValue<long>() ?? timestamp;
            var body = Body(rejection["body_hex"]?.GetValue<string>() ?? vector["body_hex"]!.GetValue<string>());
            var signature = rejection["swap_versions"]?.GetValue<bool>() == true
                ? "v1," + vector["v1a"]!.GetValue<string>()[4..] + " v1a," + vector["v1"]!.GetValue<string>()[3..]
                : vector["v1a"]!.GetValue<string>() + " " + vector["v1"]!.GetValue<string>();

            foreach (var key in new[] { PublicKey, HmacKey })
            {
                Assert.Throws<WebhookVerificationException>(() =>
                    Verifier(key).Verify(Headers(id, timestamp, signature), body, DateTimeOffset.FromUnixTimeSeconds(now)));
            }
        }
    }

    [Fact]
    public void WH_7_the_tolerance_holds_in_both_directions()
    {
        var vector = Case("standard-webhooks-reference-body");
        var id = vector["webhook_id"]!.GetValue<string>();
        var timestamp = vector["webhook_timestamp"]!.GetValue<long>();
        var body = Body(vector["body_hex"]!.GetValue<string>());
        var headers = Headers(id, timestamp, vector["v1"]!.GetValue<string>());
        var verifier = Verifier(HmacKey);

        verifier.Verify(headers, body, DateTimeOffset.FromUnixTimeSeconds(timestamp + 300));
        verifier.Verify(headers, body, DateTimeOffset.FromUnixTimeSeconds(timestamp - 300));
        var late = Assert.Throws<WebhookVerificationException>(() =>
            verifier.Verify(headers, body, DateTimeOffset.FromUnixTimeSeconds(timestamp + 301)));
        Assert.Equal(WebhookRejection.TimestampOutOfTolerance, late.Rejection);
        var early = Assert.Throws<WebhookVerificationException>(() =>
            verifier.Verify(headers, body, DateTimeOffset.FromUnixTimeSeconds(timestamp - 301)));
        Assert.Equal(WebhookRejection.TimestampOutOfTolerance, early.Rejection);
    }

    [Fact]
    public void WH_7_missing_duplicate_and_malformed_headers_are_refused()
    {
        var vector = Case("standard-webhooks-reference-body");
        var id = vector["webhook_id"]!.GetValue<string>();
        var timestamp = vector["webhook_timestamp"]!.GetValue<long>();
        var body = Body(vector["body_hex"]!.GetValue<string>());
        var now = DateTimeOffset.FromUnixTimeSeconds(timestamp);
        var verifier = Verifier(HmacKey);
        var v1 = vector["v1"]!.GetValue<string>();

        var missing = Headers(id, timestamp, v1);
        missing.RemoveAt(0);
        Assert.Equal(WebhookRejection.MissingHeader, Refused(verifier, missing, body, now));

        var duplicate = Headers(id, timestamp, v1);
        duplicate.Add(new("webhook-id", id));
        Assert.Equal(WebhookRejection.DuplicateHeader, Refused(verifier, duplicate, body, now));

        Assert.Equal(WebhookRejection.MalformedHeader, Refused(verifier, Headers(id, timestamp, "v1,not base64!"), body, now));
        Assert.Equal(WebhookRejection.MalformedHeader, Refused(verifier, Headers("bad id", timestamp, v1), body, now));
        Assert.Equal(WebhookRejection.MalformedHeader, Refused(verifier, Headers(id, timestamp, " "), body, now));

        var unknownScheme = Headers(id, timestamp, "v2,AAAA " + v1);
        Assert.Equal(WebhookScheme.V1, verifier.Verify(unknownScheme, body, now).Scheme);
    }

    [Fact]
    public void WH_4_keys_must_use_the_profile_text_forms()
    {
        Assert.Throws<ArgumentException>(() => new WebhookVerifier(["whsec_c2hvcnQ="]));
        Assert.Throws<ArgumentException>(() => new WebhookVerifier(["whpk_AAAA"]));
        Assert.Throws<ArgumentException>(() => new WebhookVerifier(["secret"]));
    }

    private static WebhookRejection Refused(
        WebhookVerifier verifier,
        List<KeyValuePair<string, string>> headers,
        byte[] body,
        DateTimeOffset now) =>
        Assert.Throws<WebhookVerificationException>(() => verifier.Verify(headers, body, now)).Rejection;
}
