using System.Net;
using System.Text;
using System.Text.Json.Nodes;

namespace Esuiss.Relay.Tests;

public sealed class ConformanceTests
{
    private const string Vectors = "conformance/sdk/vectors/1/";

    private static readonly JsonNode Errors = Repo.Json(Vectors + "errors.json");
    private static readonly JsonNode Retry = Repo.Json(Vectors + "retry.json");
    private static readonly JsonNode Idempotency = Repo.Json(Vectors + "idempotency.json");
    private static readonly JsonNode Pagination = Repo.Json(Vectors + "pagination.json");
    private static readonly JsonNode Webhooks = Repo.Json(Vectors + "webhooks.json");

    private static IEnumerable<JsonNode> Items(JsonNode node, string name) => node[name]!.AsArray().Select(n => n!);

    private static string Str(JsonNode? node) => node!.GetValue<string>();

    private static string ClassName(ErrorClass value) => value switch
    {
        ErrorClass.Auth => "auth",
        ErrorClass.Validation => "validation",
        ErrorClass.RateLimit => "rate_limit",
        ErrorClass.Idempotency => "idempotency",
        _ => "server",
    };

    private static HttpResponseMessage Response(JsonNode response)
    {
        var message = new HttpResponseMessage((HttpStatusCode)response["status"]!.GetValue<int>());
        var body = response["body"];
        var headers = response["headers"]?.AsObject() ?? [];
        var contentType = headers.FirstOrDefault(h => h.Key.Equals("content-type", StringComparison.OrdinalIgnoreCase)).Value?.GetValue<string>();
        if (body is not null)
        {
            var text = body is JsonValue value && value.TryGetValue<string>(out var s) ? s : body.ToJsonString();
            message.Content = new StringContent(text, Encoding.UTF8, contentType ?? "application/problem+json");
        }
        else
        {
            message.Content = new ByteArrayContent([]);
        }

        foreach (var (name, value) in headers)
        {
            if (!name.Equals("content-type", StringComparison.OrdinalIgnoreCase))
            {
                message.Headers.TryAddWithoutValidation(name, value!.GetValue<string>());
            }
        }

        return message;
    }

    private static async Task<RelayError> ProblemOf(JsonNode response, DateTimeOffset now)
    {
        using var message = Response(response);
        var bytes = await message.Content.ReadAsByteArrayAsync();
        return RelayClient.Problem((int)message.StatusCode, message, bytes, now);
    }

    [Fact]
    public async Task X_29_error_cases_classify_as_the_vectors_say()
    {
        foreach (var vector in Items(Errors, "cases"))
        {
            var expect = vector["expect"]!;
            var error = await ProblemOf(vector["response"]!, DateTimeOffset.UnixEpoch);
            var name = Str(vector["name"]);

            Assert.True(Str(expect["class"]) == ClassName(ErrorMapping.Classify(error.Status, error.Code)), name);
            Assert.True(expect["code"]?.GetValue<string>() == error.Code, name);
            Assert.True(expect["status"]!.GetValue<int>() == error.Status, name);
            Assert.True(expect["retryable"]!.GetValue<bool>() == error.Retryable, name);
            if (expect["request_id"] is { } requestId)
            {
                Assert.Equal(Str(requestId), error.RequestId);
            }

            if (expect["retry_after_s"] is { } retryAfter)
            {
                Assert.Equal(TimeSpan.FromSeconds(retryAfter.GetValue<int>()), error.RetryAfter);
            }

            if (expect["field_errors"] is { } fieldErrors)
            {
                Assert.Equal(fieldErrors.GetValue<int>(), error.Problem!["errors"]!.AsArray().Count);
            }
        }
    }

    [Fact]
    public void X_29_the_generated_catalog_matches_the_vector_catalog()
    {
        var catalog = Items(Errors, "catalog").ToList();
        Assert.Equal(catalog.Count, ErrorCatalog.Codes.Count);
        foreach (var entry in catalog)
        {
            var code = Str(entry["code"]);
            var generated = ErrorCatalog.Codes[code];
            Assert.Equal(Str(entry["family"]), generated.Family);
            Assert.Equal(entry["status"]!.GetValue<int>(), generated.Status);
            Assert.Equal(entry["retryable"]!.GetValue<bool>(), generated.Retryable);
            Assert.True(Str(entry["class"]) == ClassName(ErrorMapping.Classify(generated.Status, code)), code);
        }

        var defaults = Items(Errors, "status_defaults").ToList();
        Assert.Equal(defaults.Count, ErrorCatalog.Defaults.Count);
        for (var i = 0; i < defaults.Count; i++)
        {
            Assert.Equal(defaults[i]["status"]!.GetValue<int>(), ErrorCatalog.Defaults[i].Status);
            Assert.Equal(defaults[i]["code"]?.GetValue<string>(), ErrorCatalog.Defaults[i].Code);
            Assert.Equal(defaults[i]["retryable"]!.GetValue<bool>(), ErrorCatalog.Defaults[i].Retryable);
        }
    }

