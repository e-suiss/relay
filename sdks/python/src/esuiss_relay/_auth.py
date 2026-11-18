from __future__ import annotations

import base64
import hashlib
import json
import secrets
import threading
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Protocol

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from ._errors import AccessTokenError
from ._transport import HttpRequest, Transport


@dataclass(frozen=True)
class AuthContext:
    """What an authorizer may use: Relay's base URL, the transport, the clock and the timeout."""

    base_url: str
    transport: Transport
    clock: Callable[[], float]
    timeout: float


class Auth(Protocol):
    """Supplies the Authorization and DPoP headers of each request attempt."""

    def headers(self, method: str, url: str, context: AuthContext) -> dict[str, str]: ...

    def invalidate(self) -> None: ...


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _json(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


# E-93
class DPoPKey:
    """An Ed25519 proof-of-possession key that signs RFC 9449 DPoP proofs."""

    def __init__(self, private_key: Ed25519PrivateKey) -> None:
        self._private = private_key
        raw = private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.jwk: dict[str, str] = {"kty": "OKP", "crv": "Ed25519", "x": _b64(raw)}

    @classmethod
    def generate(cls) -> DPoPKey:
        """A new random key."""
        return cls(Ed25519PrivateKey.generate())

    @classmethod
    def from_private_bytes(cls, seed: bytes) -> DPoPKey:
        """The key of a 32-byte Ed25519 seed."""
        return cls(Ed25519PrivateKey.from_private_bytes(seed))

    def proof(
        self,
        method: str,
        url: str,
        now: float,
        *,
        token: str | None = None,
        nonce: str | None = None,
    ) -> str:
        """A fresh proof for one request; the URL loses its query and fragment."""
        header = {"typ": "dpop+jwt", "alg": "Ed25519", "jwk": self.jwk}
        claims: dict[str, Any] = {
            "htm": method.upper(),
            "htu": url.split("?", 1)[0].split("#", 1)[0],
            "iat": int(now),
            "jti": _b64(secrets.token_bytes(16)),
        }
        if token is not None:
            claims["ath"] = _b64(hashlib.sha256(token.encode("ascii")).digest())
        if nonce is not None:
            claims["nonce"] = nonce
        signing_input = _b64(_json(header)) + "." + _b64(_json(claims))
        signature = self._private.sign(signing_input.encode("ascii"))
        return signing_input + "." + _b64(signature)


class StaticToken:
    """A DPoP-bound access token obtained elsewhere, with the key it is bound to."""

    def __init__(self, token: str | Callable[[], str], key: DPoPKey) -> None:
        self._token = token
        self._key = key

    def headers(self, method: str, url: str, context: AuthContext) -> dict[str, str]:
        token = self._token() if callable(self._token) else self._token
        proof = self._key.proof(method, url, context.clock(), token=token)
        return {"Authorization": f"DPoP {token}", "DPoP": proof}

    def invalidate(self) -> None:
        return None


# E-93
# API-41
class ClientCredentials:
    """Access client credentials: a DPoP-bound access token per client, renewed before expiry."""

    def __init__(
        self,
        issuer: str,
        client_id: str,
        client_secret: str,
        *,
        scope: str | None = None,
        key: DPoPKey | None = None,
    ) -> None:
        self._issuer = issuer.rstrip("/")
        self._client_id = client_id
        self._client_secret = client_secret
        self._scope = scope
        self._key = key or DPoPKey.generate()
        self._lock = threading.Lock()
        self._token: str | None = None
        self._expires_at = 0.0
        self._resource: str | None = None
        self._endpoint: tuple[str, list[str]] | None = None

    def headers(self, method: str, url: str, context: AuthContext) -> dict[str, str]:
        token = self._current(context)
        proof = self._key.proof(method, url, context.clock(), token=token)
        return {"Authorization": f"DPoP {token}", "DPoP": proof}

    def invalidate(self) -> None:
        with self._lock:
            self._token = None

    def _current(self, context: AuthContext) -> str:
        with self._lock:
            if self._token is not None and context.clock() < self._expires_at:
                return self._token
            resource = self._relay_client_id(context)
            endpoint, methods = self._token_endpoint(context)
            token, lifetime = self._request(context, endpoint, methods, resource, None)
            self._token = token
            self._expires_at = context.clock() + max(lifetime - 30, 0) if lifetime else float("inf")
            return token

    def _get_json(self, context: AuthContext, url: str, what: str) -> dict[str, Any]:
        response = context.transport.send(
            HttpRequest("GET", url, {"Accept": "application/json"}, None, context.timeout)
        )
        if response.status != 200:
            raise AccessTokenError(f"{what} answered HTTP {response.status}")
        try:
            document = json.loads(response.body)
        except ValueError as error:
            raise AccessTokenError(f"{what} is not JSON") from error
        if not isinstance(document, dict):
            raise AccessTokenError(f"{what} is not a JSON object")
        return document

    def _relay_client_id(self, context: AuthContext) -> str:
        if self._resource is None:
            url = context.base_url.rstrip("/") + "/.well-known/relay-configuration"
            document = self._get_json(context, url, "the Relay discovery document")
            resource = document.get("access_client_id")
            if not isinstance(resource, str) or not resource:
                raise AccessTokenError("the Relay discovery document names no access_client_id")
            self._resource = resource
        return self._resource

    def _token_endpoint(self, context: AuthContext) -> tuple[str, list[str]]:
        if self._endpoint is None:
            url = self._issuer + "/.well-known/openid-configuration"
            document = self._get_json(context, url, "the Access discovery document")
            issuer = document.get("issuer")
            endpoint = document.get("token_endpoint")
            if not isinstance(issuer, str) or issuer.rstrip("/") != self._issuer:
                raise AccessTokenError("the Access discovery document names another issuer")
            if not isinstance(endpoint, str) or not endpoint.startswith("https://"):
                raise AccessTokenError("the Access token endpoint is not an https URL")
            methods = document.get("token_endpoint_auth_methods_supported")
            listed = [m for m in methods if isinstance(m, str)] if isinstance(methods, list) else []
            self._endpoint = (endpoint, listed)
        return self._endpoint

    def _request(
        self,
        context: AuthContext,
        endpoint: str,
        methods: list[str],
        resource: str,
        nonce: str | None,
    ) -> tuple[str, float | None]:
        form = {"grant_type": "client_credentials", "resource": resource}
        if self._scope:
            form["scope"] = self._scope
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "DPoP": self._key.proof("POST", endpoint, context.clock(), nonce=nonce),
        }
        if "client_secret_post" in methods and "client_secret_basic" not in methods:
            form["client_id"] = self._client_id
            form["client_secret"] = self._client_secret
        else:
            pair = (
                urllib.parse.quote_plus(self._client_id)
                + ":"
                + urllib.parse.quote_plus(self._client_secret)
            )
            headers["Authorization"] = "Basic " + base64.b64encode(pair.encode()).decode("ascii")
        body = urllib.parse.urlencode(form).encode("ascii")
        response = context.transport.send(
            HttpRequest("POST", endpoint, headers, body, context.timeout)
        )
        try:
            answer = json.loads(response.body) if response.body else {}
        except ValueError:
            answer = {}
        if not isinstance(answer, dict):
            answer = {}
        if response.status == 400 and answer.get("error") == "use_dpop_nonce" and nonce is None:
            fresh = response.headers.get("dpop-nonce")
            if not fresh:
                raise AccessTokenError("Access asked for a DPoP nonce without naming one")
            return self._request(context, endpoint, methods, resource, fresh)
        if response.status != 200:
            error = answer.get("error")
            reason = error if isinstance(error, str) else f"HTTP {response.status}"
            raise AccessTokenError(f"Access refused the client credentials: {reason}")
        token = answer.get("access_token")
        kind = answer.get("token_type")
        if not isinstance(token, str) or not token:
            raise AccessTokenError("Access answered without an access token")
        if not isinstance(kind, str) or kind.lower() != "dpop":
            raise AccessTokenError("Access issued a token that is not DPoP-bound")
        lifetime = answer.get("expires_in")
        if isinstance(lifetime, (int, float)) and not isinstance(lifetime, bool):
            return token, float(lifetime)
        return token, None
