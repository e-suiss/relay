<?php

declare(strict_types=1);

namespace DocsExamples;

use Esuiss\Relay\Auth\ClientCredentials;
use Esuiss\Relay\Client;
use Esuiss\Relay\Exception\ValidationException;
use Esuiss\Relay\Exception\WebhookVerificationException;
use Esuiss\Relay\Webhook;

final class Snippets
{
    /** @var array<string, true> */
    private static array $processed = [];

    public static function quickstart(string $clientId, string $clientSecret): void
    {
        // #region quickstart
        $relay = new Client(
            'https://relay.example.com',
            new ClientCredentials('https://access.example.com', $clientId, $clientSecret),
        );

        $accepted = $relay->createEvent([
            'workflow' => 'welcome',
            'to' => [['id' => 'user-4821', 'email' => 'ayse@example.com']],
            'data' => ['first_name' => 'Ayşe'],
        ]);
        echo json_encode($accepted), PHP_EOL;
        // #endregion quickstart

        // #region decisions
        foreach ($relay->listSubscriberDecisions('user-4821', limit: 10) as $decision) {
            echo json_encode($decision), PHP_EOL;
        }
        // #endregion decisions

        // #region errors
        try {
            $relay->createEvent(['workflow' => 'welcome', 'to' => []], idempotencyKey: 'order:4821:shipped');
        } catch (ValidationException $e) {
            error_log($e->errorCode . ' ' . json_encode($e->problem['errors'] ?? []));
        }
        // #endregion errors
    }

    // #region verify
    /** @param array<string, string> $headers */
    public static function handleRelayWebhook(string $rawBody, array $headers): int
    {
        $webhook = new Webhook([(string) getenv('RELAY_WEBHOOK_PUBLIC_KEY')]);
        try {
            $event = $webhook->verifyAndDecode($rawBody, $headers);
        } catch (WebhookVerificationException) {
            return 400;
        }
        $id = (string) ($event['id'] ?? '');
        if (!isset(self::$processed[$id])) {
            self::$processed[$id] = true;
            error_log('received ' . (string) ($event['type'] ?? ''));
        }
        return 204;
    }
    // #endregion verify
}
