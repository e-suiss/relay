using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Esuiss.Relay;

/// <summary>Supplies the authorization headers of each request attempt.</summary>
public interface IRelayCredentials
{
    /// <summary>Returns the headers that authorize one attempt of a request.</summary>
    /// <param name="method">The HTTP method.</param>
    /// <param name="url">The full request URL.</param>
    /// <param name="cancellationToken">Cancels the call.</param>
    ValueTask<IReadOnlyList<KeyValuePair<string, string>>> AuthorizeAsync(
        string method,
        Uri url,
        CancellationToken cancellationToken);
}

/// <summary>A DPoP-bound Access access token obtained elsewhere, with the key it is bound to.</summary>
public sealed class DpopTokenCredentials : IRelayCredentials
{
    private readonly Func<CancellationToken, ValueTask<string>> _token;
    private readonly DpopKey _key;
    private readonly TimeProvider _time;

    /// <summary>Uses a fixed access token.</summary>
    public DpopTokenCredentials(string accessToken, DpopKey key, TimeProvider? timeProvider = null)
        : this(_ => ValueTask.FromResult(accessToken), key, timeProvider)
    {
        ArgumentException.ThrowIfNullOrEmpty(accessToken);
    }

    /// <summary>Asks a callback for the current access token before every attempt.</summary>
    public DpopTokenCredentials(
        Func<CancellationToken, ValueTask<string>> accessToken,
        DpopKey key,
        TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(accessToken);
        ArgumentNullException.ThrowIfNull(key);
        _token = accessToken;
        _key = key;
        _time = timeProvider ?? TimeProvider.System;
    }

    /// <inheritdoc />
    public async ValueTask<IReadOnlyList<KeyValuePair<string, string>>> AuthorizeAsync(
        string method,
        Uri url,
        CancellationToken cancellationToken)
    {
        var token = await _token(cancellationToken).ConfigureAwait(false);
        return
        [
            new("Authorization", "DPoP " + token),
            new("DPoP", _key.CreateProof(method, url, token, _time.GetUtcNow())),
        ];
    }
}

/// <summary>Obtains DPoP-bound access tokens from Access with the OAuth 2.0 client credentials grant and keeps them until shortly before they expire.</summary>
public sealed class AccessClientCredentials : IRelayCredentials, IDisposable
{
    private static readonly TimeSpan Skew = TimeSpan.FromSeconds(30);

    private readonly Uri _tokenEndpoint;
    private readonly string _clientId;
    private readonly string _clientSecret;
    private readonly string _resource;
    private readonly string? _scope;
    private readonly DpopKey _key;
    private readonly HttpClient _http;
    private readonly bool _ownsHttp;
    private readonly TimeProvider _time;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private string? _token;
    private DateTimeOffset _expiresAt;

    /// <summary>Creates the credentials.</summary>
    /// <param name="tokenEndpoint">The token endpoint of the Access issuer.</param>
    /// <param name="clientId">The Access client id of the API client.</param>
    /// <param name="clientSecret">The Access client secret of the API client.</param>
    /// <param name="resource">Relay's Access client id (access_client_id in Relay's discovery document).</param>
    /// <param name="key">The DPoP key the tokens are bound to.</param>
    /// <param name="scope">Space separated scopes that narrow the token, or null.</param>
    /// <param name="httpClient">The HTTP client for the token endpoint, or null for a new one.</param>
    /// <param name="timeProvider">The clock, or null for the system clock.</param>
    public AccessClientCredentials(
        Uri tokenEndpoint,
        string clientId,
        string clientSecret,
        string resource,
        DpopKey key,
        string? scope = null,
        HttpClient? httpClient = null,
        TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(tokenEndpoint);
        ArgumentException.ThrowIfNullOrEmpty(clientId);
        ArgumentException.ThrowIfNullOrEmpty(clientSecret);
        ArgumentException.ThrowIfNullOrEmpty(resource);
        ArgumentNullException.ThrowIfNull(key);
        if (tokenEndpoint.Scheme != Uri.UriSchemeHttps)
        {
            throw new ArgumentException("the token endpoint must be an https URL", nameof(tokenEndpoint));
        }

        _tokenEndpoint = tokenEndpoint;
        _clientId = clientId;
        _clientSecret = clientSecret;
        _resource = resource;
        _scope = scope;
        _key = key;
        _ownsHttp = httpClient is null;
        _http = httpClient ?? new HttpClient();
        _time = timeProvider ?? TimeProvider.System;
    }

