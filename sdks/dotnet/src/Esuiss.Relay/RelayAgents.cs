using System.Text.Json.Nodes;

namespace Esuiss.Relay;

/// <summary>Helpers for agents and the API clients that wait like agents: waitpoints and the durable mailbox.</summary>
public sealed class RelayAgents
{
    private static readonly TimeSpan DefaultPoll = TimeSpan.FromSeconds(2);

    private readonly RelayClient _client;

    internal RelayAgents(RelayClient client) => _client = client;

    /// <summary>Opens a waitpoint. The Idempotency-Key is the waitpoint's identity, so a retry keeps its deadline.</summary>
    public Task<JsonNode> CreateWaitpointAsync(
        JsonNode body,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default) =>
        _client.Api.CreateWaitpointAsync(body, options, cancellationToken);

    /// <summary>Reads the waitpoint until it is no longer open or stalled and returns it; raises <see cref="RelayWaitpointTimeoutException"/> when it is still waiting after <paramref name="timeout"/> of polling.</summary>
    public async Task<JsonNode> AwaitWaitpointAsync(
        string waitpointId,
        TimeSpan timeout,
        TimeSpan? pollInterval = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(waitpointId);
        var poll = pollInterval ?? DefaultPoll;
        var waited = TimeSpan.Zero;
        while (true)
        {
            var waitpoint = await _client.Api.GetWaitpointAsync(waitpointId, null, cancellationToken).ConfigureAwait(false);
            var state = waitpoint["state"] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
            if (state is not "open" and not "stalled")
            {
                return waitpoint;
            }

            if (waited >= timeout)
            {
                throw new RelayWaitpointTimeoutException(waitpointId, waitpoint);
            }

            var step = poll < timeout - waited ? poll : timeout - waited;
            await _client.DelayFunction(step, cancellationToken).ConfigureAwait(false);
            waited += step;
        }
    }

