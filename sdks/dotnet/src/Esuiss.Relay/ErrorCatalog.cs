namespace Esuiss.Relay;

internal sealed record ErrorCode(string Code, string Family, int Status, bool Retryable);

internal sealed record RetryableDefault(int Status, string? Code, bool Retryable);

internal static partial class ErrorCatalog
{
    internal static string? Family(string? code) =>
        code is not null && Codes.TryGetValue(code, out var entry) ? entry.Family : null;

    internal static bool Retryable(int status, string? code, bool? stated)
    {
        if (stated is { } value)
        {
            return value;
        }

        if (code is not null && Codes.TryGetValue(code, out var entry))
        {
            return entry.Retryable;
        }

        foreach (var row in Defaults)
        {
            if (row.Status == status && row.Code is not null && row.Code == code)
            {
                return row.Retryable;
            }
        }

        foreach (var row in Defaults)
        {
            if (row.Status == status && row.Code is null)
            {
                return row.Retryable;
            }
        }

        return status >= 500;
    }
}
