using System.Text.Json.Nodes;

namespace Esuiss.Relay.Tests;

public sealed class RelayClientTests
{
    private const string OrderKey = "order-4821-shipped";

    private const string Waitpoint = """{"object":"waitpoint","id":"wp_1","state":"open"}""";

    private static string ProblemBody(int status, string code, bool retryable) =>
        $$"""{"type":"https://relay.example.com/v1/errors/{{code}}","title":"t","status":{{status}},"code":"{{code}}","retryable":{{(retryable ? "true" : "false")}}}""";

    private static JsonObject WaitpointBody() => new() { ["kind"] = "event" };

    [Fact]
    public async Task X_29_every_request_carries_the_pinned_version_and_dpop()
    {
        using var h = new Harness();
        h.Handler.Json(200, Waitpoint);

        await h.Client.Api.GetWaitpointAsync("wp_1");

        var request = Assert.Single(h.Handler.Requests);
        Assert.Equal("GET", request.Method);
        Assert.Equal("https://relay.example.com/v1/waitpoints/wp_1", request.Url.ToString());
        Assert.Equal(RelayApiInfo.ApiVersion, request.Headers["Relay-Version"]);
        Assert.Equal("2026-11-01", RelayApiInfo.ApiVersion);
        Assert.Equal("DPoP token-1", request.Headers["Authorization"]);
        Assert.True(request.Headers.ContainsKey("DPoP"));
        Assert.False(request.Headers.ContainsKey("Idempotency-Key"));
        Assert.StartsWith("esuiss-relay-dotnet/", request.Headers["User-Agent"], StringComparison.Ordinal);
    }

    [Fact]
    public async Task API_10_a_mutation_gets_a_generated_key_that_every_retry_reuses()
    {
        using var h = new Harness();
        h.Handler
            .Problem(503, ProblemBody(503, "service_unavailable", true), ("Retry-After", "7"))
            .Problem(409, ProblemBody(409, "idempotency_key_in_progress", true), ("Retry-After", "1"))
            .Json(201, Waitpoint);

        var created = await h.Client.Api.CreateWaitpointAsync(WaitpointBody());

        Assert.Equal("wp_1", created["id"]!.GetValue<string>());
        Assert.Equal(3, h.Handler.Requests.Count);
        var keys = h.Handler.Requests.Select(r => r.Headers["Idempotency-Key"]).Distinct().ToList();
        var key = Assert.Single(keys);
        Assert.True(key.Length is >= 8 and <= 255);
        Assert.Equal(new[] { TimeSpan.FromSeconds(7), TimeSpan.FromSeconds(1) }, h.Delays);
        Assert.Equal(3, h.Handler.Requests.Select(r => r.Headers["DPoP"]).Distinct().Count());
        Assert.All(h.Handler.Requests, r => Assert.Equal("application/json", r.ContentType));
    }

    [Fact]
    public async Task API_10_a_given_key_is_sent_unchanged()
    {
        using var h = new Harness();
        h.Handler.Json(201, Waitpoint);

        await h.Client.Api.CreateWaitpointAsync(WaitpointBody(), new RequestOptions { IdempotencyKey = OrderKey });

        Assert.Equal(OrderKey, Assert.Single(h.Handler.Requests).Headers["Idempotency-Key"]);
    }

    [Fact]
    public async Task X_29_a_non_retryable_error_is_not_retried()
    {
        using var h = new Harness();
        h.Handler.Problem(429, ProblemBody(429, "quota_exhausted", false));

        var error = await Assert.ThrowsAsync<RelayQuotaException>(() => h.Client.Api.CreateWaitpointAsync(WaitpointBody()));

        Assert.Equal("quota_exhausted", error.Code);
        Assert.False(error.Retryable);
        Assert.Single(h.Handler.Requests);
        Assert.Empty(h.Delays);
    }

    [Fact]
    public async Task API_38_the_body_retryable_flag_wins_over_the_status_default()
    {
        using var h = new Harness();
        h.Handler.Problem(500, ProblemBody(500, "internal_error", false));

        await Assert.ThrowsAsync<RelayServerException>(() => h.Client.Api.GetWaitpointAsync("wp_1"));

        Assert.Single(h.Handler.Requests);
    }

    [Fact]
    public async Task API_38_without_a_flag_the_catalog_decides()
    {
        using var h = new Harness();
        h.Handler.Problem(429, """{"code":"rate_limited"}""").Json(200, Waitpoint);

        await h.Client.Api.GetWaitpointAsync("wp_1");

        Assert.Equal(2, h.Handler.Requests.Count);
    }

