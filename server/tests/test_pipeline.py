"""Unit tests for the transcription selection and the task pipeline."""

from __future__ import annotations

from pathlib import Path

import pytest

from app import llm, tasks, transcribe
from app.config import settings


@pytest.mark.asyncio
async def test_transcribe_falls_back_to_the_next_backend(monkeypatch, tmp_path) -> None:
    audio = tmp_path / "voice.m4a"
    audio.write_bytes(b"x")

    async def broken(path: Path, timeout: int):
        raise FileNotFoundError("wtx-transcribe not found")

    async def working(path: Path, timeout: int):
        return "olá mundo", "fake"

    monkeypatch.setitem(transcribe.BACKENDS, "wtx-transcribe", broken)
    monkeypatch.setitem(transcribe.BACKENDS, "fake", working)
    monkeypatch.setattr(settings, "transcribe_backends", ["wtx-transcribe", "fake"])

    result = await transcribe.transcribe(audio)
    assert result.ok
    assert result.text == "olá mundo"
    assert result.backend == "fake"
    assert result.attempts[0]["status"] == "unavailable"


@pytest.mark.asyncio
async def test_transcribe_reports_every_failed_backend(monkeypatch, tmp_path) -> None:
    audio = tmp_path / "voice.m4a"
    audio.write_bytes(b"x")

    async def broken(path: Path, timeout: int):
        raise RuntimeError("boom")

    monkeypatch.setitem(transcribe.BACKENDS, "wtx-transcribe", broken)
    monkeypatch.setattr(settings, "transcribe_backends", ["wtx-transcribe"])

    result = await transcribe.transcribe(audio)
    assert not result.ok
    assert result.backend == "none"
    assert result.attempts[0]["status"] == "unavailable"


@pytest.mark.asyncio
async def test_llm_without_a_key_fails_gracefully(monkeypatch) -> None:
    monkeypatch.setattr(settings, "openrouter_api_key", "")
    result = await llm.complete("diz olá")
    assert not result.ok
    assert "OPENROUTER_API_KEY" in result.error


@pytest.mark.asyncio
async def test_task_pipeline_marks_failure_when_transcription_is_empty(monkeypatch, tmp_path) -> None:
    audio = tmp_path / "voice.m4a"
    audio.write_bytes(b"x")
    task = tasks.create(audio, 1)

    async def silent(path: Path, timeout: int):
        raise RuntimeError("no assets")

    monkeypatch.setitem(transcribe.BACKENDS, "wtx-transcribe", silent)
    monkeypatch.setattr(settings, "transcribe_backends", ["wtx-transcribe"])

    await tasks.run(task)
    assert task.status == "failed"
    assert task.progress == 1.0
    assert "transcrever" in task.error


@pytest.mark.asyncio
async def test_task_pipeline_happy_path(monkeypatch, tmp_path) -> None:
    audio = tmp_path / "voice.m4a"
    audio.write_bytes(b"x")
    task = tasks.create(audio, 1)

    async def fake_transcribe(path: Path, timeout: int):
        return "que horas são", "fake"

    async def fake_complete(prompt: str) -> llm.LlmResult:
        assert prompt == "que horas são"
        return llm.LlmResult(text="São três da tarde.", model="m", elapsed_ms=5, reasoning_tokens=7)

    monkeypatch.setitem(transcribe.BACKENDS, "wtx-transcribe", fake_transcribe)
    monkeypatch.setattr(settings, "transcribe_backends", ["wtx-transcribe"])
    monkeypatch.setattr(llm, "complete", fake_complete)

    await tasks.run(task)
    assert task.status == "completed"
    assert task.transcript == "que horas são"
    assert task.ai_reply == "São três da tarde."
    assert task.reasoning_tokens == 7
    assert "total" in task.timings_ms
