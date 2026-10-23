"""The speech leg of the pipeline: TTS synthesis, the reply-audio route and the
notification endpoint — everything the watch needs to *hear* the answer."""

from __future__ import annotations

import asyncio

import httpx
import pytest
from fastapi.testclient import TestClient

from app import llm, main, notify, tasks, tts
from app.config import settings


@pytest.fixture()
def client(fresh_guard) -> TestClient:
    return TestClient(main.app)


@pytest.fixture()
def stub_llm(monkeypatch):
    async def fake_complete(prompt: str) -> llm.LlmResult:
        return llm.LlmResult(
            text=f"resposta falada para: {prompt}",
            model="xiaomi/mimo-v2.6-pro",
            elapsed_ms=7,
            reasoning_tokens=5,
        )

    monkeypatch.setattr(llm, "complete", fake_complete)
    return fake_complete


async def _run_pipeline(client: TestClient, totp_code) -> str:
    response = client.post(
        "/api/v1/assistant/audio",
        headers={"X-Watch-TOTP": totp_code()},
        files={"audio_file": ("voice_cmd.m4a", b"not-really-audio", "audio/mp4")},
    )
    assert response.status_code == 202
    task_id = response.json()["task_id"]

    task = None
    for _ in range(200):
        await asyncio.sleep(0.02)
        task = tasks.get(task_id)
        if task and task.status in {"completed", "failed"}:
            break
    assert task is not None
    assert task.status == "completed", task.error
    return task_id


# ---------------------------------------------------------------------------
# TTS module
# ---------------------------------------------------------------------------
def test_tts_payload_declares_voice_and_format() -> None:
    payload = tts._payload("olá")
    assert payload["input"] == "olá"
    assert payload["voice"] == settings.tts_voice
    assert payload["response_format"] == "mp3"


async def test_synthesize_falls_back_to_the_next_backend(monkeypatch, tmp_path) -> None:
    async def broken(stem, text, timeout):
        raise RuntimeError("sem chave")

    async def working(stem, text, timeout):
        path = stem.with_suffix(".mp3")
        path.write_bytes(b"ID3-audio")
        return path, "fake-voice", [{"backend": "fake-voice", "status": 200}]

    monkeypatch.setattr(tts, "BACKENDS", {"broken": broken, "fake-voice": working})
    monkeypatch.setattr(settings, "tts_backends", ["broken", "fake-voice"])

    result = await tts.synthesize("olá mundo", tmp_path / "out")
    assert result.ok
    assert result.backend == "fake-voice"
    assert result.bytes == len(b"ID3-audio")
    assert any(a.get("status") == "unavailable" for a in result.attempts)


async def test_synthesize_reports_failure_without_raising(monkeypatch, tmp_path) -> None:
    async def broken(stem, text, timeout):
        raise RuntimeError("down")

    monkeypatch.setattr(tts, "BACKENDS", {"broken": broken})
    monkeypatch.setattr(settings, "tts_backends", ["broken"])

    result = await tts.synthesize("olá", tmp_path / "out")
    assert not result.ok
    assert result.path is None
    assert result.error


async def test_openrouter_stores_only_real_audio(monkeypatch, tmp_path) -> None:
    """A 200 with a JSON body is a rejected payload, never a corrupt 'mp3'."""
    monkeypatch.setattr(tts, "_ffmpeg", lambda: None)
    monkeypatch.setattr(settings, "tts_backends", ["openrouter"])
    monkeypatch.setattr(settings, "openrouter_api_key", "sk-or-v1-test")

    def json_error(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"error": {"message": "ZodError"}})

    monkeypatch.setattr(
        tts, "_client", lambda timeout: httpx.AsyncClient(transport=httpx.MockTransport(json_error))
    )
    result = await tts.synthesize("olá", tmp_path / "out")
    assert not result.ok
    assert not list(tmp_path.glob("*.mp3"))


