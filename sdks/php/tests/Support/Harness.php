<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests\Support;

use Esuiss\Relay\Client;
use Esuiss\Relay\RetryPolicy;

final class Harness
{
    public readonly StubTransport $transport;

    public readonly StubAuthorizer $auth;

    public readonly Client $client;

    /**
     * @var list<float>
     */
    public array $sleeps = [];

    public float $time = 1_793_784_600.0;

    public function __construct(int $maxRetries = 3, float $random = 0.5)
    {
        $this->transport = new StubTransport();
        $this->auth = new StubAuthorizer();
        $this->client = new Client(
            'https://relay.test/',
            $this->auth,
            maxRetries: $maxRetries,
            transport: $this->transport,
            retry: new RetryPolicy(random: static fn (): float => $random),
            sleep: function (float $seconds): void {
                $this->sleeps[] = $seconds;
                $this->time += $seconds;
            },
            now: fn (): float => $this->time,
        );
    }

    public static function root(): string
    {
        return dirname(__DIR__, 4);
    }
}
