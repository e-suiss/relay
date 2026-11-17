"""Verification of Relay webhook requests (Suiss webhook profile, Standard Webhooks signatures)."""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import re
import time
from collections.abc import Callable, Mapping, Sequence
from typing import Any

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from ._errors import WebhookVerificationError

DEFAULT_TOLERANCE = 300

_TIMESTAMP = re.compile(r"^(?:0|[1-9][0-9]*)$")
_LENGTHS = {"v1a": 64, "v1": 32}


def _decode(text: str) -> bytes:
    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("webhook key is not valid base64") from error


def _tokens(header: str) -> list[tuple[str, bytes]]:
    parts = header.split()
    if not parts:
        raise WebhookVerificationError("malformed_header", "webhook-signature is empty")
    tokens: list[tuple[str, bytes]] = []
    for part in parts:
        version, comma, encoded = part.partition(",")
        if version not in _LENGTHS:
            continue
        try:
            signature = base64.b64decode(encoded, validate=True) if comma else b""
        except (binascii.Error, ValueError):
            signature = b""
        if len(signature) != _LENGTHS[version]:
            raise WebhookVerificationError("malformed_header", "webhook-signature is malformed")
        tokens.append((version, signature))
    return tokens


# X-29
# WH-7
class Webhook:
    """Verifies the raw body of a webhook request against `whpk_` (v1a) and `whsec_` (v1) keys."""

    def __init__(
        self,
        keys: str | Sequence[str],
        *,
        tolerance: int = DEFAULT_TOLERANCE,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._ed25519: list[Ed25519PublicKey] = []
        self._hmac: list[bytes] = []
        for key in [keys] if isinstance(keys, str) else keys:
            if key.startswith("whpk_"):
                self._ed25519.append(Ed25519PublicKey.from_public_bytes(_decode(key[5:])))
            elif key.startswith("whsec_"):
                self._hmac.append(_decode(key[6:]))
            else:
                raise ValueError("webhook keys start with whpk_ or whsec_")
        if not self._ed25519 and not self._hmac:
            raise ValueError("at least one webhook key is needed")
        self._tolerance = tolerance
        self._clock = clock

    def verify(self, body: bytes, headers: Mapping[str, str | None]) -> str:
        """Verifies a signature over the raw body within the tolerance; returns its scheme."""
        lowered = {name.lower(): value for name, value in headers.items() if value is not None}
        webhook_id = lowered.get("webhook-id")
        timestamp = lowered.get("webhook-timestamp")
        signatures = lowered.get("webhook-signature")
        if not webhook_id or not timestamp or signatures is None:
            raise WebhookVerificationError("missing_header", "webhook headers are missing")
        if not _TIMESTAMP.match(timestamp):
            raise WebhookVerificationError("malformed_header", "webhook-timestamp is malformed")
        if abs(self._clock() - int(timestamp)) > self._tolerance:
            raise WebhookVerificationError(
                "timestamp_out_of_tolerance", "webhook-timestamp is outside the tolerance"
            )
        tokens = _tokens(signatures)
        content = f"{webhook_id}.{timestamp}.".encode() + body
        for version, signature in tokens:
            if version == "v1a" and self._valid_ed25519(signature, content):
                return version
            if version == "v1" and self._valid_hmac(signature, content):
                return version
        raise WebhookVerificationError("no_matching_signature", "no webhook signature matches")

    def verify_event(self, body: bytes, headers: Mapping[str, str | None]) -> Any:
        """Verifies the request and returns its JSON body."""
        self.verify(body, headers)
        return json.loads(body)

    def _valid_ed25519(self, signature: bytes, content: bytes) -> bool:
        for key in self._ed25519:
            try:
                key.verify(signature, content)
            except InvalidSignature:
                continue
            return True
        return False

    def _valid_hmac(self, signature: bytes, content: bytes) -> bool:
        return any(
            hmac.compare_digest(hmac.new(key, content, hashlib.sha256).digest(), signature)
            for key in self._hmac
        )
