<?php

declare(strict_types=1);

namespace Esuiss\Relay\Auth;

use Closure;
use Esuiss\Relay\Exception\TokenException;
use Esuiss\Relay\Http\CurlTransport;
use Esuiss\Relay\Http\HttpRequest;
use Esuiss\Relay\Http\HttpResponse;
use Esuiss\Relay\Http\Transport;
use JsonException;
use SensitiveParameter;

/**
 * DPoP-bound Access access tokens for an API client, obtained with the OAuth 2.0 client credentials grant.
 *
 * Relay's Access client_id comes from Relay's discovery document and the token endpoint from the Access issuer's.
 * Every request attempt carries a fresh DPoP proof of an Ed25519 key made for this instance.
 */
final class ClientCredentials implements Authorizer
{
    private const EXPIRY_MARGIN = 30.0;

    private readonly string $clientSecret;

    private readonly Transport $transport;

    /**
     * @var Closure(): float
     */
    private readonly Closure $now;

    /**
     * @var non-empty-string
     */
    private readonly string $secretKey;

    /**
     * @var non-empty-string
     */
    private readonly string $publicKey;

    private ?string $token = null;

    private float $expiresAt = 0.0;

    private ?string $tokenEndpoint = null;

    private bool $postOnly = false;

    /**
     * @param (Closure(): float)|null $now
     * @param string|null $resource Relay's Access client_id; discovered from Relay when null
     */
    public function __construct(
        private readonly string $issuer,
        private readonly string $clientId,
        #[SensitiveParameter]
        string $clientSecret,
        private readonly ?string $scope = null,
        private ?string $resource = null,
        ?Transport $transport = null,
        ?Closure $now = null,
        private readonly float $timeout = 30.0,
    ) {
        $this->clientSecret = $clientSecret;
        $this->transport = $transport ?? new CurlTransport();
        $this->now = $now ?? static fn (): float => microtime(true);
        $keypair = sodium_crypto_sign_keypair();
        $secretKey = sodium_crypto_sign_secretkey($keypair);
        $publicKey = sodium_crypto_sign_publickey($keypair);
        if ($secretKey === '' || $publicKey === '') {
            throw new TokenException('dpop_key_failed', 'no DPoP key could be made');
        }
        $this->secretKey = $secretKey;
        $this->publicKey = $publicKey;
    }

    // API-65
    public function authorize(string $method, string $url): array
    {
        $token = $this->token($url);

        return [
            'Authorization' => 'DPoP ' . $token,
            'DPoP' => $this->proof($method, $url, $token),
        ];
    }

    public function invalidate(): void
    {
        $this->token = null;
        $this->expiresAt = 0.0;
    }

    /**
     * A DPoP proof (RFC 9449) of this instance's key for $method on $url, bound to $token when given.
     */
    public function proof(string $method, string $url, ?string $token = null, ?string $nonce = null): string
    {
        $header = [
            'typ' => 'dpop+jwt',
            'alg' => 'Ed25519',
            'jwk' => ['kty' => 'OKP', 'crv' => 'Ed25519', 'x' => self::b64($this->publicKey)],
        ];
        $claims = [
            'htm' => strtoupper($method),
            'htu' => (string) preg_replace('/[?#].*$/s', '', $url),
            'iat' => (int) floor(($this->now)()),
            'jti' => self::b64(random_bytes(16)),
        ];
        if ($token !== null) {
            $claims['ath'] = self::b64(hash('sha256', $token, true));
        }
        if ($nonce !== null) {
            $claims['nonce'] = $nonce;
        }
        $input = self::b64(self::json($header)) . '.' . self::b64(self::json($claims));

        return $input . '.' . self::b64(sodium_crypto_sign_detached($input, $this->secretKey));
    }

    /**
     * The raw 32-byte Ed25519 public key of this instance's DPoP key.
     *
     * @return non-empty-string
     */
    public function publicKey(): string
    {
        return $this->publicKey;
    }

    /**
     * @return array<string, string|null>
     */
    public function __debugInfo(): array
    {
        return ['issuer' => $this->issuer, 'clientId' => $this->clientId, 'scope' => $this->scope];
    }

    private function token(string $url): string
    {
        if ($this->token !== null && ($this->now)() < $this->expiresAt) {
            return $this->token;
        }
        $resource = $this->resource ?? $this->discoverResource($url);
        $this->resource = $resource;
        $endpoint = $this->tokenEndpoint ?? $this->discoverTokenEndpoint();
        $this->tokenEndpoint = $endpoint;

        return $this->request($endpoint, $resource, null);
    }

    private function discoverResource(string $url): string
    {
        $parts = parse_url($url);
        if (!is_array($parts) || !isset($parts['scheme'], $parts['host'])) {
            throw new TokenException('access_discovery_failed', 'the Relay URL is not absolute');
        }
        $origin = $parts['scheme'] . '://' . $parts['host'] . (isset($parts['port']) ? ':' . $parts['port'] : '');
        $document = $this->document($origin . '/.well-known/relay-configuration', 'Relay');
        $resource = $document['access_client_id'] ?? null;
        if (!is_string($resource) || $resource === '') {
            throw new TokenException('access_discovery_failed', 'the Relay discovery document names no access_client_id');
        }

        return $resource;
    }

