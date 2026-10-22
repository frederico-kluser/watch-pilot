"""Authentication: RFC 6238 TOTP (Google Authenticator parameters), sessions and rate limits.

The Apple Watch app generates the six-digit code locally (CryptoKit HMAC-SHA1) and
sends it in the ``X-Watch-TOTP`` header of every request. The browser flow uses the
same secret through a small login form and a signed cookie.

Design notes
------------
* TOTP parameters: HMAC-SHA1, 6 digits, 30 s period, ±1 period of skew — the exact
  Google Authenticator defaults, and the ones the zone-runner of kluser.me also uses.
* ``bin % 10**digits`` (dynamic truncation), never "the first six digits of an
  eight-digit HOTP".
* Replay protection is per secret and **monotonic**: a counter older than the last
  accepted one is always refused (a sniffed code cannot be replayed once the watch
  has moved on), while the *current* counter may be reused a bounded number of times
  so that polling every three seconds does not require a fresh code per request.
  Two independent keys ("watch" for the API, "browser" for the cookie flow) keep
  their own cursor.
* Failures are rate limited per client: 5 failures in 300 s raise a 429.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import struct
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import settings


# ---------------------------------------------------------------------------
# Core algorithm
# ---------------------------------------------------------------------------
def normalise_secret(secret: str) -> bytes:
    """Decode a base32 secret, tolerating lower case, spaces and missing padding."""
    cleaned = secret.strip().replace(" ", "").replace("-", "").upper()
    padding = "=" * ((8 - len(cleaned) % 8) % 8)
    return base64.b32decode(cleaned + padding, casefold=True)


def hotp(secret: bytes, counter: int, digits: int = 6) -> str:
    """RFC 4226 HOTP value for ``counter``."""
    mac = hmac.new(secret, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    binary = struct.unpack(">I", mac[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(binary % (10**digits)).zfill(digits)


def totp(secret: str | bytes, at: float | None = None, *, digits: int = 6, period: int = 30) -> str:
    """RFC 6238 TOTP value for the instant ``at`` (defaults to now)."""
    key = normalise_secret(secret) if isinstance(secret, str) else secret
    counter = int((at if at is not None else time.time()) // period)
    return hotp(key, counter, digits)


def current_counter(at: float | None = None, period: int = 30) -> int:
    return int((at if at is not None else time.time()) // period)


def verify_totp(
    secret: str,
    code: str,
    *,
    at: float | None = None,
    digits: int = 6,
    period: int = 30,
    skew: int = 1,
) -> tuple[bool, int | None, str]:
    """Validate ``code``.

    Returns ``(ok, counter, reason)`` where ``reason`` is one of ``ok``,
    ``malformed``, ``mismatch`` or ``replay``.  Replay detection is *not* performed
    here — that is the store's job — but the counter that matched is returned.
    """
    candidate = (code or "").strip().replace(" ", "")
    # isascii() first: ``str.isdigit()`` accepts Unicode digits such as "１２３４５６",
    # and ``hmac.compare_digest`` refuses non-ASCII strings — that combination was a
    # remote 500. Reject anything outside 0-9 as malformed.
    if len(candidate) != digits or not candidate.isascii() or not candidate.isdigit():
        return False, None, "malformed"
    reference = current_counter(at, period)
    key = normalise_secret(secret)
    for delta in range(-skew, skew + 1):
        counter = reference + delta
        if counter < 0:
            continue
        if hmac.compare_digest(hotp(key, counter, digits), candidate):
            return True, counter, "ok"
    return False, None, "mismatch"


# ---------------------------------------------------------------------------
# Replay guard + rate limiting (persisted, thread safe)
# ---------------------------------------------------------------------------
@dataclass
class AuthFailure:
    count: int = 0
    window_start: float = 0.0


class ReplayGuard:
    """Remembers the highest accepted counter per secret so codes cannot be reused."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        self._last: dict[str, int] = {}
        self._uses: dict[str, int] = {}
        self._failures: dict[str, AuthFailure] = {}
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return
        self._last = {str(k): int(v) for k, v in raw.get("last_counter", {}).items()}

    def _save(self) -> None:
        payload = {"last_counter": self._last, "updated_at": time.time()}
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        tmp.chmod(0o600)
        tmp.replace(self.path)

    def accept(self, key_id: str, counter: int, *, max_uses: int = 24) -> bool:
        """Accept ``counter`` for ``key_id``.

        Refused when the counter is *older* than the last accepted one (stale
        replay), or when the current counter already reached ``max_uses``.
        """
        with self._lock:
            previous = self._last.get(key_id, -1)
            if counter < previous:
                return False
            slot = f"{key_id}:{counter}"
            if counter == previous:
                uses = self._uses.get(slot, 0)
                if uses >= max_uses:
                    return False
                self._uses[slot] = uses + 1
                return True
            self._last[key_id] = counter
            # Keep only the fresh slot: older counters can never be accepted again.
            self._uses = {key: value for key, value in self._uses.items() if key == slot}
            self._uses[slot] = 1
            self._save()
            return True

    def register_failure(self, client: str, *, limit: int = 5, window: float = 300.0) -> bool:
        """Count a failure; True when the client is now over the limit."""
        now = time.time()
        with self._lock:
            entry = self._failures.get(client)
            if entry is None or now - entry.window_start > window:
                entry = AuthFailure(count=0, window_start=now)
                self._failures[client] = entry
            entry.count += 1
            return entry.count >= limit

    def blocked(self, client: str, *, limit: int = 5, window: float = 300.0) -> bool:
        now = time.time()
        with self._lock:
            entry = self._failures.get(client)
            if entry is None:
                return False
            if now - entry.window_start > window:
                self._failures.pop(client, None)
                return False
            return entry.count >= limit

    def clear_failures(self, client: str) -> None:
        with self._lock:
            self._failures.pop(client, None)


guard = ReplayGuard(Path(settings.data_dir) / "auth-state.json")


# ---------------------------------------------------------------------------
# Session cookies (browser only)
# ---------------------------------------------------------------------------
def sign_session(payload: dict[str, Any]) -> str:
    body = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")
    signature = hmac.new(settings.session_secret.encode(), body.encode(), hashlib.sha256).hexdigest()
    return f"{body}.{signature}"


def read_session(token: str | None) -> dict[str, Any] | None:
    if not token or "." not in token:
        return None
    body, _, signature = token.rpartition(".")
    expected = hmac.new(settings.session_secret.encode(), body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        return None
    try:
        padded = body + "=" * ((4 - len(body) % 4) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
    except (ValueError, json.JSONDecodeError):
        return None
    if float(payload.get("exp", 0)) < time.time():
        return None
    return payload


# ---------------------------------------------------------------------------
# Request authentication helper used by the API routes
# ---------------------------------------------------------------------------
@dataclass
class AuthResult:
    ok: bool
    reason: str = ""
    counter: int | None = None


def authenticate(code: str, client: str) -> AuthResult:
    """Validate a watch-generated TOTP code for an API request."""
    if guard.blocked(client):
        return AuthResult(False, "rate_limited")
    ok, counter, reason = verify_totp(
        settings.totp_secret,
        code,
        digits=settings.totp_digits,
        period=settings.totp_period,
        skew=settings.totp_skew,
    )
    if not ok:
        guard.register_failure(client)
        return AuthResult(False, reason)
    assert counter is not None
    if not guard.accept("watch", counter):
        return AuthResult(False, "replay")
    guard.clear_failures(client)
    return AuthResult(True, "ok", counter)
