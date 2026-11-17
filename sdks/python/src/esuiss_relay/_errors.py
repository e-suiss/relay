from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any

from ._generated.errors import ERRORS


class RelayError(Exception):
    """Base class of every error the SDK raises."""


class RelayConnectionError(RelayError):
    """The request did not get an HTTP response: connection failure or timeout."""


class AccessTokenError(RelayError):
    """Access did not issue a DPoP-bound access token for the client credentials."""


class WebhookVerificationError(RelayError):
    """A webhook request failed signature or timestamp verification."""


class WaitTimeoutError(RelayError):
    """A wait helper reached its deadline before the awaited state."""


# X-29
class APIError(RelayError):
    """An RFC 9457 problem answered by Relay."""

    def __init__(self, status: int, problem: Mapping[str, Any], headers: Mapping[str, str]) -> None:
        self.status = status
        self.problem: Mapping[str, Any] = problem
        self.headers: Mapping[str, str] = headers
        self.code: str = _text(problem.get("code")) or "unexpected_response"
        self.title: str = _text(problem.get("title")) or f"HTTP {status}"
        self.detail: str | None = _text(problem.get("detail"))
        self.type: str | None = _text(problem.get("type"))
        self.retryable: bool = problem.get("retryable") is True
        self.request_id: str | None = _text(problem.get("request_id")) or headers.get("request-id")
        retry_after = problem.get("retry_after")
        self.retry_after: int | None = (
            retry_after
            if isinstance(retry_after, int) and not isinstance(retry_after, bool)
            else None
        )
        super().__init__(f"{status} {self.code}: {self.detail or self.title}")


class AuthenticationError(APIError):
    """Credentials, token, scope or tenant state refused the request."""


class ValidationError(APIError):
    """The request is malformed or failed validation."""


class NotFoundError(APIError):
    """The resource does not exist in this tenant and environment."""


class ConflictError(APIError):
    """The request conflicts with the resource state or a precondition."""


class RateLimitError(APIError):
    """A rate limit or quota refused the request."""


class IdempotencyError(APIError):
    """The Idempotency-Key is missing, invalid, reused or still in progress."""


class ServerError(APIError):
    """Relay failed or is unavailable."""


_FAMILIES: dict[str, type[APIError]] = {
    "auth": AuthenticationError,
    "idempotency": IdempotencyError,
    "quota": RateLimitError,
}


def error_class(status: int, code: str | None) -> type[APIError]:
    """The error class of a problem with this status and code."""
    info = ERRORS.get(code) if code else None
    if info is not None and info.family in _FAMILIES:
        return _FAMILIES[info.family]
    if status >= 500:
        return ServerError
    if status in (401, 403):
        return AuthenticationError
    if status == 429:
        return RateLimitError
    if status == 404:
        return NotFoundError
    if status in (409, 412, 428):
        return ConflictError
    return ValidationError


def api_error(status: int, body: bytes, headers: Mapping[str, str]) -> APIError:
    """Builds the typed error of a non-2xx response."""
    problem: Mapping[str, Any] = {}
    try:
        decoded = json.loads(body) if body else None
    except ValueError:
        decoded = None
    if isinstance(decoded, dict):
        problem = decoded
    code = _text(problem.get("code"))
    return error_class(status, code)(status, problem, headers)


def _text(value: Any) -> str | None:
    return value if isinstance(value, str) else None
