using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Esuiss.Relay;

/// <summary>The client of the Relay server API.</summary>
public sealed class RelayClient : IDisposable
{
    /// <summary>The version of this SDK.</summary>
    public const string SdkVersion = "0.1.0";

    private static readonly string UserAgent =
        $"esuiss-relay-dotnet/{SdkVersion} (api {RelayApiInfo.ApiVersion})";

    private readonly RelayClientOptions _options;
    private readonly HttpClient _http;
    private readonly bool _ownsHttp;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly Func<double> _random;
    private readonly TimeProvider _time;
    private readonly string _base;

    /// <summary>Creates a client.</summary>
    public RelayClient(RelayClientOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(options.BaseUrl);
        ArgumentNullException.ThrowIfNull(options.Credentials);
        if (options.BaseUrl.Scheme != Uri.UriSchemeHttps)
        {
            throw new ArgumentException("Relay is reached over https only", nameof(options));
        }

        if (options.MaxRetries < 0)
        {
            throw new ArgumentException("MaxRetries cannot be negative", nameof(options));
        }

        _options = options;
        _base = options.BaseUrl.GetLeftPart(UriPartial.Path).TrimEnd('/');
        _ownsHttp = options.HttpClient is null;
        _http = options.HttpClient ?? new HttpClient { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
        _delay = options.Delay ?? ((wait, token) => Task.Delay(wait, token));
        _random = options.Random ?? (() => System.Random.Shared.NextDouble());
        _time = options.TimeProvider ?? TimeProvider.System;
        Api = new RelayApi(this);
        Agents = new RelayAgents(this);
    }

    /// <summary>One method for every operation of the server API.</summary>
    public RelayApi Api { get; }

    /// <summary>Helpers for waitpoints and the mailbox.</summary>
    public RelayAgents Agents { get; }

    internal Func<TimeSpan, CancellationToken, Task> DelayFunction => _delay;

    /// <inheritdoc />
    public void Dispose()
    {
        if (_ownsHttp)
        {
            _http.Dispose();
        }
    }

    /// <summary>Sends one operation and returns the successful response, retrying retryable failures with the same Idempotency-Key.</summary>
    /// <param name="operation">The operation.</param>
    /// <param name="pathParameters">The path parameters, in the order of the path template.</param>
    /// <param name="query">The query parameters.</param>
    /// <param name="body">The body, or null.</param>
    /// <param name="options">Options of this call.</param>
    /// <param name="cancellationToken">Cancels the call.</param>
    public async Task<ApiResponse> SendAsync(
        Operation operation,
        IReadOnlyList<string> pathParameters,
        QueryBuilder query,
        JsonNode? body,
        RequestOptions? options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(pathParameters);
        ArgumentNullException.ThrowIfNull(query);

        if (operation.Body == BodyMode.Required && body is null)
        {
            throw new ArgumentNullException(nameof(body), $"{operation.Id} needs a body");
        }

        if (operation.IfMatch == IfMatchMode.Required && string.IsNullOrEmpty(options?.IfMatch))
        {
            throw new ArgumentException($"{operation.Id} needs RequestOptions.IfMatch", nameof(options));
        }

        var url = new Uri(_base + ExpandPath(operation, pathParameters) + query.Encode());
        var idempotencyKey = operation.Idempotency == IdempotencyMode.None
            ? null
            : options?.IdempotencyKey ?? NewIdempotencyKey();
        var payload = body is null ? null : Encoding.UTF8.GetBytes(body.ToJsonString());
        var contentType = options?.ContentType ?? operation.ContentType ?? "application/json";
        var maxRetries = options?.MaxRetries ?? _options.MaxRetries;
        var timeout = options?.Timeout ?? _options.Timeout;

        for (var retry = 1; ; retry++)
        {
            HttpResponseMessage response;
            try
            {
                using var request = await BuildRequestAsync(operation, url, idempotencyKey, payload, contentType,
                    options, cancellationToken).ConfigureAwait(false);
                using var attemptToken = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                attemptToken.CancelAfter(timeout);
                response = await _http.SendAsync(request, attemptToken.Token).ConfigureAwait(false);
            }
            catch (Exception ex) when (Transport(ex, cancellationToken))
            {
                var decision = Decide(retry, maxRetries, RetryPolicy.TransportRetryable(operation.Method, idempotencyKey), null);
                if (decision.ShouldRetry)
                {
                    await _delay(decision.Delay, cancellationToken).ConfigureAwait(false);
                    continue;
                }

                throw new RelayConnectionException($"{operation.Id}: Relay could not be reached", ex);
            }

            using (response)
            {
                var status = (int)response.StatusCode;
                var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
                if (status is >= 200 and < 300)
                {
                    return new ApiResponse(status, Headers(response), bytes);
                }

                var error = Problem(status, response, bytes, _time.GetUtcNow());
                var decision = Decide(retry, maxRetries, error.Retryable, error.RetryAfter);
                if (decision.ShouldRetry)
                {
                    await _delay(decision.Delay, cancellationToken).ConfigureAwait(false);
                    continue;
                }

                throw ErrorMapping.Create(error);
            }
        }
    }

    internal async Task<JsonNode> SendJsonAsync(
        Operation operation,
        IReadOnlyList<string> pathParameters,
        QueryBuilder query,
        JsonNode? body,
        RequestOptions? options,
        CancellationToken cancellationToken)
    {
        var response = await SendAsync(operation, pathParameters, query, body, options, cancellationToken)
            .ConfigureAwait(false);
        return response.Json();
    }

    internal async Task<string> SendTextAsync(
        Operation operation,
        IReadOnlyList<string> pathParameters,
        QueryBuilder query,
        JsonNode? body,
        RequestOptions? options,
        CancellationToken cancellationToken)
    {
        var response = await SendAsync(operation, pathParameters, query, body, options, cancellationToken)
            .ConfigureAwait(false);
        return response.Text();
    }

    internal async Task SendEmptyAsync(
        Operation operation,
        IReadOnlyList<string> pathParameters,
        QueryBuilder query,
        JsonNode? body,
        RequestOptions? options,
        CancellationToken cancellationToken) =>
        await SendAsync(operation, pathParameters, query, body, options, cancellationToken).ConfigureAwait(false);

    internal async Task<Page> ListAsync(
        Operation operation,
        IReadOnlyList<string> pathParameters,
        QueryBuilder query,
        JsonNode? body,
        RequestOptions? options,
        CancellationToken cancellationToken)
    {
        var backward = query.Has("ending_before");
        if (backward && query.Has("starting_after"))
        {
            throw new ArgumentException($"{operation.Id} takes starting_after or ending_before, not both", nameof(query));
        }

        var json = await SendJsonAsync(operation, pathParameters, query, body, options, cancellationToken)
            .ConfigureAwait(false);
        var cursorName = backward ? "ending_before" : "starting_after";
        return new Page(json, backward, (cursor, token) =>
            ListAsync(operation, pathParameters, query.WithCursor(cursorName, cursor), body, options, token));
    }

    private RetryDecision Decide(int retry, int maxRetries, bool retryable, TimeSpan? retryAfter) =>
        RetryPolicy.Decide(retry, maxRetries, retryable, retryAfter, _random(), _options.BaseDelay,
            _options.MaxDelay, _options.MaxRetryAfter);

    internal static string NewIdempotencyKey() => Guid.NewGuid().ToString("D");

    private static string ExpandPath(Operation operation, IReadOnlyList<string> values)
    {
        var path = new StringBuilder();
        var index = 0;
        var template = operation.Path;
        for (var i = 0; i < template.Length; i++)
        {
            if (template[i] != '{')
            {
                path.Append(template[i]);
                continue;
            }

            var end = template.IndexOf('}', i);
            if (index >= values.Count || string.IsNullOrEmpty(values[index]))
            {
                throw new ArgumentException($"{operation.Id} needs the path parameter {template[(i + 1)..end]}");
            }

            path.Append(Uri.EscapeDataString(values[index++]));
            i = end;
        }

        return path.ToString();
    }

    private async Task<HttpRequestMessage> BuildRequestAsync(
        Operation operation,
        Uri url,
        string? idempotencyKey,
        byte[]? payload,
        string contentType,
        RequestOptions? options,
        CancellationToken cancellationToken)
    {
        var request = new HttpRequestMessage(new HttpMethod(operation.Method), url);
        try
        {
            var headers = request.Headers;
            headers.TryAddWithoutValidation("Relay-Version", RelayApiInfo.ApiVersion);
            headers.TryAddWithoutValidation("Accept", "application/json");
            headers.TryAddWithoutValidation("User-Agent", UserAgent);
            if (idempotencyKey is not null)
            {
                headers.TryAddWithoutValidation("Idempotency-Key", idempotencyKey);
            }

            if (options?.IfMatch is { Length: > 0 } ifMatch && operation.IfMatch != IfMatchMode.None)
            {
                headers.TryAddWithoutValidation("If-Match", ifMatch);
            }

            if (options?.Beta is { Length: > 0 } beta)
            {
                headers.TryAddWithoutValidation("Relay-Beta", beta);
            }

            if (options?.Headers is { } extra)
            {
                foreach (var (name, value) in extra)
                {
                    headers.TryAddWithoutValidation(name, value);
                }
            }

            var authorization = await _options.Credentials.AuthorizeAsync(operation.Method, url, cancellationToken)
                .ConfigureAwait(false);
            foreach (var (name, value) in authorization)
            {
                headers.Remove(name);
                headers.TryAddWithoutValidation(name, value);
            }

            if (payload is not null)
            {
                var content = new ByteArrayContent(payload);
                content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
                request.Content = content;
            }

            return request;
        }
        catch
        {
            request.Dispose();
            throw;
        }
    }

    private static bool Transport(Exception ex, CancellationToken cancellationToken) =>
        ex is HttpRequestException ||
        (ex is OperationCanceledException && !cancellationToken.IsCancellationRequested);

    private static Dictionary<string, IReadOnlyList<string>> Headers(HttpResponseMessage response)
    {
        var headers = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, values) in response.Headers)
        {
            headers[name] = [.. values];
        }

