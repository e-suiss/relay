using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;

namespace Esuiss.Relay.Tests;

public sealed class RelayAgentsTests
{
    private static string Record(string id, int seq) =>
        $$"""{"object":"mailbox_record","id":"{{id}}","seq":{{seq}},"kind":"waitpoint_event"}""";

    private static string Records(string cursor, bool hasMore, params string[] records) =>
        $$"""{"object":"mailbox_records","records":[{{string.Join(",", records)}}],"cursor":"{{cursor}}","has_more":{{(hasMore ? "true" : "false")}},"resync_required":false}""";

    [Fact]
    public async Task X_30_await_waitpoint_polls_until_the_waitpoint_is_no_longer_open()
    {
        using var h = new Harness();
        h.Handler
            .Json(201, """{"object":"waitpoint","id":"wp_1","state":"open"}""")
            .Json(200, """{"object":"waitpoint","id":"wp_1","state":"open"}""")
            .Json(200, """{"object":"waitpoint","id":"wp_1","state":"stalled"}""")
            .Json(200, """{"object":"waitpoint","id":"wp_1","state":"resolved","response":{"value":{"approved":true}}}""");

        var resolved = await h.Client.Agents.CreateAndAwaitWaitpointAsync(
            new JsonObject { ["kind"] = "event" }, TimeSpan.FromMinutes(1), TimeSpan.FromSeconds(5));

        Assert.Equal("resolved", resolved["state"]!.GetValue<string>());
        Assert.Equal(new[] { TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5) }, h.Delays);
        Assert.Equal("POST", h.Handler.Requests[0].Method);
        Assert.All(h.Handler.Requests.Skip(1), r => Assert.Equal("/v1/waitpoints/wp_1", r.Url.AbsolutePath));
    }

    [Fact]
    public async Task X_30_await_waitpoint_gives_up_after_the_timeout()
    {
        using var h = new Harness();
        for (var i = 0; i < 3; i++)
        {
            h.Handler.Json(200, """{"object":"waitpoint","id":"wp_1","state":"open"}""");
        }

        var error = await Assert.ThrowsAsync<RelayWaitpointTimeoutException>(() =>
            h.Client.Agents.AwaitWaitpointAsync("wp_1", TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(2)));

        Assert.Equal("wp_1", error.WaitpointId);
        Assert.Equal(new[] { TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(1) }, h.Delays);
    }

    [Fact]
    public async Task X_30_lease_and_ack_send_the_mailbox_bodies()
    {
        using var h = new Harness();
        h.Handler
            .Json(200, """{"object":"mailbox_lease","lease_id":"ls_1","lease_expires_at":null,"records":[]}""")
            .Json(200, """{"object":"mailbox_ack","results":[],"acked_cursor":"c1"}""");

        await h.Client.Agents.LeaseAsync(5);
        await h.Client.Agents.AckAsync("ls_1", ["mbr_1", "mbr_2"]);

        Assert.Equal("""{"max":5}""", h.Handler.Requests[0].Body);
        Assert.Equal("/v1/mailbox/leases", h.Handler.Requests[0].Url.AbsolutePath);
        Assert.Equal("""{"lease_id":"ls_1","record_ids":["mbr_1","mbr_2"]}""", h.Handler.Requests[1].Body);
        Assert.True(h.Handler.Requests.All(r => r.Headers.ContainsKey("Idempotency-Key")));
    }

    [Fact]
    public async Task X_30_follow_opens_the_stream_then_reads_history_then_dedupes_by_id()
    {
        using var h = new Harness();
        h.Handler
            .Json(200, Records("c1", true, Record("mbr_1", 1), Record("mbr_2", 2)))
            .Json(200, Records("c2", false, Record("mbr_3", 3)))
            .Json(200, Records("c3", false, Record("mbr_3", 3), Record("mbr_4", 4)))
            .Json(200, Records("c3", false));

        var events = new List<string>();
        var handled = new List<string>();
        await h.Client.Agents.FollowAsync(Hints(events), (record, _) =>
        {
            handled.Add(record["id"]!.GetValue<string>());
            events.Add("record");
            return Task.CompletedTask;
        });

        Assert.Equal("opened", events[0]);
        Assert.Equal(5, events.Count);
        Assert.Equal(new[] { "mbr_1", "mbr_2", "mbr_3", "mbr_4" }, handled);
        Assert.Equal(4, h.Handler.Requests.Count);
        Assert.Equal("", h.Handler.Requests[0].Url.Query);
        Assert.Equal("?since=c1", h.Handler.Requests[1].Url.Query);
        Assert.Equal("?since=c2", h.Handler.Requests[2].Url.Query);
        Assert.Equal("?since=c3", h.Handler.Requests[3].Url.Query);
    }

    [Fact]
    public async Task X_30_a_resync_starts_over_from_the_returned_cursor()
    {
        using var h = new Harness();
        h.Handler
            .Json(200, """{"object":"mailbox_records","records":[],"cursor":"c9","has_more":false,"resync_required":true}""")
            .Json(200, Records("c10", false, Record("mbr_9", 9)));

        var follower = h.Client.Agents.Follower();
        var handled = new List<string>();
        await follower.SyncAsync((record, _) =>
        {
            handled.Add(record["id"]!.GetValue<string>());
            return Task.CompletedTask;
        });

        Assert.Equal(new[] { "mbr_9" }, handled);
        Assert.Equal("?since=c9", h.Handler.Requests[1].Url.Query);
        Assert.Equal("c10", follower.Cursor);
    }

    [Fact]
    public void X_30_the_deduplicator_is_bounded()
    {
        var seen = new RecordDeduplicator(2);
        Assert.True(seen.Add("a"));
        Assert.False(seen.Add("a"));
        Assert.True(seen.Add("b"));
        Assert.True(seen.Add("c"));
        Assert.True(seen.Add("a"));
    }

    private static async IAsyncEnumerable<int> Hints(List<string> events, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        events.Add("opened");
        await Task.Yield();
        cancellationToken.ThrowIfCancellationRequested();
        yield return 1;
        yield return 2;
    }
}