    private function discoverTokenEndpoint(): string
    {
        $issuer = rtrim($this->issuer, '/');
        $document = $this->document($issuer . '/.well-known/openid-configuration', 'Access');
        $found = $document['issuer'] ?? null;
        $endpoint = $document['token_endpoint'] ?? null;
        if (!is_string($found) || !is_string($endpoint)) {
            throw new TokenException('access_discovery_failed', 'the discovery document has no issuer or token_endpoint');
        }
        if (rtrim($found, '/') !== $issuer) {
            throw new TokenException('access_discovery_failed', 'the discovery document names another issuer: ' . $found);
        }
        if (!str_starts_with($endpoint, 'https://')) {
            throw new TokenException('access_discovery_failed', 'the token endpoint is not an https URL');
        }
        $methods = $document['token_endpoint_auth_methods_supported'] ?? null;
        $this->postOnly = is_array($methods)
            && in_array('client_secret_post', $methods, true)
            && !in_array('client_secret_basic', $methods, true);

        return $endpoint;
    }

    /**
     * @return array<mixed>
     */
    private function document(string $url, string $who): array
    {
        $response = $this->transport->send(
            new HttpRequest('GET', $url, ['Accept' => 'application/json']),
            $this->timeout,
        );
        if ($response->status !== 200) {
            throw new TokenException(
                'access_discovery_failed',
                $who . ' answered HTTP ' . $response->status . ' to the discovery request',
            );
        }

        return self::decode($response) ?? throw new TokenException(
            'access_discovery_failed',
            $who . ' answered the discovery request without a JSON object',
        );
    }

    private function request(string $endpoint, string $resource, ?string $nonce): string
    {
        $form = ['grant_type' => 'client_credentials', 'resource' => $resource];
        if ($this->scope !== null) {
            $form['scope'] = $this->scope;
        }
        $headers = ['Accept' => 'application/json', 'Content-Type' => 'application/x-www-form-urlencoded'];
        if ($this->postOnly) {
            $form['client_id'] = $this->clientId;
            $form['client_secret'] = $this->clientSecret;
        } else {
            $headers['Authorization'] = 'Basic '
                . base64_encode(urlencode($this->clientId) . ':' . urlencode($this->clientSecret));
        }
        $headers['DPoP'] = $this->proof('POST', $endpoint, null, $nonce);

        $response = $this->transport->send(
            new HttpRequest('POST', $endpoint, $headers, http_build_query($form)),
            $this->timeout,
        );
        $body = self::decode($response) ?? [];

        if ($response->status === 200) {
            return $this->issued($body);
        }
        if ($response->status === 400 && ($body['error'] ?? null) === 'use_dpop_nonce' && $nonce === null) {
            $next = $response->header('dpop-nonce');
            if ($next === null || $next === '') {
                throw new TokenException('access_token_refused', 'Access asked for a DPoP nonce without naming one');
            }

            return $this->request($endpoint, $resource, $next);
        }
        $error = is_string($body['error'] ?? null) && preg_match('/^[a-z_]{1,64}$/', $body['error']) === 1
            ? $body['error']
            : 'token_refused';
        $message = 'Access refused the client credentials (HTTP ' . $response->status . ')';
        if (is_string($body['error_description'] ?? null)) {
            $message .= ': ' . $body['error_description'];
        }

        throw new TokenException('access_' . $error, $message);
    }

    /**
     * @param array<mixed> $body
     */
    private function issued(array $body): string
    {
        $token = $body['access_token'] ?? null;
        $type = $body['token_type'] ?? null;
        if (!is_string($token) || $token === '' || !is_string($type)) {
            throw new TokenException('access_token_refused', 'Access answered without a DPoP access token');
        }
        if (strtolower($type) !== 'dpop') {
            throw new TokenException('access_token_refused', 'Access issued a ' . $type . ' token, not a DPoP token');
        }
        $lifetime = $body['expires_in'] ?? null;
        $lifetime = is_int($lifetime) || is_float($lifetime) ? (float) $lifetime : 0.0;
        $this->token = $token;
        $this->expiresAt = ($this->now)() + max(0.0, $lifetime - self::EXPIRY_MARGIN);

        return $token;
    }

    /**
     * @return array<mixed>|null
     */
    private static function decode(HttpResponse $response): ?array
    {
        try {
            $decoded = json_decode($response->body, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException) {
            return null;
        }

        return is_array($decoded) ? $decoded : null;
    }

    /**
     * @param array<string, mixed> $value
     */
    private static function json(array $value): string
    {
        return json_encode($value, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
    }

    private static function b64(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }
}
