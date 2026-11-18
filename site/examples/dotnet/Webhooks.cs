using System.Collections.Concurrent;
using Esuiss.Relay;

namespace DocsExamples;

public static class Webhooks
{
    private static readonly ConcurrentDictionary<string, bool> Processed = new();

    public static void Map(WebApplication app)
    {
        #region verify
        var verifier = new WebhookVerifier([Environment.GetEnvironmentVariable("RELAY_WEBHOOK_KEY")!]);

        app.MapPost("/relay/webhooks", async (HttpRequest request) =>
        {
            using var buffer = new MemoryStream();
            await request.Body.CopyToAsync(buffer);
            var headers = request.Headers.SelectMany(
                h => h.Value.Select(v => KeyValuePair.Create(h.Key, v ?? "")));
            try
            {
                var verified = verifier.Verify(headers, buffer.ToArray());
                if (Processed.TryAdd(verified.Id, true))
                {
                    Console.WriteLine($"received {verified.Id}");
                }
                return Results.NoContent();
            }
            catch (WebhookVerificationException)
            {
                return Results.BadRequest();
            }
        });
        #endregion verify
    }
}
