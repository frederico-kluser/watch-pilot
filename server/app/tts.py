"""Speech synthesis for the assistant's answer — the reply travels as *fala*.

The pipeline ends with a spoken answer: the watch plays the audio and the T-800
jaw follows the real speech level.  Backends, tried in the order configured by
``settings.tts_backends``:

``openrouter``
    ElevenLabs voices through the OpenRouter audio API
    (``POST /api/v1/audio/speech`` → raw audio bytes).  This is the same account
    already used for the reasoning step, so no second credential is required.
``say``
    macOS ``say`` (offline fallback) rendered through ``ffmpeg`` when available.

A failed synthesis never fails the task: the text reply is still delivered and the
watch falls back to its synthetic speech cadence (``AvatarPose.speechLevel = -1``).
"""

from __future__ import annotations

import asyncio
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx

from .config import settings


@dataclass
class TtsResult:
    path: Path | None
    backend: str
    elapsed_ms: int
    bytes: int = 0
    error: str = ""
    attempts: list[dict[str, object]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.path is not None and self.path.exists() and self.bytes > 0


def _headers() -> dict[str, str]:
    return {
        "Authorization": f"Bearer {settings.openrouter_api_key}",
        "Content-Type": "application/json",
        "HTTP-Referer": settings.public_base_url,
        "X-OpenRouter-Title": "Watch Pilot",
    }


def _payload(text: str) -> dict[str, object]:
    return {
        "model": settings.tts_model,
        "input": text,
        "voice": settings.tts_voice,
        "response_format": "mp3",
    }


async def _run(cmd: list[str], timeout: int) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return 124, "", "timeout"
    return proc.returncode or 0, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def _ffmpeg() -> str | None:
    return shutil.which("ffmpeg")


def _finalise(source: Path, stem: Path) -> Path:
    """Normalise to 16 kHz mono AAC when ffmpeg exists (what the watch records)."""
    ffmpeg = _ffmpeg()
    if not ffmpeg:
        return source
    target = stem.with_suffix(".m4a")
    proc = subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-i", str(source), "-ac", "1", "-ar", "16000",
         "-c:a", "aac", "-b:a", "48k", str(target)],
        capture_output=True,
    )
    if proc.returncode != 0 or not target.exists() or target.stat().st_size == 0:
        return source
    source.unlink(missing_ok=True)
    return target


def _client(timeout: int) -> httpx.AsyncClient:
    """Build the HTTP client (a seam for tests to inject a MockTransport)."""
    return httpx.AsyncClient(http2=True, timeout=timeout)


async def _openrouter(stem: Path, text: str, timeout: int) -> tuple[Path, str, list[dict[str, object]]]:
    if not settings.openrouter_api_key:
        raise RuntimeError("missing OPENROUTER_API_KEY")
    attempts: list[dict[str, object]] = []
    url = f"{settings.openrouter_base_url}/audio/speech"
    async with _client(timeout) as client:
        for attempt in (1, 2):
            try:
                response = await client.post(url, headers=_headers(), json=_payload(text))
            except httpx.HTTPError as exc:
                attempts.append({"attempt": attempt, "status": "transport-error", "detail": repr(exc)[:200]})
                continue
            content_type = response.headers.get("content-type", "")
            if response.status_code == 200 and content_type.startswith("audio/"):
                raw = stem.with_suffix(".mp3")
                raw.write_bytes(response.content)
                attempts.append(
                    {
                        "attempt": attempt,
                        "status": 200,
                        "content_type": content_type,
                        "generation": response.headers.get("x-generation-id", ""),
                    }
                )
                return _finalise(raw, stem), "openrouter", attempts
            # A rejected payload comes back as JSON even with HTTP 200 — never store it.
            attempts.append(
                {
                    "attempt": attempt,
                    "status": response.status_code,
                    "detail": response.text[:200],
                }
            )
            if response.status_code not in {408, 429, 500, 502, 503, 504}:
                break
            await asyncio.sleep(1.0)
    raise RuntimeError(f"openrouter tts failed: {attempts[-1] if attempts else 'no response'}")


async def _say(stem: Path, text: str, timeout: int) -> tuple[Path, str, list[dict[str, object]]]:
    say = shutil.which("say")
    if not say:
        raise RuntimeError("say not installed")
    attempts: list[dict[str, object]] = []
    wav = stem.with_suffix(".aiff")
    cmd = [say, "-o", str(wav)]
    if settings.tts_say_voice:
        cmd += ["-v", settings.tts_say_voice]
    cmd.append(text)
    code, _, err = await _run(cmd, timeout)
    if code != 0 or not wav.exists():
        raise RuntimeError(f"say exit {code}: {err.strip()[:200]}")
    attempts.append({"attempt": 1, "status": code, "backend": "say"})
    return _finalise(wav, stem), "say", attempts


BACKENDS = {
    "openrouter": _openrouter,
    "say": _say,
}


async def synthesize(text: str, stem: Path) -> TtsResult:
    """Speak ``text`` into ``stem`` (+format suffix).  Never raises."""
    started = time.perf_counter()
    cleaned = " ".join(text.split())[: settings.tts_max_chars]
    if not cleaned:
        return TtsResult(path=None, backend="none", elapsed_ms=0, error="empty text")
    attempts: list[dict[str, object]] = []
    for name in settings.tts_backends:
        backend = BACKENDS.get(name)
        if backend is None:
            attempts.append({"backend": name, "status": "unknown-backend"})
            continue
        try:
            path, used, tried = await backend(stem, cleaned, settings.tts_timeout_seconds)
        except (RuntimeError, OSError) as exc:
            attempts.append({"backend": name, "status": "unavailable", "detail": str(exc)[:200]})
            continue
        attempts.extend(tried)
        size = path.stat().st_size if path.exists() else 0
        if size:
            return TtsResult(
                path=path,
                backend=used,
                elapsed_ms=int((time.perf_counter() - started) * 1000),
                bytes=size,
                attempts=attempts,
            )
        attempts.append({"backend": name, "status": "empty"})
    return TtsResult(
        path=None,
        backend="none",
        elapsed_ms=int((time.perf_counter() - started) * 1000),
        error="nenhum backend de TTS produziu áudio",
        attempts=attempts,
    )


def available_backends() -> list[dict[str, object]]:
    """Report which TTS backends can run right now (used by /api/v1/status)."""
    report: list[dict[str, object]] = []
    for name in settings.tts_backends:
        if name == "openrouter":
            report.append({"backend": name, "available": bool(settings.openrouter_api_key)})
        elif name == "say":
            report.append({"backend": name, "available": bool(shutil.which("say"))})
        else:
            report.append({"backend": name, "available": False})
    return report
