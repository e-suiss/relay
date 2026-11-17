from __future__ import annotations

import json
import random as _random
import time
import urllib.parse
import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any, Literal

from ._agents import AgentHelpers
from ._auth import Auth, AuthContext
from ._base import RequestOptions
from ._errors import RelayConnectionError, api_error
from ._generated.version import API_VERSION
from ._pagination import Page
from ._retry import RetryPolicy, retry_after_seconds
from ._transport import HttpRequest, HttpResponse, Transport, UrllibTransport
from ._version import __version__

USER_AGENT = f"esuiss-relay-python/{__version__}"


@dataclass(frozen=True)
class Response:
    """A successful raw response of `Relay.request`."""

    status: int
    headers: Mapping[str, str]
    body: bytes

    @property
    def replayed(self) -> bool:
        """True when Relay answered with the stored response of an earlier request with this key."""
        return self.headers.get("idempotency-replayed", "").lower() == "true"

    def json(self) -> Any:
        """The body decoded as JSON, or None when empty."""
        return json.loads(self.body) if self.body else None


# X-29
# API-55
class Relay(AgentHelpers):
    """Client of the Relay server API, pinned to one API version."""

    def __init__(
        self,
        base_url: str,
        auth: Auth,
        *,
        max_retries: int = 3,
        timeout: float = 30.0,
        retry: RetryPolicy | None = None,
        transport: Transport | None = None,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
        random: Callable[[], float] = _random.random,
        idempotency_key: Callable[[], str] | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self._auth = auth
        self._retry = retry or RetryPolicy(max_retries=max_retries)
        self._timeout = timeout
        self._transport: Transport = transport or UrllibTransport()
        self._clock = clock
        self._sleep = sleep
        self._random = random
        self._key_factory = idempotency_key or (lambda: str(uuid.uuid4()))

    def _new_idempotency_key(self) -> str:
        return self._key_factory()

    def request(
        self,
        method: str,
        path: str,
        *,
        query: Mapping[str, Any] | None = None,
        json_body: Any = None,
        content_type: str = "application/json",
        idempotency_key: str | None = None,
        idempotent: bool | None = None,
        options: RequestOptions | None = None,
    ) -> Response:
        """Calls any path with the client's auth, idempotency and retry rules; writes take a key."""
        mutating = method.upper() in ("POST", "PUT", "PATCH", "DELETE")
        if idempotent is not None:
            mutating = idempotent
        answer = self._send(
            method.upper(),
            self._url(path, {}, query or {}),
            {},
            json_body,
            content_type if json_body is not None else None,
            mutating,
            idempotency_key,
            options,
        )
        return Response(answer.status, answer.headers, answer.body)

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
        answer = self._send(
            method,
            self._url(template, path, query),
            headers,
            body,
            content_type,
            idempotent,
            idempotency_key,
            options,
        )
        if response == "none" or not answer.body:
            return None
        if response == "text":
            return answer.body.decode("utf-8")
        return json.loads(answer.body)

    # API-56
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
        backward = query.get("ending_before") is not None
        if backward and query.get("starting_after") is not None:
            raise ValueError("both_cursors: pass starting_after or ending_before, not both")
        cursor_name = "ending_before" if backward else "starting_after"

        def fetch(cursor: str) -> Page[Any]:
            following = {
                k: v for k, v in query.items() if k not in ("starting_after", "ending_before")
            }
            following[cursor_name] = cursor
            return self._page(
                method,
                template,
                path=path,
                query=following,
                headers=headers,
                body=body,
                content_type=content_type,
                idempotent=idempotent,
                idempotency_key=None,
                options=options,
            )

        answer = self._call(
            method,
            template,
            path=path,
            query=query,
            headers=headers,
            body=body,
            content_type=content_type,
            idempotent=idempotent,
            idempotency_key=idempotency_key,
            options=options,
            response="json",
        )
        return Page(answer if isinstance(answer, dict) else {}, fetch, backward=backward)

    def _url(self, template: str, path: Mapping[str, Any], query: Mapping[str, Any]) -> str:
        url = template
        for name, value in path.items():
            url = url.replace("{" + name + "}", urllib.parse.quote(_text(value), safe=""))
        pairs: list[tuple[str, str]] = []
        for name, value in query.items():
            if value is None:
                continue
            if isinstance(value, (list, tuple)):
                pairs.extend((name, _text(item)) for item in value)
            else:
                pairs.append((name, _text(value)))
        if pairs:
            url += "?" + urllib.parse.urlencode(pairs)
        return self.base_url + url

    # X-29
    # API-10
    # API-65
    def _send(
        self,
        method: str,
        url: str,
        extra: Mapping[str, Any],
        body: Any,
        content_type: str | None,
        idempotent: bool,
        idempotency_key: str | None,
        options: RequestOptions | None,
    ) -> HttpResponse:
        key = (idempotency_key or self._new_idempotency_key()) if idempotent else None
        timeout = options.timeout if options and options.timeout is not None else self._timeout
        budget = self._retry.max_retries
        if options and options.max_retries is not None:
            budget = options.max_retries
        payload = None
        if body is not None:
            payload = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        context = AuthContext(self.base_url, self._transport, self._clock, timeout)
        retry = 1
        renewed = False
        while True:
            headers = {
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
                "Relay-Version": API_VERSION,
            }
            for name, value in extra.items():
                if value is not None:
                    headers[name] = _text(value)
            if options and options.headers:
                headers.update(options.headers)
            if payload is not None:
                headers["Content-Type"] = content_type or "application/json"
            if key is not None:
                headers["Idempotency-Key"] = key
            headers.update(self._auth.headers(method, url, context))
            try:
                answer = self._transport.send(HttpRequest(method, url, headers, payload, timeout))
            except RelayConnectionError:
                decision = self._retry.decide(retry, True, None, self._random(), budget)
                if not decision.retry:
                    raise
                self._sleep(decision.delay_ms / 1000)
                retry += 1
                continue
            if 200 <= answer.status < 300:
                return answer
            error = api_error(answer.status, answer.body, answer.headers)
            if error.code == "auth_expired_token" and not renewed:
                renewed = True
                self._auth.invalidate()
                continue
            decision = self._retry.decide(
                retry,
                error.retryable,
                retry_after_seconds(answer.headers, error.retry_after, self._clock),
                self._random(),
                budget,
            )
            if not decision.retry:
                raise error
            self._sleep(decision.delay_ms / 1000)
            retry += 1


def _text(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)
