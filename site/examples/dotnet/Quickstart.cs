using System.Text.Json.Nodes;
using Esuiss.Relay;

namespace DocsExamples;

public static class Quickstart
{
    public static async Task RunAsync()
    {
        #region quickstart
        var key = DpopKey.Generate();
        using var credentials = new AccessClientCredentials(
            tokenEndpoint: new Uri("https://access.example.com/oauth2/token"),
            clientId: Environment.GetEnvironmentVariable("ACCESS_CLIENT_ID")!,
            clientSecret: Environment.GetEnvironmentVariable("ACCESS_CLIENT_SECRET")!,
            resource: Environment.GetEnvironmentVariable("RELAY_ACCESS_CLIENT_ID")!,
            key: key);

        using var relay = new RelayClient(new RelayClientOptions
        {
            BaseUrl = new Uri("https://relay.example.com"),
            Credentials = credentials,
        });

        var accepted = await relay.Api.CreateEventAsync(new JsonObject
        {
            ["workflow"] = "welcome",
            ["to"] = new JsonArray(new JsonObject { ["id"] = "user-4821", ["email"] = "ayse@example.com" }),
            ["data"] = new JsonObject { ["first_name"] = "Ayşe" },
        });
        Console.WriteLine(accepted["id"]);
        #endregion quickstart

        #region decisions
        var page = await relay.Api.ListSubscriberDecisionsAsync("user-4821");
        await foreach (var decision in page.AllAsync())
        {
            Console.WriteLine(decision["notification_id"]);
        }
        #endregion decisions

        #region errors
        try
        {
            await relay.Api.CreateEventAsync(
                new JsonObject { ["workflow"] = "welcome", ["to"] = new JsonArray("user-4821") },
                new RequestOptions { IdempotencyKey = "order:4821:shipped" });
        }
        catch (RelayValidationException e)
        {
            Console.WriteLine($"{e.Status} {e.Code}, request {e.RequestId}");
        }
        #endregion errors
    }
}