    /// <inheritdoc />
    public async ValueTask<IReadOnlyList<KeyValuePair<string, string>>> AuthorizeAsync(
        string method,
        Uri url,
        CancellationToken cancellationToken)
    {
        var token = await TokenAsync(cancellationToken).ConfigureAwait(false);
        return
        [
            new("Authorization", "DPoP " + token),
            new("DPoP", _key.CreateProof(method, url, token, _time.GetUtcNow())),
        ];
    }

    /// <summary>Forgets the cached token, so the next request obtains a new one.</summary>
    public void Invalidate() => _token = null;

    /// <inheritdoc />
    public void Dispose()
    {
        _lock.Dispose();
        if (_ownsHttp)
        {
            _http.Dispose();
        }
    }

    private async Task<string> TokenAsync(CancellationToken cancellationToken)
    {
        await _lock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_token is not null && _time.GetUtcNow() < _expiresAt)
            {
                return _token;
            }

            var (token, lifetime) = await RequestAsync(null, true, cancellationToken).ConfigureAwait(false);
            _token = token;
            _expiresAt = _time.GetUtcNow() + lifetime - Skew;
            return token;
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task<(string Token, TimeSpan Lifetime)> RequestAsync(
        string? nonce,
        bool nonceAllowed,
        CancellationToken cancellationToken)
    {
        var form = new List<KeyValuePair<string, string>>
        {
            new("grant_type", "client_credentials"),
            new("resource", _resource),
        };
        if (_scope is not null)
        {
            form.Add(new("scope", _scope));
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, _tokenEndpoint)
        {
            Content = new FormUrlEncodedContent(form),
        };
        var basic = Uri.EscapeDataString(_clientId) + ":" + Uri.EscapeDataString(_clientSecret);
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes(basic)));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.TryAddWithoutValidation("DPoP", _key.CreateProof("POST", _tokenEndpoint, null, _time.GetUtcNow(), nonce));

        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        var json = Parse(body);
        var status = (int)response.StatusCode;

        if (status == 400 && nonceAllowed && Text(json, "error") == "use_dpop_nonce" &&
            response.Headers.TryGetValues("DPoP-Nonce", out var nonces) &&
            nonces.FirstOrDefault() is { Length: > 0 } issued)
        {
            return await RequestAsync(issued, false, cancellationToken).ConfigureAwait(false);
        }

        if (status != 200)
        {
            var code = Text(json, "error") is { } error ? "access_" + error : "access_token_refused";
            var relayError = new RelayError(status, code, "Access refused the token request",
                Text(json, "error_description"), null, null, status >= 500 || status == 429, null, json);
            throw status >= 500 ? new RelayServerException(relayError) : new RelayAuthenticationException(relayError);
        }

        var token = Text(json, "access_token");
        var type = Text(json, "token_type");
        if (string.IsNullOrEmpty(token) || !string.Equals(type, "DPoP", StringComparison.OrdinalIgnoreCase))
        {
            throw new RelayAuthenticationException(new RelayError(status, "access_token_not_dpop",
                "Access did not issue a DPoP access token", null, null, null, false, null, json));
        }

        var seconds = json?["expires_in"] is JsonValue value && value.TryGetValue<long>(out var s) ? s : 300;
        return (token, TimeSpan.FromSeconds(seconds));
    }

    private static JsonObject? Parse(byte[] body)
    {
        try
        {
            return body.Length == 0 ? null : JsonNode.Parse(body) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Text(JsonObject? json, string name) =>
        json?[name] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}
