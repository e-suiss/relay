from __future__ import annotations

from typing import Any

import pytest
from conftest import conformance

from esuiss_relay import Webhook, WebhookVerificationError

VECTOR = conformance("webhooks", "vectors", "1", "signature.json")
KEYS = VECTOR["keys"]
CASES = {case["name"]: case for case in VECTOR["cases"]}


def headers(case: dict[str, Any], signature: str) -> dict[str, str]:
    return {
        "Webhook-Id": case["webhook_id"],
        "Webhook-Timestamp": str(case["webhook_timestamp"]),
        "Webhook-Signature": signature,
    }


def webhook(now: float, *keys: str) -> Webhook:
    return Webhook(list(keys), tolerance=VECTOR["tolerance_s"], clock=lambda: now)


@pytest.mark.parametrize("case", VECTOR["cases"], ids=lambda case: case["name"])
def test_x29_v1a_signature_verifies(case: dict[str, Any]) -> None:
    body = bytes.fromhex(case["body_hex"])
    hook = webhook(case["webhook_timestamp"], KEYS["ed25519_public_key"])
    hook.verify(body, headers(case, case["v1a"]))


@pytest.mark.parametrize("case", VECTOR["cases"], ids=lambda case: case["name"])
def test_x29_v1_signature_verifies(case: dict[str, Any]) -> None:
    body = bytes.fromhex(case["body_hex"])
    hook = webhook(case["webhook_timestamp"], KEYS["hmac_secret"])
    hook.verify(body, headers(case, case["v1"]))


@pytest.mark.parametrize("case", VECTOR["cases"], ids=lambda case: case["name"])
def test_wh7_both_signatures_in_one_header(case: dict[str, Any]) -> None:
    body = bytes.fromhex(case["body_hex"])
    hook = webhook(case["webhook_timestamp"], KEYS["ed25519_public_key"], KEYS["hmac_secret"])
    hook.verify(body, headers(case, f"{case['v1a']} {case['v1']}"))


@pytest.mark.parametrize("rejection", VECTOR["rejections"], ids=lambda r: r["name"])
def test_wh7_rejections(rejection: dict[str, Any]) -> None:
    case = dict(CASES[rejection["case"]])
    body = bytes.fromhex(rejection.get("body_hex", case["body_hex"]))
    if "webhook_id" in rejection:
        case["webhook_id"] = rejection["webhook_id"]
    now = rejection.get("now", case["webhook_timestamp"])
    if rejection.get("swap_versions"):
        signature = "v1a," + case["v1"].split(",", 1)[1] + " v1," + case["v1a"].split(",", 1)[1]
    else:
        signature = f"{case['v1a']} {case['v1']}"
    hook = webhook(now, KEYS["ed25519_public_key"], KEYS["hmac_secret"])
    with pytest.raises(WebhookVerificationError):
        hook.verify(body, headers(case, signature))


def test_wh7_v1a_signature_is_not_accepted_by_hmac_key_alone() -> None:
    case = CASES["standard-webhooks-reference-body"]
    hook = webhook(case["webhook_timestamp"], KEYS["hmac_secret"])
    with pytest.raises(WebhookVerificationError):
        hook.verify(bytes.fromhex(case["body_hex"]), headers(case, case["v1a"]))


def test_wh7_missing_headers_are_rejected() -> None:
    hook = webhook(0, KEYS["hmac_secret"])
    with pytest.raises(WebhookVerificationError):
        hook.verify(b"{}", {})


def test_wh7_verify_event_returns_json() -> None:
    case = CASES["standard-webhooks-reference-body"]
    hook = webhook(case["webhook_timestamp"], KEYS["ed25519_public_key"])
    event = hook.verify_event(bytes.fromhex(case["body_hex"]), headers(case, case["v1a"]))
    assert event == {"test": 2432232314}
