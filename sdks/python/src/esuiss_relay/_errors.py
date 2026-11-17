from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any, ClassVar

from ._generated.errors import ERRORS, RETRYABLE_DEFAULTS


class RelayError(Exception):
    """Base class of every error the SDK raises."""


class RelayConnectionError(RelayError):
    """The request did not get an HTTP response: connection failure or timeout."""


class AccessTokenError(RelayError):
    """Access did not issue a DPoP-bound access token for the client credentials."""


class WebhookVerificationError(RelayError):
    """A webhook request failed verification; `reason` names the failed check."""

    def __init__(self, reason: str, message: str) -> None:
        self.reason = reason
        super().__init__(message)


class WaitTimeoutError(RelayError):
    """A wait helper reached its deadline before the awaited state."""


# X-29
class APIError(RelayError):
    """An error response of Relay, usually an RFC 9457 problem."""

    kind: ClassVar[str] = "validation"

    def __init__(self, status: int, problem: Mapping[str, Any], headers: Mapping[str, str]) -> None:
        self.status = status
        self.problem: Mapping[str, Any] = problem
        self.headers: Mapping[str, str] = headers
        self.code: str | None = _text(problem.get("code"))
        self.title: str = _text(problem.get("title")) or f"HTTP {status}"
        self.detail: str | None = _text(problem.get("detail"))
        self.type: str | None = _text(problem.get("type"))
        declared = problem.get("retryable")
        self.retryable: bool = (
            declared if isinstance(declared, bool) else default_retryable(status, self.code)
        )
        self.request_id: str | None = _text(problem.get("request_id")) or headers.get("request-id")
        retry_after = problem.get("retry_after")
        self.retry_after: int | None = (
            retry_after
            if isinstance(retry_after, int) and not isinstance(retry_after, bool)
            else None
        )
        errors = problem.get("errors")
        self.field_errors: list[Any] = list(errors) if isinstance(errors, list) else []
        super().__init__(f"{status} {self.code or 'error'}: {self.detail or self.title}")


class AuthenticationError(APIError):
    """Credentials, token, scope or tenant state refused the request."""

    kind = "auth"


class ValidationError(APIError):
    """The request is malformed, failed validation, or names a missing or conflicting resource."""

    kind = "validation"


class NotFoundError(ValidationError):
    """The resource does not exist in this tenant and environment."""


class ConflictError(ValidationError):
    """The request conflicts with the resource state or a precondition."""


class RateLimitError(APIError):
    """A rate limit or quota refused the request."""

    kind = "rate_limit"


class IdempotencyError(APIError):
    """The Idempotency-Key is missing, invalid, reused or still in progress."""

    kind = "idempotency"


class ServerError(APIError):
    """Relay failed or is unavailable."""

    kind = "server"


_FAMILIES: dict[str, type[APIError]] = {
    "auth": AuthenticationError,
    "idempotency": IdempotencyError,
    "quota": RateLimitError,
    "platform": ServerError,
}


def _by_status(status: int) -> type[APIError]:
    if status in (401, 403):
        return AuthenticationError
    if status == 429:
        return RateLimitError
    if status >= 500:
        return ServerError
    if status == 404:
        return NotFoundError
    if status in (409, 412, 428):
        return ConflictError
    return ValidationError


def error_class(status: int, code: str | None) -> type[APIError]:
    """The error class of a response with this status and problem code."""
    info = ERRORS.get(code) if code else None
    if info is None:
        return _by_status(status)
    if info.family in _FAMILIES:
        return _FAMILIES[info.family]
    if status >= 500:
        return ServerError
    if status == 404:
        return NotFoundError
    if status in (409, 412, 428):
        return ConflictError
    return ValidationError


def default_retryable(status: int, code: str | None) -> bool:
    """The contract's retryable default of a status (and code) without a problem member."""
    for row_status, row_code, retryable in RETRYABLE_DEFAULTS:
        if row_status == status and row_code is not None and row_code == code:
            return retryable
    for row_status, row_code, retryable in RETRYABLE_DEFAULTS:
        if row_status == status and row_code is None:
            return retryable
    return False


def api_error(status: int, body: bytes, headers: Mapping[str, str]) -> APIError:
    """Builds the typed error of a non-2xx response."""
    problem: Mapping[str, Any] = {}
    try:
        decoded = json.loads(body) if body else None
    except ValueError:
        decoded = None
    if isinstance(decoded, dict):
        problem = decoded
    return error_class(status, _text(problem.get("code")))(status, problem, headers)


def _text(value: Any) -> str | None:
    return value if isinstance(value, str) else None
