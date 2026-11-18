<?php

declare(strict_types=1);

namespace Esuiss\Relay\Http;

use Esuiss\Relay\Exception\ConnectionException;

/**
 * The default transport on ext-curl: no redirects, HTTP and HTTPS only, TLS verification always on.
 */
final class CurlTransport implements Transport
{
    public function send(HttpRequest $request, float $timeout): HttpResponse
    {
        $url = $request->url;
        $method = $request->method;
        if ($url === '' || $method === '') {
            throw new ConnectionException('a request needs a method and a URL');
        }
        $handle = curl_init();
        if ($handle === false) {
            throw new ConnectionException('curl could not be initialised');
        }

        $headers = [];
        foreach ($request->headers as $name => $value) {
            $headers[] = $name . ': ' . $value;
        }
        $received = [];
        $options = [
            CURLOPT_URL => $url,
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_TIMEOUT_MS => max(1, (int) round($timeout * 1000)),
            CURLOPT_PROTOCOLS => CURLPROTO_HTTPS | CURLPROTO_HTTP,
            CURLOPT_HEADERFUNCTION => static function ($curl, string $line) use (&$received): int {
                $parts = explode(':', $line, 2);
                if (count($parts) === 2) {
                    $received[strtolower(trim($parts[0]))] = trim($parts[1]);
                } elseif (str_starts_with($line, 'HTTP/')) {
                    $received = [];
                }

                return strlen($line);
            },
        ];
        if ($request->body !== null) {
            $options[CURLOPT_POSTFIELDS] = $request->body;
        }
        curl_setopt_array($handle, $options);

        $body = curl_exec($handle);
        if (!is_string($body)) {
            throw new ConnectionException('Relay is unreachable: ' . curl_error($handle));
        }
        $status = (int) curl_getinfo($handle, CURLINFO_RESPONSE_CODE);

        /** @var array<string, string> $received */
        return new HttpResponse($status, $received, $body);
    }
}