    [Fact]
    public async Task X_29_retry_decisions_follow_the_vectors()
    {
        var policy = Retry["policy"]!;
        var maxRetries = policy["max_retries"]!.GetValue<int>();
        var baseDelay = TimeSpan.FromMilliseconds(policy["base_ms"]!.GetValue<int>());
        var cap = TimeSpan.FromMilliseconds(policy["cap_ms"]!.GetValue<int>());
        var limit = TimeSpan.FromSeconds(policy["max_retry_after_s"]!.GetValue<int>());

        foreach (var row in Items(Retry, "backoff"))
        {
            var delay = RetryPolicy.Backoff(row["retry"]!.GetValue<int>(), row["random"]!.GetValue<double>(), baseDelay, cap);
            Assert.Equal(row["delay_ms"]!.GetValue<int>(), delay.TotalMilliseconds);
            Assert.InRange(delay.TotalMilliseconds, row["min_ms"]!.GetValue<int>(), row["max_ms"]!.GetValue<int>());
        }

        foreach (var vector in Items(Retry, "decisions"))
        {
            var name = Str(vector["name"]);
            var retry = vector["retry"]!.GetValue<int>();
            var random = vector["random"]!.GetValue<double>();
            var now = DateTimeOffset.Parse(Str(vector["now"]), System.Globalization.CultureInfo.InvariantCulture);
            RetryDecision decision;
            if (vector["network_error"]?.GetValue<bool>() == true)
            {
                decision = RetryPolicy.Decide(retry, maxRetries, true, null, random, baseDelay, cap, limit);
            }
            else
            {
                var error = await ProblemOf(vector["response"]!, now);
                decision = RetryPolicy.Decide(retry, maxRetries, error.Retryable, error.RetryAfter, random, baseDelay, cap, limit);
            }

            var expect = vector["expect"]!;
            Assert.True(expect["retry"]!.GetValue<bool>() == decision.ShouldRetry, name);
            if (decision.ShouldRetry)
            {
                Assert.True(expect["delay_ms"]!.GetValue<int>() == decision.Delay.TotalMilliseconds, name);
            }
            else
            {
                var reason = decision.Verdict switch
                {
                    RetryVerdict.NotRetryable => "not_retryable",
                    RetryVerdict.RetriesExhausted => "retries_exhausted",
                    _ => "retry_after_too_long",
                };
                Assert.True(Str(expect["reason"]) == reason, name);
            }
        }
    }

    [Fact]
    public async Task API_10_idempotency_cases_follow_the_vectors()
    {
        foreach (var vector in Items(Idempotency, "cases"))
        {
            using var h = new Harness();
            var keys = new List<string?>();
            foreach (var call in Items(vector, "calls"))
            {
                foreach (var response in Items(call, "responses"))
                {
                    if (response["network_error"]?.GetValue<bool>() == true)
                    {
                        h.Handler.Fail();
                    }
                    else
                    {
                        var copy = response.DeepClone();
                        h.Handler.Respond(_ => Response(copy));
                    }
                }

                var method = Str(call["method"]);
                var takesKey = call["takes_idempotency_key"]!.GetValue<bool>();
                var operation = new Operation("vector", method, Str(call["path"]),
                    takesKey ? IdempotencyMode.Required : IdempotencyMode.None, IfMatchMode.None,
                    method == "GET" ? BodyMode.None : BodyMode.Optional, "application/json", ResponseKind.Json);
                var options = call["caller_idempotency"] is { } given ? new RequestOptions { IdempotencyKey = Str(given) } : null;
                var before = h.Handler.Requests.Count;
                var expect = call["expect"]!;
                var name = Str(vector["name"]);

                try
                {
                    var result = await h.Client.SendAsync(operation, [], new QueryBuilder(),
                        method == "GET" ? null : new JsonObject(), options);
                    Assert.True(Str(expect["outcome"]) == "success", name);
                    Assert.True(expect["replayed"]!.GetValue<bool>() == result.IdempotencyReplayed, name);
                }
                catch (RelayApiException error)
                {
                    Assert.True(Str(expect["outcome"]) == "error", name);
                    Assert.True(Str(expect["error_class"]) == ClassName(ErrorMapping.Classify(error.Status, error.Code)), name);
                    Assert.Equal(Str(expect["error_code"]), error.Code);
                }

                var sent = h.Handler.Requests.Skip(before).ToList();
                Assert.True(expect["requests"]!.GetValue<int>() == sent.Count, name);
                var callKeys = sent.Select(r => r.Headers.TryGetValue("Idempotency-Key", out var k) ? k : null).ToList();
                Assert.True(expect["key_sent"]!.GetValue<bool>() == callKeys.All(k => k is not null), name);
                if (expect["key_sent"]!.GetValue<bool>())
                {
                    Assert.Single(callKeys.Distinct());
                    Assert.InRange(callKeys[0]!.Length, 8, 255);
                }

                if (expect["sent_idempotency"] is { } sentKey)
                {
                    Assert.Equal(Str(sentKey), callKeys[0]);
                }

                keys.Add(callKeys.FirstOrDefault());
            }

            if (vector["distinct_keys_across_calls"]?.GetValue<bool>() == true)
            {
                Assert.Equal(keys.Count, keys.Distinct().Count());
            }
        }
    }

