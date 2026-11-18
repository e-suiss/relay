from __future__ import annotations

import re
from collections.abc import Callable, Hashable, Iterable, Iterator, Sequence
from typing import Any, TypeVar

from ._errors import WaitTimeoutError
from ._generated import models as m
from ._generated.operations import Operations

T = TypeVar("T")

TERMINAL_STATES = frozenset({"resolved", "expired", "cancelled"})

_DURATION = re.compile(
    r"^P(?:(?P<days>\d+)D)?(?:T(?:(?P<hours>\d+)H)?(?:(?P<minutes>\d+)M)?"
    r"(?:(?P<seconds>\d+(?:\.\d+)?)S)?)?$"
)


def parse_duration(value: str | None) -> float | None:
    """Seconds of an ISO 8601 duration of days, hours, minutes and seconds, or None."""
    if not value:
        return None
    match = _DURATION.match(value)
    if match is None or value in ("P", "PT"):
        return None
    parts = {k: float(v) for k, v in match.groupdict().items() if v is not None}
    return (
        parts.get("days", 0.0) * 86400
        + parts.get("hours", 0.0) * 3600
        + parts.get("minutes", 0.0) * 60
        + parts.get("seconds", 0.0)
    )


# X-30
class AgentHelpers(Operations):
    """Waitpoint and mailbox helpers of the agent face (AG-20, AG-21)."""

    def await_waitpoint(
        self,
        waitpoint_id: str,
        *,
        timeout: float,
        poll_interval: float = 2.0,
        heartbeat: bool = True,
    ) -> m.Waitpoint:
        """Polls a waitpoint until it is resolved, expired or cancelled, sending heartbeats."""
        deadline = self._clock() + timeout
        next_beat: float | None = None
        while True:
            waitpoint = self.get_waitpoint(waitpoint_id)
            if waitpoint["state"] in TERMINAL_STATES:
                return waitpoint
            now = self._clock()
            interval = parse_duration(waitpoint.get("heartbeat_interval")) if heartbeat else None
            if interval and (next_beat is None or now >= next_beat):
                self.heartbeat_waitpoint(waitpoint_id)
                next_beat = now + interval / 2
            if now >= deadline:
                raise WaitTimeoutError(f"waitpoint {waitpoint_id} is still {waitpoint['state']}")
            pause = min(poll_interval, deadline - now)
            if next_beat is not None:
                pause = min(pause, max(next_beat - now, 0.0))
            self._sleep(pause)

    def create_and_await_waitpoint(
        self,
        body: m.WaitpointCreate,
        *,
        timeout: float,
        idempotency_key: str | None = None,
        poll_interval: float = 2.0,
    ) -> m.Waitpoint:
        """Opens a waitpoint and waits for its outcome; the key keeps the deadline on retry."""
        key = idempotency_key or self._new_idempotency_key()
        waitpoint = self.create_waitpoint(body, idempotency_key=key)
        if waitpoint["state"] in TERMINAL_STATES:
            return waitpoint
        return self.await_waitpoint(waitpoint["id"], timeout=timeout, poll_interval=poll_interval)

    def mailbox_read(
        self, *, since: str | None = None, limit: int | None = None
    ) -> m.MailboxRecords:
        """Records after a position in stream order, without taking a lease."""
        return self.list_mailbox_records(since=since, limit=limit)

    def mailbox_lease(self, max_records: int = 1) -> m.MailboxLease:
        """Takes up to `max_records` records with a lease."""
        return self.lease_mailbox_records(body={"max": max_records})

    def mailbox_ack(self, lease_id: str, record_ids: Sequence[str]) -> m.MailboxAck:
        """Acknowledges records of one lease."""
        return self.ack_mailbox_records({"lease_id": lease_id, "record_ids": list(record_ids)})


def _id(item: Any) -> Hashable:
    return item["id"]  # type: ignore[no-any-return]


def _seq(item: Any) -> int:
    return int(item["seq"])


# IN-28
# AG-21
def merge_stream_and_history(
    open_stream: Callable[[], Iterable[T]],
    list_history: Callable[[], Iterable[T]],
    *,
    key: Callable[[T], Hashable] = _id,
    version: Callable[[T], int] = _seq,
) -> Iterator[T]:
    """Opens the stream first, then lists history; yields each item once by key and version."""
    stream = iter(open_stream())
    seen: dict[Hashable, int] = {}

    def fresh(item: T) -> bool:
        identity = key(item)
        current = version(item)
        if identity in seen and current <= seen[identity]:
            return False
        seen[identity] = current
        return True

    def merged() -> Iterator[T]:
        for item in list_history():
            if fresh(item):
                yield item
        for item in stream:
            if fresh(item):
                yield item

    return merged()