async def test_openrouter_writes_the_audio_bytes(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(tts, "_ffmpeg", lambda: None)
    monkeypatch.setattr(settings, "tts_backends", ["openrouter"])
    monkeypatch.setattr(settings, "openrouter_api_key", "sk-or-v1-test")

    body = b"ID3-real-mp3-bytes"

    def audio(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/audio/speech")
        return httpx.Response(
            200, content=body, headers={"content-type": "audio/mpeg", "x-generation-id": "gen-tts-1"}
        )

    monkeypatch.setattr(
        tts, "_client", lambda timeout: httpx.AsyncClient(transport=httpx.MockTransport(audio))
    )
    result = await tts.synthesize("olá", tmp_path / "out")
    assert result.ok
    assert result.backend == "openrouter"
    assert result.path.read_bytes() == body
    assert result.attempts[-1]["generation"] == "gen-tts-1"


# ---------------------------------------------------------------------------
# Reply-audio route + notifications
# ---------------------------------------------------------------------------
async def test_pipeline_exposes_the_answer_as_speech(
    client: TestClient, totp_code, stub_llm, stub_tts
) -> None:
    task_id = await _run_pipeline(client, totp_code)

    progress = client.get(
        f"/api/v1/assistant/progress/{task_id}", headers={"X-Watch-TOTP": totp_code()}
    )
    payload = progress.json()
    assert payload["status"] == "completed"
    assert payload["reply_audio_url"] == f"/api/v1/assistant/reply/{task_id}"
    assert payload["reply_audio_bytes"] > 0
    assert payload["tts_backend"] == "stub"
    assert payload["timings_ms"]["tts"] >= 0
    assert stub_tts == [payload["ai_reply"]]

    speech = client.get(payload["reply_audio_url"], headers={"X-Watch-TOTP": totp_code()})
    assert speech.status_code == 200
    assert speech.headers["content-type"].startswith("audio/")
    assert speech.content.startswith(b"\x00\x00\x00\x18ftyp")


async def test_reply_audio_requires_a_totp_code(client: TestClient, totp_code, stub_llm, stub_tts) -> None:
    task_id = await _run_pipeline(client, totp_code)
    response = client.get(f"/api/v1/assistant/reply/{task_id}")
    assert response.status_code == 401


def test_reply_audio_unknown_task_is_404(client: TestClient, totp_code) -> None:
    response = client.get("/api/v1/assistant/reply/nope", headers={"X-Watch-TOTP": totp_code()})
    assert response.status_code == 404


async def test_task_without_speech_reports_an_empty_url(
    client: TestClient, totp_code, stub_llm, monkeypatch
) -> None:
    async def no_speech(text: str, stem) -> tts.TtsResult:
        return tts.TtsResult(path=None, backend="none", elapsed_ms=1, error="sem TTS")

    monkeypatch.setattr(tts, "synthesize", no_speech)
    task_id = await _run_pipeline(client, totp_code)

    payload = client.get(
        f"/api/v1/assistant/progress/{task_id}", headers={"X-Watch-TOTP": totp_code()}
    ).json()
    assert payload["status"] == "completed"
    assert payload["ai_reply"]
    assert payload["reply_audio_url"] == ""

    speech = client.get(f"/api/v1/assistant/reply/{task_id}", headers={"X-Watch-TOTP": totp_code()})
    assert speech.status_code == 404


def test_notify_endpoint_feeds_the_inbox(client: TestClient, totp_code) -> None:
    """The second endpoint of the hub: notifications in, notifications out."""
    notify.INBOX.clear()
    posted = client.post(
        "/api/v1/notify",
        headers={"X-Watch-TOTP": totp_code()},
        json={"title": "Watch Pilot", "body": "A fala está pronta.", "progress": 1.0},
    )
    assert posted.status_code == 200
    record = posted.json()
    assert record["body"] == "A fala está pronta."
    assert record["id"]

    inbox = client.get("/api/v1/inbox", headers={"X-Watch-TOTP": totp_code()})
    assert inbox.status_code == 200
    items = inbox.json()["items"]
    assert items[0]["id"] == record["id"]
    assert items[0]["title"] == "Watch Pilot"