    private static readonly Operation ListOperation = new("vector", "GET", "/v1/notifications", IdempotencyMode.None,
        IfMatchMode.None, BodyMode.None, null, ResponseKind.Json);

    private static QueryBuilder QueryOf(JsonNode parameters)
    {
        var query = new QueryBuilder();
        query.Add("limit", parameters["limit"]?.GetValue<int>());
        query.Add("starting_after", parameters["starting_after"]?.GetValue<string>());
        query.Add("ending_before", parameters["ending_before"]?.GetValue<string>());
        return query;
    }

    private static Dictionary<string, string> Query(Uri url) =>
        url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(pair => pair.Split('=', 2))
            .ToDictionary(pair => Uri.UnescapeDataString(pair[0]), pair => Uri.UnescapeDataString(pair[1]));

    [Fact]
    public async Task API_56_pagination_cases_follow_the_vectors()
    {
        foreach (var vector in Items(Pagination, "cases"))
        {
            var name = Str(vector["name"]);
            using var h = new Harness();
            var exchanges = Items(vector, "exchanges").ToList();
            foreach (var exchange in exchanges)
            {
                h.Handler.Json(200, exchange["page"]!.ToJsonString());
            }

            var take = vector["take"]?.GetValue<int>() ?? int.MaxValue;
            var items = new List<string>();
            var page = await h.Client.ListAsync(ListOperation, [], QueryOf(vector["params"]!), null, null, CancellationToken.None);
            await foreach (var item in page.AllAsync())
            {
                items.Add(Str(item["id"]));
                if (items.Count >= take)
                {
                    break;
                }
            }

            var expected = Items(vector["expect"]!, "items").Select(Str).ToList();
            Assert.True(expected.SequenceEqual(items), name);
            Assert.True(vector["expect"]!["requests"]!.GetValue<int>() == h.Handler.Requests.Count, name);
            for (var i = 0; i < h.Handler.Requests.Count; i++)
            {
                var want = exchanges[i]["query"]!.AsObject().ToDictionary(p => p.Key, p => Str(p.Value));
                Assert.Equal(want, Query(h.Handler.Requests[i].Url));
            }
        }

        foreach (var vector in Items(Pagination, "rejections"))
        {
            using var h = new Harness();
            await Assert.ThrowsAsync<ArgumentException>(() =>
                h.Client.ListAsync(ListOperation, [], QueryOf(vector["params"]!), null, null, CancellationToken.None));
            Assert.Empty(h.Handler.Requests);
        }
    }

    [Fact]
    public void WH_4_webhook_header_cases_follow_the_vectors()
    {
        var signatures = Repo.Json(Str(Webhooks["signatures"]));
        var cases = Items(signatures, "cases").ToDictionary(c => Str(c["name"]));
        var tolerance = TimeSpan.FromSeconds(signatures["tolerance_s"]!.GetValue<int>());

        foreach (var vector in Items(Webhooks, "cases"))
        {
            var name = Str(vector["name"]);
            var baseCase = cases[Str(vector["base"])];
            var timestamp = baseCase["webhook_timestamp"]!.GetValue<long>();
            var headers = new List<KeyValuePair<string, string>>
            {
                new("webhook-id", Str(baseCase["webhook_id"])),
                new("webhook-timestamp", timestamp.ToString(System.Globalization.CultureInfo.InvariantCulture)),
            };
            foreach (var (header, value) in vector["headers"]!.AsObject())
            {
                headers.RemoveAll(h => h.Key == header);
                if (value is not null)
                {
                    var text = Str(value).Replace("{v1a}", Str(baseCase["v1a"]), StringComparison.Ordinal)
                        .Replace("{v1}", Str(baseCase["v1"]), StringComparison.Ordinal);
                    headers.Add(new(header, text));
                }
            }

            var keys = Items(vector, "keys").Select(k => Str(signatures["keys"]![Str(k)]));
            var verifier = new WebhookVerifier(keys, tolerance);
            var body = Convert.FromHexString(Str(vector["body_hex"] ?? baseCase["body_hex"]));
            var now = DateTimeOffset.FromUnixTimeSeconds(vector["now"]?.GetValue<long>() ?? timestamp);
            var expect = vector["expect"]!;

            if (expect["ok"]!.GetValue<bool>())
            {
                var verified = verifier.Verify(headers, body, now);
                Assert.True(Str(expect["scheme"]) == (verified.Scheme == WebhookScheme.V1a ? "v1a" : "v1"), name);
            }
            else
            {
                var error = Assert.Throws<WebhookVerificationException>(() => verifier.Verify(headers, body, now));
                var reason = error.Rejection switch
                {
                    WebhookRejection.MissingHeader => "missing_header",
                    WebhookRejection.DuplicateHeader => "duplicate_header",
                    WebhookRejection.MalformedHeader => "malformed_header",
                    WebhookRejection.TimestampOutOfTolerance => "timestamp_out_of_tolerance",
                    _ => "no_matching_signature",
                };
                Assert.True(Str(expect["error"]) == reason, name);
            }
        }
    }
}
