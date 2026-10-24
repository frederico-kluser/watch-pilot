"""The live stream: typed events, monotonic ids, replay and the snapshot frame."""

from __future__ import annotations

import json

from app import activity, launches, notify, stream
from fastapi.testclient import TestClient


def client(fresh_guard) -> TestClient:
    return TestClient(main_app())


def main_app():
    from app import main

    return main.app


def test_publish_assigns_monotonic_ids_and_keeps_the_ring() -> None:
    stream.reset()
    first = stream.publish("notify", {"body": "a"})
    second = stream.publish("launch", {"status": "running"})
    assert first["id"] < second["id"]
    assert stream.events_since(first["id"]) == [second]
    assert stream.events_since(second["id"]) == []


def test_frame_shape_matches_the_sse_spec() -> None:
    frame = stream._frame("notify", {"body": "olá"}, event_id=7)
    assert frame.startswith("id: 7\nevent: notify\ndata: ")
    assert frame.endswith("\n\n")
    payload = json.loads(frame.split("data: ", 1)[1].strip())
    assert payload == {"body": "olá"}


def test_sources_publish_into_the_stream(fresh_guard, totp_code) -> None:
    stream.reset()
    notify.INBOX.clear()
    activity.clear()
    cli = client(fresh_guard)

    launch = cli.post(
        "/api/v1/launch",
        headers={"X-Watch-TOTP": totp_code()},
        json={"prompt": "arranca", "project": "proj", "new_story": True},
    ).json()
    cli.post(
        f"/api/v1/launches/{launch['launch_id']}/report",
        headers={"X-Watch-TOTP": totp_code()},
        json={"status": "completed"},
    )
    cli.post(
        "/api/v1/activity",
        headers={"X-Watch-TOTP": totp_code()},
        json={"sessions": [{"id": "s1", "state": "running", "line": "a escrever"}]},
    )

    kinds = [event["kind"] for event in stream.EVENTS]
    assert "launch" in kinds       # launch progress flows to the phone
    assert "notify" in kinds       # the milestone notification too
    assert "activity" in kinds     # and the live telemetry


def test_stream_sends_snapshot_then_replay(fresh_guard, totp_code) -> None:
    stream.reset()
    notify.INBOX.clear()
    # One event BEFORE the client connects: it must arrive as replay.
    stream.publish("notify", {"body": "já lá ia"})

    cli = client(fresh_guard)
    with cli.stream(
        "GET",
        "/api/v1/stream",
        headers={"X-Watch-TOTP": totp_code(), "Last-Event-ID": "0"},
    ) as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        assert response.headers["x-accel-buffering"] == "no"
        assert response.headers["cache-control"] == "no-cache, no-transform"

        frames: list[str] = []
        for line in response.iter_lines():
            if line.startswith("event: "):
                frames.append(line.removeprefix("event: "))
            if len(frames) >= 2:
                break

    assert frames[0] == "snapshot"  # the client reconciles from state first
    assert frames[1] == "notify"    # then the replay of what it missed


def test_snapshot_carries_the_state_the_phone_needs(fresh_guard) -> None:
    stream.reset()
    notify.INBOX.clear()
    activity.clear()
    activity.update({"sessions": [{"id": "s1", "state": "running", "line": "…"}]})
    snap = stream.snapshot()
    assert snap["activity"]["working_count"] == 1
    assert "pending_launches" in snap
    assert "unread_notifications" in snap
