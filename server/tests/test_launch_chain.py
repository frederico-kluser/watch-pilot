"""The phone↔hub↔plugin chain: launch queue, activity feed and folder browsing."""

from __future__ import annotations

from fastapi.testclient import TestClient

from app import activity, launches, main, notify


def client(fresh_guard) -> TestClient:
    return TestClient(main.app)


def test_launch_queues_a_pending_request(fresh_guard, totp_code) -> None:
    cli = client(fresh_guard)
    response = cli.post(
        "/api/v1/launch",
        headers={"X-Watch-TOTP": totp_code()},
        json={"prompt": "Arranca o trabalho", "project": "watch-pilot", "new_story": True, "story_name": "feat-x"},
    )
    assert response.status_code == 202
    payload = response.json()
    assert payload["status"] == "pending"
    assert payload["project"] == "watch-pilot"
    assert payload["new_story"] is True

    queue = cli.get("/api/v1/launches?pending=1", headers={"X-Watch-TOTP": totp_code()})
    assert queue.status_code == 200
    assert any(item["launch_id"] == payload["launch_id"] for item in queue.json()["items"])


def test_launch_requires_totp(fresh_guard) -> None:
    cli = client(fresh_guard)
    assert cli.post("/api/v1/launch", json={"prompt": "x", "project": "y"}).status_code == 401


def test_plugin_reports_progress_and_the_phone_is_notified(fresh_guard, totp_code) -> None:
    notify.INBOX.clear()
    cli = client(fresh_guard)
    launch = cli.post(
        "/api/v1/launch",
        headers={"X-Watch-TOTP": totp_code()},
        json={"prompt": "Arranca", "project": "dsh-worktree-jump", "new_story": True},
    ).json()

    running = cli.post(
        f"/api/v1/launches/{launch['launch_id']}/report",
        headers={"X-Watch-TOTP": totp_code()},
        json={"status": "running", "worktree_path": "/repo/.worktrees/x", "session_id": "session-1"},
    )
    assert running.status_code == 200
    assert running.json()["status"] == "running"

    done = cli.post(
        f"/api/v1/launches/{launch['launch_id']}/report",
        headers={"X-Watch-TOTP": totp_code()},
        json={"status": "completed", "detail": "feito"},
    )
    assert done.json()["status"] == "completed"
    assert done.json()["worktree_path"] == "/repo/.worktrees/x"

    # The milestone produced a notification the phone can pick up.
    inbox = cli.get("/api/v1/inbox", headers={"X-Watch-TOTP": totp_code()})
    assert any("Concluído" in item["title"] for item in inbox.json()["items"])


def test_activity_round_trip(fresh_guard, totp_code) -> None:
    activity.clear()
    cli = client(fresh_guard)
    posted = cli.post(
        "/api/v1/activity",
        headers={"X-Watch-TOTP": totp_code()},
        json={
            "sessions": [
                {"id": "session-a", "name": "feat-x", "state": "running", "line": "a escrever o parser"},
                {"id": "session-b", "name": "fix-y", "state": "idle", "line": ""},
            ]
        },
    )
    assert posted.status_code == 200
    payload = posted.json()
    assert payload["working_count"] == 1
    assert payload["idle_count"] == 1

    read = cli.get("/api/v1/activity", headers={"X-Watch-TOTP": totp_code()}).json()
    typing = [entry for entry in read["sessions"] if entry["state"] == "running"]
    assert typing[0]["line"] == "a escrever o parser"


def test_fs_browses_names_only(fresh_guard, totp_code, tmp_path) -> None:
    (tmp_path / "projeto").mkdir()
    (tmp_path / "projeto" / "segredo.txt").write_text("não deve aparecer")
    (tmp_path / ".oculto").mkdir()

    cli = client(fresh_guard)
    response = cli.get(f"/api/v1/fs?path={tmp_path}", headers={"X-Watch-TOTP": totp_code()})
    assert response.status_code == 200
    payload = response.json()
    names = [entry["name"] for entry in payload["entries"]]
    assert "projeto" in names
    assert ".oculto" not in names  # hidden entries stay out of the browse
    project = [entry for entry in payload["entries"] if entry["name"] == "projeto"][0]
    assert project["is_dir"] is True
    assert set(project.keys()) == {"name", "path", "is_dir"}  # names only, never contents

    missing = cli.get("/api/v1/fs?path=/não/existe", headers={"X-Watch-TOTP": totp_code()})
    assert missing.status_code == 404
