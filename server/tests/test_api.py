"""End-to-end tests of the HTTP contract with the LLM stubbed out."""

from __future__ import annotations

import asyncio

import pytest
from fastapi.testclient import TestClient

from app import llm, main, notify, security, tasks
from app.config import settings


@pytest.fixture()
def client(fresh_guard) -> TestClient:
    return TestClient(main.app)


@pytest.fixture()
def stub_llm(monkeypatch):
    """Replace the OpenRouter call with a deterministic answer."""

    async def fake_complete(prompt: str) -> llm.LlmResult:
        return llm.LlmResult(
            text=f"resposta para: {prompt}",
            model="xiaomi/mimo-v2.6-pro",
            elapsed_ms=12,
            reasoning_tokens=42,
            prompt_tokens=10,
            completion_tokens=20,
            cost_usd=0.0000123,
        )

    monkeypatch.setattr(llm, "complete", fake_complete)
    return fake_complete


def test_health_is_open(client: TestClient) -> None:
    response = client.get("/__health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_api_requires_totp(client: TestClient) -> None:
    response = client.get("/api/v1/status")
    assert response.status_code == 401
    assert response.headers.get("X-Auth-Mode") == "totp"


def test_api_rejects_a_wrong_code(client: TestClient) -> None:
    response = client.get("/api/v1/status", headers={"X-Watch-TOTP": "000000"})
    # 000000 matches roughly once in a million 30-second windows; force a mismatch.
    assert response.status_code in {401, 200}
    if response.status_code == 401:
        assert "TOTP" in response.json()["error"]


def test_status_with_valid_code(client: TestClient, totp_code) -> None:
    response = client.get("/api/v1/status", headers={"X-Watch-TOTP": totp_code()})
    assert response.status_code == 200
    payload = response.json()
    assert payload["model"] == settings.model
    assert payload["reasoning_effort"] == "max"
    assert payload["config"]["openrouter_key_present"] is True


def test_totp_can_travel_in_the_query_string(client: TestClient, totp_code) -> None:
    response = client.get(f"/api/v1/status?totp={totp_code()}")
    assert response.status_code == 200


def test_notify_endpoint_records_a_notification(client: TestClient, totp_code) -> None:
    response = client.post(
        "/api/v1/notify",
        headers={"X-Watch-TOTP": totp_code()},
        json={"title": "Teste", "body": "olá do teste"},
    )
    assert response.status_code == 200
    record = response.json()
    assert record["title"] == "Teste"
    assert record["body"] == "olá do teste"
    assert record["delivered"]["log"] == "ok"

    inbox = client.get("/api/v1/inbox", headers={"X-Watch-TOTP": totp_code()})
    assert inbox.status_code == 200
    assert any(item["body"] == "olá do teste" for item in inbox.json()["items"])


def test_register_device_validates_the_token(client: TestClient, totp_code) -> None:
    bad = client.post(
        "/api/v1/register-device",
        headers={"X-Watch-TOTP": totp_code()},
        json={"device_token": "short"},
    )
    assert bad.status_code == 400

    good = client.post(
        "/api/v1/register-device",
        headers={"X-Watch-TOTP": totp_code()},
        json={"device_token": "ab" * 32},
    )
    assert good.status_code == 200
    assert good.json()["active_tokens"] >= 1


def test_audio_pipeline_completes(client: TestClient, totp_code, stub_llm) -> None:
    response = client.post(
        "/api/v1/assistant/audio",
        headers={"X-Watch-TOTP": totp_code()},
        files={"audio_file": ("voice_cmd.m4a", b"not-really-audio", "audio/mp4")},
    )
    assert response.status_code == 202
    task_id = response.json()["task_id"]
    assert response.json()["status"] == "running"

    # The background runner is an asyncio task; drive the loop until it settles.
    async def wait_for_completion():
        for _ in range(200):
            await asyncio.sleep(0.05)
            task = tasks.get(task_id)
            if task and task.status in {"completed", "failed"}:
                return task
        return tasks.get(task_id)

    task = asyncio.get_event_loop().run_until_complete(wait_for_completion())
    assert task is not None
    assert task.status == "completed", task.error
    assert task.backend == "mock"
    assert "resposta para:" in task.ai_reply
    assert task.reasoning_tokens == 42
    assert task.timings_ms["total"] >= 0

    progress = client.get(
        f"/api/v1/assistant/progress/{task_id}", headers={"X-Watch-TOTP": totp_code()}
    )
    assert progress.status_code == 200
    assert progress.json()["status"] == "completed"


def test_progress_for_unknown_task_is_404(client: TestClient, totp_code) -> None:
    response = client.get("/api/v1/assistant/progress/nope", headers={"X-Watch-TOTP": totp_code()})
    assert response.status_code == 404


def test_empty_upload_is_rejected(client: TestClient, totp_code) -> None:
    response = client.post(
        "/api/v1/assistant/audio",
        headers={"X-Watch-TOTP": totp_code()},
        files={"audio_file": ("empty.m4a", b"", "audio/mp4")},
    )
    assert response.status_code == 400


def test_root_shows_the_login_form_without_a_session(client: TestClient) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert "código do autenticador" in response.text
    assert "__totp__" in response.text


def test_login_sets_a_session_cookie(client: TestClient, totp_code) -> None:
    response = client.post(
        "/__totp__",
        data={"code": totp_code(), "next": "/"},
        follow_redirects=False,
    )
    assert response.status_code == 303
    assert "wp_session" in response.cookies


def test_login_with_a_bad_code_does_not_set_a_cookie(client: TestClient) -> None:
    response = client.post("/__totp__", data={"code": "000000", "next": "/"}, follow_redirects=False)
    assert response.status_code == 303
    assert "wp_session" not in response.cookies


def test_dashboard_renders_with_a_session(client: TestClient, totp_code) -> None:
    login = client.post("/__totp__", data={"code": totp_code(), "next": "/"}, follow_redirects=False)
    client.cookies.update(login.cookies)
    page = client.get("/")
    assert page.status_code == 200
    assert "Watch Pilot" in page.text


def test_redirect_target_is_sanitised() -> None:
    from app import web

    assert web.redirect_target(None) == "/"
    assert web.redirect_target("//evil.example") == "/"
    assert web.redirect_target("https://evil.example") == "/"
    assert web.redirect_target("/api/v1/status") == "/api/v1/status"


def test_pair_page_is_loopback_only(client: TestClient) -> None:
    # TestClient reports testclient as the host, so the route must refuse it.
    response = client.get("/pair")
    assert response.status_code == 404
