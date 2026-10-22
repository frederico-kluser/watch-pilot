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
def synthesise(text: str, out: Path) -> Path:
    """Create a watch-like voice memo: 16 kHz mono AAC in an .m4a container."""
    say = shutil.which("say")
    ffmpeg = shutil.which("ffmpeg")
    if not say or not ffmpeg:
        raise SystemExit("Erro: say/ffmpeg em falta — Solução: instala ffmpeg (brew install ffmpeg).")
    wav = out.with_suffix(".aiff")
    # Prefer the European Portuguese voice so the transcriber sees the same accent
    # the user speaks; fall back to Brazilian and then to the system default.
    voice = next((v for v in ("Joana", "Luciana", "Fernanda") if _has_voice(v)), None)
    cmd = [say, "-o", str(wav)]
    if voice:
        cmd += ["-v", voice]
    cmd.append(text)
    subprocess.run(cmd, check=True, capture_output=True)
    subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-i", str(wav), "-ac", "1", "-ar", "16000",
         "-c:a", "aac", "-b:a", "48k", str(out)],
        check=True,
        capture_output=True,
    )
    wav.unlink(missing_ok=True)
    return out


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


def cmd_ask(args: argparse.Namespace) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        audio = Path(tmp) / "voice_cmd.m4a"
        synthesise(args.text, audio)
        size = audio.stat().st_size
        if args.keep:
            kept = Path(args.keep).expanduser()
            shutil.copyfile(audio, kept)
            print(f"→ áudio guardado em {kept}")
        print(f"→ voz sintetizada ({size} bytes, 16 kHz mono AAC)")
        task = _upload(args.base, audio)
        task_id = task["task_id"]
        print(f"→ tarefa {task_id}")
        final = _poll(args.base, task_id)
    _print_result(final)
    return 0 if final.get("status") == "completed" else 1


def _print_result(task: dict) -> None:
    print("\n" + "─" * 66)
    print(f"transcrição : {task.get('transcript') or '(vazia)'}")
    print(f"resposta    : {task.get('ai_reply') or '(vazia)'}")
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
    ask.set_defaults(func=cmd_ask)

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
