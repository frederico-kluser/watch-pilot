"""Task lifecycle: transcribe → reason → report, with live progress.

Each voice command becomes a task with a stable ``task_id`` that the watch polls at
``GET /api/v1/assistant/progress/{task_id}``.  Progress is coarse but honest: it
only advances when a real stage completes.
"""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from . import llm, notify, transcribe
from .config import settings

STARTED_AT = time.time()


@dataclass
class Task:
    task_id: str
    status: str = "queued"
    progress: float = 0.0
    step_description: str = "Comando recebido."
    transcript: str = ""
    ai_reply: str = ""
    reasoning_tokens: int = 0
    reasoning_excerpt: str = ""
    model: str = ""
    cost_usd: float = 0.0
    backend: str = ""
    audio_path: str = ""
    audio_bytes: int = 0
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    timings_ms: dict[str, int] = field(default_factory=dict)
    attempts: list[dict[str, Any]] = field(default_factory=list)
    error: str = ""

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


TASKS: dict[str, Task] = {}
_ORDER: list[str] = []
_LOCK = asyncio.Lock()


def _persist(task: Task) -> None:
    try:
        path = Path(settings.data_dir) / "tasks.jsonl"
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(task.to_json(), ensure_ascii=False) + "\n")
    except OSError:
        pass


def recent(limit: int = 20) -> list[dict[str, Any]]:
    return [TASKS[tid].to_json() for tid in reversed(_ORDER[-limit:])]


def get(task_id: str) -> Task | None:
    return TASKS.get(task_id)


def create(audio_path: Path, audio_bytes: int) -> Task:
    task = Task(task_id=str(uuid.uuid4()), audio_path=str(audio_path), audio_bytes=audio_bytes)
    TASKS[task.task_id] = task
    _ORDER.append(task.task_id)
    return task


def _advance(task: Task, progress: float, step: str, status: str = "running") -> None:
    task.progress = progress
    task.step_description = step
    task.status = status
    task.updated_at = time.time()


async def run(task: Task) -> None:
    """Execute the full pipeline for ``task`` in the background."""
    async with _LOCK:
        started = time.perf_counter()
        _advance(task, 0.10, "A transcrever o áudio no Mac Mini…")
        transcript = await transcribe.transcribe(Path(task.audio_path))
        task.backend = transcript.backend
        task.attempts = transcript.attempts
        task.timings_ms["transcribe"] = transcript.elapsed_ms
        if not transcript.ok:
            task.status = "failed"
            task.progress = 1.0
            task.error = "Não consegui transcrever o áudio."
            task.step_description = task.error
            task.updated_at = time.time()
            _persist(task)
            await notify.notify("Watch Pilot", task.error, task_id=task.task_id, progress=1.0)
            return

        task.transcript = transcript.text
        _advance(task, 0.45, "A pensar com o MiMo 2.6 Pro…")

        result = await llm.complete(transcript.text)
        task.timings_ms["llm"] = result.elapsed_ms
        task.reasoning_tokens = result.reasoning_tokens
        task.reasoning_excerpt = result.reasoning_excerpt
        task.model = result.model
        task.cost_usd = result.cost_usd
        if result.ok:
            task.ai_reply = result.text
        else:
            task.ai_reply = (
                "Transcrevi o teu comando, mas não consegui falar com o modelo agora: "
                f"{result.error or 'erro desconhecido'}."
            )
            task.error = result.error

        _advance(task, 0.85, "A guardar o resultado…")
        await notify.notify(
            "Watch Pilot",
            task.ai_reply[:180],
            task_id=task.task_id,
            progress=1.0,
        )

        task.status = "completed"
        task.progress = 1.0
        task.step_description = "Concluído no Mac Mini."
        task.timings_ms["total"] = int((time.perf_counter() - started) * 1000)
        task.updated_at = time.time()
        _persist(task)
