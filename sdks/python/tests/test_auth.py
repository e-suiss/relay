from __future__ import annotations

import base64
import hashlib
import json
import urllib.parse
from typing import Any

import pytest
from conftest import StubTransport, answer
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from esuiss_relay import (
    AccessTokenError,
    ClientCredentials,
    DPoPKey,
    HttpRequest,
    HttpResponse,
    Relay,
)

ISSUER = "https://access.example.com"
TOKEN_URL = "https://access.example.com/oauth2/token"


def unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def decode_proof(proof: str) -> tuple[dict[str, Any], dict[str, Any]]:
    head, claims, signature = proof.split(".")
    header = json.loads(unb64(head))
    raw = unb64(header["jwk"]["x"])
    Ed25519PublicKey.from_public_bytes(raw).verify(unb64(signature), f"{head}.{claims}".encode())
    return header, json.loads(unb64(claims))


def discovery(methods: list[str] | None = None) -> list[HttpResponse]:
    access: dict[str, Any] = {"issuer": ISSUER, "token_endpoint": TOKEN_URL}
    if methods is not None:
        access["token_endpoint_auth_methods_supported"] = methods
    return [
        answer(200, {"access_client_id": "relay-client"}),
        answer(200, access),
    ]


def token(value: str = "at-1", expires_in: int = 300) -> HttpResponse:
    return answer(200, {"access_token": value, "token_type": "DPoP", "expires_in": expires_in})


def relay(transport: StubTransport, clock: list[float]) -> Relay:
    return Relay(
        "https://relay.example.com",
        ClientCredentials(ISSUER, "client id", "s3cret"),
        transport=transport,
        clock=lambda: clock[0],
    )


def test_e93_client_credentials_obtain_a_dpop_token() -> None:
    clock = [1_800_000_000.0]
    transport = StubTransport(*discovery(), token(), answer(200, {"object": "notification"}))
    relay(transport, clock).get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    relay_discovery, access_discovery, grant, call = transport.requests
    assert relay_discovery.url == "https://relay.example.com/.well-known/relay-configuration"
    assert access_discovery.url == ISSUER + "/.well-known/openid-configuration"
    assert grant.url == TOKEN_URL
    form = urllib.parse.parse_qs((grant.body or b"").decode())
    assert form == {"grant_type": ["client_credentials"], "resource": ["relay-client"]}
    basic = base64.b64decode(grant.headers["Authorization"].removeprefix("Basic ")).decode()
    assert basic == "client+id:s3cret"
    header, claims = decode_proof(grant.headers["DPoP"])
    assert header["typ"] == "dpop+jwt"
    assert header["alg"] == "Ed25519"
    assert claims["htm"] == "POST"
    assert claims["htu"] == TOKEN_URL
    assert "ath" not in claims
    assert call.headers["Authorization"] == "DPoP at-1"
    _header, call_claims = decode_proof(call.headers["DPoP"])
    assert call_claims["htm"] == "GET"
    assert call_claims["htu"] == call.url
    assert call_claims["iat"] == 1_800_000_000
    expected = base64.urlsafe_b64encode(hashlib.sha256(b"at-1").digest()).rstrip(b"=").decode()
    assert call_claims["ath"] == expected


def test_e93_token_is_reused_until_expiry() -> None:
    clock = [1_800_000_000.0]
    transport = StubTransport(
        *discovery(),
        token("at-1", 300),
        answer(200, {}),
        answer(200, {}),
        token("at-2", 300),
        answer(200, {}),
    )
    client = relay(transport, clock)
    client.get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    client.get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    clock[0] += 280
    client.get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    assert transport.requests[-1].headers["Authorization"] == "DPoP at-2"


def test_e93_client_secret_post_when_basic_is_not_offered() -> None:
    clock = [1_800_000_000.0]
    transport = StubTransport(*discovery(["client_secret_post"]), token(), answer(200, {}))
    relay(transport, clock).get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    grant = transport.requests[2]
    form = urllib.parse.parse_qs((grant.body or b"").decode())
    assert form["client_id"] == ["client id"]
    assert form["client_secret"] == ["s3cret"]
    assert "Authorization" not in grant.headers


def test_e93_dpop_nonce_is_used_once() -> None:
    clock = [1_800_000_000.0]
    nonce = answer(400, {"error": "use_dpop_nonce"}, {"dpop-nonce": "n-1"})
    transport = StubTransport(*discovery(), nonce, token(), answer(200, {}))
    relay(transport, clock).get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")
    _header, claims = decode_proof(transport.requests[3].headers["DPoP"])
    assert claims["nonce"] == "n-1"


def test_e93_bearer_token_is_refused() -> None:
    clock = [1_800_000_000.0]
    bearer = answer(200, {"access_token": "at", "token_type": "Bearer"})
    transport = StubTransport(*discovery(), bearer)
    with pytest.raises(AccessTokenError):
        relay(transport, clock).get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")


def test_e93_foreign_issuer_is_refused() -> None:
    clock = [1_800_000_000.0]
    transport = StubTransport(
        answer(200, {"access_client_id": "relay-client"}),
        answer(200, {"issuer": "https://evil.example.com", "token_endpoint": TOKEN_URL}),
    )
    with pytest.raises(AccessTokenError):
        relay(transport, clock).get_notification("ntf_01j9zq3k4m5n6p7q8r9s0t1v2w")


def test_e93_proof_drops_query_and_has_unique_jti() -> None:
    key = DPoPKey.generate()
    first = key.proof("get", "https://relay.example.com/v1/x?limit=1#f", 10.0, token="t")
    second = key.proof("GET", "https://relay.example.com/v1/x", 10.0, token="t")
    _h1, one = decode_proof(first)
    _h2, two = decode_proof(second)
    assert one["htu"] == "https://relay.example.com/v1/x"
    assert one["htm"] == "GET"
    assert one["jti"] != two["jti"]


def test_e93_proof_key_from_seed_is_stable() -> None:
    seed = bytes(range(32))
    assert DPoPKey.from_private_bytes(seed).jwk == DPoPKey.from_private_bytes(seed).jwk


def test_e93_request_type_is_plain_data() -> None:
    request = HttpRequest("GET", "https://relay.example.com", {})
    assert request.body is None
