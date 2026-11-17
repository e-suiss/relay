from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest
import yaml
from conftest import REPO

from esuiss_relay import (
    APIError,
    AuthenticationError,
    ConflictError,
    IdempotencyError,
    NotFoundError,
    RateLimitError,
    ServerError,
    ValidationError,
    error_class,
)
from esuiss_relay._errors import api_error

CATALOG: dict[str, Any] = yaml.safe_load(
    Path(REPO, "contracts", "errors.yaml").read_text(encoding="utf-8")
)

FAMILY_CLASSES: dict[str, type[APIError]] = {
    "auth": AuthenticationError,
    "idempotency": IdempotencyError,
    "quota": RateLimitError,
    "platform": ServerError,
}


def expected(entry: dict[str, Any]) -> type[APIError]:
    if entry["family"] in FAMILY_CLASSES:
        return FAMILY_CLASSES[entry["family"]]
    status = int(entry["status"])
    if status >= 500:
        return ServerError
    if status == 404:
        return NotFoundError
    if status in (409, 412, 428):
        return ConflictError
    return ValidationError


@pytest.mark.parametrize("entry", CATALOG["codes"], ids=lambda entry: entry["code"])
def test_x29_every_catalog_code_has_a_typed_error(entry: dict[str, Any]) -> None:
    assert error_class(int(entry["status"]), entry["code"]) is expected(entry)


@pytest.mark.parametrize("entry", CATALOG["codes"], ids=lambda entry: entry["code"])
def test_x29_retryable_comes_from_the_problem(entry: dict[str, Any]) -> None:
    body = (
        f'{{"type":"t","title":"x","status":{entry["status"]},'
        f'"code":"{entry["code"]}","retryable":{"true" if entry["retryable"] else "false"}}}'
    )
    error = api_error(int(entry["status"]), body.encode(), {"request-id": "req_1"})
    assert error.retryable is bool(entry["retryable"])
    assert error.code == entry["code"]
    assert error.request_id == "req_1"


def test_x29_unknown_codes_fall_back_to_status() -> None:
    assert error_class(503, "new_code") is ServerError
    assert error_class(401, None) is AuthenticationError
    assert error_class(429, None) is RateLimitError
    assert error_class(400, None) is ValidationError
