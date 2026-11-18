<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests\Live;

use Esuiss\Relay\Auth\ClientCredentials;
use Esuiss\Relay\Client;
use PHPUnit\Framework\TestCase;

final class LiveTest extends TestCase
{
    public function testX48TalksToTheTestPlane(): void
    {
        $env = [];
        foreach (['BASE_URL', 'ISSUER', 'CLIENT_ID', 'CLIENT_SECRET'] as $name) {
            $value = getenv('RELAY_SDK_LIVE_' . $name);
            if (!is_string($value) || $value === '') {
                self::markTestSkipped('RELAY_SDK_LIVE_' . $name . ' is not set');
            }
            $env[$name] = $value;
        }
        $client = new Client(
            $env['BASE_URL'],
            new ClientCredentials($env['ISSUER'], $env['CLIENT_ID'], $env['CLIENT_SECRET']),
        );

        $configuration = $client->getRelayConfiguration();
        self::assertIsString($configuration['access_client_id'] ?? null);

        $page = $client->listNotifications(limit: 1, isTest: true);
        self::assertLessThanOrEqual(1, count($page->data));
    }
}
