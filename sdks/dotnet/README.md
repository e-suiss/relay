# Esuiss.Relay

The .NET server SDK for Relay, the notification, messaging and event orchestration platform of Suiss.

- One method for every operation of the server API, generated from the OpenAPI contract
- Automatic `Idempotency-Key` on every mutation, kept the same on every retry
- Retries only when Relay says an error is retryable, with exponential backoff, full jitter and `Retry-After`
- Typed errors: authentication, validation, rate limit and quota, idempotency, server
- DPoP-bound Access tokens (client credentials) handled for you
- Webhook verification over the raw body (Ed25519 `v1a` and HMAC `v1`)
- Lazy pagination and helpers for waitpoints and the agent mailbox
- Pinned to one API version: updating the package never changes behaviour silently

## Install

```sh
dotnet add package Esuiss.Relay
```

Requires .NET 10.

## Quick start

```csharp
using System.Text.Json.Nodes;
using Esuiss.Relay;

var key = DpopKey.Generate();
using var credentials = new AccessClientCredentials(
    tokenEndpoint: new Uri("https://access.example.com/oauth2/token"),
    clientId: "your-access-client-id",
    clientSecret: Environment.GetEnvironmentVariable("ACCESS_CLIENT_SECRET")!,
    resource: "relay-access-client-id",
    key: key);

using var relay = new RelayClient(new RelayClientOptions
{
    BaseUrl = new Uri("https://relay.example.com"),
    Credentials = credentials,
});

var evt = await relay.Api.CreateEventAsync(new JsonObject
{
    ["workflow"] = "order-shipped",
    ["to"] = new JsonArray(new JsonObject { ["external_id"] = "user-42" }),
    ["data"] = new JsonObject { ["order_id"] = "4821" },
});
```

Every mutation carries an `Idempotency-Key`. Pass your own to tie a call to your business operation:

```csharp
await relay.Api.CreateEventAsync(body, new RequestOptions { IdempotencyKey = $"order-{orderId}-shipped" });
```

## Errors

```csharp
try
{
    await relay.Api.GetNotificationAsync("ntf_...");
}
catch (RelayNotFoundException)
{
}
catch (RelayRateLimitException e)
{
    Console.WriteLine($"{e.Code} retry after {e.Error.RetryAfter}");
}
catch (RelayApiException e)
{
    Console.WriteLine($"{e.Status} {e.Code} request {e.RequestId}");
}
```

| Exception | When |
|---|---|
| `RelayAuthenticationException` | credentials missing, invalid or lacking a scope |
| `RelayValidationException` | malformed request or invalid fields |
| `RelayRateLimitException` / `RelayQuotaException` | rate limited / quota exhausted |
| `RelayIdempotencyException` | key missing, invalid, reused or in progress |
| `RelayNotFoundException`, `RelayConflictException` | missing resource, state conflict |
| `RelayServerException` | Relay failed or is unavailable |
| `RelayConnectionException` | Relay could not be reached |

## Pagination

```csharp
var page = await relay.Api.ListWaitpointsAsync(state: "open");
await foreach (var waitpoint in page.AllAsync())
{
    Console.WriteLine(waitpoint["id"]);
}
```

Further pages are fetched only when the iteration reaches them.

## Webhooks

Verify the raw body exactly as it arrived, before parsing it:

```csharp
var verifier = new WebhookVerifier(["whpk_..."]);

app.MapPost("/relay/webhooks", async (HttpRequest request) =>
{
    using var buffer = new MemoryStream();
    await request.Body.CopyToAsync(buffer);
    var headers = request.Headers.SelectMany(h => h.Value.Select(v => KeyValuePair.Create(h.Key, v ?? "")));
    try
    {
        var verified = verifier.Verify(headers, buffer.ToArray());
        return Results.NoContent();
    }
    catch (WebhookVerificationException)
    {
        return Results.BadRequest();
    }
});
```

Deduplicate by `verified.Id`: delivery is at least once.

## Agents

```csharp
var waitpoint = await relay.Agents.CreateAndAwaitWaitpointAsync(body, timeout: TimeSpan.FromMinutes(10));

var lease = await relay.Agents.LeaseAsync(max: 10);
await relay.Agents.AckAsync(lease["lease_id"]!.GetValue<string>(), ids);

await relay.Agents.FollowAsync(hints, async (record, ct) => await HandleAsync(record, ct));
```

`FollowAsync` opens the hint stream first, reads the mailbox history, then reads again on every hint, and hands each record to your handler once by its id.

## Development

The operation table and `RelayApi` under `src/Esuiss.Relay/Generated` are generated from `contracts/openapi/server.yaml` and `contracts/errors.yaml`:

```sh
dotnet run --project generator/Esuiss.Relay.Generator -- ../../contracts/openapi/server.yaml ../../contracts/errors.yaml src/Esuiss.Relay/Generated
dotnet format Esuiss.Relay.slnx
dotnet test Esuiss.Relay.slnx
```

## License

Apache-2.0
