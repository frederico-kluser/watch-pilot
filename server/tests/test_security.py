"""TOTP, replay guard and session-cookie tests (RFC vectors included)."""

from __future__ import annotations

import base64
import time

import pytest

from app import security
from app.config import settings

# RFC 4226 Appendix D / RFC 6238 Appendix B seed: base32("12345678901234567890")
SEED = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
SEED_BYTES = base64.b32decode(SEED)


@pytest.mark.parametrize(
    ("counter", "expected"),
    [
        (0, "755224"),
        (1, "287082"),
        (2, "359152"),
        (3, "969429"),
        (4, "338314"),
        (5, "254676"),
        (6, "287922"),
        (7, "162583"),
        (8, "399871"),
        (9, "520489"),
    ],
)
def test_rfc4226_hotp_vectors(counter: int, expected: str) -> None:
    assert security.hotp(SEED_BYTES, counter) == expected


@pytest.mark.parametrize(
    ("timestamp", "expected"),
    [
        (59, "287082"),
        (1111111109, "081804"),
        (1111111111, "050471"),
        (1234567890, "005924"),
        (2000000000, "279037"),
        (20000000000, "353130"),
    ],
)
def test_rfc6238_totp_vectors(timestamp: int, expected: str) -> None:
    """Six-digit values are ``bin % 10^6`` — not the first six of the 8-digit HOTP."""
    assert security.totp(SEED_BYTES, at=timestamp) == expected


def test_secret_normalisation_accepts_lowercase_and_spaces() -> None:
    assert security.normalise_secret("gezd gnbv gy3t qojq gezd gnbv gy3t qojq") == SEED_BYTES


def test_verify_accepts_previous_period_within_skew() -> None:
    now = 1_700_000_000.0
    previous = security.totp(settings.totp_secret, at=now - 30)
    ok, counter, reason = security.verify_totp(settings.totp_secret, previous, at=now, skew=1)
    assert ok and reason == "ok"
    assert counter == security.current_counter(now - 30)


def test_verify_rejects_stale_code_outside_skew() -> None:
    now = 1_700_000_000.0
    stale = security.totp(settings.totp_secret, at=now - 300)
    ok, _, reason = security.verify_totp(settings.totp_secret, stale, at=now, skew=1)
    assert not ok and reason == "mismatch"


@pytest.mark.parametrize("code", ["", "12345", "1234567", "abcdef", "１２３４５６", "12345 6x"])
def test_verify_rejects_malformed(code: str) -> None:
    ok, _, reason = security.verify_totp(settings.totp_secret, code)
    assert not ok and reason == "malformed"


def test_spaces_inside_a_numeric_code_are_tolerated() -> None:
    """Users type "123 456"; that is a well-formed attempt, not a malformed one."""
    code = security.totp(settings.totp_secret)
    spaced = f"{code[:3]} {code[3:]}"
    ok, _, reason = security.verify_totp(settings.totp_secret, spaced)
    assert ok and reason == "ok"


def test_replay_guard_is_monotonic_and_bounded(tmp_path) -> None:
    guard = security.ReplayGuard(tmp_path / "state.json")
    assert guard.accept("watch", 100, max_uses=2) is True
    assert guard.accept("watch", 100, max_uses=2) is True
    assert guard.accept("watch", 100, max_uses=2) is False  # budget exhausted
    assert guard.accept("watch", 99, max_uses=2) is False   # stale replay
    assert guard.accept("watch", 101, max_uses=2) is True   # clock moves on
    # The cursor survives a restart.
    reloaded = security.ReplayGuard(tmp_path / "state.json")
    assert reloaded.accept("watch", 100) is False


def test_authenticate_burns_counter_and_rate_limits(tmp_path, monkeypatch) -> None:
    guard = security.ReplayGuard(tmp_path / "state.json")
    monkeypatch.setattr(security, "guard", guard)
    code = security.totp(settings.totp_secret)

    first = security.authenticate(code, "watch-client")
    assert first.ok

    # A wrong code counts as a failure for that client.
    for _ in range(5):
        bad = security.authenticate("000000" if code != "000000" else "111111", "noisy-client")
        assert not bad.ok
    assert guard.blocked("noisy-client")


def test_rate_limit_blocks_even_a_valid_code(tmp_path, monkeypatch) -> None:
    guard = security.ReplayGuard(tmp_path / "state.json")
    monkeypatch.setattr(security, "guard", guard)
    for _ in range(5):
        security.authenticate("999999", "attacker")
    result = security.authenticate(security.totp(settings.totp_secret), "attacker")
    assert not result.ok and result.reason == "rate_limited"


def test_session_round_trip_and_tamper_detection() -> None:
    token = security.sign_session({"exp": time.time() + 60, "role": "browser"})
    assert security.read_session(token) is not None
    assert security.read_session(token[:-1] + ("0" if token[-1] != "0" else "1")) is None
    assert security.read_session(None) is None
    expired = security.sign_session({"exp": time.time() - 1})
    assert security.read_session(expired) is None
