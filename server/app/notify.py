"""Notification fan-out from the Mac mini.

Channels (all optional, chosen by ``settings.notify_channels``):

``local``
    A native macOS notification via ``osascript`` (``display notification``).
``log``
    Append to ``<data_dir>/notifications.jsonl`` and the in-memory inbox.
``imessage``
    AppleScript bridge to Messages.app — the zero-cost route for a Personal Team
    account, delivered to the iPhone and mirrored to the watch.
``apns``
    Direct HTTP/2 push to Apple's gateway using a ``.p8`` auth key (requires a paid
    Apple Developer Program membership and the app's APNs device token).
``webhook``
    A plain JSON POST to an arbitrary URL.
"""

from __future__ import annotations

import asyncio
import json
import shutil
import time
import uuid
from collections import deque
from dataclasses import asdict, dataclass, field
from pathlib import Path

import httpx

from .config import settings

INBOX: deque["Notification"] = deque(maxlen=200)
DEVICE_TOKENS: set[str] = set()
_JWT_CACHE: dict[str, float | str] = {"token": "", "issued_at": 0.0}


@dataclass
class Notification:
    id: str
    title: str
    body: str
    created_at: float
    task_id: str = ""
    progress: float = 0.0
    kind: str = "alert"
    channels: list[str] = field(default_factory=list)
    delivered: dict[str, str] = field(default_factory=dict)

    def to_json(self) -> dict[str, object]:
        return asdict(self)


def _log_path() -> Path:
    return Path(settings.data_dir) / "notifications.jsonl"


def _record(notification: Notification) -> None:
    INBOX.append(notification)
    try:
        with _log_path().open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(notification.to_json(), ensure_ascii=False) + "\n")
    except OSError:
        pass


def inbox(limit: int = 50) -> list[dict[str, object]]:
    items = list(INBOX)[-limit:]
    return [item.to_json() for item in reversed(items)]


# ---------------------------------------------------------------------------
# Channels
# ---------------------------------------------------------------------------
async def _send_local(title: str, body: str) -> bool:
    script = (
        'on run argv\n'
        '  display notification (item 2 of argv) with title (item 1 of argv) sound name "default"\n'
        'end run'
    )
    osascript = shutil.which("osascript")
    if not osascript:
        return False
    proc = await asyncio.create_subprocess_exec(
        osascript, "-e", script, title, body,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
    )
    try:
        _, err = await asyncio.wait_for(proc.communicate(), timeout=10)
    except asyncio.TimeoutError:
        proc.kill()
        return False
    return proc.returncode == 0


async def _send_imessage(title: str, body: str) -> bool:
    """Send through Messages.app to the iPhone number.

    The recipient is passed through ``argv`` so that quoting/escaping cannot break
    the script, and the service is discovered at runtime to dodge the
    "can't send a message to yourself" failure when targeting the same Apple ID.
    """
    if not settings.imessage_phone:
        return False
    osascript = shutil.which("osascript")
    if not osascript:
        return False
    script = (
        'on run argv\n'
        '  set targetBuddy to item 1 of argv\n'
        '  set targetMessage to item 2 of argv\n'
        '  tell application "Messages"\n'
        '    set targetService to id of 1st service whose service type = iMessage\n'
        '    set theBuddy to buddy targetBuddy of service id targetService\n'
        '    send targetMessage to theBuddy\n'
        '  end tell\n'
        'end run'
    )
    proc = await asyncio.create_subprocess_exec(
        osascript, "-e", script, settings.imessage_phone, f"{title}: {body}",
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
    )
    try:
        _, err = await asyncio.wait_for(proc.communicate(), timeout=15)
    except asyncio.TimeoutError:
        proc.kill()
        return False
    if proc.returncode != 0:
        return False
    return True


