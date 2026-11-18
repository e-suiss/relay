import os

# #region verify
from esuiss_relay import Webhook, WebhookVerificationError

webhook = Webhook(os.environ["RELAY_WEBHOOK_KEY"])
processed: set[str] = set()


def handle_relay_webhook(raw_body: bytes, headers: dict[str, str]) -> int:
    try:
        event = webhook.verify_event(raw_body, headers)
    except WebhookVerificationError:
        return 400
    if event["id"] not in processed:
        processed.add(event["id"])
        print("received", event["type"])
    return 204
# #endregion verify
