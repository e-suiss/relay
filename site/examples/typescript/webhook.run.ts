import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { handleRelayWebhook } from "./webhook.ts";

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const raw = publicKey.export({ format: "der", type: "spki" }).subarray(-32);
process.env.RELAY_WEBHOOK_KEY = `whpk_${raw.toString("base64")}`;

const body = JSON.stringify({
  specversion: "1.0",
  id: "evt_docs_example",
  source: "https://relay.example.com",
  type: "notification.delivered",
  time: new Date().toISOString(),
  datacontenttype: "application/json",
  data: { notification_id: "ntf_docs_example" },
});
const id = `msg_${createHash("sha256").update(body).digest("hex").slice(0, 24)}`;
const timestamp = Math.floor(Date.now() / 1000).toString();
const signature = sign(null, Buffer.from(`${id}.${timestamp}.${body}`), privateKey).toString(
  "base64",
);

function request(signatureHeader: string): Request {
  return new Request("http://localhost/relay/webhooks", {
    method: "POST",
    headers: {
      "content-type": "application/cloudevents+json",
      "webhook-id": id,
      "webhook-timestamp": timestamp,
      "webhook-signature": signatureHeader,
    },
    body,
  });
}

const accepted = await handleRelayWebhook(request(`v1a,${signature}`));
const refused = await handleRelayWebhook(request(`v1a,${Buffer.alloc(64).toString("base64")}`));
if (accepted.status !== 204 || refused.status !== 400) {
  throw new Error(`unexpected statuses ${accepted.status} and ${refused.status}`);
}
console.log("webhook example: signed message accepted, forged message refused");
