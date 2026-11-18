<?php

declare(strict_types=1);

namespace Esuiss\Relay\Tests\Support;

use Esuiss\Relay\Auth\Authorizer;

final class StubAuthorizer implements Authorizer
{
    public int $authorizations = 0;

    public int $invalidations = 0;

    public function authorize(string $method, string $url): array
    {
        ++$this->authorizations;

        return [
            'Authorization' => 'DPoP token-' . $this->invalidations,
            'DPoP' => 'proof-' . $this->authorizations,
        ];
    }

    public function invalidate(): void
    {
        ++$this->invalidations;
    }
}