        foreach (var (name, values) in response.Content.Headers)
        {
            headers[name] = [.. values];
        }

        return headers;
    }

    internal static RelayError Problem(int status, HttpResponseMessage response, byte[] bytes, DateTimeOffset now)
    {
        JsonObject? problem = null;
        try
        {
            problem = bytes.Length == 0 ? null : JsonNode.Parse(bytes) as JsonObject;
        }
        catch (JsonException)
        {
        }

        var code = Text(problem, "code");
        var stated = problem?["retryable"] is JsonValue flag && flag.TryGetValue<bool>(out var b) ? b : (bool?)null;
        var retryAfter = RetryAfter(response, problem, now);
        var requestId = response.Headers.TryGetValues("Request-Id", out var ids) ? ids.FirstOrDefault() : null;
        return new RelayError(
            status,
            code,
            Text(problem, "title") ?? response.ReasonPhrase ?? "error",
            Text(problem, "detail"),
            Text(problem, "type"),
            Text(problem, "request_id") ?? requestId,
            ErrorCatalog.Retryable(status, code, stated),
            retryAfter,
            problem);
    }

    private static TimeSpan? RetryAfter(HttpResponseMessage response, JsonObject? problem, DateTimeOffset now)
    {
        if (response.Headers.TryGetValues("Retry-After", out var values) &&
            RetryPolicy.ParseRetryAfter(values.FirstOrDefault(), now) is { } header)
        {
            return header;
        }

        if (problem?["retry_after"] is JsonValue value && value.TryGetValue<long>(out var stated) && stated >= 0)
        {
            return TimeSpan.FromSeconds(stated);
        }

        return null;
    }

    private static string? Text(JsonObject? json, string name) =>
        json?[name] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}
