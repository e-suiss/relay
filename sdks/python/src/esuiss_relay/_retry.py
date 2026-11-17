from __future__ import annotations

import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from email.utils import parsedate_to_datetime


# X-29
@dataclass(frozen=True)
class RetryPolicy:
    """Exponential backoff with full jitter, honouring Retry-After, for retryable problems only."""

    max_retries: int = 3
    base_delay: float = 0.5
    max_delay: float = 8.0
    max_retry_after: float = 60.0

    def delay(
        self, retry: int, retry_after: float | None, random: Callable[[], float]
    ) -> float | None:
        """Seconds to wait before retry number `retry` (from 0), or None when not to retry."""
        jitter = random() * min(self.max_delay, self.base_delay * (2**retry))
        if retry_after is None:
            return jitter
        if retry_after > self.max_retry_after:
            return None
        return max(retry_after, jitter)


def retry_after_seconds(
    headers: Mapping[str, str], body_value: int | None, now: Callable[[], float] = time.time
) -> float | None:
    """Retry-After in seconds from the header (seconds or HTTP date), else the problem body."""
    header = headers.get("retry-after")
    if header is not None:
        text = header.strip()
        if text.isdigit():
            return float(text)
        try:
            moment = parsedate_to_datetime(text)
        except (TypeError, ValueError):
            moment = None
        if moment is not None:
            return max(0.0, moment.timestamp() - now())
    if body_value is not None and body_value >= 0:
        return float(body_value)
    return None
