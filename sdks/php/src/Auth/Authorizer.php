<?php

declare(strict_types=1);

namespace Esuiss\Relay\Auth;

/**
 * Supplies the Authorization and DPoP headers of one request attempt.
 */
interface Authorizer
{
    /**
     * Headers that authorize one attempt of $method on $url; called again for every retry.
     *
     * @return array<string, string>
     */
    public function authorize(string $method, string $url): array;

    /**
     * Forgets the current token so that the next attempt obtains a new one.
     */
    public function invalidate(): void;
}
