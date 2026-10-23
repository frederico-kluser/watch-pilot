"""Configuration for the Watch Pilot hub.

Values come from (in order of precedence):

1. environment variables (``WATCHPILOT_*``),
2. a JSON settings file (``~/.config/watch-pilot/config.json``, mode 0600),
3. the safe defaults below.

Secrets are never logged and never rendered by the web UI.
"""

from __future__ import annotations

import json
import os
import secrets
from dataclasses import asdict, dataclass, field
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("WATCHPILOT_CONFIG_DIR", Path.home() / ".config" / "watch-pilot"))
CONFIG_PATH = CONFIG_DIR / "config.json"
DATA_DIR = Path(os.environ.get("WATCHPILOT_DATA_DIR", Path.home() / ".local" / "share" / "watch-pilot"))

# Reserved ports on this machine (kluser.me pool): 3080 (DSH), 8787 (Trello), 8790 (defcon4).
DEFAULT_PORT = 8765


def _default_totp_secret() -> str:
    """Return the shared TOTP secret, generating a persistent one on first run."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    secret_file = CONFIG_DIR / "totp.secret"
    if secret_file.exists():
        return secret_file.read_text(encoding="utf-8").strip()
    # 20 random bytes -> canonical base32 (RFC 4648, no padding) as Google Authenticator expects.
    import base64

    raw = secrets.token_bytes(20)
    value = base64.b32encode(raw).decode("ascii").rstrip("=")
    secret_file.write_text(value + "\n", encoding="utf-8")
    secret_file.chmod(0o600)
    return value


@dataclass
class Settings:
    # --- network -------------------------------------------------------
    host: str = "127.0.0.1"
    port: int = DEFAULT_PORT
    public_base_url: str = "https://watch.kluser.me"

    # --- auth ----------------------------------------------------------
    totp_secret: str = ""
    totp_issuer: str = "Watch Pilot"
    totp_account: str = "minim1@kluser.me"
    totp_digits: int = 6
    totp_period: int = 30
    totp_skew: int = 1
    session_secret: str = ""
    session_ttl_seconds: int = 12 * 3600
    allow_mock_transcription: bool = False
    max_upload_bytes: int = 12 * 1024 * 1024

    # --- transcription -------------------------------------------------
    # Ordered list of backends; the first one that returns text wins.
    transcribe_backends: list[str] = field(
        default_factory=lambda: ["wtx-transcribe", "yap", "shortcut", "mock"]
    )
    transcribe_timeout_seconds: int = 120
    # The Mac's UI language is English but the user speaks Portuguese; force the
    # locale instead of inheriting Locale.current (which mis-detects the language).
    transcribe_locale: str = "pt-PT"

    # --- language model ------------------------------------------------
    openrouter_api_key: str = ""
    openrouter_base_url: str = "https://openrouter.ai/api/v1"
    model: str = "xiaomi/mimo-v2.6-pro"
    model_fallbacks: list[str] = field(
        default_factory=lambda: ["xiaomi/mimo-v2.5-pro", "xiaomi/mimo-v2.6-flash"]
    )
    reasoning_effort: str = "max"
    # The provider strips the graded effort, so the depth demand lives in the system
    # prompt; exposing the reasoning text is optional (tokens are billed either way).
    include_reasoning: bool = False
    max_tokens: int = 2048
    llm_timeout_seconds: float = 120.0
    llm_temperature: float = 0.4

    # --- speech synthesis (the answer comes back as *fala*) -------------
    tts_enabled: bool = True
    # Ordered list; the first backend that produces audio wins.
    tts_backends: list[str] = field(default_factory=lambda: ["openrouter", "say"])
    # ElevenLabs through the OpenRouter audio API (same key as the reasoning step).
    tts_model: str = "elevenlabs/eleven-v4-turbo"
    tts_voice: str = "george"
    # Local fallback voice for macOS `say` ("" = system default).
    tts_say_voice: str = ""
    tts_timeout_seconds: int = 60
    tts_max_chars: int = 600

    system_prompt: str = (
        "You are Watch Pilot, the voice assistant running on a Mac mini M1. "
        "The user spoke one short command through an Apple Watch. "
        "Reply in the user's language, in at most three sentences, ready to be read on a 40 mm watch screen. "
        "Be concrete and operational: state what you will do or what you know, never pad with pleasantries. "
        "Think exhaustively before answering: enumerate the options, check your arithmetic and your facts, "
        "then compress the conclusion into the short answer."
    )

    # --- notifications -------------------------------------------------
    notify_channels: list[str] = field(default_factory=lambda: ["local", "log"])
    imessage_phone: str = ""
    apns_bundle_id: str = "me.kluser.watchpilot"
    apns_key_path: str = ""
    apns_key_id: str = ""
    apns_team_id: str = ""
    apns_use_sandbox: bool = True
    webhook_url: str = ""

    # --- storage -------------------------------------------------------
    data_dir: str = str(DATA_DIR)
    upload_dir: str = str(DATA_DIR / "uploads")

    # ------------------------------------------------------------------
    @classmethod
    def load(cls) -> "Settings":
        data: dict[str, object] = {}
        if CONFIG_PATH.exists():
            try:
                data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                data = {}
        settings = cls()
        for key, value in data.items():
            if hasattr(settings, key) and value is not None:
                setattr(settings, key, value)

        # 2. environment wins over the file.
        for key in asdict(settings):
            env_key = "WATCHPILOT_" + key.upper()
            raw = os.environ.get(env_key)
            if raw is None:
                continue
            current = getattr(settings, key)
            if isinstance(current, bool):
                setattr(settings, key, raw.lower() in {"1", "true", "yes", "on"})
            elif isinstance(current, int):
                setattr(settings, key, int(raw))
            elif isinstance(current, float):
                setattr(settings, key, float(raw))
            elif isinstance(current, list):
                setattr(settings, key, [item.strip() for item in raw.split(",") if item.strip()])
            else:
                setattr(settings, key, raw)

        # 3. secrets: env -> file -> generated.
        if not settings.openrouter_api_key:
            settings.openrouter_api_key = os.environ.get("OPENROUTER_API_KEY", "")
        if not settings.totp_secret:
            settings.totp_secret = os.environ.get("WATCHPILOT_TOTP_SECRET") or _default_totp_secret()
        else:
            settings.totp_secret = settings.totp_secret.replace(" ", "").upper()
        if not settings.session_secret:
            secret_file = CONFIG_DIR / "session.secret"
            if secret_file.exists():
                settings.session_secret = secret_file.read_text(encoding="utf-8").strip()
            else:
                CONFIG_DIR.mkdir(parents=True, exist_ok=True)
                settings.session_secret = secrets.token_urlsafe(48)
                secret_file.write_text(settings.session_secret + "\n", encoding="utf-8")
                secret_file.chmod(0o600)

        Path(settings.data_dir).mkdir(parents=True, exist_ok=True)
        Path(settings.upload_dir).mkdir(parents=True, exist_ok=True)
        return settings

    def save(self) -> None:
        """Persist non-derived settings (never the raw API key)."""
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "host": self.host,
            "port": self.port,
            "public_base_url": self.public_base_url,
            "model": self.model,
            "reasoning_effort": self.reasoning_effort,
            "notify_channels": self.notify_channels,
            "imessage_phone": self.imessage_phone,
        }
        CONFIG_PATH.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        CONFIG_PATH.chmod(0o600)

    # ------------------------------------------------------------------
    @property
    def totp_uri(self) -> str:
        """otpauth:// URI for Google Authenticator (contains the secret)."""
        from urllib.parse import quote

        label = quote(f"{self.totp_issuer}:{self.totp_account}")
        params = (
            f"secret={self.totp_secret}&issuer={quote(self.totp_issuer)}"
            f"&algorithm=SHA1&digits={self.totp_digits}&period={self.totp_period}"
        )
        return f"otpauth://totp/{label}?{params}"

    def redacted(self) -> dict[str, object]:
        """Safe representation for the status endpoint and logs."""
        return {
            "host": self.host,
            "port": self.port,
            "public_base_url": self.public_base_url,
            "model": self.model,
            "reasoning_effort": self.reasoning_effort,
            "transcribe_backends": self.transcribe_backends,
            "notify_channels": self.notify_channels,
            "openrouter_key_present": bool(self.openrouter_api_key),
            "apns_configured": bool(self.apns_key_path and self.apns_key_id and self.apns_team_id),
            "imessage_configured": bool(self.imessage_phone),
        }


settings = Settings.load()
