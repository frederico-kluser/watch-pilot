#!/usr/bin/env python3
"""wp — command line client for the Watch Pilot hub.

Commands
--------
``wp totp``                 print the current six-digit code
``wp pair``                 print the otpauth:// URI, secret and (best effort) a QR
``wp status``               hub configuration and backend health
``wp ask "texto"``          synthesise speech, upload it, poll and print the answer
``wp audio FILE.m4a``       upload an existing audio file
``wp notify "texto"``       send a notification through the hub
``wp inbox``                recent notifications
``wp tasks``                recent tasks
``wp demo``                 full end-to-end demo (ask + notify + verify)

The client authenticates every request with a fresh TOTP code in
``X-Watch-TOTP`` — the same contract the watchOS app honours.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("WATCHPILOT_CONFIG_DIR", Path.home() / ".config" / "watch-pilot"))
DEFAULT_BASE = os.environ.get("WATCHPILOT_URL", "http://127.0.0.1:8765")
USER_AGENT = "WatchPilot/0.1 (watchOS; Apple Watch SE) wp-cli"


# ---------------------------------------------------------------------------
# TOTP (RFC 6238 · SHA1 · 6 digits · 30 s) — mirrors server/app/security.py
# ---------------------------------------------------------------------------
def _secret() -> str:
    value = os.environ.get("WATCHPILOT_TOTP_SECRET", "").strip()
    if value:
        return value.replace(" ", "").upper()
    for candidate in (CONFIG_DIR / "totp.secret",):
        if candidate.exists():
            return candidate.read_text(encoding="utf-8").strip().upper()
    raise SystemExit("Erro: segredo TOTP não encontrado — Solução: arranca o hub uma vez ou define WATCHPILOT_TOTP_SECRET.")


def totp_code(at: float | None = None, *, digits: int = 6, period: int = 30) -> str:
    secret = _secret()
    cleaned = secret + "=" * ((8 - len(secret) % 8) % 8)
    key = base64.b32decode(cleaned, casefold=True)
    counter = int((at if at is not None else time.time()) // period)
    mac = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    binary = struct.unpack(">I", mac[offset : offset + 4])[0] & 0x7FFFFFFF
    return str(binary % (10**digits)).zfill(digits)


def _otpauth_uri(secret: str) -> str:
    from urllib.parse import quote

    return (
        f"otpauth://totp/{quote('Watch Pilot:minim1@kluser.me')}?secret={secret}"
        f"&issuer={quote('Watch Pilot')}&algorithm=SHA1&digits=6&period=30"
    )


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def request(method: str, path: str, *, base: str, body: bytes | None = None, headers: dict[str, str] | None = None) -> dict:
    url = base.rstrip("/") + path
    # Cloudflare's bot signature blocks Python-urllib; identify as the watch client.
    hdrs = {
        "X-Watch-TOTP": totp_code(),
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            raw = response.read()
            status = response.status
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"Erro: HTTP {exc.code} em {path} — Solução: {detail[:300]}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"Erro: hub inacessível em {base} — Solução: arranca scripts/run-hub.sh ({exc.reason})") from exc
    try:
        payload = json.loads(raw or b"{}")
    except json.JSONDecodeError:
        payload = {"raw": raw.decode("utf-8", "replace")}
    payload.setdefault("_status", status)
    return payload


def multipart(field: str, filename: str, content: bytes, content_type: str) -> tuple[bytes, str]:
    boundary = f"----wpb{ uuid.uuid4().hex }"
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    return head + content + tail, f"multipart/form-data; boundary={boundary}"


# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------
TTS_MODEL = "elevenlabs/eleven-v4-turbo"
TTS_VOICE = "george"
OPENROUTER_SPEECH_URL = "https://openrouter.ai/api/v1/audio/speech"


def _openrouter_key() -> str:
    """The OpenRouter key: environment first, then the local secrets file.

    The value is never printed — this helper is the only place that touches it.
    """
    value = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if value:
        return value
    secrets_file = Path.home() / ".secrets"
    if secrets_file.exists():
        for line in secrets_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("#") or "OPENROUTER_API_KEY=" not in line:
                continue
            raw = line.split("OPENROUTER_API_KEY=", 1)[1]
            return raw.split()[0].strip().strip('"').strip("'")
    raise SystemExit(
        "Erro: OPENROUTER_API_KEY não encontrada — Solução: exporta a variável ou define "
        "OPENROUTER_API_KEY=… em ~/.secrets."
    )


def _to_watch_format(source: Path, out: Path) -> Path:
    """16 kHz mono AAC in an .m4a container — exactly what VoiceRecorder writes."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("Erro: ffmpeg em falta — Solução: instala ffmpeg (brew install ffmpeg).")
    subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-i", str(source), "-ac", "1", "-ar", "16000",
         "-c:a", "aac", "-b:a", "48k", str(out)],
        check=True,
        capture_output=True,
    )
    source.unlink(missing_ok=True)
    return out


