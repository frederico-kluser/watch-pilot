"""Server-Sent Events stream: one live channel per device, no third parties.

This is the notification/telemetry pattern the architecture research settled on:
a single server→client HTTP stream per device (the phone never needs to push
through it), monotonic event ids with ``Last-Event-ID`` replay, a snapshot event
on connect so a reconnecting client reconciles from state, and a 15 s comment
heartbeat (the WHATWG-recommended keepalive that keeps proxies from dropping a
quiet stream). Foreground consumes this; background falls back to polling
``/api/v1/inbox``; the watch never holds a socket.
"""

from __future__ import annotations

import asyncio
import json
import time
from collections import deque
from typing import Any

from .config import settings

# Ring buffer of recent events plus one queue per live subscriber.
EVENTS: deque[dict[str, Any]] = deque(maxlen=200)
SUBSCRIBERS: set[asyncio.Queue] = set()
_COUNTER = {"next": 0}

KEEPALIVE_SECONDS = 15.0


def publish(kind: str, payload: dict[str, Any]) -> dict[str, Any]:
    """Publish one typed event to every live subscriber and the replay ring."""
    _COUNTER["next"] += 1
    event = {"id": _COUNTER["next"], "kind": kind, "at": time.time(), "payload": payload}
    EVENTS.append(event)
    for queue in list(SUBSCRIBERS):
        try:
            queue.put_nowait(event)
        except asyncio.QueueFull:
            pass
    return event


def events_since(last_id: int) -> list[dict[str, Any]]:
    return [event for event in EVENTS if event["id"] > last_id]


def snapshot() -> dict[str, Any]:
    """The state a fresh (or reconnecting) client reconciles from."""
    from . import activity, launches, notify  # local import: no cycles at import time

    unread = len(notify.INBOX)
    return {
        "server_time": time.time(),
        "activity": activity.snapshot(),
        "pending_launches": launches.pending(),
        "unread_notifications": unread,
    }


async def event_stream(last_id: int):
    """Yield SSE frames: snapshot → replay → live, with keepalive comments."""
    queue: asyncio.Queue = asyncio.Queue(maxsize=256)
    SUBSCRIBERS.add(queue)
    try:
        yield _frame("snapshot", snapshot(), event_id=None)
        for event in events_since(last_id):
            yield _frame(event["kind"], event["payload"], event_id=event["id"])
        while True:
            try:
                event = await asyncio.wait_for(queue.get(), timeout=KEEPALIVE_SECONDS)
                yield _frame(event["kind"], event["payload"], event_id=event["id"])
            except asyncio.TimeoutError:
                # The keepalive comment is what stops proxies from reaping a
                # quiet stream (WHATWG: legacy proxies drop idle connections).
                yield ": keepalive\n\n"
    finally:
        SUBSCRIBERS.discard(queue)


def _frame(kind: str, payload: dict[str, Any], event_id: int | None) -> str:
    lines = []
    if event_id is not None:
        lines.append(f"id: {event_id}")
    lines.append(f"event: {kind}")
    lines.append(f"data: {json.dumps(payload, ensure_ascii=False)}")
    return "\n".join(lines) + "\n\n"


def stream_headers() -> dict[str, str]:
    """Headers that keep intermediaries from buffering or compressing the stream."""
    return {
        "Cache-Control": "no-cache, no-transform",
        "X-Accel-Buffering": "no",
        "Connection": "keep-alive",
    }


def reset() -> None:
    EVENTS.clear()
    SUBSCRIBERS.clear()
    _COUNTER["next"] = 0
