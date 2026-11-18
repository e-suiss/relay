using System.Globalization;
using System.Text;
using YamlDotNet.Serialization;

namespace Esuiss.Relay.Generator;

internal static class Program
{
    private static readonly string[] Methods = ["get", "post", "put", "patch", "delete"];

    private static readonly HashSet<string> Keywords =
    [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked",
        "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else",
        "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for",
        "foreach", "from", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock",
        "long", "namespace", "new", "null", "object", "operator", "out", "override", "params",
        "private", "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short",
        "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
        "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "virtual",
        "void", "volatile", "while",
    ];

    private static readonly HashSet<string> Reserved = ["body", "options", "cancellationToken", "query", "path"];

    private static readonly Dictionary<string, object?> Documents = [];

    public static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("usage: <server.yaml> <errors.yaml> <output directory>");
            return 2;
        }

        var server = Path.GetFullPath(args[0]);
        var errors = Path.GetFullPath(args[1]);
        var output = Path.GetFullPath(args[2]);
        Directory.CreateDirectory(output);

        var document = Map(Load(server));
        var operations = ReadOperations(document, server);

        Write(Path.Combine(output, "RelayApiInfo.g.cs"), ApiInfo(document));
        Write(Path.Combine(output, "ErrorCatalog.g.cs"), ErrorCatalog(Map(Load(errors))));
        Write(Path.Combine(output, "Operations.g.cs"), OperationTable(operations));
        Write(Path.Combine(output, "RelayApi.g.cs"), Api(operations));
        return 0;
    }

    private static void Write(string path, string content) =>
        File.WriteAllText(path, content.ReplaceLineEndings("\n"), new UTF8Encoding(false));

    private static object? Load(string path)
    {
        if (!Documents.TryGetValue(path, out var document))
        {
            document = new DeserializerBuilder().Build().Deserialize<object?>(File.ReadAllText(path));
            Documents[path] = document;
        }

        return document;
    }

    private static Dictionary<object, object> Map(object? node) =>
        node as Dictionary<object, object> ?? [];

    private static List<object> List(object? node) => node as List<object> ?? [];

    private static string? Text(Dictionary<object, object> map, string key) =>
        map.TryGetValue(key, out var value) ? value as string : null;

    private static (Dictionary<object, object> Node, string File) Resolve(object? node, string file)
    {
        var map = Map(node);
        var guard = 0;
        while (Text(map, "$ref") is { } reference && guard++ < 32)
        {
            var hash = reference.IndexOf('#', StringComparison.Ordinal);
            var target = hash < 0 ? reference : reference[..hash];
            var pointer = hash < 0 ? "" : reference[(hash + 1)..];
            if (target.Length > 0)
            {
                file = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, target));
            }

            object? current = Load(file);
            foreach (var segment in pointer.Split('/', StringSplitOptions.RemoveEmptyEntries))
            {
                var key = segment.Replace("~1", "/", StringComparison.Ordinal).Replace("~0", "~", StringComparison.Ordinal);
                current = Map(current).TryGetValue(key, out var next) ? next : null;
            }

            map = Map(current);
        }

        return (map, file);
    }

    private static string ApiInfo(Dictionary<object, object> document)
    {
        var version = Text(Map(document["info"]), "version") ?? throw new InvalidOperationException("info.version");
        var b = new StringBuilder();
        b.Append("#nullable enable\n\n");
        b.Append("namespace Esuiss.Relay;\n\n");
        b.Append("/// <summary>The Relay API version this SDK is pinned to.</summary>\n");
        b.Append("public static partial class RelayApiInfo\n{\n");
        b.Append("    /// <summary>The dated API version sent as Relay-Version on every request.</summary>\n");
        b.Append(CultureInfo.InvariantCulture, $"    public const string ApiVersion = {Literal(version)};\n");
        b.Append("}\n");
        return b.ToString();
    }

    private static string ErrorCatalog(Dictionary<object, object> errors)
    {
        var b = new StringBuilder();
        b.Append("#nullable enable\n\n");
        b.Append("namespace Esuiss.Relay;\n\n");
        b.Append("internal static partial class ErrorCatalog\n{\n");
        b.Append("    internal static readonly IReadOnlyDictionary<string, ErrorCode> Codes = new Dictionary<string, ErrorCode>\n    {\n");
        foreach (var entry in List(errors["codes"]))
        {
            var code = Map(entry);
            var name = Text(code, "code")!;
            b.Append(CultureInfo.InvariantCulture,
                $"        [{Literal(name)}] = new({Literal(name)}, {Literal(Text(code, "family")!)}, {Text(code, "status")}, {Text(code, "retryable")}),\n");
        }

        b.Append("    };\n\n");
        b.Append("    internal static readonly IReadOnlyList<RetryableDefault> Defaults =\n    [\n");
        foreach (var entry in List(errors["retryable_defaults"]))
        {
            var row = Map(entry);
            var code = Text(row, "code");
            b.Append(CultureInfo.InvariantCulture,
                $"        new({Text(row, "status")}, {(code is null ? "null" : Literal(code))}, {Text(row, "retryable")}),\n");
        }

        b.Append("    ];\n}\n");
        return b.ToString();
    }

    private sealed record Parameter(string Name, string Identifier, string Kind, bool Required);

    private sealed record Op(
        string Id,
        string Method,
        string Path,
        string Summary,
        List<Parameter> PathParameters,
        List<Parameter> QueryParameters,
        string Idempotency,
        string IfMatch,
        string Body,
        string? ContentType,
        bool Paginated,
        string Response);

    private static List<Op> ReadOperations(Dictionary<object, object> document, string file)
    {
        var operations = new List<Op>();
        var topSecurity = document.TryGetValue("security", out var s) ? s : null;
        foreach (var (pathKey, item) in Map(document["paths"]))
        {
            var path = (string)pathKey;
            foreach (var (methodKey, node) in Map(item))
            {
                var method = (string)methodKey;
                if (!Methods.Contains(method))
                {
                    continue;
                }

                var op = Map(node);
                var security = op.TryGetValue("security", out var own) ? own : topSecurity;
                if (!List(security).Any(entry => Map(entry).ContainsKey("access_bearer")))
                {
                    continue;
                }

                operations.Add(ReadOperation(path, method, op, file));
            }
        }

        return operations;
    }

    private static Op ReadOperation(string path, string method, Dictionary<object, object> op, string file)
    {
        var id = Text(op, "operationId")!;
        var pathParameters = new List<Parameter>();
        var queryParameters = new List<Parameter>();
        var idempotency = "None";
        var ifMatch = "None";
        var paginated = false;
        var used = new HashSet<string>(Reserved);

        foreach (var entry in List(op.GetValueOrDefault("parameters")))
        {
            var reference = Text(Map(entry), "$ref") ?? "";
            var (parameter, parameterFile) = Resolve(entry, file);
            var name = Text(parameter, "name")!;
            var location = Text(parameter, "in");
            switch (location)
            {
                case "header" when reference.EndsWith("#/IdempotencyKey", StringComparison.Ordinal):
                    idempotency = "Required";
                    break;
                case "header" when reference.EndsWith("#/IdempotencyKeyCloudEvents", StringComparison.Ordinal):
                    idempotency = "Optional";
                    break;
                case "header" when reference.EndsWith("#/IfMatch", StringComparison.Ordinal):
                    ifMatch = "Required";
                    break;
                case "header" when reference.EndsWith("#/IfMatchOptional", StringComparison.Ordinal):
                    ifMatch = "Optional";
                    break;
                case "path":
                    pathParameters.Add(new Parameter(name, Identifier(name, used), "string", true));
                    break;
                case "query":
                    if (name == "starting_after" && method == "get")
                    {
                        paginated = true;
                    }

                    var kind = QueryKind(parameter, parameterFile);
                    queryParameters.Add(new Parameter(name, Identifier(name, used), kind, Text(parameter, "required") == "true"));
                    break;
                default:
                    break;
            }
        }

        pathParameters = [.. pathParameters.OrderBy(p => path.IndexOf("{" + p.Name + "}", StringComparison.Ordinal))];

        var body = "None";
        string? contentType = null;
        if (op.TryGetValue("requestBody", out var requestBody))
        {
            var (resolved, _) = Resolve(requestBody, file);
            body = Text(resolved, "required") == "true" ? "Required" : "Optional";
            contentType = Map(resolved.GetValueOrDefault("content")).Keys.Cast<string>().FirstOrDefault();
        }

        var response = "None";
        foreach (var (codeKey, responseNode) in Map(op["responses"]))
        {
            var code = (string)codeKey;
            if (!code.StartsWith('2'))
            {
                continue;
            }

            var (resolved, _) = Resolve(responseNode, file);
            var content = Map(resolved.GetValueOrDefault("content"));
            response = content.ContainsKey("application/json") ? "Json" : content.Count > 0 ? "Text" : "None";
            break;
        }

        var summary = Text(op, "summary") ?? id;
        return new Op(id, method.ToUpperInvariant(), path, summary, pathParameters, queryParameters,
            idempotency, ifMatch, body, contentType, paginated, response);
    }

    private static string QueryKind(Dictionary<object, object> parameter, string file)
    {
        var (schema, _) = Resolve(parameter.GetValueOrDefault("schema"), file);
        var type = schema.GetValueOrDefault("type");
        var name = type as string ?? List(type).Cast<string>().FirstOrDefault(t => t != "null");
        return name switch
        {
            "integer" => "integer",
            "boolean" => "boolean",
            "array" => "string_array",
            _ => "string",
        };
    }

    private static string Identifier(string name, HashSet<string> used)
    {
        var parts = name.Split(['_', '.', '-'], StringSplitOptions.RemoveEmptyEntries);
        var b = new StringBuilder(parts[0]);
        foreach (var part in parts.Skip(1))
        {
            b.Append(char.ToUpperInvariant(part[0])).Append(part[1..]);
        }

        var identifier = b.ToString();
        while (!used.Add(identifier))
        {
            identifier += "Value";
        }

        return Keywords.Contains(identifier) ? "@" + identifier : identifier;
    }

    private static string Pascal(string id) => char.ToUpperInvariant(id[0]) + id[1..];

    private static string Literal(string value)
    {
        var b = new StringBuilder("\"");
        foreach (var c in value)
        {
            b.Append(c switch
            {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                _ => c.ToString(),
            });
        }

        return b.Append('"').ToString();
    }

    private static string Xml(string value) =>
        value.Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal);

    private static string OperationTable(List<Op> operations)
    {
        var b = new StringBuilder();
        b.Append("#nullable enable\n\n");
        b.Append("namespace Esuiss.Relay;\n\n");
        b.Append("/// <summary>Every operation of the Relay server API that an API client calls.</summary>\n");
        b.Append("public static partial class Operations\n{\n");
        foreach (var op in operations)
        {
            var contentType = op.ContentType is null ? "null" : Literal(op.ContentType);
            b.Append(CultureInfo.InvariantCulture, $"    /// <summary>{Xml(op.Summary)}</summary>\n");
            b.Append(CultureInfo.InvariantCulture,
                $"    public static readonly Operation {Pascal(op.Id)} = new({Literal(op.Id)}, {Literal(op.Method)}, {Literal(op.Path)}, IdempotencyMode.{op.Idempotency}, IfMatchMode.{op.IfMatch}, BodyMode.{op.Body}, {contentType}, ResponseKind.{op.Response});\n\n");
        }

        b.Append("    /// <summary>All operations, in contract order.</summary>\n");
        b.Append("    public static readonly IReadOnlyList<Operation> All =\n    [\n");
        foreach (var op in operations)
        {
            b.Append(CultureInfo.InvariantCulture, $"        {Pascal(op.Id)},\n");
        }

        b.Append("    ];\n}\n");
        return b.ToString();
    }

    private static string ParameterType(Parameter p, bool optional) => p.Kind switch
    {
        "integer" => optional ? "int?" : "int",
        "boolean" => optional ? "bool?" : "bool",
        "string_array" => optional ? "IEnumerable<string>?" : "IEnumerable<string>",
        _ => optional ? "string?" : "string",
    };

    private static string Api(List<Op> operations)
    {
        var b = new StringBuilder();
        b.Append("#nullable enable\n\n");
        b.Append("using System.Text.Json.Nodes;\n\n");
        b.Append("namespace Esuiss.Relay;\n\n");
        b.Append("/// <summary>One method for every operation of the Relay server API.</summary>\n");
        b.Append("public sealed partial class RelayApi\n{\n");
        var first = true;
        foreach (var op in operations)
        {
            if (!first)
            {
                b.Append('\n');
            }

            first = false;
            var args = new List<string>();
            args.AddRange(op.PathParameters.Select(p => "string " + p.Identifier));
            if (op.Body == "Required")
            {
                args.Add("JsonNode body");
            }

            args.AddRange(op.QueryParameters.Where(p => p.Required).Select(p => ParameterType(p, false) + " " + p.Identifier));
            if (op.Body == "Optional")
            {
                args.Add("JsonNode? body = null");
            }

            args.AddRange(op.QueryParameters.Where(p => !p.Required).Select(p => ParameterType(p, true) + " " + p.Identifier + " = null"));
            args.Add("RequestOptions? options = null");
            args.Add("CancellationToken cancellationToken = default");

            var returns = op.Paginated ? "Task<Page>" : op.Response switch
            {
                "Json" => "Task<JsonNode>",
                "Text" => "Task<string>",
                _ => "Task",
            };
            var call = op.Paginated ? "ListAsync" : op.Response switch
            {
                "Json" => "SendJsonAsync",
                "Text" => "SendTextAsync",
                _ => "SendEmptyAsync",
            };

            b.Append(CultureInfo.InvariantCulture, $"    /// <summary>{Xml(op.Summary)}</summary>\n");
            b.Append(CultureInfo.InvariantCulture, $"    public {returns} {Pascal(op.Id)}Async(\n");
            for (var i = 0; i < args.Count; i++)
            {
                b.Append(CultureInfo.InvariantCulture, $"        {args[i]}{(i == args.Count - 1 ? ")" : ",")}\n");
            }

            b.Append("    {\n");
            var pathArgs = op.PathParameters.Count == 0
                ? "[]"
                : "[" + string.Join(", ", op.PathParameters.Select(p => p.Identifier)) + "]";
            b.Append("        var query = new QueryBuilder();\n");
            foreach (var p in op.QueryParameters)
            {
                b.Append(CultureInfo.InvariantCulture, $"        query.Add({Literal(p.Name)}, {p.Identifier});\n");
            }

            var bodyArg = op.Body == "None" ? "null" : "body";
            b.Append(CultureInfo.InvariantCulture,
                $"        return _client.{call}(Operations.{Pascal(op.Id)}, {pathArgs}, query, {bodyArg}, options, cancellationToken);\n");
            b.Append("    }\n");
        }

        b.Append("}\n");
        return b.ToString();
    }
}
