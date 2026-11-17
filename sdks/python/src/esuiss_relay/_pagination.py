from __future__ import annotations

from collections.abc import Callable, Iterator, Mapping
from typing import Any, Generic, TypeVar

T = TypeVar("T")


# API-56
class Page(Generic[T]):
    """One page of a cursor-paginated list; iterating it walks every later page lazily."""

    def __init__(self, body: Mapping[str, Any], fetch: Callable[[str], Page[T]]) -> None:
        data = body.get("data")
        self.data: list[T] = list(data) if isinstance(data, list) else []
        self.has_more: bool = body.get("has_more") is True
        next_cursor = body.get("next_cursor")
        previous_cursor = body.get("previous_cursor")
        self.next_cursor: str | None = next_cursor if isinstance(next_cursor, str) else None
        self.previous_cursor: str | None = (
            previous_cursor if isinstance(previous_cursor, str) else None
        )
        self.raw: Mapping[str, Any] = body
        self._fetch = fetch

    def next_page(self) -> Page[T] | None:
        """The following page, fetched now, or None on the last page."""
        if not self.has_more or self.next_cursor is None:
            return None
        return self._fetch(self.next_cursor)

    def iter_pages(self) -> Iterator[Page[T]]:
        """This page and every later one, each fetched only when reached."""
        page: Page[T] | None = self
        while page is not None:
            yield page
            page = page.next_page()

    def __iter__(self) -> Iterator[T]:
        for page in self.iter_pages():
            yield from page.data
