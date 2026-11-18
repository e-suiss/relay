import base64
import hashlib
import json
import os
import subprocess

from esuiss_relay import DPoPKey, StaticToken

relay_url = os.environ.get("RELAY", "https://localhost:4443")
key = DPoPKey.from_private_bytes(hashlib.sha256(b"relay-dev-dpop-ed25519").digest())
thumbprint_input = json.dumps(
    {"crv": key.jwk["crv"], "kty": key.jwk["kty"], "x": key.jwk["x"]},
    separators=(",", ":"),
    sort_keys=True,
).encode()
thumbprint = base64.urlsafe_b64encode(hashlib.sha256(thumbprint_input).digest()).rstrip(b"=")
token = subprocess.run(
    ["mix", "relay.dev.token", "--jkt", thumbprint.decode()],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip().splitlines()[-1]
auth = StaticToken(token, key)