    [Fact]
    public async Task X_29_backoff_uses_full_jitter_without_retry_after_and_stops_after_max_retries()
    {
        using var h = new Harness(maxRetries: 3, random: 0.5);
        for (var i = 0; i < 4; i++)
        {
            h.Handler.Problem(500, ProblemBody(500, "internal_error", true));
        }

        var error = await Assert.ThrowsAsync<RelayServerException>(() => h.Client.Api.GetWaitpointAsync("wp_1"));

        Assert.True(error.Retryable);
        Assert.Equal(4, h.Handler.Requests.Count);
        Assert.Equal(new[] { TimeSpan.FromSeconds(0.25), TimeSpan.FromSeconds(0.5), TimeSpan.FromSeconds(1) }, h.Delays);
    }

    [Fact]
    public void X_29_the_backoff_ceiling_doubles_and_is_capped()
    {
        var baseDelay = TimeSpan.FromMilliseconds(500);
        var max = TimeSpan.FromSeconds(8);
        var limit = TimeSpan.FromSeconds(60);
        Assert.Equal(TimeSpan.Zero, RetryPolicy.Backoff(1, 0, baseDelay, max));
        Assert.Equal(TimeSpan.FromMilliseconds(250), RetryPolicy.Backoff(1, 0.5, baseDelay, max));
        Assert.Equal(TimeSpan.FromMilliseconds(3996), RetryPolicy.Backoff(4, 0.999, baseDelay, max));
        Assert.Equal(TimeSpan.FromMilliseconds(6000), RetryPolicy.Backoff(10, 0.75, baseDelay, max));
        Assert.Equal(RetryVerdict.RetryAfterTooLong, RetryPolicy.Decide(1, 3, true, TimeSpan.FromSeconds(61), 0.5, baseDelay, max, limit).Verdict);
        Assert.Equal(TimeSpan.FromSeconds(60), RetryPolicy.Decide(1, 3, true, TimeSpan.FromSeconds(60), 0.5, baseDelay, max, limit).Delay);
        Assert.Equal(RetryVerdict.RetriesExhausted, RetryPolicy.Decide(4, 3, true, null, 0.5, baseDelay, max, limit).Verdict);
        Assert.Equal(RetryVerdict.NotRetryable, RetryPolicy.Decide(1, 3, false, null, 0.5, baseDelay, max, limit).Verdict);
        var now = new DateTimeOffset(2026, 11, 18, 10, 0, 0, TimeSpan.Zero);
        Assert.Equal(TimeSpan.FromSeconds(12), RetryPolicy.ParseRetryAfter("Wed, 18 Nov 2026 10:00:12 GMT", now));
        Assert.Equal(TimeSpan.Zero, RetryPolicy.ParseRetryAfter("Wed, 18 Nov 2026 09:59:00 GMT", now));
        Assert.Null(RetryPolicy.ParseRetryAfter("-3", now));
        Assert.Null(RetryPolicy.ParseRetryAfter("soon", now));
    }

    [Fact]
    public async Task API_56_both_cursors_are_refused_before_sending()
    {
        using var h = new Harness();

        await Assert.ThrowsAsync<ArgumentException>(() => h.Client.Api.ListWaitpointsAsync(startingAfter: "c1", endingBefore: "c2"));

        Assert.Empty(h.Handler.Requests);
    }

    [Fact]
    public async Task API_49_a_retry_after_above_the_limit_surfaces_the_error()
    {
        using var h = new Harness();
        h.Handler.Problem(429, ProblemBody(429, "rate_limited", true), ("Retry-After", "3600"));

        var error = await Assert.ThrowsAsync<RelayRateLimitException>(() => h.Client.Api.GetWaitpointAsync("wp_1"));

        Assert.Equal(TimeSpan.FromHours(1), error.Error.RetryAfter);
        Assert.Single(h.Handler.Requests);
    }

    [Fact]
    public async Task X_29_transport_failures_are_retried_only_when_safe()
    {
        using var h = new Harness();
        h.Handler.Fail().Json(201, Waitpoint);
        await h.Client.Api.CreateWaitpointAsync(WaitpointBody());
        Assert.Equal(2, h.Handler.Requests.Count);
        Assert.Equal(h.Handler.Requests[0].Headers["Idempotency-Key"], h.Handler.Requests[1].Headers["Idempotency-Key"]);

        using var g = new Harness(maxRetries: 0);
        g.Handler.Fail();
        await Assert.ThrowsAsync<RelayConnectionException>(() => g.Client.Api.GetWaitpointAsync("wp_1"));
    }

