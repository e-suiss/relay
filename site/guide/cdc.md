# Change data capture

Relay never connects to your database. If you want notifications to follow changes in your tables, use a change data capture (CDC) tool such as [Debezium](https://debezium.io) or [Sequin](https://sequinstream.com) and send the changes to Relay as CloudEvents. The CDC tool owns reading your database; Relay owns turning events into notifications.

```text
your database ──▶ Debezium or Sequin ──▶ Kafka, NATS or a webhook ──▶ forwarder ──▶ POST /v1/events
                   (reads the log)         (durable buffer)            (your code)     (CloudEvents)
```

## 1. Map the event type to a workflow

A mapping binds a CloudEvents `type` (and optionally an exact `source`) to a workflow. CloudEvents carry no recipients, so the mapping also names where the recipient is in `data` (`to_pointer`, a JSON Pointer) and which fields to copy into the workflow's data (`data_fields`). There is no transformation script: anything else is left out.

<<< @/examples/curl/cloudevents-mapping.sh

`to_pointer` may point at a subscriber id that already exists, or at an object with an `id` and contact details such as `email`, which creates the subscriber.

## 2. Send the change as a CloudEvent

Relay accepts structured mode (`application/cloudevents+json`), binary mode (`ce-*` headers with a JSON body) and batches (`application/cloudevents-batch+json`):

<<< @/examples/curl/cloudevents-send.sh

No `Idempotency-Key` header is needed: Relay derives the key from `source` and `id`, and uses `(source, id)` to drop repeats. Give each change an `id` that stays the same when the CDC tool delivers it again, such as the topic, partition and offset, or the table, primary key and log position.

## 3. Forward from your pipeline

Relay authenticates every request with an Access token bound to a key (DPoP), which CDC tools cannot do on their own. Put a small forwarder between the durable buffer and Relay, and let a Relay SDK handle tokens, retries and idempotency:

<<< @/examples/typescript/cdc-forwarder.ts#forward

The forwarder passes an idempotency key derived from the CloudEvent, so a redelivery after a crash, even from another process, opens no second event. Commit the consumer offset only after Relay answered `202`.

### Debezium

Flatten the change envelope to the row with the `ExtractNewRecordState` transform, so the forwarder receives the columns your mapping points at, and keep the operation and commit time as fields:

```properties
transforms=unwrap
transforms.unwrap.type=io.debezium.transforms.ExtractNewRecordState
transforms.unwrap.add.fields=op,source.ts_ms
```

The forwarder above builds the CloudEvent from the topic, partition and offset of the record. Debezium can also emit CloudEvents itself with its CloudEvents converter; then forward the envelope unchanged and keep its `id`.

Use the [outbox pattern](https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html) when a notification should follow a business event rather than a raw row change: write an outbox row in the same transaction as your change, and capture only the outbox table.

### Sequin

Send changes to a Sequin sink (Kafka, NATS or a webhook sink pointed at your forwarder), and build the CloudEvent from Sequin's message: its `action` decides whether to forward, `record` becomes `data`, and the table name and commit position give a stable `id`.

## Ordering and responsibility

Relay processes each event as it arrives. In which order changes happen in your system, and whether an event should be produced at all, is decided on your side: if order matters, keep one partition per key in your buffer and forward sequentially. Relay never reads your tables to fill in missing data; put what a template needs into the event.