def synthesise_openrouter(text: str, out: Path, *, model: str = TTS_MODEL, voice: str = TTS_VOICE) -> Path:
    """Emulate the watch microphone with speech generated via OpenRouter (ElevenLabs).

    The bytes come back as mp3 and are re-encoded to the exact format the watch
    records, so the hub transcribes the same kind of file it would get from the wrist.
    """
    body = json.dumps(
        {"model": model, "input": text, "voice": voice, "response_format": "mp3"}
    ).encode()
    request = urllib.request.Request(
        OPENROUTER_SPEECH_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {_openrouter_key()}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            payload = response.read()
            content_type = response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"Erro: TTS do OpenRouter devolveu HTTP {exc.code} — Solução: {detail[:300]}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"Erro: OpenRouter inacessível — Solução: verifica a rede ({exc.reason}).") from exc
    if not content_type.startswith("audio/") or not payload:
        raise SystemExit(
            f"Erro: TTS devolveu '{content_type or 'corpo vazio'}' em vez de áudio — "
            f"Solução: {payload[:200]!r}"
        )
    mp3 = out.with_suffix(".mp3")
    mp3.write_bytes(payload)
    return _to_watch_format(mp3, out)


def synthesise_say(text: str, out: Path) -> Path:
    """Local fallback: macOS ``say`` rendered into the same watch format."""
    say = shutil.which("say")
    if not say:
        raise SystemExit("Erro: say em falta — Solução: usa --voice-src openrouter.")
    wav = out.with_suffix(".aiff")
    # Prefer the European Portuguese voice so the transcriber sees the same accent
    # the user speaks; fall back to Brazilian and then to the system default.
    voice = next((v for v in ("Joana", "Luciana", "Fernanda") if _has_voice(v)), None)
    cmd = [say, "-o", str(wav)]
    if voice:
        cmd += ["-v", voice]
    cmd.append(text)
    subprocess.run(cmd, check=True, capture_output=True)
    return _to_watch_format(wav, out)


def synthesise(text: str, out: Path, source: str = "openrouter") -> Path:
    """Create a watch-like voice memo: 16 kHz mono AAC in an .m4a container."""
    if source == "say":
        return synthesise_say(text, out)
    return synthesise_openrouter(text, out)


_VOICES: set[str] | None = None


def _voices() -> set[str]:
    """Names of the voices actually installed (``say -v '?'``)."""
    global _VOICES
    if _VOICES is None:
        say = shutil.which("say")
        _VOICES = set()
        if say:
            proc = subprocess.run([say, "-v", "?"], capture_output=True, text=True)
            for line in proc.stdout.splitlines():
                parts = line.split()
                if parts:
                    _VOICES.add(parts[0])
    return _VOICES


def _has_voice(name: str) -> bool:
    return name in _voices()


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_totp(args: argparse.Namespace) -> int:
    remaining = 30 - int(time.time()) % 30
    print(f"{totp_code()}  (válido {remaining}s)")
    return 0


def cmd_pair(args: argparse.Namespace) -> int:
    secret = _secret()
    uri = _otpauth_uri(secret)
    print(f"segredo : {secret}")
    print(f"uri     : {uri}")
    qrencode = shutil.which("qrencode")
    if qrencode:
        subprocess.run([qrencode, "-t", "ANSIUTF8", "-m", "1", uri])
    else:
        print("(instala qrencode para ver o QR: brew install qrencode)")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    print(json.dumps(request("GET", "/api/v1/status", base=args.base), indent=2, ensure_ascii=False))
    return 0


def _poll(base: str, task_id: str, *, interval: float = 1.0, timeout: float = 240) -> dict:
    deadline = time.time() + timeout
    last_progress = -1.0
    while time.time() < deadline:
        task = request("GET", f"/api/v1/assistant/progress/{task_id}", base=base)
        progress = float(task.get("progress") or 0)
        if progress != last_progress:
            print(f"  {int(progress * 100):>3}% · {task.get('step_description')}", flush=True)
            last_progress = progress
        if task.get("status") in {"completed", "failed"}:
            return task
        time.sleep(interval)
    raise SystemExit("Erro: tempo esgotado à espera da tarefa — Solução: vê os logs do hub.")


def _upload(base: str, path: Path) -> dict:
    body, content_type = multipart("audio_file", path.name, path.read_bytes(), "audio/mp4")
    return request(
        "POST",
        "/api/v1/assistant/audio",
        base=base,
        body=body,
        headers={"Content-Type": content_type},
    )


def cmd_audio(args: argparse.Namespace) -> int:
    path = Path(args.file).expanduser()
    if not path.exists():
        raise SystemExit(f"Erro: {path} não existe — Solução: indica um .m4a válido.")
    print(f"→ upload {path.name} ({path.stat().st_size} bytes)")
    task = _upload(args.base, path)
    task_id = task["task_id"]
    print(f"→ tarefa {task_id}")
    final = _poll(args.base, task_id)
    _print_result(final)
    return 0 if final.get("status") == "completed" else 1


def _fetch_reply_audio(base: str, task_id: str, out: Path) -> tuple[Path, str]:
    """Download the answer as *fala* from the hub (TOTP-protected route)."""
    url = base.rstrip("/") + f"/api/v1/assistant/reply/{task_id}"
    request_http = urllib.request.Request(
        url,
        method="GET",
        headers={"X-Watch-TOTP": totp_code(), "Accept": "audio/*", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request_http, timeout=120) as response:
            payload = response.read()
            content_type = response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"Erro: fala da resposta indisponível (HTTP {exc.code}) — Solução: {exc.read()[:200]!r}") from exc
    if not payload:
        raise SystemExit("Erro: a fala da resposta veio vazia — Solução: vê os logs do hub.")
    out.write_bytes(payload)
    return out, content_type


def cmd_ask(args: argparse.Namespace) -> int:
    source = getattr(args, "voice_src", "openrouter")
    with tempfile.TemporaryDirectory() as tmp:
        audio = Path(tmp) / "voice_cmd.m4a"
        synthesise(args.text, audio, source=source)
        size = audio.stat().st_size
        if args.keep:
            kept = Path(args.keep).expanduser()
            shutil.copyfile(audio, kept)
            print(f"→ áudio guardado em {kept}")
        print(f"→ microfone emulado com voz {source} ({size} bytes, 16 kHz mono AAC)")
        task = _upload(args.base, audio)
        task_id = task["task_id"]
        print(f"→ tarefa {task_id}")
        final = _poll(args.base, task_id)
        if final.get("status") == "completed" and final.get("reply_audio_url"):
            reply_out = Path(getattr(args, "reply_out", "") or (Path(tmp) / f"reply-{task_id}.m4a")).expanduser()
            path, content_type = _fetch_reply_audio(args.base, task_id, reply_out)
            final["_reply_audio"] = {"path": str(path), "bytes": path.stat().st_size, "content_type": content_type}
            if getattr(args, "play", False):
                afplay = shutil.which("afplay")
                if afplay:
                    print("→ a tocar a fala da resposta…")
                    subprocess.run([afplay, str(path)], check=False)
    _print_result(final)
    return 0 if final.get("status") == "completed" else 1


def _print_result(task: dict) -> None:
    print("\n" + "─" * 66)
    print(f"transcrição : {task.get('transcript') or '(vazia)'}")
    print(f"resposta    : {task.get('ai_reply') or '(vazia)'}")
    speech = task.get("_reply_audio") or {}
    if speech:
        print(f"fala        : {speech['bytes']} bytes · {speech['content_type']} · {speech['path']}")
    elif task.get("reply_audio_url"):
        print(f"fala        : {task.get('reply_audio_bytes')} bytes · {task.get('tts_backend')}")
    else:
        print("fala        : (sem TTS — o relógio usa a cadência sintética)")
    timings = task.get("timings_ms") or {}
    print(
        "tempos      : "
        + " · ".join(f"{k}={v}ms" for k, v in timings.items())
        + f"  stt={task.get('backend')} model={task.get('model')}"
    )
    if task.get("reasoning_tokens"):
        print(f"pensamento  : {task['reasoning_tokens']} tokens · ${float(task.get('cost_usd') or 0):.6f}")
    if task.get("error"):
        print(f"erro        : {task['error']}")
    print("─" * 66)


def cmd_notify(args: argparse.Namespace) -> int:
    body = json.dumps({"title": args.title, "body": args.text}).encode()
    result = request("POST", "/api/v1/notify", base=args.base, body=body, headers={"Content-Type": "application/json"})
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


def cmd_inbox(args: argparse.Namespace) -> int:
    print(json.dumps(request("GET", "/api/v1/inbox", base=args.base), indent=2, ensure_ascii=False))
    return 0


def cmd_tasks(args: argparse.Namespace) -> int:
    print(json.dumps(request("GET", "/api/v1/tasks", base=args.base), indent=2, ensure_ascii=False))
    return 0


def _normalise(text: str) -> str:
    stripped = "".join(c for c in unicodedata.normalize("NFD", text.lower()) if unicodedata.category(c) != "Mn")
    return " ".join("".join(c if c.isalnum() or c == " " else " " for c in stripped).split())


def _audio_duration(path: Path) -> float:
    """Seconds of audio in the file, via afinfo (0 when it cannot be read)."""
    afinfo = shutil.which("afinfo")
    if not afinfo:
        return 0.0
    proc = subprocess.run([afinfo, str(path)], capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        if "estimated duration" in line:
            try:
                return float(line.split()[-2])
            except (ValueError, IndexError):
                return 0.0
    return 0.0


def cmd_e2e(args: argparse.Namespace) -> int:
    """Validar o pipeline inteiro: microfone emulado → transcrição → fala → notificações."""
    results: list[tuple[str, bool, str]] = []

    def check(name: str, ok: bool, detail: str = "") -> bool:
        results.append((name, ok, detail))
        print(f"  [{'OK' if ok else 'FALHOU'}] {name}" + (f" — {detail}" if detail else ""))
        return ok

    print("\n══ E2E Watch Pilot ══════════════════════════════════════════")

    print("1/6 · hub e autenticação TOTP")
    health = request("GET", "/__health", base=args.base)
    check("hub vivo em /__health", health.get("status") == "ok", str(health))
    status_payload = request("GET", "/api/v1/status", base=args.base)
    check("TOTP aceite em /api/v1/status", bool(status_payload.get("model")), f"modelo {status_payload.get('model')}")
    stt = ", ".join(f"{b['backend']}={'sim' if b['available'] else 'não'}" for b in status_payload.get("transcribe", []))
    tts_backends = ", ".join(f"{b['backend']}={'sim' if b['available'] else 'não'}" for b in status_payload.get("tts", []))
    check("backends de transcrição disponíveis", any(b["available"] for b in status_payload.get("transcribe", [])), stt)
    check("backends de fala (TTS) disponíveis", any(b["available"] for b in status_payload.get("tts", [])), tts_backends)

    print("2/6 · microfone emulado com áudio gerado via OpenRouter")
    expected = args.text
    with tempfile.TemporaryDirectory() as tmp:
        mic_audio = Path(tmp) / "voice_cmd.m4a"
        synthesise(expected, mic_audio, source="openrouter")
        size = mic_audio.stat().st_size
        duration = _audio_duration(mic_audio)
        check("áudio do microfone gerado", size > 1000, f"{size} bytes · {duration:.2f}s · 16 kHz mono AAC")

        print("3/6 · endpoint que MANDA informação (POST /api/v1/assistant/audio)")
        task = _upload(args.base, mic_audio)
        task_id = task.get("task_id")
        check("upload aceite com task_id", bool(task_id), f"tarefa {task_id}")

        print("4/6 · endpoint que BUSCA informação (GET /api/v1/assistant/progress/{id})")
        final = _poll(args.base, task_id)
        transcript = final.get("transcript") or ""
        reply = final.get("ai_reply") or ""
        check("tarefa concluída", final.get("status") == "completed", final.get("step_description", ""))
        check("transcrição não vazia", bool(transcript.strip()), transcript[:90])
        wanted, got = set(_normalise(expected).split()), set(_normalise(transcript).split())
        overlap = len(wanted & got) / max(1, len(wanted))
        check("transcrição corresponde ao comando falado", overlap >= 0.5, f"sobreposição de palavras {overlap:.0%}")
        check("resposta do modelo não vazia", bool(reply.strip()), reply[:90])
        timings = final.get("timings_ms") or {}
        print(f"      tempos: {timings} · stt={final.get('backend')} · tts={final.get('tts_backend')}")

        print("5/6 · a resposta como FALA (GET /api/v1/assistant/reply/{id})")
        reply_url = final.get("reply_audio_url") or ""
        check("tarefa expõe reply_audio_url", bool(reply_url), reply_url or "(vazio)")
        if reply_url:
            reply_path = Path(tmp) / f"reply-{task_id}.m4a"
            path, content_type = _fetch_reply_audio(args.base, task_id, reply_path)
            speech_bytes = path.stat().st_size
            speech_duration = _audio_duration(path)
            check("fala descarregada como áudio", speech_bytes > 1000 and content_type.startswith("audio/"),
                  f"{speech_bytes} bytes · {speech_duration:.2f}s · {content_type}")
            if args.play:
                afplay = shutil.which("afplay")
                if afplay:
                    print("      a tocar a fala da resposta…")
                    subprocess.run([afplay, str(path)], check=False)

    print("6/6 · endpoint de NOTIFICAÇÕES no computador (POST /api/v1/notify + GET /api/v1/inbox)")
    marker = f"e2e-{uuid.uuid4().hex[:8]}"
    record = request(
        "POST",
        "/api/v1/notify",
        base=args.base,
        body=json.dumps({"title": "Watch Pilot E2E", "body": f"notificação {marker}", "progress": 1.0}).encode(),
        headers={"Content-Type": "application/json"},
    )
    check("notificação registada", record.get("body", "").endswith(marker), f"id {record.get('id', '')[:8]}")
    inbox = request("GET", "/api/v1/inbox", base=args.base)
    items = inbox.get("items") or []
    check("notificação visível no inbox", any(item.get("id") == record.get("id") for item in items),
          f"{len(items)} itens no inbox")

    failed = [name for name, ok, _ in results if not ok]
    print("════════════════════════════════════════════════════════════")
    if failed:
        print(f"RESULTADO: {len(results) - len(failed)}/{len(results)} verificações · FALHOU: {', '.join(failed)}")
        return 1
    print(f"RESULTADO: {len(results)}/{len(results)} verificações — pipeline de voz validado ponta-a-ponta")
    return 0


def cmd_demo(args: argparse.Namespace) -> int:
    print("1/4 · saúde do hub")
    health = request("GET", "/__health", base=args.base)
    print("   ", health.get("status"))
    print("2/4 · autenticação TOTP no /api/v1/status")
    status_payload = request("GET", "/api/v1/status", base=args.base)
    print("    modelo:", status_payload.get("model"), "· reasoning", status_payload.get("reasoning_effort"))
    print("3/4 · comando de voz completo")
    code = cmd_ask(
        argparse.Namespace(
            text="Olá Watch Pilot. Diz-me em duas frases o que consegues fazer por mim a partir do Mac Mini.",
            base=args.base,
            keep="",
        )
    )
    print("4/4 · endpoint de notificação")
    cmd_notify(argparse.Namespace(text="Demo concluída do lado do relógio.", title="Watch Pilot", base=args.base))
    return code


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="wp", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default=DEFAULT_BASE, help=f"hub base URL (default {DEFAULT_BASE})")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("totp", help="show the current TOTP code").set_defaults(func=cmd_totp)
    sub.add_parser("pair", help="show the otpauth URI and QR").set_defaults(func=cmd_pair)
    sub.add_parser("status", help="hub status").set_defaults(func=cmd_status)
    sub.add_parser("inbox", help="recent notifications").set_defaults(func=cmd_inbox)
    sub.add_parser("tasks", help="recent tasks").set_defaults(func=cmd_tasks)
    sub.add_parser("demo", help="end-to-end demo").set_defaults(func=cmd_demo)

    ask = sub.add_parser("ask", help="synthesise speech and send it")
    ask.add_argument("text")
    ask.add_argument("--keep", default="", help="copy the generated audio here")
    ask.add_argument("--voice-src", default="openrouter", choices=["openrouter", "say"],
                     help="where the emulated microphone audio comes from (default: openrouter)")
    ask.add_argument("--reply-out", default="", help="save the answer speech here")
    ask.add_argument("--play", action="store_true", help="play the answer speech on this machine")
    ask.set_defaults(func=cmd_ask)

    e2e = sub.add_parser("e2e", help="validate the whole voice pipeline and both endpoints")
    e2e.add_argument("--text", default="Watch Pilot, cria um lembrete para amanhã às nove da manhã.")
    e2e.add_argument("--play", action="store_true", help="play the answer speech on this machine")
    e2e.set_defaults(func=cmd_e2e)

    audio = sub.add_parser("audio", help="send an audio file")
    audio.add_argument("file")
    audio.set_defaults(func=cmd_audio)

    notify_cmd = sub.add_parser("notify", help="send a notification")
    notify_parser = notify_cmd.add_argument("text")
    notify_cmd.add_argument("--title", default="Watch Pilot")
    notify_cmd.set_defaults(func=cmd_notify)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
