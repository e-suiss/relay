"""Python server SDK of Relay, the Suiss notification, messaging and event orchestration API."""

from ._agents import TERMINAL_STATES, merge_stream_and_history, parse_duration
from ._auth import Auth, AuthContext, ClientCredentials, DPoPKey, StaticToken
from ._base import RequestOptions
from ._client import Relay, Response
from ._errors import (
    AccessTokenError,
    APIError,
    AuthenticationError,
    ConflictError,
    IdempotencyError,
    NotFoundError,
    RateLimitError,
    RelayConnectionError,
    RelayError,
    ServerError,
    ValidationError,
    WaitTimeoutError,
    WebhookVerificationError,
    error_class,
)
from ._generated.version import API_VERSION
from ._pagination import Page
from ._retry import RetryPolicy
from ._transport import HttpRequest, HttpResponse, Transport, UrllibTransport
from ._version import __version__
from .webhooks import Webhook

__all__ = [
    "API_VERSION",
    "TERMINAL_STATES",
    "APIError",
    "AccessTokenError",
    "Auth",
    "AuthContext",
    "AuthenticationError",
    "ClientCredentials",
    "ConflictError",
    "DPoPKey",
    "HttpRequest",
    "HttpResponse",
    "IdempotencyError",
    "NotFoundError",
    "Page",
    "RateLimitError",
    "Relay",
    "RelayConnectionError",
    "RelayError",
    "RequestOptions",
    "Response",
    "RetryPolicy",
    "ServerError",
    "StaticToken",
    "Transport",
    "UrllibTransport",
    "ValidationError",
    "WaitTimeoutError",
    "Webhook",
    "WebhookVerificationError",
    "__version__",
    "error_class",
    "merge_stream_and_history",
    "parse_duration",
]
