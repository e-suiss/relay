<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests;

use Esuiss\Relay\Auth\ClientCredentials;
use Esuiss\Relay\Exception\TokenException;
use Esuiss\Relay\Http\HttpRequest;
use Esuiss\Relay\Tests\Support\StubTransport;
use PHPUnit\Framework\TestCase;

final class ClientCredentialsTest extends TestCase
{
    private const NOW = 1_793_784_600.0;

    public function testAPI65ObtainsADpopTokenAndSignsEveryAttempt(): void
    {
        $transport = new StubTransport(
            StubTransport::json(200, ['access_client_id' => 'relay-client']),
            StubTransport::json(200, [
                'issuer' => 'https://access.test',
                'token_endpoint' => 'https://access.test/oauth2/token',
                'token_endpoint_auth_methods_supported' => ['client_secret_basic', 'client_secret_post'],
            ]),
            StubTransport::json(400, ['error' => 'use_dpop_nonce'], ['DPoP-Nonce' => 'nonce-1']),
            StubTransport::json(200, ['access_token' => 'tok', 'token_type' => 'DPoP', 'expires_in' => 300]),
        );
        $auth = new ClientCredentials(
            'https://access.test/',
            'client a',
            's3cret',
            scope: 'publish read',
            transport: $transport,
            now: static fn (): float => self::NOW,
        );

        $headers = $auth->authorize('post', 'https://relay.test/v1/events?dry=1#x');

        self::assertSame('DPoP tok', $headers['Authorization']);
        self::assertCount(4, $transport->requests);
        self::assertSame('https://relay.test/.well-known/relay-configuration', $transport->requests[0]->url);
        self::assertSame('https://access.test/.well-known/openid-configuration', $transport->requests[1]->url);

        $first = $transport->requests[2];
        self::assertSame('POST', $first->method);
        self::assertSame('Basic ' . base64_encode('client+a:s3cret'), $first->header('Authorization'));
        parse_str((string) $first->body, $form);
        self::assertSame(
            ['grant_type' => 'client_credentials', 'resource' => 'relay-client', 'scope' => 'publish read'],
            $form,
        );
        $tokenProof = $this->claims($auth, (string) $first->header('DPoP'));
        self::assertArrayNotHasKey('ath', $tokenProof);
        self::assertArrayNotHasKey('nonce', $tokenProof);
        self::assertSame('https://access.test/oauth2/token', $tokenProof['htu']);
        self::assertSame('nonce-1', $this->claims($auth, (string) $transport->requests[3]->header('DPoP'))['nonce']);

        $claims = $this->claims($auth, $headers['DPoP']);
        self::assertSame('POST', $claims['htm']);
        self::assertSame('https://relay.test/v1/events', $claims['htu']);
        self::assertSame((int) self::NOW, $claims['iat']);
        self::assertSame(self::b64(hash('sha256', 'tok', true)), $claims['ath']);

        $again = $auth->authorize('GET', 'https://relay.test/v1/notifications');
        self::assertCount(4, $transport->requests);
        self::assertNotSame($claims['jti'], $this->claims($auth, $again['DPoP'])['jti']);

        $transport->push(StubTransport::json(200, ['access_token' => 'tok2', 'token_type' => 'dpop', 'expires_in' => 300]));
        $auth->invalidate();
        self::assertSame('DPoP tok2', $auth->authorize('GET', 'https://relay.test/v1/notifications')['Authorization']);
        self::assertCount(5, $transport->requests);
    }

    public function testAPI65UsesClientSecretPostWhenTheIssuerOnlyOffersIt(): void
    {
        $transport = new StubTransport(
            StubTransport::json(200, [
                'issuer' => 'https://access.test',
                'token_endpoint' => 'https://access.test/oauth2/token',
                'token_endpoint_auth_methods_supported' => ['client_secret_post'],
            ]),
            StubTransport::json(200, ['access_token' => 'tok', 'token_type' => 'DPoP', 'expires_in' => 300]),
        );
        $auth = new ClientCredentials('https://access.test', 'client', 'secret', resource: 'relay-client', transport: $transport);

        $auth->authorize('GET', 'https://relay.test/v1/notifications');

        $request = $transport->requests[1];
        self::assertNull($request->header('Authorization'));
        parse_str((string) $request->body, $form);
        self::assertSame('client', $form['client_id']);
        self::assertSame('secret', $form['client_secret']);
    }

    public function testAPI65RefusesADiscoveryDocumentOfAnotherIssuer(): void
    {
        $transport = new StubTransport(StubTransport::json(200, [
            'issuer' => 'https://evil.test',
            'token_endpoint' => 'https://evil.test/token',
        ]));
        $auth = new ClientCredentials('https://access.test', 'client', 'secret', resource: 'relay-client', transport: $transport);

        $this->expectException(TokenException::class);
        $auth->authorize('GET', 'https://relay.test/v1/notifications');
    }

    public function testAPI65RefusesABearerToken(): void
    {
        $transport = new StubTransport(
            StubTransport::json(200, ['issuer' => 'https://access.test', 'token_endpoint' => 'https://access.test/token']),
            StubTransport::json(200, ['access_token' => 'tok', 'token_type' => 'Bearer']),
        );
        $auth = new ClientCredentials('https://access.test', 'client', 'secret', resource: 'relay-client', transport: $transport);

        try {
            $auth->authorize('GET', 'https://relay.test/v1/notifications');
            self::fail('no exception');
        } catch (TokenException $e) {
            self::assertSame('access_token_refused', $e->errorCode);
        }
    }

    public function testAPI65KeepsTheSecretOutOfDumps(): void
    {
        $auth = new ClientCredentials('https://access.test', 'client', 'very-secret-value', transport: new StubTransport());

        self::assertStringNotContainsString('very-secret-value', print_r($auth, true));
        self::assertStringNotContainsString('very-secret-value', (string) json_encode($auth->__debugInfo()));
        $request = new HttpRequest('GET', 'https://relay.test', ['Authorization' => 'DPoP secret-token']);
        self::assertStringNotContainsString('secret-token', print_r($request, true));
    }

    /**
     * @return array<string, mixed>
     */
    private function claims(ClientCredentials $auth, string $proof): array
    {
        $parts = explode('.', $proof);
        self::assertCount(3, $parts);
        $header = json_decode(self::unb64($parts[0]), true, 512, JSON_THROW_ON_ERROR);
        self::assertIsArray($header);
        self::assertSame('dpop+jwt', $header['typ']);
        self::assertSame('Ed25519', $header['alg']);
        self::assertSame(['kty' => 'OKP', 'crv' => 'Ed25519', 'x' => self::b64($auth->publicKey())], $header['jwk']);
        $signature = self::unb64($parts[2]);
        if ($signature === '') {
            self::fail('the proof has no signature');
        }
        self::assertTrue(sodium_crypto_sign_verify_detached(
            $signature,
            $parts[0] . '.' . $parts[1],
            $auth->publicKey(),
        ));
        $claims = json_decode(self::unb64($parts[1]), true, 512, JSON_THROW_ON_ERROR);
        self::assertIsArray($claims);
        self::assertIsString($claims['jti']);
        self::assertSame(22, strlen($claims['jti']));

        /** @var array<string, mixed> $claims */
        return $claims;
    }

    private static function b64(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }

    private static function unb64(string $text): string
    {
        $decoded = base64_decode(strtr($text, '-_', '+/'), true);
        self::assertIsString($decoded);

        return $decoded;
    }
}
