using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;

namespace Esuiss.Relay;

/// <summary>One page of a cursor-paginated list, with a lazy iterator over the whole list.</summary>
public sealed class Page
{
    private readonly Func<string, CancellationToken, Task<Page>> _next;

    internal Page(JsonNode json, Func<string, CancellationToken, Task<Page>> next)
    {
        Raw = json;
        _next = next;
        Data = json["data"] is JsonArray items ? [.. items.Select(item => item!)] : [];
        HasMore = json["has_more"] is JsonValue more && more.TryGetValue<bool>(out var flag) && flag;
        NextCursor = Cursor(json, "next_cursor");
        PreviousCursor = Cursor(json, "previous_cursor");
    }

    /// <summary>The items of this page.</summary>
    public IReadOnlyList<JsonNode> Data { get; }

    /// <summary>Whether more items follow this page.</summary>
    public bool HasMore { get; }

    /// <summary>The cursor of the next page, or null.</summary>
    public string? NextCursor { get; }

    /// <summary>The cursor of the previous page, or null.</summary>
    public string? PreviousCursor { get; }

    /// <summary>The page as Relay returned it.</summary>
    public JsonNode Raw { get; }

    /// <summary>Fetches the next page, or returns null when this is the last one.</summary>
    public async Task<Page?> NextPageAsync(CancellationToken cancellationToken = default)
    {
        if (!HasMore || NextCursor is null)
        {
            return null;
        }

        return await _next(NextCursor, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Iterates over the items of this page and of every following page; a page is fetched only when the iteration reaches it.</summary>
    public async IAsyncEnumerable<JsonNode> AllAsync([EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        Page? page = this;
        while (page is not null)
        {
            foreach (var item in page.Data)
            {
                yield return item;
            }

            page = await page.NextPageAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private static string? Cursor(JsonNode json, string name) =>
        json[name] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}