def _apns_jwt() -> str:
    """Mint (and cache for 45 min) the ES256 provider token."""
    import jwt  # PyJWT

    now = time.time()
    if _JWT_CACHE.get("token") and now - float(_JWT_CACHE.get("issued_at") or 0) < 2700:
        return str(_JWT_CACHE["token"])
    private_key = Path(settings.apns_key_path).read_text(encoding="utf-8")
    token = jwt.encode(
        {"iss": settings.apns_team_id, "iat": int(now)},
        private_key,
        algorithm="ES256",
        headers={"alg": "ES256", "kid": settings.apns_key_id},
    )
    _JWT_CACHE["token"] = token
    _JWT_CACHE["issued_at"] = now
    return token


async def _send_apns(title: str, body: str, *, task_id: str, progress: float, silent: bool) -> int:
    if not (settings.apns_key_path and settings.apns_key_id and settings.apns_team_id):
        return 0
    if not DEVICE_TOKENS:
        return 0
    host = "https://api.sandbox.push.apple.com" if settings.apns_use_sandbox else "https://api.push.apple.com"
    if silent:
        push_type, priority = "background", "5"
        payload: dict[str, object] = {"aps": {"content-available": 1}, "task_id": task_id, "progress": progress}
    else:
        push_type, priority = "alert", "10"
        payload = {
            "aps": {"alert": {"title": title, "body": body}, "sound": "default"},
            "task_id": task_id,
            "progress": progress,
        }
    delivered = 0
    try:
        token = _apns_jwt()
    except Exception:
        return 0
    async with httpx.AsyncClient(http2=True, timeout=10.0) as client:
        for device in list(DEVICE_TOKENS):
            try:
                response = await client.post(
                    f"{host}/3/device/{device}",
                    headers={
                        "authorization": f"bearer {token}",
                        "apns-topic": settings.apns_bundle_id,
                        "apns-push-type": push_type,
                        "apns-priority": priority,
                        "apns-expiration": "0" if silent else str(int(time.time()) + 3600),
                    },
                    json=payload,
                )
            except httpx.HTTPError:
                continue
            if response.status_code == 200:
                delivered += 1
            elif response.status_code in {400, 410}:
                DEVICE_TOKENS.discard(device)  # BadDeviceToken / Unregistered
    return delivered


async def _send_webhook(title: str, body: str, *, task_id: str, progress: float) -> bool:
    if not settings.webhook_url:
        return False
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(
                settings.webhook_url,
                json={"title": title, "body": body, "task_id": task_id, "progress": progress},
            )
        return response.status_code < 400
    except httpx.HTTPError:
        return False


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
async def notify(
    title: str,
    body: str,
    *,
    task_id: str = "",
    progress: float = 0.0,
    silent: bool = False,
    channels: list[str] | None = None,
) -> Notification:
    """Fan out one notification and record it in the inbox."""
    active = channels or settings.notify_channels
    notification = Notification(
        id=str(uuid.uuid4()),
        title=title,
        body=body,
        created_at=time.time(),
        task_id=task_id,
        progress=progress,
        kind="background" if silent else "alert",
        channels=list(active),
    )
    for channel in active:
        try:
            if channel == "local" and not silent:
                notification.delivered[channel] = "ok" if await _send_local(title, body) else "skipped"
            elif channel == "imessage" and not silent:
                notification.delivered[channel] = "ok" if await _send_imessage(title, body) else "skipped"
            elif channel == "apns":
                count = await _send_apns(title, body, task_id=task_id, progress=progress, silent=silent)
                notification.delivered[channel] = f"ok:{count}" if count else "skipped"
            elif channel == "webhook":
                notification.delivered[channel] = "ok" if await _send_webhook(title, body, task_id=task_id, progress=progress) else "failed"
            elif channel == "log":
                notification.delivered[channel] = "ok"
            else:
                notification.delivered[channel] = "unknown-channel"
        except Exception as exc:  # pragma: no cover - defensive
            notification.delivered[channel] = f"error:{exc.__class__.__name__}"
    _record(notification)
    return notification
