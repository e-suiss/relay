using System.Globalization;
using System.Text.Json.Nodes;

namespace Esuiss.Relay.Tests;

public sealed class LiveSmokeTests
{
    private static string? Env(string name) => Environment.GetEnvironmentVariable(name);

    [Fact]
    public async Task X_48_live_smoke_sends_an_event_pages_notifications_and_verifies_a_webhook()
    {
        var baseUrl = Env("SDK_LIVE_BASE_URL");
        Assert.SkipUnless(!string.IsNullOrEmpty(baseUrl), "SDK_LIVE_BASE_URL is not set");

        var key = DpopKey.FromSeed(Convert.FromBase64String(Env("SDK_LIVE_DPOP_SEED")!));
        using var client = new RelayClient(new RelayClientOptions
        {
            BaseUrl = new Uri(baseUrl!),
            Credentials = new DpopTokenCredentials(Env("SDK_LIVE_TOKEN")!, key),
        });

        var evt = new JsonObject
        {
            ["workflow"] = Env("SDK_LIVE_WORKFLOW"),
            ["to"] = new JsonArray(Env("SDK_LIVE_RECIPIENT")),
        };
        var accepted = await client.Api.CreateEventAsync(evt, cancellationToken: TestContext.Current.CancellationToken);
        Assert.NotNull(accepted["id"]);

        var page = await client.Api.ListNotificationsAsync(limit: 2, cancellationToken: TestContext.Current.CancellationToken);
        var seen = 0;
        await foreach (var _ in page.AllAsync(TestContext.Current.CancellationToken))
        {
            if (++seen >= 6)
            {
                break;
            }
        }

        var vectors = JsonNode.Parse(await File.ReadAllTextAsync(Env("SDK_LIVE_WEBHOOK_VECTORS")!, TestContext.Current.CancellationToken))!;
        var vector = vectors["cases"]![0]!;
        var timestamp = vector["webhook_timestamp"]!.GetValue<long>();
        var verifier = new WebhookVerifier([vectors["keys"]!["ed25519_public_key"]!.GetValue<string>()]);
        var verified = verifier.Verify(
            [
                new("webhook-id", vector["webhook_id"]!.GetValue<string>()),
                new("webhook-timestamp", timestamp.ToString(CultureInfo.InvariantCulture)),
                new("webhook-signature", vector["v1a"]!.GetValue<string>()),
            ],
            Convert.FromHexString(vector["body_hex"]!.GetValue<string>()),
            DateTimeOffset.FromUnixTimeSeconds(timestamp));
        Assert.Equal(WebhookScheme.V1a, verified.Scheme);
    }
}
