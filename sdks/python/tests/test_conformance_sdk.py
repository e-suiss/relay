from __future__ import annotations

import itertools
import json
import urllib.parse
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest

from conftest import REPO, StubTransport, client, conformance
from esuiss_relay import (
    APIError,
    HttpRequest,
    HttpResponse,
    RelayConnectionError,
    RetryPolicy,
    Webhook,
    WebhookVerificationError,
    error_class,
)
from esuiss_relay._errors import api_error
from esuiss_relay._generated.errors import ERRORS
from esuiss_relay._retry import retry_after_seconds

VECTORS = Path(REPO, "conformance", "sdk", "vectors", "1")

pytestmark = pytest.mark.skipif(
    not VECTORS.is_dir(), reason="conformance/sdk vectors are not present"
)


def vector(name: str) -> Any:
    if not VECTORS.is_dir():
        return {}
    return conformance("sdk", "vectors", "1", name)


ERRORS_VECTOR = vector("errors.json")
RETRY = vector("retry.json")
IDEMPOTENCY = vector("idempotency.json")
PAGINATION = vector("pagination.json")
WEBHOOKS = vector("webhooks.json")


def raw_body(body: Any) -> bytes:
    if body is None:
        return b""
    if isinstance(body, str):
        return body.encode()
    return json.dumps(body).encode()


def response(spec: dict[str, Any]) -> HttpResponse:
    headers = {k.lower(): v for k, v in (spec.get("headers") or {}).items()}
    return HttpResponse(spec["status"], headers, raw_body(spec.get("body")))


def instant(text: str) -> float:
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


@pytest.mark.parametrize("case", ERRORS_VECTOR.get("cases", []), ids=lambda c: c["name"])
def test_x29_error_classification(case: dict[str, Any]) -> None:
    answer = response(case["response"])
    error = api_error(answer.status, answer.body, answer.headers)
    expect = case["expect"]
    assert error.kind == expect["class"]
    assert error.code == expect["code"]
    assert error.status == expect["status"]
    assert error.retryable is expect["retryable"]
    if "request_id" in expect:
        assert error.request_id == expect["request_id"]
    if "retry_after_s" in expect:
        assert retry_after_seconds(answer.headers, error.retry_after) == expect["retry_after_s"]
    if "field_errors" in expect:
        assert len(error.field_errors) == expect["field_errors"]


@pytest.mark.parametrize("entry", ERRORS_VECTOR.get("catalog", []), ids=lambda e: e["code"])
def test_x29_error_catalog(entry: dict[str, Any]) -> None:
    assert error_class(entry["status"], entry["code"]).kind == entry["class"]
    info = ERRORS[entry["code"]]
    assert (info.family, info.status, info.retryable) == (
        entry["family"],
        entry["status"],
        entry["retryable"],
    )


def test_x29_error_classes_are_the_five() -> None:
    kinds = {cls.kind for cls in [APIError, *_subclasses(APIError)]}
    assert kinds == set(ERRORS_VECTOR["classes"])


def _subclasses(cls: type[APIError]) -> list[type[APIError]]:
    found: list[type[APIError]] = []
    for sub in cls.__subclasses__():
        found.extend([sub, *_subclasses(sub)])
    return found


def test_x29_retry_policy_matches_the_vector() -> None:
    policy = RETRY["policy"]
    default = RetryPolicy()
    assert (default.max_retries, default.base_ms, default.cap_ms) == (
        policy["max_retries"],
        policy["base_ms"],
        policy["cap_ms"],
    )
    assert default.max_retry_after_s == policy["max_retry_after_s"]


BACKOFF = RETRY.get("backoff", [])


@pytest.mark.parametrize("row", BACKOFF, ids=lambda r: f"{r['retry']}-{r['random']}")
def test_x29_backoff_with_full_jitter(row: dict[str, Any]) -> None:
    delay = RetryPolicy().backoff_ms(row["retry"], row["random"])
    assert delay == row["delay_ms"]
    assert row["min_ms"] <= delay <= row["max_ms"]


@pytest.mark.parametrize("case", RETRY.get("decisions", []), ids=lambda c: c["name"])
def test_x29_retry_decision(case: dict[str, Any]) -> None:
    policy = RetryPolicy()
    if case.get("network_error"):
        decision = policy.decide(case["retry"], True, None, case["random"])
    else:
        answer = response(case["response"])
        error = api_error(answer.status, answer.body, answer.headers)
        now = instant(case["now"])
        wait = retry_after_seconds(answer.headers, error.retry_after, lambda: now)
        decision = policy.decide(case["retry"], error.retryable, wait, case["random"])
    expect = case["expect"]
    assert decision.retry is expect["retry"]
    if expect["retry"]:
        assert decision.delay_ms == expect["delay_ms"]
    else:
        assert decision.reason == expect["reason"]


