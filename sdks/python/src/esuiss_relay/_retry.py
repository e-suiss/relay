from __future__ import annotations

import math
import re
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from email.utils import parsedate_to_datetime


@dataclass(frozen=True)
class RetryDecision:
    """Whether to retry, after how many milliseconds, and why not when not."""

    retry: bool
    delay_ms: int = 0
    reason: str | None = None


# X-29
# API-65
@dataclass(frozen=True)
class RetryPolicy:
    """Exponential backoff with full jitter, honouring Retry-After, for retryable failures only."""

    max_retries: int = 3
    base_ms: int = 500
    cap_ms: int = 8000
    max_retry_after_s: float = 60.0

    def backoff_ms(self, retry: int, random: float) -> int:
        """The full-jitter wait before retry number `retry`, counted from 1."""
        return math.floor(random * min(self.cap_ms, self.base_ms * 2 ** (retry - 1)))

    def decide(
        self,
        retry: int,
        retryable: bool,
        retry_after_s: float | None,
        random: float,
        budget: int | None = None,
    ) -> RetryDecision:
        """The decision for retry number `retry` (from 1) of a failure."""
        if not retryable:
            return RetryDecision(False, reason="not_retryable")
        if retry > (self.max_retries if budget is None else budget):
            return RetryDecision(False, reason="retries_exhausted")
        if retry_after_s is None:
            return RetryDecision(True, self.backoff_ms(retry, random))
        if retry_after_s > self.max_retry_after_s:
            return RetryDecision(False, reason="retry_after_too_long")
        return RetryDecision(True, round(retry_after_s * 1000))


_SECONDS = re.compile(r"^\d+$")


def retry_after_seconds(
    headers: Mapping[str, str], body_value: int | None, now: Callable[[], float] = time.time
) -> float | None:
    """Retry-After in seconds from the header (seconds or HTTP date), else the problem body."""
    header = headers.get("retry-after")
    if header is not None:
        text = header.strip()
        if _SECONDS.match(text):
            return float(text)
        try:
            moment = parsedate_to_datetime(text)
        except (TypeError, ValueError, IndexError):
            moment = None
        if moment is not None:
            return max(0.0, moment.timestamp() - now())
    if body_value is not None and body_value >= 0:
        return float(body_value)
    return None
