from __future__ import annotations

import urllib.parse
from typing import Any

from conftest import StubTransport, answer, client


def page(ids: list[str], has_more: bool, cursor: str | None) -> dict[str, Any]:
    return {
        "object": "list",
        "data": [{"id": item} for item in ids],
        "has_more": has_more,
        "next_cursor": cursor,
    }


def query(url: str) -> dict[str, list[str]]:
    return urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)


def test_api56_pages_are_fetched_lazily() -> None:
    transport = StubTransport(
        answer(200, page(["a", "b"], True, "c1")),
        answer(200, page(["c"], True, "c2")),
        answer(200, page(["d"], False, None)),
    )
    first = client(transport).list_notifications(limit=2)
    assert len(transport.requests) == 1
    assert [item["id"] for item in first.data] == ["a", "b"]
    iterator = iter(first)
    assert [next(iterator)["id"], next(iterator)["id"]] == ["a", "b"]
    assert len(transport.requests) == 1
    assert next(iterator)["id"] == "c"
    assert len(transport.requests) == 2
    assert [item["id"] for item in iterator] == ["d"]
    assert len(transport.requests) == 3
    second = query(transport.requests[1].url)
    assert second == {"limit": ["2"], "starting_after": ["c1"]}
    assert query(transport.requests[2].url)["starting_after"] == ["c2"]


def test_api56_last_page_stops_without_request() -> None:
    transport = StubTransport(answer(200, page(["a"], False, None)))
    first = client(transport).list_notifications()
    assert [item["id"] for item in first] == ["a"]
    assert first.next_page() is None
    assert len(transport.requests) == 1


def test_api56_null_cursor_ends_iteration_even_when_has_more() -> None:
    transport = StubTransport(answer(200, page(["a"], True, None)))
    assert [item["id"] for item in client(transport).list_notifications()] == ["a"]
    assert len(transport.requests) == 1


def test_api56_iter_pages_yields_each_page() -> None:
    transport = StubTransport(
        answer(200, page(["a"], True, "c1")), answer(200, page(["b"], False, None))
    )
    pages = list(client(transport).list_notifications().iter_pages())
    assert [p.next_cursor for p in pages] == ["c1", None]
