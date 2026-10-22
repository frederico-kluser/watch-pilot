"""Test bootstrap.

Environment must be in place *before* ``app.config`` is imported: the settings
singleton reads it at import time. Keeping every test on a throwaway data directory
also means the replay guard never touches the real ``auth-state.json``.
"""

from __future__ import annotations

import os
import tempfile

_TMP = tempfile.mkdtemp(prefix="watchpilot-tests-")

os.environ.setdefault("WATCHPILOT_DATA_DIR", _TMP)
os.environ.setdefault("WATCHPILOT_UPLOAD_DIR", os.path.join(_TMP, "uploads"))
os.environ.setdefault("WATCHPILOT_CONFIG_DIR", os.path.join(_TMP, "config"))
os.environ.setdefault("WATCHPILOT_ALLOW_MOCK_TRANSCRIPTION", "true")
os.environ.setdefault("WATCHPILOT_TRANSCRIBE_BACKENDS", "mock")
os.environ.setdefault("WATCHPILOT_TRANSCRIBE_LOCALE", "pt-PT")
os.environ.setdefault("WATCHPILOT_NOTIFY_CHANNELS", "log")
os.environ.setdefault("WATCHPILOT_TOTP_SECRET", "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP")
os.environ.setdefault("WATCHPILOT_SESSION_SECRET", "test-session-secret")
os.environ.setdefault("OPENROUTER_API_KEY", "test-key-not-used")

import pytest  # noqa: E402

from app import security  # noqa: E402
from app.config import settings  # noqa: E402


@pytest.fixture()
def fresh_guard(tmp_path, monkeypatch):
    """A replay guard with its own state file, so tests cannot leak counters."""
    guard = security.ReplayGuard(tmp_path / "auth-state.json")
    monkeypatch.setattr(security, "guard", guard)
    return guard


@pytest.fixture()
def totp_code():
    def _make(at: float | None = None) -> str:
        return security.totp(
            settings.totp_secret,
            at,
            digits=settings.totp_digits,
            period=settings.totp_period,
        )

    return _make
