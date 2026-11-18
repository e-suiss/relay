using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;

namespace Esuiss.Relay;

/// <summary>The signature scheme that verified a webhook.</summary>
public enum WebhookScheme
{
    /// <summary>Ed25519, the default.</summary>
    V1a,

    /// <summary>HMAC-SHA256, for compatibility.</summary>
    V1,
}

/// <summary>Why a webhook was refused.</summary>
public enum WebhookRejection
{
    /// <summary>A signed header is missing.</summary>
    MissingHeader,

    /// <summary>A signed header appears more than once.</summary>
    DuplicateHeader,

    /// <summary>A signed header is not well formed.</summary>
    MalformedHeader,

    /// <summary>webhook-timestamp is outside the tolerance.</summary>
    TimestampOutOfTolerance,

    /// <summary>No signature verifies against any key.</summary>
    NoMatchingSignature,
}

/// <summary>A verified webhook.</summary>
/// <param name="Id">The webhook-id, the same for every attempt; deduplicate by it.</param>
/// <param name="Timestamp">The webhook-timestamp in Unix seconds.</param>
/// <param name="Scheme">The scheme of the signature that verified.</param>
public sealed record VerifiedWebhook(string Id, long Timestamp, WebhookScheme Scheme);

/// <summary>A webhook that failed verification.</summary>
public sealed class WebhookVerificationException : RelayException
{
    /// <summary>Creates the error.</summary>
    public WebhookVerificationException(WebhookRejection rejection)
        : base("webhook refused: " + rejection)
    {
        Rejection = rejection;
    }

    /// <summary>Why the webhook was refused.</summary>
    public WebhookRejection Rejection { get; }
}

/// <summary>Verifies webhooks of the Suiss webhook profile (Standard Webhooks headers, v1a Ed25519 and v1 HMAC-SHA256 signatures) over the raw request body.</summary>
public sealed partial class WebhookVerifier
{
    private const string IdHeader = "webhook-id";
    private const string TimestampHeader = "webhook-timestamp";
    private const string SignatureHeader = "webhook-signature";

    private readonly List<(WebhookScheme Scheme, byte[] Key)> _keys = [];
    private readonly TimeSpan _tolerance;
    private readonly TimeProvider _time;

    /// <summary>Creates a verifier.</summary>
    /// <param name="keys">Every key that may have signed: whpk_ (Ed25519 public key) or whsec_ (HMAC secret) text forms.</param>
    /// <param name="tolerance">The allowed distance between now and webhook-timestamp; defaults to 5 minutes.</param>
    /// <param name="timeProvider">The clock, or null for the system clock.</param>
    public WebhookVerifier(IEnumerable<string> keys, TimeSpan? tolerance = null, TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(keys);
        foreach (var key in keys)
        {
            _keys.Add(ParseKey(key));
        }

        if (_keys.Count == 0)
        {
            throw new ArgumentException("at least one key is needed", nameof(keys));
        }

        _tolerance = tolerance ?? TimeSpan.FromMinutes(5);
        _time = timeProvider ?? TimeProvider.System;
    }

    /// <summary>Verifies a webhook against the current time.</summary>
    /// <param name="headers">The request headers as they arrived, one pair per occurrence.</param>
    /// <param name="rawBody">The request body exactly as it arrived.</param>
    public VerifiedWebhook Verify(IEnumerable<KeyValuePair<string, string>> headers, ReadOnlySpan<byte> rawBody) =>
        Verify(headers, rawBody, _time.GetUtcNow());

    /// <summary>Verifies a webhook from HttpHeaders against the current time.</summary>
    public VerifiedWebhook Verify(HttpHeaders headers, ReadOnlySpan<byte> rawBody)
    {
        ArgumentNullException.ThrowIfNull(headers);
        var pairs = headers.SelectMany(h => h.Value.Select(v => new KeyValuePair<string, string>(h.Key, v)));
        return Verify(pairs, rawBody, _time.GetUtcNow());
    }

    /// <summary>Verifies a webhook at a given time.</summary>
    public VerifiedWebhook Verify(IEnumerable<KeyValuePair<string, string>> headers, ReadOnlySpan<byte> rawBody, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(headers);
        var list = headers.ToList();
        var id = Header(list, IdHeader);
        var timestampText = Header(list, TimestampHeader);
        var signatureText = Header(list, SignatureHeader);

        if (!IdSyntax().IsMatch(id) || !TimestampSyntax().IsMatch(timestampText))
        {
            throw new WebhookVerificationException(WebhookRejection.MalformedHeader);
        }

        var timestamp = long.Parse(timestampText, System.Globalization.CultureInfo.InvariantCulture);
        var tokens = ParseSignatures(signatureText);
        if (Math.Abs(now.ToUnixTimeSeconds() - timestamp) > _tolerance.TotalSeconds)
        {
            throw new WebhookVerificationException(WebhookRejection.TimestampOutOfTolerance);
        }

        var content = SignedContent(id, timestamp, rawBody);
        foreach (var (scheme, signature) in tokens)
        {
            foreach (var (keyScheme, key) in _keys)
            {
                if (scheme == keyScheme && Valid(scheme, signature, key, content))
                {
                    return new VerifiedWebhook(id, timestamp, scheme);
                }
            }
        }

        throw new WebhookVerificationException(WebhookRejection.NoMatchingSignature);
    }

