"""Watch Pilot hub — FastAPI application.

Endpoints
---------
``GET  /``                                  browser dashboard (TOTP session)
``POST /__totp__``                          browser TOTP login
``GET  /__health``                          unauthenticated liveness probe
``POST /api/v1/assistant/audio``            upload a voice command (multipart)
``GET  /api/v1/assistant/progress/{id}``    poll a task
``GET  /api/v1/assistant/reply/{id}``       the answer as synthesised speech
``POST /api/v1/notify``                     push a notification to the user
``GET  /api/v1/inbox``                      recent notifications
``POST /api/v1/register-device``            register an APNs device token
``GET  /api/v1/tasks``                      recent tasks
``GET  /api/v1/status``                     redacted configuration + backend health
``GET  /pair``                              one-time pairing page (loopback only)
"""

from __future__ import annotations

import asyncio
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, Request, UploadFile, status
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, Field

from . import activity, launches, llm, notify, security, tasks, transcribe, tts, web
from .config import settings

app = FastAPI(title="Watch Pilot Hub", version="0.1.0", docs_url=None, redoc_url=None)

SESSION_COOKIE = "wp_session"

_ERRORS = {
    "malformed": "O código tem de ter seis dígitos.",
    "mismatch": "Código inválido ou já expirado. Tenta o próximo.",
    "replay": "Esse código já foi usado. Espera pelo seguinte.",
    "limitado": "Demasiadas tentativas. Aguarda cinco minutos.",
}


def _error_text(code: str) -> str:
    return _ERRORS.get(code, "")
_RUNNING: set[asyncio.Task[Any]] = set()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _client(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _session_ok(request: Request) -> bool:
    return security.read_session(request.cookies.get(SESSION_COOKIE)) is not None


async def require_auth(
    request: Request,
    x_watch_totp: str | None = Header(default=None, alias="X-Watch-TOTP"),
    totp: str | None = Query(default=None, description="TOTP code, for clients that cannot set headers"),
) -> str:
    """Authenticate an API call: TOTP header/query, or a browser session cookie."""
    if _session_ok(request):
        return "session"
    code = x_watch_totp or totp or ""
    if not code:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Cabeçalho X-Watch-TOTP em falta.",
            headers={"X-Auth-Mode": "totp"},
        )
    result = security.authenticate(code, _client(request))
    if not result.ok:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Código TOTP rejeitado ({result.reason}).",
            headers={"X-Auth-Mode": "totp", "X-Auth-Reason": result.reason},
        )
    return "totp"


# ---------------------------------------------------------------------------
# Browser surface
# ---------------------------------------------------------------------------
@app.get("/__health")
async def health() -> dict[str, object]:
    return {"status": "ok", "service": "watch-pilot", "uptime_s": int(time.time() - tasks.STARTED_AT)}


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    if not _session_ok(request):
        return HTMLResponse(
            web.login_page(
                error=_error_text(request.query_params.get("erro", "")),
                next_path=web.redirect_target(request.query_params.get("next", "/")),
            )
        )
    task_list = tasks.recent(8)
    completed = [t for t in task_list if t.get("status") == "completed"]
    last = task_list[0] if task_list else None
    cards = [
        ("Comandos", str(len(tasks.TASKS)), "desde o arranque"),
        (
            "Último",
            f"{int((last or {}).get('timings_ms', {}).get('total', 0))} ms" if last else "—",
            (last or {}).get("backend", "sem tráfego"),
        ),
        ("Modelo", settings.model.split("/")[-1], f"reasoning {settings.reasoning_effort}"),
        ("Concluídos", f"{len(completed)}/{len(task_list)}", "recentes"),
    ]
    state = {
        "subtitle": f"{settings.host}:{settings.port} · Mac mini M1",
        "cards": cards,
        "footer": "watch.kluser.me · TOTP por pedido",
    }
    return HTMLResponse(web.dashboard(state, task_list, notify.inbox(6)))


@app.post("/__totp__")
async def totp_login(request: Request, code: str = Form(""), next: str = Form("/")) -> RedirectResponse:
    client = _client(request)
    if security.guard.blocked(client):
        return RedirectResponse(f"/?erro=limitado&next={next}", status_code=303)
    if security.guard.blocked(client):
        raise HTTPException(429, "Demasiadas tentativas.")
    ok, counter, reason = security.verify_totp(
        settings.totp_secret,
        code,
        digits=settings.totp_digits,
        period=settings.totp_period,
        skew=settings.totp_skew,
    )
    target = web.redirect_target(next)
    if not ok:
        security.guard.register_failure(client)
        return RedirectResponse(f"/?erro={reason or 'invalido'}&next={target}", status_code=303)
    assert counter is not None
    if not security.guard.accept("browser", counter):
        return RedirectResponse(f"/?erro=replay&next={target}", status_code=303)
    security.guard.clear_failures(client)
    token = security.sign_session({"exp": time.time() + settings.session_ttl_seconds})
    response = RedirectResponse(target, status_code=303)
    response.set_cookie(
        SESSION_COOKIE,
        token,
        max_age=settings.session_ttl_seconds,
        httponly=True,
        secure=True,
        samesite="lax",
    )
    return response


