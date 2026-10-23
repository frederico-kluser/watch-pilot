"""Server-rendered UI: TOTP login + operations dashboard.

No JavaScript framework, no build step — the Mac mini serves a single self-contained
page that works over the Cloudflare tunnel and on the watch's own HTTP client.
"""

from __future__ import annotations

import html

from . import visor

BASE_CSS = """
:root{--bg:#07090c;--panel:#0e1218;--line:#1b2430;--ink:#e8eef6;--muted:#7e8ea3;
--mint:#5ef2c0;--blue:#5aa9ff;--pink:#ff7ab6;--amber:#ffc45a;--red:#ff6b6b}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(1200px 600px at 50% -10%,#122030 0%,var(--bg) 55%);
color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,system-ui,sans-serif;
min-height:100vh;padding:28px 18px 60px}
.wrap{max-width:920px;margin:0 auto}
header{display:flex;align-items:center;gap:12px;margin-bottom:26px}
.orb{width:34px;height:34px;border-radius:50%;
background:radial-gradient(circle at 50% 45%,var(--mint),#1c8f78 55%,#0b3f36 100%);
box-shadow:0 0 22px rgba(94,242,192,.45);animation:breathe 3.4s ease-in-out infinite}
@keyframes breathe{0%,100%{transform:scale(.92);opacity:.85}50%{transform:scale(1.06);opacity:1}}
h1{font-size:19px;margin:0;letter-spacing:-.01em}
h1 small{display:block;font-weight:400;color:var(--muted);font-size:12px;letter-spacing:.02em}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.09em;color:var(--muted);margin:30px 0 12px}
.grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(150px,1fr))}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 16px}
.card .k{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.card .v{font-size:20px;font-weight:600;margin-top:4px;font-variant-numeric:tabular-nums}
.card .s{font-size:12px;color:var(--muted);margin-top:2px}
.task{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 16px;margin-bottom:10px}
.task header{display:flex;justify-content:space-between;gap:10px;margin:0 0 6px}
.task .st{font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--mint)}
.task .st.fail{color:var(--red)}
.task .st.run{color:var(--amber)}
.task .t{font-size:12px;color:var(--muted);font-variant-numeric:tabular-nums}
.task blockquote{margin:8px 0 0;padding:10px 12px;border-left:2px solid var(--blue);
background:#0b1016;border-radius:0 8px 8px 0;font-size:14px;color:#cfe1f5}
.task p{margin:8px 0 0;font-size:13px;color:var(--muted)}
.bar{height:4px;border-radius:3px;background:#131b24;overflow:hidden;margin-top:10px}
.bar i{display:block;height:100%;background:linear-gradient(90deg,var(--blue),var(--mint))}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--mint);
background:#0b1016;border:1px solid var(--line);border-radius:6px;padding:2px 6px}
.empty{color:var(--muted);font-size:14px;padding:18px 0}
.log{font:12px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;color:#9fb3c8}
form{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:26px;max-width:360px;
margin:12vh auto;text-align:center}
input[type=text]{width:100%;font:600 28px/1 ui-monospace,Menlo,monospace;letter-spacing:.36em;
text-align:center;padding:14px 8px;border-radius:12px;border:1px solid var(--line);
background:#0b1016;color:var(--ink);margin:18px 0 14px}
input:focus{outline:2px solid rgba(94,242,192,.45);outline-offset:1px}
button{width:100%;padding:13px;border-radius:12px;border:0;font-weight:650;font-size:15px;
background:linear-gradient(180deg,#67f7c9,#2fbf95);color:#04231b;cursor:pointer}
.err{color:var(--red);font-size:13px;margin-top:12px}
.hint{color:var(--muted);font-size:12px;margin-top:14px}
footer{margin-top:40px;color:var(--muted);font-size:11px;text-align:center}
"""


def _esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def login_page(error: str = "", next_path: str = "/") -> str:
    message = f'<p class="err">{_esc(error)}</p>' if error else ""
    return f"""<!doctype html>
<html lang="pt"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Watch Pilot · verificação</title><style>{BASE_CSS}</style></head>
<body><div class="wrap">
<form method="post" action="/__totp__">
  <div class="orb" style="margin:0 auto 14px"></div>
  <h1 style="font-size:17px">Watch Pilot<small>introduz o código do autenticador</small></h1>
  <input type="text" name="code" inputmode="numeric" autocomplete="one-time-code"
         maxlength="8" placeholder="000000" autofocus>
  <input type="hidden" name="next" value="{_esc(next_path)}">
  <button type="submit">Entrar</button>
  {message}
  <p class="hint">O mesmo código que o teu Apple Watch envia no cabeçalho
  <code>X-Watch-TOTP</code>.</p>
</form>
</div></body></html>"""