    /// <summary>Opens a waitpoint and waits for it to resolve, expire or be cancelled.</summary>
    public async Task<JsonNode> CreateAndAwaitWaitpointAsync(
        JsonNode body,
        TimeSpan timeout,
        TimeSpan? pollInterval = null,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        var created = await CreateWaitpointAsync(body, options, cancellationToken).ConfigureAwait(false);
        var id = created["id"]?.GetValue<string>() ?? throw new RelayException("the waitpoint has no id");
        return await AwaitWaitpointAsync(id, timeout, pollInterval, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Takes at most <paramref name="max"/> records of the caller's mailbox with a lease.</summary>
    public Task<JsonNode> LeaseAsync(int max = 1, RequestOptions? options = null, CancellationToken cancellationToken = default) =>
        _client.Api.LeaseMailboxRecordsAsync(new JsonObject { ["max"] = max }, options, cancellationToken);

    /// <summary>Acknowledges records of one lease.</summary>
    public Task<JsonNode> AckAsync(
        string leaseId,
        IEnumerable<string> recordIds,
        RequestOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(leaseId);
        ArgumentNullException.ThrowIfNull(recordIds);
        var ids = new JsonArray();
        foreach (var id in recordIds)
        {
            ids.Add(id);
        }

        var body = new JsonObject { ["lease_id"] = leaseId, ["record_ids"] = ids };
        return _client.Api.AckMailboxRecordsAsync(body, options, cancellationToken);
    }

    /// <summary>Reads the records of the caller's mailbox after a position, in stream order; without a position, after the acknowledged one.</summary>
    public Task<JsonNode> ReadAsync(string? since = null, int? limit = null, CancellationToken cancellationToken = default) =>
        _client.Api.ListMailboxRecordsAsync(since, limit, null, cancellationToken);

    /// <summary>Creates a follower that reads the mailbox in order and hands every record out once.</summary>
    public MailboxFollower Follower(int dedupeCapacity = RecordDeduplicator.DefaultCapacity) =>
        new(this, new RecordDeduplicator(dedupeCapacity));

    /// <summary>Opens the hint stream first, then reads the history, then reads again on every hint; each record reaches the handler once by its id.</summary>
    /// <param name="hints">Wake-up hints, such as webhook or push deliveries; their content is not trusted, only the mailbox is.</param>
    /// <param name="handler">Called once for each record.</param>
    /// <param name="cancellationToken">Ends the loop.</param>
    public Task FollowAsync<THint>(
        IAsyncEnumerable<THint> hints,
        Func<JsonNode, CancellationToken, Task> handler,
        CancellationToken cancellationToken = default) =>
        Follower().FollowAsync(hints, handler, cancellationToken);
}

/// <summary>Reads a mailbox in stream order from a cursor and passes every record through a deduplicator.</summary>
public sealed class MailboxFollower
{
    private const int MaxResyncs = 3;

    private readonly RelayAgents _agents;
    private readonly RecordDeduplicator _seen;

    internal MailboxFollower(RelayAgents agents, RecordDeduplicator seen)
    {
        _agents = agents;
        _seen = seen;
    }

    /// <summary>The position after the last record read, or null before the first read.</summary>
    public string? Cursor { get; private set; }

    /// <summary>Opens the hint stream first, then reads the history, then reads again on every hint.</summary>
    public async Task FollowAsync<THint>(
        IAsyncEnumerable<THint> hints,
        Func<JsonNode, CancellationToken, Task> handler,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(hints);
        ArgumentNullException.ThrowIfNull(handler);
        var stream = hints.GetAsyncEnumerator(cancellationToken);
        await using (stream.ConfigureAwait(false))
        {
            var pending = stream.MoveNextAsync().AsTask();
            await SyncAsync(handler, cancellationToken).ConfigureAwait(false);
            while (await pending.ConfigureAwait(false))
            {
                await SyncAsync(handler, cancellationToken).ConfigureAwait(false);
                pending = stream.MoveNextAsync().AsTask();
            }
        }
    }

    /// <summary>Reads every record after the cursor and hands the ones not seen before to the handler.</summary>
    public async Task SyncAsync(Func<JsonNode, CancellationToken, Task> handler, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(handler);
        var resyncs = 0;
        while (true)
        {
            var page = await _agents.ReadAsync(Cursor, null, cancellationToken).ConfigureAwait(false);
            var cursor = page["cursor"]?.GetValue<string>();
            if (page["resync_required"] is JsonValue resync && resync.TryGetValue<bool>(out var required) && required)
            {
                if (++resyncs > MaxResyncs)
                {
                    throw new RelayException("the mailbox asked for a resync too many times");
                }

                Cursor = cursor;
                continue;
            }

            if (page["records"] is JsonArray records)
            {
                foreach (var record in records)
                {
                    var id = record?["id"]?.GetValue<string>();
                    if (record is not null && id is not null && _seen.Add(id))
                    {
                        await handler(record, cancellationToken).ConfigureAwait(false);
                    }
                }
            }

            Cursor = cursor ?? Cursor;
            var more = page["has_more"] is JsonValue flag && flag.TryGetValue<bool>(out var hasMore) && hasMore;
            if (!more)
            {
                return;
            }
        }
    }
}

/// <summary>Remembers the most recent record ids, so that a record delivered more than once is handled once.</summary>
public sealed class RecordDeduplicator
{
    /// <summary>The number of ids remembered by default.</summary>
    public const int DefaultCapacity = 10_000;

    private readonly int _capacity;
    private readonly HashSet<string> _ids = [];
    private readonly Queue<string> _order = new();

    /// <summary>Creates a deduplicator that remembers at most <paramref name="capacity"/> ids.</summary>
    public RecordDeduplicator(int capacity = DefaultCapacity)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(capacity, 1);
        _capacity = capacity;
    }

    /// <summary>Returns true the first time an id is seen and false after.</summary>
    public bool Add(string id)
    {
        ArgumentNullException.ThrowIfNull(id);
        if (!_ids.Add(id))
        {
            return false;
        }

        _order.Enqueue(id);
        if (_order.Count > _capacity)
        {
            _ids.Remove(_order.Dequeue());
        }

        return true;
    }
}
