"""Speech-to-text backends that run entirely on the Mac mini.

The Apple Watch cannot use ``SpeechAnalyzer`` (the framework is not exposed on
watchOS) and ``SFSpeechRecognizer`` caps out at one minute of audio, so the audio
file travels to the Mac mini and is transcribed there.

Backends, tried in the order configured by ``settings.transcribe_backends``:

``wtx-transcribe``
    Our own Swift binary (``apps/mac-tools``) driving Apple's on-device
    ``SpeechAnalyzer``/``SpeechTranscriber`` stack.  No network, no length limit.
``yap``
    Third-party Homebrew CLI that wraps the same framework.
``shortcut``
    ``shortcuts run TranscreverAudio -i <file>`` — the Apple Shortcuts bridge.
``mock``
    Explicit offline stub, only when ``allow_mock_transcription`` is enabled.  It is
    what keeps the demo working on a machine without the speech assets installed.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path

from .config import settings

BIN_DIR = Path(__file__).resolve().parent.parent / "bin"


@dataclass
class Transcript:
    text: str
    backend: str
    elapsed_ms: int
    attempts: list[dict[str, str]] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.text.strip())


def _resolve_binary(name: str) -> str | None:
    """Prefer the project-local binary, then $PATH."""
    local = BIN_DIR / name
    if local.exists() and os.access(local, os.X_OK):
        return str(local)
    return shutil.which(name)


async def _run(cmd: list[str], timeout: int, stdin: str | None = None) -> tuple[int, str, str]:
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdin=asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        out, err = await asyncio.wait_for(
            proc.communicate(stdin.encode() if stdin else None), timeout=timeout
        )
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return 124, "", "timeout"
    return proc.returncode or 0, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


async def _wtx_transcribe(path: Path, timeout: int) -> tuple[str, str]:
    binary = _resolve_binary("wtx-transcribe")
    if not binary:
        raise FileNotFoundError("wtx-transcribe not found")
    cmd = [binary, "--input", str(path), "--format", "txt"]
    if settings.transcribe_locale:
        cmd += ["--locale", settings.transcribe_locale]
    code, out, err = await _run(cmd, timeout)
    if code != 0:
        raise RuntimeError(f"wtx-transcribe exit {code}: {err.strip()[:300]}")
    return out.strip(), "wtx-transcribe"


async def _yap(path: Path, timeout: int) -> tuple[str, str]:
    binary = shutil.which("yap")
    if not binary:
        raise FileNotFoundError("yap not installed")
    code, out, err = await _run([binary, str(path), "--format", "txt"], timeout)
    if code != 0:
        raise RuntimeError(f"yap exit {code}: {err.strip()[:300]}")
    return out.strip(), "yap"


async def _shortcut(path: Path, timeout: int) -> tuple[str, str]:
    binary = shutil.which("shortcuts")
    if not binary:
        raise FileNotFoundError("shortcuts CLI not found")
    code, out, err = await _run([binary, "run", "TranscreverAudio", "-i", str(path)], timeout)
    if code != 0:
        raise RuntimeError(f"shortcut exit {code}: {err.strip()[:300]}")
    return out.strip(), "shortcut"


async def _mock(path: Path, timeout: int) -> tuple[str, str]:
    if not settings.allow_mock_transcription:
        raise RuntimeError("mock transcription disabled (set WATCHPILOT_ALLOW_MOCK_TRANSCRIPTION=true to enable)")
    size_kb = path.stat().st_size / 1024 if path.exists() else 0
    return (
        f"[demonstração offline] Comando de voz recebido com {size_kb:.0f} KB de áudio. "
        "Resume as tarefas pendentes do Mac Mini.",
        "mock",
    )


BACKENDS = {
    "wtx-transcribe": _wtx_transcribe,
    "yap": _yap,
    "shortcut": _shortcut,
    "mock": _mock,
}


async def transcribe(path: Path) -> Transcript:
    """Try each configured backend in order and return the first non-empty transcript."""
    started = time.perf_counter()
    attempts: list[dict[str, str]] = []
    for name in settings.transcribe_backends:
        backend = BACKENDS.get(name)
        if backend is None:
            attempts.append({"backend": name, "status": "unknown-backend"})
            continue
        try:
            text, used = await backend(path, settings.transcribe_timeout_seconds)
        except (FileNotFoundError, RuntimeError) as exc:
            attempts.append({"backend": name, "status": "unavailable", "detail": str(exc)[:200]})
            continue
        except Exception as exc:  # pragma: no cover - defensive
            attempts.append({"backend": name, "status": "error", "detail": repr(exc)[:200]})
            continue
        if text:
            attempts.append({"backend": name, "status": "ok"})
            return Transcript(
                text=text,
                backend=used,
                elapsed_ms=int((time.perf_counter() - started) * 1000),
                attempts=attempts,
            )
        attempts.append({"backend": name, "status": "empty"})
    return Transcript(
        text="",
        backend="none",
        elapsed_ms=int((time.perf_counter() - started) * 1000),
        attempts=attempts,
    )


def available_backends() -> list[dict[str, object]]:
    """Report which backends can run right now (used by /api/v1/health)."""
    report: list[dict[str, object]] = []
    for name in settings.transcribe_backends:
        if name == "wtx-transcribe":
            report.append({"backend": name, "available": bool(_resolve_binary(name))})
        elif name == "yap":
            report.append({"backend": name, "available": bool(shutil.which("yap"))})
        elif name == "shortcut":
            report.append({"backend": name, "available": bool(shutil.which("shortcuts"))})
        elif name == "mock":
            report.append({"backend": name, "available": settings.allow_mock_transcription})
        else:
            report.append({"backend": name, "available": False})
    return report
