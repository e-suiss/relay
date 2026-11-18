from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from esuiss_relay import AuthContext, HttpRequest, HttpResponse, Relay

REPO = Path(__file__).resolve().parents[3]


def conformance(*parts: str) -> Any:
    return json.loads(REPO.joinpath("conformance", *parts).read_text(encoding="utf-8"))


def answer(status: int, body: Any = None, headers: dict[str, str] | None = None) -> HttpResponse:
    raw = b"" if body is None else json.dumps(body).encode()
    return HttpResponse(status, headers or {}, raw)


def problem(status: int, code: str, retryable: bool, **extra: Any) -> HttpResponse:
    body = {
        "type": f"https://relay.example.com/v1/errors/{code}",
        "title": code,
        "status": status,
        "code": code,
        "retryable": retryable,
        **extra,
    }
    return answer(status, body, {"content-type": "application/problem+json"})


class StubTransport:
    def __init__(self, *responses: HttpResponse | Callable[[HttpRequest], HttpResponse]) -> None:
        self.responses = list(responses)
        self.requests: list[HttpRequest] = []

    def send(self, request: HttpRequest) -> HttpResponse:
        self.requests.append(request)
        if not self.responses:
            raise AssertionError(f"unexpected request {request.method} {request.url}")
        next_response = self.responses.pop(0)
        return next_response(request) if callable(next_response) else next_response


class FakeAuth:
    def __init__(self) -> None:
        self.calls = 0
        self.invalidated = 0

    def headers(self, method: str, url: str, context: AuthContext) -> dict[str, str]:
        self.calls += 1
        return {"Authorization": "DPoP token", "DPoP": f"proof-{self.calls}"}

    def invalidate(self) -> None:
        self.invalidated += 1


class Sleeper:
    def __init__(self) -> None:
        self.waits: list[float] = []

    def __call__(self, seconds: float) -> None:
        self.waits.append(seconds)


@pytest.fixture
def sleeper() -> Sleeper:
    return Sleeper()


def client(
    transport: StubTransport,
    sleeper: Sleeper | None = None,
    *,
    random_value: float = 0.5,
    auth: FakeAuth | None = None,
    clock: Callable[[], float] = lambda: 1_800_000_000.0,
    **options: Any,
) -> Relay:
    return Relay(
        "https://relay.example.com",
        auth or FakeAuth(),
        transport=transport,
        sleep=sleeper or Sleeper(),
        random=lambda: random_value,
        clock=clock,
        **options,
    )
