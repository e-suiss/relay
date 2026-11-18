import { forward } from "./cdc-forwarder.ts";

const change = {
  topic: "shop.public.customer",
  partition: 0,
  offset: Date.now(),
  table: "customer",
  operation: "c" as const,
  committedAt: new Date().toISOString(),
  row: { id: 4821, customer_ref: "user-4821", first_name: "Ayşe" },
};

await forward(change);
await forward(change);
await forward({ ...change, operation: "u", offset: change.offset + 1 });
console.log("cdc example: the change was forwarded once as a CloudEvent");
