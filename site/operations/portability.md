# Portability

Notification platforms get shut down, change their terms or leave a region. Relay is built so that this cannot strand you: you can run it yourself, see every event as it happens, and take all of your data with you in open formats.

## Run it yourself, completely

The self-hosted release is the same package the hosted regions run, with every feature. If the hosted service no longer suits you, you can move to your own installation without losing a capability. See [Operations](/operations/) for what the hosted service adds on top.

## Stream every event

Everything that happens to notifications, deliveries, devices and addresses is published as signed events to your webhook endpoints, or to queues and streams such as Kafka, NATS, RabbitMQ, SQS, SNS, EventBridge, Pub/Sub, Service Bus and S3. A copy of your activity can therefore live in your own systems from day one. See [Webhooks](/guide/webhooks) and the [event catalog](/reference/events).

## Export raw data

Delivery data can be exported from the API and the console as files, so you can analyse it in your own tools without going through Relay's reports.

## Export one person's data

A tenant can export everything Relay holds about one recipient, such as their delivery history, as a JSON document. Use it to answer a data subject access request or to move one person's record elsewhere.

## Closing a tenant

Closing a tenant takes two steps, each recorded in the audit log:

1. **Close and export.** The tenant stops accepting new sends, and a full export starts. It is written as JSON lines, CSV and Parquet to object storage in the tenant's own region, and the tenant receives a signed download link that expires.
2. **Destroy the keys.** Thirty days after the export is ready, or earlier if the tenant explicitly agrees, the tenant's data keys and the per-person keys of records with no retention obligation are destroyed. From then on that data cannot be read by anyone. Records that the law requires to be kept remain, for their legal retention period only.