    [Theory]
    [InlineData(401, "auth_invalid_token", typeof(RelayAuthenticationException))]
    [InlineData(403, "auth_insufficient_scope", typeof(RelayAuthenticationException))]
    [InlineData(422, "validation_failed", typeof(RelayValidationException))]
    [InlineData(400, "malformed_request", typeof(RelayValidationException))]
    [InlineData(400, "idempotency_key_missing", typeof(RelayIdempotencyException))]
    [InlineData(422, "idempotency_key_reuse", typeof(RelayIdempotencyException))]
    [InlineData(429, "rate_limited", typeof(RelayRateLimitException))]
    [InlineData(429, "quota_exhausted", typeof(RelayQuotaException))]
    [InlineData(404, "waitpoint_not_found", typeof(RelayNotFoundException))]
    [InlineData(409, "resource_conflict", typeof(RelayConflictException))]
    [InlineData(503, "service_unavailable", typeof(RelayServerException))]
    public async Task X_29_errors_map_to_the_typed_hierarchy(int status, string code, Type expected)
    {
        using var h = new Harness(maxRetries: 0);
        h.Handler.Problem(status, ProblemBody(status, code, false), ("Request-Id", "req_1"));

        var error = await Assert.ThrowsAnyAsync<RelayApiException>(() => h.Client.Api.GetWaitpointAsync("wp_1"));

        Assert.Equal(expected, error.GetType());
        Assert.Equal(status, error.Status);
        Assert.Equal(code, error.Code);
        Assert.Equal("req_1", error.RequestId);
    }

    [Fact]
    public async Task API_56_pages_are_fetched_lazily_with_the_next_cursor()
    {
        using var h = new Harness();
        h.Handler
            .Json(200, """{"object":"list","data":[{"id":"wp_1"},{"id":"wp_2"}],"has_more":true,"next_cursor":"c2"}""")
            .Json(200, """{"object":"list","data":[{"id":"wp_3"}],"has_more":false,"next_cursor":null}""");

        var page = await h.Client.Api.ListWaitpointsAsync(state: "open", limit: 2);

        Assert.Single(h.Handler.Requests);
        Assert.Equal("?limit=2&state=open", h.Handler.Requests[0].Url.Query);
        Assert.True(page.HasMore);
        Assert.Equal("c2", page.NextCursor);

        var ids = new List<string>();
        await foreach (var item in page.AllAsync())
        {
            ids.Add(item["id"]!.GetValue<string>());
        }

        Assert.Equal(new[] { "wp_1", "wp_2", "wp_3" }, ids);
        Assert.Equal(2, h.Handler.Requests.Count);
        Assert.Equal("?limit=2&state=open&starting_after=c2", h.Handler.Requests[1].Url.Query);
    }

    [Fact]
    public async Task API_2_required_if_match_and_path_parameters_are_checked_before_sending()
    {
        using var h = new Harness();
        var ifMatch = Operations.All.First(o => o.IfMatch == IfMatchMode.Required);
        var path = Enumerable.Repeat("x", ifMatch.Path.Count(c => c == '{')).ToList();

        await Assert.ThrowsAsync<ArgumentException>(() =>
            h.Client.SendAsync(ifMatch, path, new QueryBuilder(), new JsonObject(), null));
        await Assert.ThrowsAsync<ArgumentException>(() => h.Client.Api.GetWaitpointAsync(""));
        Assert.Empty(h.Handler.Requests);
    }

    [Fact]
    public void API_2_the_generated_table_covers_the_server_contract()
    {
        Assert.True(Operations.All.Count > 200);
        Assert.Equal(Operations.All.Count, Operations.All.Select(o => o.Id).Distinct().Count());
        Assert.Equal(IdempotencyMode.Required, Operations.CreateWaitpoint.Idempotency);
        Assert.Equal(IdempotencyMode.None, Operations.ListWaitpoints.Idempotency);
        Assert.Equal(IdempotencyMode.Optional, Operations.CreateEvent.Idempotency);
        Assert.DoesNotContain(Operations.All, o => o.Id == "releaseKillSwitch");
        Assert.Equal(IdempotencyMode.None, Operations.CallMcp.Idempotency);
    }

    [Fact]
    public async Task API_55_a_text_response_is_returned_as_text()
    {
        using var h = new Harness();
        h.Handler.Respond(_ => StubHandler.Response(200, "flowchart TD", "text/plain"));

        var text = await h.Client.Api.GetWorkflowVersionMermaidAsync("welcome", "1");

        Assert.Equal("flowchart TD", text);
    }
}