def _task_card(task: dict[str, object]) -> str:
    status = str(task.get("status", ""))
    css = "fail" if status == "failed" else ("run" if status != "completed" else "")
    label = {"completed": "concluído", "failed": "falhou", "running": "a correr"}.get(status, status)
    progress = float(task.get("progress") or 0)
    transcript = str(task.get("transcript") or "").strip()
    reply = str(task.get("ai_reply") or "").strip()
    timings = task.get("timings_ms") or {}
    total = timings.get("total") if isinstance(timings, dict) else None
    meta = []
    if total:
        meta.append(f"{int(total)} ms")
    if task.get("reasoning_tokens"):
        meta.append(f"{int(task['reasoning_tokens'])} tokens de pensamento")
    if task.get("backend") and task.get("backend") != "none":
        meta.append(f"stt: {task['backend']}")
    if task.get("cost_usd"):
        meta.append(f"${float(task['cost_usd']):.5f}")
    return f"""<article class="task">
  <header><span class="st {css}">{_esc(label)}</span>
  <span class="t">{_esc(' · '.join(meta)) or ''}</span></header>
  <p><strong>Tu:</strong> {_esc(transcript) or '<em>(sem transcrição)</em>'}</p>
  {f'<blockquote>{_esc(reply)}</blockquote>' if reply else ''}
  <p>{_esc(task.get('step_description') or '')}</p>
  <div class="bar"><i style="width:{max(2, int(progress * 100))}%"></i></div>
</article>"""


def dashboard(state: dict[str, object], tasks: list[dict[str, object]], events: list[dict[str, object]]) -> str:
    cards = "".join(
        f'<div class="card"><div class="k">{_esc(k)}</div>'
        f'<div class="v">{_esc(v)}</div><div class="s">{_esc(s)}</div></div>'
        for k, v, s in state["cards"]  # type: ignore[index]
    )
    task_html = "".join(_task_card(task) for task in tasks) or '<p class="empty">Ainda sem comandos de voz.</p>'
    event_html = "".join(
        f'<div class="log">{_esc(e.get("title"))} · {_esc(e.get("body"))}</div>' for e in events
    ) or '<p class="empty">Sem notificações.</p>'
    return f"""<!doctype html>
<html lang="pt"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>Watch Pilot · Mac mini M1</title><style>{BASE_CSS}</style></head>
<body class="dash">
{visor.fragment()}
<div class="wrap">
<header><div class="orb"></div>
<h1>Watch Pilot<small>{_esc(state['subtitle'])}</small></h1></header>
<section class="grid">{cards}</section>
<h2>Comandos de voz</h2>
<section>{task_html}</section>
<h2>Notificações</h2>
<section>{event_html}</section>
<footer>watch-pilot · {_esc(state['footer'])}</footer>
</div></body></html>"""


def pair_page(uri: str, secret: str, qr_svg: str) -> str:
    qr_block = f'<div style="background:#fff;padding:12px;border-radius:12px;display:inline-block">{qr_svg}</div>' if qr_svg else ""
    return f"""<!doctype html>
<html lang="pt"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Watch Pilot · emparelhar</title><style>{BASE_CSS}</style></head>
<body><div class="wrap">
<header><div class="orb"></div><h1>Emparelhar o relógio<small>segredo TOTP partilhado</small></h1></header>
<div class="card" style="text-align:center">{qr_block}
<p style="margin-top:16px">Adiciona esta conta em <strong>Google Authenticator</strong>:</p>
<p><code>{_esc(secret)}</code></p>
<p style="color:var(--muted);font-size:12px;word-break:break-all">{_esc(uri)}</p>
<p style="color:var(--muted);font-size:12px">O app do relógio traz o mesmo segredo no Keychain e gera
os códigos localmente (RFC 6238 · SHA1 · 6 dígitos · 30 s).</p>
</div>
<footer>Esta página só responde em <code>127.0.0.1</code>.</footer>
</div></body></html>"""


def redirect_target(raw: str | None) -> str:
    """Sanitise a post-login redirect to a local path (never an absolute URL)."""
    if not raw:
        return "/"
    if not raw.startswith("/") or raw.startswith("//") or "__totp" in raw or "__health" in raw:
        return "/"
    return raw
