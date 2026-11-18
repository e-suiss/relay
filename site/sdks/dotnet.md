# .NET

`Esuiss.Relay` is the server SDK for .NET 10.

```sh
dotnet add package Esuiss.Relay
```

## Send an event

`AccessClientCredentials` obtains Access tokens with your API client's credentials and binds them to a DPoP key; `resource` is Relay's Access client id, `access_client_id` in Relay's discovery document.

<<< @/examples/dotnet/Quickstart.cs#quickstart

Every operation of the [server API](/reference/api/server/) is a method on `relay.Api`. Every write carries an `Idempotency-Key`; pass `RequestOptions { IdempotencyKey = ... }` to choose it.

## Page through lists

<<< @/examples/dotnet/Quickstart.cs#decisions

## Errors

<<< @/examples/dotnet/Quickstart.cs#errors

| Exception                                          | When                                            |
| -------------------------------------------------- | ----------------------------------------------- |
| `RelayAuthenticationException`                     | Credentials missing, invalid or lacking a scope |
| `RelayValidationException`                         | Malformed request or invalid fields             |
| `RelayRateLimitException`, `RelayQuotaException`   | Rate limited, quota exhausted                   |
| `RelayIdempotencyException`                        | Key missing, invalid, reused or in progress     |
| `RelayNotFoundException`, `RelayConflictException` | Missing resource, state conflict                |
| `RelayServerException`                             | Relay failed or is unavailable                  |
| `RelayConnectionException`                         | Relay could not be reached                      |

## Verify webhooks

<<< @/examples/dotnet/Webhooks.cs#verify

## Agents

`relay.Agents` has `CreateAndAwaitWaitpointAsync`, `LeaseAsync`, `AckAsync` and `FollowAsync`, which opens the hint stream first, reads the mailbox history, reads again on every hint and hands each record to your handler once.
