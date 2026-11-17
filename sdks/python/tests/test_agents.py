from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import pytest
from conftest import Sleeper, StubTransport, answer, client

from esuiss_relay import WaitTimeoutError, merge_stream_and_history, parse_duration

WP = "wp_01j9zq3k4m5n6p7q8r9s0t1v2w"


def waitpoint(state: str, **extra: Any) -> dict[str, Any]:
    return {"object": "waitpoint", "id": WP, "state": state, **extra}


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


def test_x30_await_waitpoint_polls_until_terminal() -> None:
    clock = Clock()
    sleeps: list[float] = []

    def sleep(seconds: float) -> None:
        sleeps.append(seconds)
        clock.now += seconds

    transport = StubTransport(
        answer(200, waitpoint("open")),
        answer(200, waitpoint("open")),
        answer(200, waitpoint("resolved")),
    )
    relay = client(transport, clock=clock)
    relay._sleep = sleep
    result = relay.await_waitpoint(WP, timeout=60, poll_interval=2)
    assert result["state"] == "resolved"
    assert sleeps == [2, 2]
    assert all(r.method == "GET" for r in transport.requests)


def test_x30_await_waitpoint_sends_heartbeats() -> None:
    clock = Clock()

    def sleep(seconds: float) -> None:
        clock.now += seconds

    transport = StubTransport(
        answer(200, waitpoint("open", heartbeat_interval="PT10S")),
        answer(200, waitpoint("open")),
        answer(200, waitpoint("expired")),
    )
    relay = client(transport, clock=clock)
    relay._sleep = sleep
    relay.await_waitpoint(WP, timeout=60, poll_interval=2)
    beat = transport.requests[1]
    assert beat.method == "POST"
    assert beat.url.endswith(f"/v1/waitpoints/{WP}/heartbeat")
    assert "Idempotency-Key" in beat.headers


def test_x30_await_waitpoint_times_out() -> None:
    clock = Clock()

    def sleep(seconds: float) -> None:
        clock.now += seconds

    transport = StubTransport(*[answer(200, waitpoint("open")) for _ in range(4)])
    relay = client(transport, clock=clock)
    relay._sleep = sleep
    with pytest.raises(WaitTimeoutError):
        relay.await_waitpoint(WP, timeout=5, poll_interval=2)


def test_x30_create_and_await_waitpoint_keeps_the_key(sleeper: Sleeper) -> None:
    transport = StubTransport(answer(201, waitpoint("open")), answer(200, waitpoint("resolved")))
    relay = client(transport, sleeper)
    spec: Any = {"kind": "event"}
    result = relay.create_and_await_waitpoint(spec, timeout=10, idempotency_key="wp-key-0001")
    assert result["state"] == "resolved"
    assert transport.requests[0].headers["Idempotency-Key"] == "wp-key-0001"


def test_x30_mailbox_lease_and_ack() -> None:
    lease = {"object": "mailbox_lease", "lease_id": "l1", "lease_expires_at": None, "records": []}
    transport = StubTransport(answer(200, lease), answer(200, {"object": "mailbox_ack"}))
    relay = client(transport)
    assert relay.mailbox_lease(5)["lease_id"] == "l1"
    relay.mailbox_ack("l1", ["mbr_a", "mbr_b"])
    lease_request, ack_request = transport.requests
    assert lease_request.url.endswith("/v1/mailbox/leases")
    assert json.loads(lease_request.body or b"") == {"max": 5}
    acked = json.loads(ack_request.body or b"")
    assert acked == {"lease_id": "l1", "record_ids": ["mbr_a", "mbr_b"]}


def test_x30_mailbox_read_uses_since() -> None:
    records = {"object": "mailbox_records", "records": [], "cursor": "c", "has_more": False}
    transport = StubTransport(answer(200, records))
    client(transport).mailbox_read(since="c0", limit=10)
    assert transport.requests[0].url.endswith("/v1/mailbox/records?since=c0&limit=10")


def test_in28_stream_is_opened_before_history_and_deduplicated() -> None:
    order: list[str] = []

    def open_stream() -> Iterator[dict[str, Any]]:
        order.append("stream")
        return iter([{"id": "a", "seq": 1}, {"id": "b", "seq": 3}, {"id": "c", "seq": 1}])

    def history() -> list[dict[str, Any]]:
        order.append("history")
        return [{"id": "a", "seq": 1}, {"id": "b", "seq": 2}]

    merged = merge_stream_and_history(open_stream, history)
    assert order == ["stream"]
    assert [(i["id"], i["seq"]) for i in merged] == [("a", 1), ("b", 2), ("b", 3), ("c", 1)]
    assert order == ["stream", "history"]


def test_x30_parse_duration() -> None:
    assert parse_duration("PT10S") == 10
    assert parse_duration("P1D") == 86400
    assert parse_duration("PT1H30M") == 5400
    assert parse_duration("P") is None
    assert parse_duration(None) is None
