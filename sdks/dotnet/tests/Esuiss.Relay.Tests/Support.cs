using System.Net;
using System.Text;
using System.Text.Json.Nodes;

namespace Esuiss.Relay.Tests;

public sealed record RecordedRequest(
    string Method,
    Uri Url,
    Dictionary<string, string> Headers,
    string? Body,
    string? ContentType);

public sealed class StubHandler : HttpMessageHandler
{
    private readonly Queue<Func<HttpRequestMessage, HttpResponseMessage>> _responses = new();

    public List<RecordedRequest> Requests { get; } = [];

    public StubHandler Respond(Func<HttpRequestMessage, HttpResponseMessage> response)
    {
        _responses.Enqueue(response);
        return this;
    }

    public StubHandler Json(int status, string body, params (string Name, string Value)[] headers) =>
        Respond(_ => Response(status, body, "application/json", headers));

    public StubHandler Problem(int status, string body, params (string Name, string Value)[] headers) =>
        Respond(_ => Response(status, body, "application/problem+json", headers));

    public StubHandler Fail() => Respond(_ => throw new HttpRequestException("connection refused"));

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, values) in request.Headers)
        {
            headers[name] = string.Join(", ", values);
        }

        string? body = null;
        string? contentType = null;
        if (request.Content is not null)
        {
            body = await request.Content.ReadAsStringAsync(cancellationToken);
            contentType = request.Content.Headers.ContentType?.ToString();
        }

        Requests.Add(new RecordedRequest(request.Method.Method, request.RequestUri!, headers, body, contentType));
        if (_responses.Count == 0)
        {
            throw new InvalidOperationException("no stubbed response left");
        }

        return _responses.Dequeue()(request);
    }

    public static HttpResponseMessage Response(int status, string body, string contentType, params (string Name, string Value)[] headers)
    {
        var response = new HttpResponseMessage((HttpStatusCode)status)
        {
            Content = new StringContent(body, Encoding.UTF8, contentType),
        };
        foreach (var (name, value) in headers)
        {
            response.Headers.TryAddWithoutValidation(name, value);
        }

        return response;
    }
}

public sealed class Harness : IDisposable
{
    public Harness(int maxRetries = 3, double random = 0.5)
    {
        Handler = new StubHandler();
        Http = new HttpClient(Handler);
        Key = DpopKey.FromSeed(new byte[32]);
        Client = new RelayClient(new RelayClientOptions
        {
            BaseUrl = new Uri("https://relay.example.com"),
            Credentials = new DpopTokenCredentials("token-1", Key),
            HttpClient = Http,
            MaxRetries = maxRetries,
            Delay = (wait, _) =>
            {
                Delays.Add(wait);
                return Task.CompletedTask;
            },
            Random = () => random,
        });
    }

    public StubHandler Handler { get; }

    public HttpClient Http { get; }

    public DpopKey Key { get; }

    public RelayClient Client { get; }

    public List<TimeSpan> Delays { get; } = [];

    public void Dispose()
    {
        Client.Dispose();
        Http.Dispose();
        Handler.Dispose();
    }
}

public static class Repo
{
    public static string Path(string relative)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = System.IO.Path.Combine(dir.FullName, relative);
            if (File.Exists(candidate))
            {
                return candidate;
            }

            dir = dir.Parent;
        }

        throw new FileNotFoundException(relative);
    }

    public static JsonNode Json(string relative) => JsonNode.Parse(File.ReadAllText(Path(relative)))!;
}
