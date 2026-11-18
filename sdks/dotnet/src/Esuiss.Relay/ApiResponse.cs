using System.Text;
using System.Text.Json.Nodes;

namespace Esuiss.Relay;

/// <summary>A successful response of the Relay API.</summary>
public sealed class ApiResponse
{
    internal ApiResponse(int status, IReadOnlyDictionary<string, IReadOnlyList<string>> headers, byte[] body)
    {
        Status = status;
        Headers = headers;
        Body = body;
    }

    /// <summary>The HTTP status.</summary>
    public int Status { get; }

    /// <summary>The response headers; names are matched without regard to case.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<string>> Headers { get; }

    /// <summary>The raw body.</summary>
    public byte[] Body { get; }

    /// <summary>The Request-Id of the response.</summary>
    public string? RequestId => Header("Request-Id");

    /// <summary>Whether Relay replayed the stored first response of this Idempotency-Key.</summary>
    public bool IdempotencyReplayed => string.Equals(Header("Idempotency-Replayed"), "true", StringComparison.OrdinalIgnoreCase);

    /// <summary>The first value of a header, or null.</summary>
    public string? Header(string name) =>
        Headers.TryGetValue(name, out var values) && values.Count > 0 ? values[0] : null;

    /// <summary>The body parsed as JSON.</summary>
    public JsonNode Json() =>
        JsonNode.Parse(Body) ?? throw new RelayException("the response body is JSON null");

    /// <summary>The body as UTF-8 text.</summary>
    public string Text() => Encoding.UTF8.GetString(Body);
}
