import base64
import json
import os
import time

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

private_key = Ed25519PrivateKey.generate()
public = private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
os.environ["RELAY_WEBHOOK_KEY"] = "whpk_" + base64.b64encode(public).decode()

from webhook import handle_relay_webhook

body = json.dumps(
    {
        "specversion": "1.0",
        "id": "evt_docs_example",
        "source": "https://relay.example.com",
        "type": "notification.delivered",
        "time": "2026-11-18T09:30:00Z",
        "datacontenttype": "application/json",
        "data": {"notification_id": "ntf_docs_example"},
    }
).encode()
message_id = "evt_docs_example"
timestamp = str(int(time.time()))
signature = base64.b64encode(
    private_key.sign(f"{message_id}.{timestamp}.".encode() + body)
).decode()


def headers(value: str) -> dict[str, str]:
    return {
        "webhook-id": message_id,
        "webhook-timestamp": timestamp,
        "webhook-signature": value,
    }


accepted = handle_relay_webhook(body, headers(f"v1a,{signature}"))
refused = handle_relay_webhook(body, headers("v1a," + base64.b64encode(bytes(64)).decode()))
assert (accepted, refused) == (204, 400), (accepted, refused)
print("webhook example: signed message accepted, forged message refused")
