using System.Globalization;
using System.Text;

namespace Esuiss.Relay;

/// <summary>The query parameters of a request, in the order they were added.</summary>
public sealed class QueryBuilder
{
    private readonly List<KeyValuePair<string, string>> _values = [];

    /// <summary>The parameters added so far.</summary>
    public IReadOnlyList<KeyValuePair<string, string>> Values => _values;

    /// <summary>Adds a text parameter unless it is null.</summary>
    public void Add(string name, string? value)
    {
        if (value is not null)
        {
            _values.Add(new(name, value));
        }
    }

    /// <summary>Adds an integer parameter unless it is null.</summary>
    public void Add(string name, int? value)
    {
        if (value is { } number)
        {
            _values.Add(new(name, number.ToString(CultureInfo.InvariantCulture)));
        }
    }

    /// <summary>Adds a boolean parameter unless it is null.</summary>
    public void Add(string name, bool? value)
    {
        if (value is { } flag)
        {
            _values.Add(new(name, flag ? "true" : "false"));
        }
    }

    /// <summary>Adds a list parameter as comma separated values unless it is null.</summary>
    public void Add(string name, IEnumerable<string>? values)
    {
        if (values is not null)
        {
            _values.Add(new(name, string.Join(',', values)));
        }
    }

    internal bool Has(string name) => _values.Exists(pair => pair.Key == name);

    internal QueryBuilder WithCursor(string name, string cursor)
    {
        var next = new QueryBuilder();
        foreach (var pair in _values)
        {
            if (pair.Key is not "starting_after" and not "ending_before")
            {
                next._values.Add(pair);
            }
        }

        next._values.Add(new(name, cursor));
        return next;
    }

    internal string Encode()
    {
        if (_values.Count == 0)
        {
            return "";
        }

        var b = new StringBuilder("?");
        for (var i = 0; i < _values.Count; i++)
        {
            if (i > 0)
            {
                b.Append('&');
            }

            b.Append(Uri.EscapeDataString(_values[i].Key)).Append('=').Append(Uri.EscapeDataString(_values[i].Value));
        }

        return b.ToString();
    }
}
