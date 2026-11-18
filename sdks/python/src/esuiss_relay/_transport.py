from __future__ import annotations

import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import IO, Any, Protocol

from ._errors import RelayConnectionError


@dataclass(frozen=True)
class HttpRequest:
    """An HTTP request as the transport sends it."""

    method: str
    url: str
    headers: dict[str, str]
    body: bytes | None = None
    timeout: float = 30.0


@dataclass(frozen=True)
class HttpResponse:
    """An HTTP response; header names are lower case."""

    status: int
    headers: dict[str, str] = field(default_factory=dict)
    body: bytes = b""


class Transport(Protocol):
    """Sends one HTTP request and returns its response; raises RelayConnectionError on failure."""

    def send(self, request: HttpRequest) -> HttpResponse: ...


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: IO[bytes],
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> urllib.request.Request | None:
        return None


class UrllibTransport:
    """The standard library transport; redirects are returned, never followed."""

    def __init__(self) -> None:
        self._opener = urllib.request.build_opener(_NoRedirect())

    def send(self, request: HttpRequest) -> HttpResponse:
        prepared = urllib.request.Request(  # noqa: S310
            request.url, data=request.body, headers=request.headers, method=request.method
        )
        try:
            with self._opener.open(prepared, timeout=request.timeout) as answer:
                return HttpResponse(answer.status, _headers(answer.headers), answer.read())
        except urllib.error.HTTPError as error:
            return HttpResponse(error.code, _headers(error.headers), error.read())
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise RelayConnectionError(f"request to {request.url} failed: {error}") from error


def _headers(source: Any) -> dict[str, str]:
    return {str(name).lower(): str(value) for name, value in source.items()}
