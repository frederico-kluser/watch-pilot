"""Live agent activity: who is working, who is not, and what each is doing.

The DSH plugin (``dsh-project-launcher``) publishes a snapshot of the harness
sessions — the same real telemetry ``dsh-work-game`` renders, restated here as a
small wire shape the phone can poll or stream. The store is intentionally dumb:
last-writer-wins snapshot plus a short history, so a phone that reconnects sees
the current truth immediately.
"""

from __future__ import annotations

import time
from typing import Any

from . import stream

# One live line per session. `state` is the harness's own vocabulary:
# "running" (working), "idle" (not working), "waiting" (approval/question).
SESSIONS: dict[str, dict[str, Any]] = {}
HISTORY: list[dict[str, Any]] = []
MAX_HISTORY = 100


def update(payload: dict[str, Any]) -> dict[str, Any]:
    """Merge one publisher snapshot into the live view."""
    now = time.time()
    sessions = payload.get("sessions")
    if isinstance(sessions, list):
        for raw in sessions:
            if not isinstance(raw, dict):
                continue
            session_id = str(raw.get("id") or raw.get("sessionId") or "")
            if session_id == "":
                continue
            entry = {
                "id": session_id,
                "name": str(raw.get("name") or session_id[:8]),
                "state": str(raw.get("state") or "idle"),
                "line": str(raw.get("line") or ""),
                "workspace": str(raw.get("workspace") or ""),
                "model": str(raw.get("model") or ""),
                "updated_at": now,
            }
            SESSIONS[session_id] = entry
            HISTORY.append(entry)
    del HISTORY[:-MAX_HISTORY]
    current = snapshot()
    stream.publish("activity", current)
    return current


def snapshot() -> dict[str, Any]:
    working = [entry for entry in SESSIONS.values() if entry["state"] == "running"]
    idle = [entry for entry in SESSIONS.values() if entry["state"] != "running"]
    return {
        "updated_at": time.time(),
        "working_count": len(working),
        "idle_count": len(idle),
        "sessions": sorted(SESSIONS.values(), key=lambda entry: entry["updated_at"], reverse=True),
        "history": list(reversed(HISTORY[-30:])),
    }


def clear() -> None:
    SESSIONS.clear()
    HISTORY.clear()
