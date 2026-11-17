from __future__ import annotations

import urllib.parse
from pathlib import Path
from typing import Any

import pytest
import yaml

from conftest import REPO, FakeAuth, Sleeper, StubTransport, answer, client, problem
from esuiss_relay import (
    API_VERSION,
    AuthenticationError,
    IdempotencyError,
    RateLimitError,
    RelayError,
    RequestOptions,
    ServerError,
    ValidationError,
)

ACCEPTED = {"object": "event", "id": "evt_01j9zq3k4m5n6p7q8r9s0t1v2w"}
EVENT: Any = {"workflow": "welcome", "to": [{"id": "user-4821"}]}


def contract_version() -> str:
    text = Path(REPO, "contracts", "openapi", "server.yaml").read_text(encoding="utf-8")
    head = text.split("\npaths:", 1)[0]
    return str(yaml.safe_load(head)["info"]["version"])


def test_x29_relay_version_is_pinned_to_the_contract() -> None:
    transport = StubTransport(answer(202, ACCEPTED))
    client(transport).create_event(EVENT)
    request = transport.requests[0]
    assert contract_version() == API_VERSION
    assert request.headers["Relay-Version"] == API_VERSION
    assert request.headers["User-Agent"].startswith("esuiss-relay-python/")
    assert request.headers["Authorization"] == "DPoP token"


def test_x29_idempotency_key_is_generated_and_kept_across_retries(sleeper: Sleeper) -> None:
    transport = StubTransport(
        problem(503, "service_unavailable", True),
        problem(409, "idempotency_key_in_progress", True),
        answer(202, ACCEPTED),
    )
    result = client(transport, sleeper).create_event(EVENT)
    assert result == ACCEPTED
    keys = {request.headers["Idempotency-Key"] for request in transport.requests}
    assert len(keys) == 1
    assert len(next(iter(keys))) >= 8
    proofs = {request.headers["DPoP"] for request in transport.requests}
    assert len(proofs) == 3
    assert len(sleeper.waits) == 2


def test_x29_caller_idempotency_key_is_sent() -> None:
    transport = StubTransport(answer(202, ACCEPTED))
    client(transport).create_event(EVENT, idempotency_key="order-4821-shipped")
    assert transport.requests[0].headers["Idempotency-Key"] == "order-4821-shipped"


def test_x29_reads_carry_no_idempotency_key() -> None:
    transport = StubTransport(answer(200, {"object": "notification"}))
    client(transport).get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    request = transport.requests[0]
    assert "Idempotency-Key" not in request.headers
    assert request.url.endswith("/v1/notifications/ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    assert request.body is None


def test_x29_non_retryable_problem_is_raised_at_once(sleeper: Sleeper) -> None:
    transport = StubTransport(problem(422, "validation_failed", False))
    with pytest.raises(ValidationError) as raised:
        client(transport, sleeper).create_event(EVENT)
    assert raised.value.code == "validation_failed"
    assert raised.value.retryable is False
    assert len(transport.requests) == 1
    assert sleeper.waits == []


def test_x29_retryable_flag_decides_not_the_status(sleeper: Sleeper) -> None:
    transport = StubTransport(problem(503, "service_unavailable", False))
    with pytest.raises(ServerError):
        client(transport, sleeper).create_event(EVENT)
    assert len(transport.requests) == 1


def test_x29_retries_stop_after_the_budget(sleeper: Sleeper) -> None:
    transport = StubTransport(*[problem(500, "internal_error", True) for _ in range(4)])
    with pytest.raises(ServerError):
        client(transport, sleeper, max_retries=3).create_event(EVENT)
    assert len(transport.requests) == 4
    assert len(sleeper.waits) == 3


def test_x29_per_call_retry_budget() -> None:
    transport = StubTransport(problem(500, "internal_error", True))
    with pytest.raises(ServerError):
        client(transport).create_event(EVENT, options=RequestOptions(max_retries=0))
    assert len(transport.requests) == 1


def test_x29_backoff_is_exponential_with_full_jitter(sleeper: Sleeper) -> None:
    transport = StubTransport(
        *[problem(500, "internal_error", True) for _ in range(3)], answer(202, ACCEPTED)
    )
    client(transport, sleeper, random_value=1.0).create_event(EVENT)
    assert sleeper.waits == [0.5, 1.0, 2.0]


def test_x29_retry_after_header_is_honoured(sleeper: Sleeper) -> None:
    limited = problem(429, "rate_limited", True, retry_after=7)
    limited.headers["retry-after"] = "7"
    transport = StubTransport(limited, answer(202, ACCEPTED))
    client(transport, sleeper, random_value=0.0).create_event(EVENT)
    assert sleeper.waits == [7.0]


def test_x29_retry_after_body_is_used_without_header(sleeper: Sleeper) -> None:
    transport = StubTransport(
        problem(409, "idempotency_key_in_progress", True, retry_after=1), answer(202, ACCEPTED)
    )
    client(transport, sleeper, random_value=0.0).create_event(EVENT)
    assert sleeper.waits == [1.0]


def test_x29_retry_after_beyond_the_cap_is_not_waited_for(sleeper: Sleeper) -> None:
    limited = problem(429, "rate_limited", True)
    limited.headers["retry-after"] = "3600"
    transport = StubTransport(limited)
    with pytest.raises(RateLimitError):
        client(transport, sleeper).create_event(EVENT)
    assert sleeper.waits == []


def test_x29_expired_token_is_renewed_once() -> None:
    auth = FakeAuth()
    transport = StubTransport(
        problem(401, "auth_expired_token", False), answer(200, {"object": "notification"})
    )
    client(transport, auth=auth).get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    assert auth.invalidated == 1
    assert len(transport.requests) == 2


def test_x29_expired_token_twice_is_raised() -> None:
    transport = StubTransport(
        problem(401, "auth_expired_token", False), problem(401, "auth_expired_token", False)
    )
    with pytest.raises(AuthenticationError):
        client(transport).get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")


def test_x29_idempotency_errors_are_typed() -> None:
    transport = StubTransport(problem(422, "idempotency_key_reuse", False))
    with pytest.raises(IdempotencyError):
        client(transport).create_event(EVENT)


def test_x29_errors_without_problem_body_are_typed() -> None:
    transport = StubTransport(answer(502))
    with pytest.raises(ServerError) as raised:
        client(transport).create_event(EVENT)
    assert isinstance(raised.value, RelayError)
    assert raised.value.code is None


def test_x29_query_and_path_parameters_are_encoded() -> None:
    transport = StubTransport(answer(200, {"object": "list", "data": [], "has_more": False}))
    client(transport).list_notifications(limit=10, subscriber="user 4821")
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(transport.requests[0].url).query)
    assert query == {"limit": ["10"], "subscriber": ["user 4821"]}