    /// <summary>The signed content of a message: id, timestamp and the raw body joined by dots.</summary>
    public static byte[] SignedContent(string id, long timestamp, ReadOnlySpan<byte> rawBody)
    {
        ArgumentNullException.ThrowIfNull(id);
        var prefix = Encoding.UTF8.GetBytes(id + "." + timestamp.ToString(System.Globalization.CultureInfo.InvariantCulture) + ".");
        var content = new byte[prefix.Length + rawBody.Length];
        prefix.CopyTo(content, 0);
        rawBody.CopyTo(content.AsSpan(prefix.Length));
        return content;
    }

    private static (WebhookScheme, byte[]) ParseKey(string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        if (key.StartsWith("whpk_", StringComparison.Ordinal) && TryBase64(key[5..], out var publicKey) && publicKey.Length == 32)
        {
            return (WebhookScheme.V1a, publicKey);
        }

        if (key.StartsWith("whsec_", StringComparison.Ordinal) && TryBase64(key[6..], out var secret) && secret.Length >= 24)
        {
            return (WebhookScheme.V1, secret);
        }

        throw new ArgumentException("a key is whpk_<base64 Ed25519 public key> or whsec_<base64 secret>", nameof(key));
    }

    private static string Header(List<KeyValuePair<string, string>> headers, string name)
    {
        string? found = null;
        var count = 0;
        foreach (var (key, value) in headers)
        {
            if (string.Equals(key, name, StringComparison.OrdinalIgnoreCase))
            {
                found = value;
                count++;
            }
        }

        return count switch
        {
            0 => throw new WebhookVerificationException(WebhookRejection.MissingHeader),
            1 when found is not null => found,
            1 => throw new WebhookVerificationException(WebhookRejection.MalformedHeader),
            _ => throw new WebhookVerificationException(WebhookRejection.DuplicateHeader),
        };
    }

    private static List<(WebhookScheme, byte[])> ParseSignatures(string value)
    {
        var tokens = new List<(WebhookScheme, byte[])>();
        var parts = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
        {
            throw new WebhookVerificationException(WebhookRejection.MalformedHeader);
        }

        foreach (var part in parts)
        {
            if (part.StartsWith("v1a,", StringComparison.Ordinal))
            {
                tokens.Add((WebhookScheme.V1a, Decode(part[4..], 64)));
            }
            else if (part.StartsWith("v1,", StringComparison.Ordinal))
            {
                tokens.Add((WebhookScheme.V1, Decode(part[3..], 32)));
            }
            else if (!OtherScheme().IsMatch(part))
            {
                throw new WebhookVerificationException(WebhookRejection.MalformedHeader);
            }
        }

        return tokens;
    }

    private static byte[] Decode(string text, int size) =>
        TryBase64(text, out var bytes) && bytes.Length == size
            ? bytes
            : throw new WebhookVerificationException(WebhookRejection.MalformedHeader);

    private static bool TryBase64(string text, out byte[] bytes)
    {
        bytes = [];
        if (text.Length == 0 || text.Length % 4 != 0 || !Base64Syntax().IsMatch(text))
        {
            return false;
        }

        try
        {
            bytes = Convert.FromBase64String(text);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool Valid(WebhookScheme scheme, byte[] signature, byte[] key, byte[] content)
    {
        if (scheme == WebhookScheme.V1)
        {
            return CryptographicOperations.FixedTimeEquals(HMACSHA256.HashData(key, content), signature);
        }

        var verifier = new Ed25519Signer();
        verifier.Init(false, new Ed25519PublicKeyParameters(key, 0));
        verifier.BlockUpdate(content, 0, content.Length);
        return verifier.VerifySignature(signature);
    }

    [GeneratedRegex(@"\A[\x21-\x7E]{1,256}\z")]
    private static partial Regex IdSyntax();

    [GeneratedRegex(@"\A(?:0|[1-9][0-9]{0,14})\z")]
    private static partial Regex TimestampSyntax();

    [GeneratedRegex(@"\Av[0-9][0-9a-z]{0,7},[A-Za-z0-9+/=_-]+\z")]
    private static partial Regex OtherScheme();

    [GeneratedRegex(@"\A[A-Za-z0-9+/]*={0,2}\z")]
    private static partial Regex Base64Syntax();
}
