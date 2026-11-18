// #region verify
import { verifyWebhook, WebhookVerificationError } from "@esuiss/relay/webhooks";

const processed = new Set<string>();

export async function handleRelayWebhook(request: Request): Promise<Response> {
  const rawBody = new Uint8Array(await request.arrayBuffer());
  try {
    const { id } = await verifyWebhook(request.headers, rawBody, [
      process.env.RELAY_WEBHOOK_KEY ?? "",
    ]);
    if (!processed.has(id)) {
      processed.add(id);
      const event = JSON.parse(new TextDecoder().decode(rawBody)) as { type: string };
      console.log("received", event.type);
    }
    return new Response(null, { status: 204 });
  } catch (error) {
    if (error instanceof WebhookVerificationError) return new Response(null, { status: 400 });
    throw error;
  }
}
// #endregion verify