@app.get("/pair", response_class=HTMLResponse)
async def pair(request: Request) -> HTMLResponse:
    """Show the otpauth URI + QR. Loopback only — this reveals the shared secret."""
    if _client(request) not in {"127.0.0.1", "::1", "localhost"}:
        raise HTTPException(404, "Not found")
    qr_svg = ""
    if shutil.which("qrencode"):
        proc = subprocess.run(
            ["qrencode", "-t", "SVG", "-o", "-", "-m", "2", settings.totp_uri],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if proc.returncode == 0:
            qr_svg = proc.stdout
    return HTMLResponse(web.pair_page(settings.totp_uri, settings.totp_secret, qr_svg))


# ---------------------------------------------------------------------------
# Automation API (watch / scripts)
# ---------------------------------------------------------------------------
@app.post("/api/v1/assistant/audio", dependencies=[Depends(require_auth)])
async def upload_audio(audio_file: UploadFile = File(...)) -> JSONResponse:
    payload = await audio_file.read()
    if not payload:
        raise HTTPException(400, "Ficheiro de áudio vazio.")
    if len(payload) > settings.max_upload_bytes:
        raise HTTPException(413, "Ficheiro demasiado grande.")

    target = Path(settings.upload_dir) / f"{uuid.uuid4()}.m4a"
    target.write_bytes(payload)

    task = tasks.create(target, len(payload))
    task.status = "running"
    task.progress = 0.05
    task.step_description = "Áudio recebido no Mac Mini."

    runner = asyncio.create_task(tasks.run(task))
    _RUNNING.add(runner)
    runner.add_done_callback(_RUNNING.discard)

    return JSONResponse(task.to_json(), status_code=202)


REPLY_MEDIA_TYPES = {
    ".m4a": "audio/mp4",
    ".mp3": "audio/mpeg",
    ".aiff": "audio/aiff",
    ".wav": "audio/wav",
}


@app.get("/api/v1/assistant/reply/{task_id}", dependencies=[Depends(require_auth)])
async def reply_audio(task_id: str) -> FileResponse:
    """The answer as *fala*: the synthesised speech of one finished task."""
    task = tasks.get(task_id)
    if task is None:
        raise HTTPException(404, "Tarefa não encontrada.")
    if not task.reply_audio_path:
        raise HTTPException(404, "Esta resposta não tem fala sintetizada.")
    path = Path(task.reply_audio_path)
    if not path.exists():
        raise HTTPException(410, "O áudio da resposta já não existe.")
    return FileResponse(
        path,
        media_type=REPLY_MEDIA_TYPES.get(path.suffix.lower(), "application/octet-stream"),
        filename=f"reply-{task_id}{path.suffix}",
    )


@app.get("/api/v1/assistant/progress/{task_id}", dependencies=[Depends(require_auth)])
async def task_progress(task_id: str) -> JSONResponse:
    task = tasks.get(task_id)
    if task is None:
        raise HTTPException(404, "Tarefa não encontrada.")
    return JSONResponse(task.to_json())


class NotifyPayload(BaseModel):
    title: str = Field(default="Watch Pilot")
    body: str
    task_id: str = ""
    progress: float = 0.0
    silent: bool = False
    channels: list[str] | None = None


@app.post("/api/v1/notify", dependencies=[Depends(require_auth)])
async def send_notification(payload: NotifyPayload) -> JSONResponse:
    """Push a notification to the user's devices (the second endpoint of the hub)."""
    record = await notify.notify(
        payload.title,
        payload.body,
        task_id=payload.task_id,
        progress=payload.progress,
        silent=payload.silent,
        channels=payload.channels,
    )
    return JSONResponse(record.to_json())


@app.get("/api/v1/inbox", dependencies=[Depends(require_auth)])
async def get_inbox(limit: int = Query(default=20, ge=1, le=200)) -> JSONResponse:
    return JSONResponse({"items": notify.inbox(limit)})


class DevicePayload(BaseModel):
    device_token: str
    platform: str = "watchos"


@app.post("/api/v1/register-device", dependencies=[Depends(require_auth)])
async def register_device(payload: DevicePayload) -> JSONResponse:
    token = payload.device_token.strip().replace(" ", "").lower()
    if not 16 <= len(token) <= 256:
        raise HTTPException(400, "Formato de device token inválido.")
    notify.DEVICE_TOKENS.add(token)
    return JSONResponse({"status": "registered", "active_tokens": len(notify.DEVICE_TOKENS)})


@app.get("/api/v1/tasks", dependencies=[Depends(require_auth)])
async def list_tasks(limit: int = Query(default=20, ge=1, le=100)) -> JSONResponse:
    return JSONResponse({"items": tasks.recent(limit)})


class LaunchPayload(BaseModel):
    prompt: str = Field(min_length=1, max_length=4000)
    project: str = Field(min_length=1, max_length=512)
    new_story: bool = True
    story_name: str = Field(default="", max_length=64)


@app.post("/api/v1/launch", dependencies=[Depends(require_auth)])
async def create_launch(payload: LaunchPayload) -> JSONResponse:
    """Queue one launch: a prompt the DSH plugin runs inside a worktree.

    ``new_story`` decides the story: True creates a fresh named worktree; False
    runs the prompt in the project as it stands.
    """
    launch = launches.create(
        prompt=payload.prompt,
        project=payload.project,
        new_story=payload.new_story,
        story_name=payload.story_name,
    )
    return JSONResponse(launch.to_json(), status_code=202)


@app.get("/api/v1/launches", dependencies=[Depends(require_auth)])
async def list_launches(pending: bool = Query(default=False)) -> JSONResponse:
    items = launches.pending() if pending else launches.recent(20)
    return JSONResponse({"items": items})


class LaunchReport(BaseModel):
    status: str = Field(pattern="^(running|completed|failed)$")
    detail: str = ""
    worktree_path: str = ""
    session_id: str = ""


@app.post("/api/v1/launches/{launch_id}/report", dependencies=[Depends(require_auth)])
async def report_launch(launch_id: str, payload: LaunchReport) -> JSONResponse:
    launch = await launches.report(
        launch_id,
        payload.status,
        detail=payload.detail,
        worktree_path=payload.worktree_path,
        session_id=payload.session_id,
    )
    if launch is None:
        raise HTTPException(404, "Pedido de lançamento não encontrado.")
    return JSONResponse(launch.to_json())


@app.get("/api/v1/activity", dependencies=[Depends(require_auth)])
async def get_activity() -> JSONResponse:
    return JSONResponse(activity.snapshot())


@app.post("/api/v1/activity", dependencies=[Depends(require_auth)])
async def post_activity(payload: dict[str, Any]) -> JSONResponse:
    return JSONResponse(activity.update(payload))


@app.get("/api/v1/fs", dependencies=[Depends(require_auth)])
async def browse(path: str = Query(default="~")) -> JSONResponse:
    """List one directory's entries (names and kinds only — never contents)."""
    target = Path(path).expanduser() if path not in {"", "~"} else Path.home()
    target = target.resolve()
    if not target.exists() or not target.is_dir():
        raise HTTPException(404, "Pasta não encontrada.")
    entries = []
    for child in sorted(target.iterdir(), key=lambda item: (not item.is_dir(), item.name.lower())):
        if child.name.startswith("."):
            continue
        entries.append({"name": child.name, "path": str(child), "is_dir": child.is_dir()})
    return JSONResponse({"path": str(target), "parent": str(target.parent), "entries": entries})


@app.get("/api/v1/status", dependencies=[Depends(require_auth)])
async def get_status() -> JSONResponse:
    return JSONResponse(
        {
            "config": settings.redacted(),
            "transcribe": transcribe.available_backends(),
            "tts": tts.available_backends(),
            "llm_configured": bool(settings.openrouter_api_key),
            "model": settings.model,
            "reasoning_effort": settings.reasoning_effort,
            "uptime_s": int(time.time() - tasks.STARTED_AT),
            "tasks_total": len(tasks.TASKS),
        }
    )


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    if request.url.path.startswith("/api/"):
        return JSONResponse(
            {"error": exc.detail, "status": exc.status_code}, status_code=exc.status_code, headers=exc.headers
        )
    if exc.status_code == 401 and not _session_ok(request):
        return HTMLResponse(web.login_page(next_path=str(request.url.path)), status_code=401)
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


def run() -> None:  # pragma: no cover - entry point used by scripts/run-hub.sh
    import uvicorn

    uvicorn.run(app, host=settings.host, port=settings.port, log_level="info")


if __name__ == "__main__":  # pragma: no cover
    run()
