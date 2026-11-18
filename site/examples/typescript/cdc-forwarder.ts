import { getAccessToken, keyPair, relayUrl } from "./credentials.ts";
// #region forward
import { RelayServerClient, dpopAuthenticator } from "@esuiss/relay";

const relay = new RelayServerClient({
  baseUrl: relayUrl,
  authenticate: dpopAuthenticator({ accessToken: getAccessToken, keyPair }),
});

export interface ChangeRecord {
  topic: string;
  partition: number;
  offset: number;
  table: string;
  operation: "c" | "u" | "d" | "r";
  committedAt: string;
  row: Record<string, unknown>;
}

export async function forward(change: ChangeRecord): Promise<void> {
  if (change.operation !== "c") return;
  const event = {
    specversion: "1.0" as const,
    id: `${change.topic}:${change.partition}/${change.offset}`,
    source: "/debezium/shop",
    type: `com.example.shop.${change.table}.created`,
    time: change.committedAt,
    datacontenttype: "application/json" as const,
    data: change.row,
  };
  await relay.call("createEvent", {
    body: event,
    contentType: "application/cloudevents+json",
    idempotencyKey: `${event.source}:${event.id}`,
  });
}
// #endregion forward
