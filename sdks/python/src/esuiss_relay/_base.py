from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any, Literal

from ._pagination import Page


@dataclass(frozen=True)
class RequestOptions:
    """Per-call options: timeout in seconds, extra headers and a retry budget for this call."""

    timeout: float | None = None
    headers: Mapping[str, str] | None = None
    max_retries: int | None = None


class OperationsBase:
    """The transport seam the generated operations call into."""

    _clock: Callable[[], float]
    _sleep: Callable[[float], None]

    def _call(
        self,
        method: str,
        template: str,
        *,
        path: Mapping[str, Any],
        query: Mapping[str, Any],
        headers: Mapping[str, Any],
        body: Any,
        content_type: str | None,
        idempotent: bool,
        idempotency_key: str | None,
        options: RequestOptions | None,
        response: Literal["json", "text", "none"],
    ) -> Any:
        raise NotImplementedError

    def _page(
        self,
        method: str,
        template: str,
        *,
        path: Mapping[str, Any],
        query: Mapping[str, Any],
        headers: Mapping[str, Any],
        body: Any,
        content_type: str | None,
        idempotent: bool,
        idempotency_key: str | None,
        options: RequestOptions | None,
    ) -> Page[Any]:
        raise NotImplementedError

    def _new_idempotency_key(self) -> str:
        raise NotImplementedError