def _scripted(spec: dict[str, Any]) -> Any:
    if spec.get("network_error"):

        def fail(request: HttpRequest) -> HttpResponse:
            raise RelayConnectionError("scripted network error")

        return fail
    return response(spec)


@pytest.mark.parametrize("case", IDEMPOTENCY.get("cases", []), ids=lambda c: c["name"])
def test_x29_idempotency_key_reuse(case: dict[str, Any]) -> None:
    keys_per_call: list[set[str]] = []
    for call in case["calls"]:
        transport = StubTransport(*[_scripted(r) for r in call["responses"]])
        relay = client(transport)
        expect = call["expect"]
        body = None if call["method"] == "GET" else {}
        outcome = "success"
        replayed = False
        try:
            answer = relay.request(
                call["method"],
                call["path"],
                json_body=body,
                idempotency_key=call.get("caller_idempotency"),
                idempotent=call["takes_idempotency_key"],
            )
            replayed = answer.replayed
        except APIError as error:
            outcome = "error"
            assert error.kind == expect["error_class"]
            assert error.code == expect["error_code"]
        assert outcome == expect["outcome"]
        assert len(transport.requests) == expect["requests"]
        keys = [r.headers.get("Idempotency-Key") for r in transport.requests]
        if expect["key_sent"]:
            sent = {k for k in keys if k is not None}
            assert len(sent) == 1 and None not in keys
            key = next(iter(sent))
            bounds = IDEMPOTENCY["key_length"]
            assert bounds["min"] <= len(key) <= bounds["max"]
            if "sent_idempotency" in expect:
                assert key == expect["sent_idempotency"]
            keys_per_call.append(sent)
        else:
            assert keys == [None] * len(keys)
        if outcome == "success":
            assert replayed is expect["replayed"]
    if case.get("distinct_keys_across_calls"):
        flattened = [key for keys in keys_per_call for key in keys]
        assert len(set(flattened)) == len(flattened)


def _page_answer(page: dict[str, Any]) -> HttpResponse:
    return HttpResponse(200, {"content-type": "application/json"}, json.dumps(page).encode())


@pytest.mark.parametrize("case", PAGINATION.get("cases", []), ids=lambda c: c["name"])
def test_api56_lazy_pagination(case: dict[str, Any]) -> None:
    transport = StubTransport(*[_page_answer(e["page"]) for e in case["exchanges"]])
    items = client(transport).list_notifications(**case["params"])
    walked = iter(items)
    if "take" in case:
        ids = [item["id"] for item in itertools.islice(walked, case["take"])]
    else:
        ids = [item["id"] for item in walked]
    assert ids == case["expect"]["items"]
    assert len(transport.requests) == case["expect"]["requests"]
    for request, exchange in zip(transport.requests, case["exchanges"], strict=False):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.url).query)
        assert {k: v[0] for k, v in query.items()} == exchange["query"]


@pytest.mark.parametrize("case", PAGINATION.get("rejections", []), ids=lambda c: c["name"])
def test_api56_pagination_rejections(case: dict[str, Any]) -> None:
    transport = StubTransport()
    with pytest.raises(ValueError, match=case["expect"]["error"]):
        client(transport).list_notifications(**case["params"])
    assert len(transport.requests) == case["expect"]["requests"]


SIGNATURES = conformance("webhooks", "vectors", "1", "signature.json")
BASES = {c["name"]: c for c in SIGNATURES["cases"]}


@pytest.mark.parametrize("case", WEBHOOKS.get("cases", []), ids=lambda c: c["name"])
def test_wh7_webhook_verifier(case: dict[str, Any]) -> None:
    base = BASES[case["base"]]
    headers: dict[str, str | None] = {
        "webhook-id": base["webhook_id"],
        "webhook-timestamp": str(base["webhook_timestamp"]),
    }
    for name, value in case["headers"].items():
        if value is None:
            headers.pop(name, None)
        else:
            headers[name] = value.replace("{v1a}", base["v1a"]).replace("{v1}", base["v1"])
    keys = [SIGNATURES["keys"][name] for name in case["keys"]]
    now = case.get("now", base["webhook_timestamp"])
    hook = Webhook(keys, tolerance=SIGNATURES["tolerance_s"], clock=lambda: now)
    body = bytes.fromhex(case.get("body_hex", base["body_hex"]))
    expect = case["expect"]
    if expect["ok"]:
        assert hook.verify(body, headers) == expect["scheme"]
    else:
        with pytest.raises(WebhookVerificationError) as raised:
            hook.verify(body, headers)
        assert raised.value.reason == expect["error"]
