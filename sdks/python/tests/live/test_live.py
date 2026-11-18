from __future__ import annotations

import os
from typing import Any

import pytest

from esuiss_relay import ClientCredentials, Relay

BASE_URL = os.environ.get("RELAY_SDK_LIVE_BASE_URL", "")

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(not BASE_URL, reason="RELAY_SDK_LIVE_BASE_URL is not set"),
]


def relay() -> Relay:
    credentials = ClientCredentials(
        os.environ["RELAY_SDK_LIVE_ISSUER"],
        os.environ["RELAY_SDK_LIVE_CLIENT_ID"],
        os.environ["RELAY_SDK_LIVE_CLIENT_SECRET"],
    )
    return Relay(BASE_URL, credentials)


def test_x48_live_send_and_list_on_the_test_plane() -> None:
    client = relay()
    event: Any = {"workflow": "welcome", "to": [{"id": "sdk-live-python"}]}
    accepted = client.create_event(event)
    assert accepted
    first = next(iter(client.list_notifications(limit=1)), None)
    assert first is not None
