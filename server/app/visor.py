"""The T-800 visor, ported to the web.

A faithful port of the watch's `AssistantAvatar` + `T800Head` — same geometry,
same poses, same math — rendered on a `<canvas>` exactly like the SwiftUI
`Canvas`. The skull art comes from `t800_art.json`, the traced SVG path data
the watch draws, and the HUD constants are the measured fractions of the
design space (190×231 pt).

Two products out of one implementation:
- ``fragment()`` — the visor embedded in the dashboard page;
- ``visor_html()`` — the immersive standalone page.

The state machine (idle / listening / uploading / waiting / answering / failed)
mirrors the watch's pose table, and the page follows the hub live through
``GET /api/v1/live`` so watch.kluser.me shows the assistant's real state.
"""

from __future__ import annotations

import json
from pathlib import Path

ART = json.loads((Path(__file__).resolve().parent / "t800_art.json").read_text(encoding="utf-8"))


def _seed() -> dict:
    """Initial state at render time; the client refines it live every 2 s."""
    return {"phase": "idle", "power": 0.0, "progress": None, "speechLevel": -1, "line": ""}


def _art_json() -> str:
    return json.dumps(ART, separators=(",", ":")).replace("</", "<\\/")


def _state_json(state: dict | None) -> str:
    seeded = _seed()
    if state:
        seeded.update(state)
    return json.dumps(seeded, separators=(",", ":")).replace("</", "<\\/")


def fragment(state: dict | None = None, overlay: str = "") -> str:
    """The visor as an embeddable fragment (scoped style + canvas + script).

    ``overlay`` is markup placed inside the visor box — used by the login page
    to put the TOTP input *in the speech bars* (the waveform band).
    """
    return (
        _STYLE
        + _MARKUP.replace("__ART__", _art_json())
        .replace("__STATE__", _state_json(state))
        .replace('<canvas id="t800-canvas"></canvas>',
                 '<canvas id="t800-canvas"></canvas>' + overlay)
    )


def visor_html(state: dict | None = None) -> str:
    """The immersive standalone visor page."""
    return (
        '<!doctype html>\n<html lang="pt"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
        f"<title>Watch Pilot · T-800</title>{_PAGE_STYLE}</head>"
        f"<body>{fragment(state)}</body></html>"
    )


_PAGE_STYLE = """
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  html, body { margin: 0; height: 100%; }
  body {
    background: #05080c;
    background-image: radial-gradient(120% 90% at 50% 30%, #0b1420 0%, #05080c 62%);
    color: #e5eef7;
    font-family: ui-rounded, "SF Pro Rounded", system-ui, sans-serif;
    display: flex; flex-direction: column; align-items: center;
    overflow: hidden;
  }
</style>"""

_STYLE = """
<style>
  .t800-root {
    color-scheme: dark;
    display: flex; flex-direction: column; align-items: center;
    font-family: ui-rounded, "SF Pro Rounded", system-ui, sans-serif;
    width: 100%;
  }
  .t800-root .visor {
    position: relative;
    width: min(96vw, 52vh);
    aspect-ratio: 190 / 231;
    margin-top: 2vh;
  }
  .t800-root canvas {
    width: 100%; height: 100%; display: block;
    filter: drop-shadow(0 0 22px rgba(255, 41, 51, 0.16));
  }
  .t800-root .status { margin: 1.6vh 0 0; text-align: center; max-width: 92vw; }
  .t800-root .state {
    font-size: clamp(11px, 1.7vh, 15px); letter-spacing: .22em; text-transform: uppercase;
    color: #7d8b9c; font-weight: 600;
  }
  .t800-root .line {
    margin-top: .6vh; font-size: clamp(11px, 1.6vh, 14px); color: #b9c6d4;
    min-height: 2.6em; line-height: 1.45;
  }
  .t800-root .foot {
    margin: 1.4vh 0 0; padding-bottom: 2vh; display: flex; gap: 18px;
    font-size: clamp(9px, 1.3vh, 11px); letter-spacing: .16em; color: #4c5a6b; text-transform: uppercase;
  }
  .t800-root .foot b { color: #ff2933; font-weight: 600; }
</style>"""

_MARKUP = r"""
<div class="t800-root">
  <div class="visor"><canvas id="t800-canvas"></canvas></div>
  <div class="status">
    <div class="state" id="t800-state">T-800 · EM ESPERA</div>
    <div class="line" id="t800-line"></div>
  </div>
  <div class="foot">
    <span>WATCH <b>PILOT</b></span><span id="t800-clock">--:--</span><span>MAC MINI M1</span>
  </div>
</div>

<script id="t800-art" type="application/json">__ART__</script>
<script id="t800-seed" type="application/json">__STATE__</script>
<script>
"use strict";
(() => {
const root = document.querySelector(".t800-root");
const ART = JSON.parse(document.getElementById("t800-art").textContent);
const SEED = JSON.parse(document.getElementById("t800-seed").textContent);

// ── design space (exactly the watch's) ──────────────────────────────────
const W = 190, H = 231;
const SKULL = { x: W / 2, y: H * 0.433, unit: Math.min(H * 0.307, W * 0.3066) };
const RING = W * 0.300;

const PALETTE = {
  background: "#05080c", muted: "#7d8b9c", ink: "#e5eef7",
  crimson: "#ff2933", blue: "#5aa9ff",
};

// ── pose table: one entry per assistant state (data, not drawing code) ──
const POSES = {
  idle:       { eyeGlow: .72, eyeScale: 1, headYaw: .15, scanning: true, ringSpeed: 5, waveAmplitude: .5 },
  listening:  { eyeGlow: .85, eyeScale: 1.12, headScale: 1.02, headYaw: -.10, ringSpeed: 16, hudPulse: true, waveAmplitude: .25 },
  uploading:  { eyeGlow: .9, eyeLookY: -2.6, headYaw: .05, ringSpeed: 26, scanLine: true, waveAmplitude: .4 },
  waiting:    { eyeGlow: .8, headYaw: .1, scanning: true, ringSpeed: 34, waveAmplitude: .35 },
  answering:  { eyeGlow: 1, jawOpen: .06, speaking: true, headYaw: .06, ringSpeed: 10, waveAmplitude: .9, waveSpeech: true, waveColor: "red" },
  failed:     { eyeGlow: .55, jawOpen: .16, eyeFlicker: true, chrome: .72, hudGlitch: true, headTilt: -.06, waveAmplitude: .06, ringSpeed: 3 },
};

const view = {
  phase: SEED.phase || "idle",
  power: SEED.power ?? 0,
  progress: SEED.progress ?? null,
  speechLevel: SEED.speechLevel ?? -1,
};

const LABELS = {
  idle: "T-800 · EM ESPERA", listening: "A OUVIR", uploading: "A ENVIAR",
  waiting: "A PENSAR", answering: "A RESPONDER", failed: "FALHA",
};

function setPhase(phase, data) {
  view.phase = POSES[phase] ? phase : "idle";
  Object.assign(view, data || {});
  root.querySelector("#t800-state").textContent = LABELS[view.phase] || LABELS.idle;
}

// ── the same math the watch runs ────────────────────────────────────────
const smoothstep = (a, b, x) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};
const glitchValue = (t) => {
  const n = Math.floor(t * 9);
  const s = Math.sin(n * 12.9898) * 43758.5453;
  return Math.abs(s - Math.floor(s));
};
const speechEnvelope = (t) =>
  Math.min(1, 0.15 + Math.max(0, Math.sin(t * 7.3)) * (0.45 + 0.55 * (0.5 + 0.5 * Math.sin(t * 1.31))));
function waveHeight(i, t, pose) {
  let value = 0.42 * (0.5 + 0.5 * Math.sin(i * 1.7 + t * 5.1));
  value += 0.35 * (0.5 + 0.5 * Math.sin(i * 0.63 - t * 3.3));
  value += 0.23 * (0.5 + 0.5 * Math.sin(i * 2.9 + t * 7.7));
  if (pose.waveSpeech) {
    const burst = Math.pow(0.5 + 0.5 * Math.sin(t * 2.9 + Math.sin(t * 0.77) * 2.0), 1.6);
    value *= 0.35 + 0.85 * burst;
  }
  return Math.min(1, value) * pose.waveAmplitude;
}

// ── canvas: the watch's layer order, one to one ─────────────────────────
const canvas = root.querySelector("#t800-canvas");
const ctx = canvas.getContext("2d");
function fit() {
  const dpr = Math.min(3, window.devicePixelRatio || 1);
  const rect = canvas.getBoundingClientRect();
  canvas.width = Math.round(rect.width * dpr);
  canvas.height = Math.round(rect.height * dpr);
  ctx.setTransform(canvas.width / W, 0, 0, canvas.height / H, 0, 0);
}
addEventListener("resize", fit);
fit();

const tone = (index, chrome) => {
  const rgb = ART.palette[index] || [0, 0, 0];
  const c = (v) => Math.round(255 * Math.min(1, v * chrome));
  return `rgb(${c(rgb[0])},${c(rgb[1])},${c(rgb[2])})`;
};

function drawBackdrop(pose) {
  const r = RING * 1.5;
  const g = ctx.createRadialGradient(SKULL.x, SKULL.y, RING * 0.3, SKULL.x, SKULL.y, r);
  g.addColorStop(0, `rgba(255,41,51,${0.05 + pose.eyeGlow * 0.05})`);
  g.addColorStop(1, "rgba(255,41,51,0)");
  ctx.fillStyle = g;
  ctx.beginPath();
  ctx.arc(SKULL.x, SKULL.y, r, 0, Math.PI * 2);
  ctx.fill();
}

function drawHUDFrame(t, pose, glitch) {
  const flick = pose.hudGlitch && glitch > 0.72;
  ctx.lineWidth = 1;
  ctx.strokeStyle = `rgba(125,139,156,${flick ? 0.15 : 0.4})`;
  ctx.beginPath();
  ctx.roundRect(W * 0.015, H * 0.105, W * 0.97, H * 0.655, W * 0.105);
  ctx.stroke();

  const pulse = pose.hudPulse ? 0.6 + 0.4 * (0.5 + 0.5 * Math.sin(t * 3.1)) : 0.9;
  const jx = flick ? (glitch - 0.86) * 16 : 0;
  const bx = W * 0.16 + jx, by = H * 0.155, bw = W * 0.68, bh = H * 0.52;
  ctx.lineWidth = 2;
  ctx.lineCap = "square";
  ctx.strokeStyle = `rgba(255,41,51,${flick ? 0.35 : pulse})`;
  ctx.beginPath();
  for (const [cx, cy, dx, dy] of [[bx, by, 1, 1], [bx + bw, by, -1, 1], [bx, by + bh, 1, -1], [bx + bw, by + bh, -1, -1]]) {
    ctx.moveTo(cx + dx * 11, cy);
    ctx.lineTo(cx, cy);
    ctx.lineTo(cx, cy + dy * 11);
  }
  ctx.stroke();

  tickColumn(W * 0.030, H * 0.19, H * 0.735, false, t, pose, 5.5, flick);
  tickColumn(W * 0.970, H * 0.19, H * 0.735, true, t, pose, 4.1, flick);

  ctx.fillStyle = "rgba(255,41,51,0.9)";
  ctx.fillRect(W * 0.030 + 5.5, H * 0.520, 3.2, H * 0.075);

  // Logo Cyberdyne: triângulo vazado + duas linhas de texto.
  const ox = W * 0.062, oy = H * 0.150;
  ctx.fillStyle = "rgba(255,41,51,0.95)";
  ctx.beginPath();
  ctx.moveTo(ox + 6, oy);
  ctx.lineTo(ox + 12, oy + 10.5);
  ctx.lineTo(ox, oy + 10.5);
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = PALETTE.background;
  ctx.beginPath();
  ctx.moveTo(ox + 6, oy + 4);
  ctx.lineTo(ox + 9.1, oy + 9.4);
  ctx.lineTo(ox + 2.9, oy + 9.4);
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = "rgba(125,139,156,0.95)";
  ctx.font = "600 6.8px ui-rounded, system-ui";
  ctx.textAlign = "left";
  ctx.fillText("CYBERDYNE", ox + 16.5, oy + 8);
  ctx.fillText("SYSTEMS", ox + 16.5, oy + 15);

  // Glifos de dados — decoração de terminal, sem significado.
  const gray = `rgba(125,139,156,${flick ? 0.2 : 0.6})`;
  const red = `rgba(255,41,51,${flick ? 0.3 : 0.9})`;
  ctx.lineWidth = 1.6;
  ctx.strokeStyle = red;
  ctx.beginPath();
  ctx.moveTo(W * 0.775, H * 0.165);
  ctx.lineTo(W * 0.775, H * 0.192);
  ctx.lineTo(W * 0.805, H * 0.192);
  ctx.stroke();
  ctx.fillStyle = gray;
  [0.09, 0.06, 0.075].forEach((width, index) => ctx.fillRect(W * 0.825, H * (0.165 + index * 0.016), W * width, 2.2));

  ctx.lineWidth = 1.4;
  ctx.lineCap = "round";
  ctx.strokeStyle = red;
  ctx.beginPath();
  ctx.moveTo(W * 0.10, H * 0.575);
  ctx.lineTo(W * 0.078, H * 0.59);
  ctx.lineTo(W * 0.10, H * 0.605);
  ctx.moveTo(W * 0.128, H * 0.575);
  ctx.lineTo(W * 0.106, H * 0.59);
  ctx.lineTo(W * 0.128, H * 0.605);
  ctx.stroke();
  ctx.fillStyle = gray;
  ctx.fillRect(W * 0.15, H * 0.572, W * 0.09, 2.2);
  ctx.fillRect(W * 0.15, H * 0.6, W * 0.06, 2.2);
  ctx.fillRect(W * 0.755, H * 0.60, 10, 6);
  ctx.fillRect(W * 0.755 + 12, H * 0.60, 10, 6);
  ctx.fillStyle = red;
  ctx.fillRect(W * 0.755 + 24, H * 0.60, 10, 6);
  ctx.fillRect(W * 0.80, H * 0.575, 11, 2.2);
}

function tickColumn(x, top, bottom, flip, t, pose, speed, flick) {
  const step = 5.0;
  ctx.lineWidth = 0.9;
  ctx.strokeStyle = "rgba(125,139,156,0.5)";
  ctx.beginPath();
  for (let y = top; y <= bottom; y += step) {
    ctx.moveTo(x, y);
    ctx.lineTo(x + (flip ? -6 : 6), y);
  }
  ctx.stroke();
  ctx.lineWidth = 0.8;
  ctx.strokeStyle = "rgba(125,139,156,0.28)";
  ctx.beginPath();
  ctx.moveTo(x + (flip ? -8 : 8), top - 3);
  ctx.lineTo(x + (flip ? -8 : 8), bottom + 3);
  ctx.stroke();
  const count = Math.floor((bottom - top) / step);
  const index = Math.floor(t * speed) % (count + 1);
  ctx.fillStyle = `rgba(255,41,51,${flick ? 0.35 : 0.95})`;
  ctx.fillRect(x + (flip ? -7 : 0), top + index * step - 1.3, 7, 2.6);
}

function drawReticle(t, pose) {
  ctx.lineWidth = 1.4;
  ctx.strokeStyle = `rgba(125,139,156,${pose.hudGlitch ? 0.2 : 0.55})`;
  ctx.beginPath();
  ctx.arc(SKULL.x, SKULL.y, RING, 0, Math.PI * 2);
  ctx.stroke();

  if (pose.ringSpeed > 0) {
    ctx.save();
    ctx.translate(SKULL.x, SKULL.y);
    ctx.rotate((t * pose.ringSpeed * Math.PI) / 180);
    ctx.translate(-SKULL.x, -SKULL.y);
    ctx.lineWidth = 1.6;
    ctx.strokeStyle = "rgba(255,41,51,0.75)";
    ctx.setLineDash([6, 15]);
    ctx.beginPath();
    ctx.arc(SKULL.x, SKULL.y, RING, 0, Math.PI * 2);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.restore();
  }

  if (view.progress !== null && view.progress !== undefined) {
    const p = Math.min(1, Math.max(0, view.progress));
    ctx.lineWidth = 2.8;
    ctx.lineCap = "round";
    ctx.strokeStyle = PALETTE.crimson;
    ctx.beginPath();
    ctx.arc(SKULL.x, SKULL.y, RING, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * p);
    ctx.stroke();
  }

  ctx.lineWidth = 2.2;
  ctx.lineCap = "round";
  ctx.strokeStyle = "rgba(255,41,51,0.9)";
  ctx.beginPath();
  ctx.arc(SKULL.x, SKULL.y, RING, (118 * Math.PI) / 180, (162 * Math.PI) / 180);
  ctx.stroke();

  const pulse = 0.55 + 0.4 * (0.5 + 0.5 * Math.sin(t * 2.2));
  ctx.lineWidth = 1.8;
  ctx.lineCap = "square";
  ctx.strokeStyle = `rgba(255,41,51,${pulse})`;
  ctx.beginPath();
  for (const angle of [0, Math.PI / 2, Math.PI, (3 * Math.PI) / 2]) {
    const dx = Math.cos(angle), dy = Math.sin(angle);
    ctx.moveTo(SKULL.x + dx * (RING + 9), SKULL.y + dy * (RING + 9));
    ctx.lineTo(SKULL.x + dx * (RING + 3), SKULL.y + dy * (RING + 3));
  }
  ctx.stroke();
}

function drawScanLine(t) {
  const sweep = (t * 38) % 100;
  const y = SKULL.y - RING + 6 + sweep * ((RING * 2 - 12) / 100);
  const half = RING * 0.94;
  const g = ctx.createLinearGradient(SKULL.x - half, 0, SKULL.x + half, 0);
  g.addColorStop(0, "rgba(255,41,51,0)");
  g.addColorStop(0.5, "rgba(255,41,51,0.9)");
  g.addColorStop(1, "rgba(255,41,51,0)");
  ctx.fillStyle = g;
  ctx.fillRect(SKULL.x - half, y - 1.2, half * 2, 2.4);
}

function drawSkull(t, pose, glitch) {
  const speech = view.speechLevel >= 0 ? view.speechLevel
    : (pose.speaking ? speechEnvelope(t) : 0);
  const drop = (pose.jawOpen + speech * 0.9) * ART.jawDropMax;

  ctx.save();
  ctx.translate(SKULL.x, SKULL.y);
  const headTilt = (pose.headTilt || 0) + (pose.scanning ? Math.sin(t * 0.45) * 0.04 : 0) + Math.sin(t * 0.9) * 0.012;
  ctx.rotate(headTilt);
  const scale = (pose.headScale || 1) * (1 + speech * 0.01);
  ctx.scale(scale, scale);
  ctx.scale(SKULL.unit, SKULL.unit);

  // Cavidade da boca: preto atrás, para a maxila abrir para o escuro.
  if (drop > 0.0005) {
    const c = ART.mouthCavity;
    ctx.fillStyle = "#000";
    ctx.fillRect(c[0] + 0.012, c[1] - 0.02, c[2] - 0.024, c[3] + drop + 0.02);
  }

  const chrome = pose.chrome ?? 1;
  const yaw = (pose.headYaw || 0) + (pose.scanning ? Math.sin(t * 0.45) * 0.55 : 0);
  const yawShift = yaw * 0.10;

  const paint = (shape, dx) => {
    ctx.save();
    ctx.translate(dx, 0);
    ctx.fillStyle = tone(shape.tone, chrome);
    ctx.fill(new Path2D(shape.d));
    ctx.restore();
  };
  for (const shape of ART.shapes) {
    if (!shape.jaw) paint(shape, yawShift * (shape.tone / 9));
  }
  ctx.save();
  ctx.translate(0, drop);
  for (const shape of ART.shapes) {
    if (shape.jaw) paint(shape, yawShift * (shape.tone / 9) * 0.6);
  }
  ctx.restore();

  // Pormenores: pistões, estruturas, parafusos, nariz.
  const line = (a, width, color) => {
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.beginPath();
    ctx.moveTo(a[0], a[1]);
    ctx.lineTo(a[2], a[3]);
    ctx.stroke();
  };
  line(ART.pistonL, ART.pistonL[4], tone(6, chrome));
  line(ART.pistonR, ART.pistonR[4], tone(6, chrome));
  line(ART.strutL, ART.strutL[4], tone(4, chrome));
  line(ART.strutR, ART.strutR[4], tone(4, chrome));
  for (const b of ART.bolts) {
    ctx.fillStyle = tone(7, chrome);
    ctx.fillRect(b[0] - b[2] / 2, b[1] - b[3] / 2, b[2], b[3]);
  }
  for (const n of ART.noseDots) {
    ctx.fillStyle = tone(2, chrome);
    ctx.beginPath();
    ctx.arc(n[0], n[1], n[2], 0, Math.PI * 2);
    ctx.fill();
  }

  // Olhos: halo + pupila, com foco (yaw) e cintilância (falha).
  const flicker = pose.eyeFlicker && glitch > 0.62 ? 0.25 : 1;
  const lookX = yawShift * 0.5;
  for (const side of [0, 1]) {
    const p = side === 1 ? ART.pupilR : ART.pupilL;
    const [px, py, rOut, rCore] = p;
    const glow = (pose.eyeGlow ?? 0.72) * (side === 1 ? flicker : 1);
    const es = pose.eyeScale ?? 1;
    const halo = ctx.createRadialGradient(px + lookX, py, rOut * 0.2, px + lookX, py, rOut * 3.2);
    halo.addColorStop(0, `rgba(255,31,38,${0.2 * glow})`);
    halo.addColorStop(1, "rgba(255,31,38,0)");
    ctx.fillStyle = halo;
    ctx.beginPath();
    ctx.arc(px + lookX, py, rOut * 3.2, 0, Math.PI * 2);
    ctx.fill();
    const core = ctx.createRadialGradient(px + lookX, py, 0, px + lookX, py, rOut * es);
    core.addColorStop(0, `rgba(255,87,89,${0.45 + 0.5 * glow})`);
    core.addColorStop(0.55, `rgba(255,31,38,${0.5 + 0.4 * glow})`);
    core.addColorStop(1, "rgba(120,10,14,0.9)");
    ctx.fillStyle = core;
    ctx.beginPath();
    ctx.ellipse(px + lookX, py, rOut * es, rCore * es * 1.6, 0, 0, Math.PI * 2);
    ctx.fill();
    const dots = side === 1 ? ART.dotsR : ART.dotsL;
    for (const d of dots) {
      ctx.fillStyle = `rgba(255,31,38,${0.35 + 0.4 * glow})`;
      ctx.beginPath();
      ctx.arc(d[0] + lookX, d[1], d[2], 0, Math.PI * 2);
      ctx.fill();
    }
  }
  ctx.restore();
}

function drawWaveform(t, pose, glitch) {
  const bars = 42;
  const left = W * 0.045, right = W * 0.955;
  const pitch = (right - left) / (bars - 1);
  const centerY = H * 0.890;
  const maxHalf = H * 0.090;
  const dot = 2.2, step = 2.6;
  // No relógio: crimson por omissão (idle/uploading/waiting/failed/answering);
  // azul↔vermelho SÓ na captação (.listening), mistura contínua com a voz.
  const mix = view.phase === "listening" ? smoothstep(0.22, 0.40, view.power) : 1;
  const rgb = [
    Math.round(90 + (255 - 90) * mix),
    Math.round(169 + (41 - 169) * mix),
    Math.round(255 + (51 - 255) * mix),
  ];
  ctx.fillStyle = `rgba(${rgb[0]},${rgb[1]},${rgb[2]},0.92)`;
  for (let i = 0; i < bars; i++) {
    let height = waveHeight(i, t, pose);
    if (pose.hudGlitch && glitchValue(t + i * 0.13) > 0.86) height = pose.waveAmplitude;
    const half = height * maxHalf;
    const stacks = 1 + Math.floor(half / step);
    const x = left + i * pitch;
    for (let s = 0; s < stacks; s++) {
      const dy = s * step;
      ctx.fillRect(x - dot / 2, centerY - dy - dot, dot, dot);
      if (s > 0) ctx.fillRect(x - dot / 2, centerY + dy, dot, dot);
    }
  }
}

// ── 30 Hz loop ─────────────────────────────────────────────────────────
const start = performance.now();
function frame(now) {
  const t = (now - start) / 1000;
  const pose = { ...POSES[view.phase] };
  if (view.phase === "listening") {
    pose.eyeGlow = 0.85 + view.power * 0.15;
    pose.headYaw = -0.10 + view.power * 0.12;
    pose.waveAmplitude = 0.25 + view.power * 0.75;
  }
  if (view.phase === "waiting" && view.progress !== null && view.progress !== undefined) {
    pose.ringProgress = view.progress;
  }
  const glitch = glitchValue(t);
  ctx.clearRect(0, 0, W, H);
  drawBackdrop(pose);
  drawHUDFrame(t, pose, glitch);
  drawReticle(t, pose);
  drawSkull(t, pose, glitch);
  if (pose.scanLine) drawScanLine(t);
  drawWaveform(t, pose, glitch);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

// ── live state: the hub drives the visor ────────────────────────────────
const clock = root.querySelector("#t800-clock");
setInterval(() => {
  clock.textContent = new Date().toLocaleTimeString("pt-PT", { hour: "2-digit", minute: "2-digit" });
}, 1000);

async function refresh() {
  try {
    const res = await fetch("/api/v1/live", { headers: { accept: "application/json" }, credentials: "same-origin" });
    if (!res.ok) return;
    const live = await res.json();
    setPhase(live.phase, {
      power: live.power ?? 0,
      progress: live.progress ?? null,
      speechLevel: live.speechLevel ?? -1,
    });
    root.querySelector("#t800-line").textContent = live.line || "";
  } catch { /* offline: o visor continua vivo */ }
}
// Hooks de debug (como os -WPDemoPhase do relógio): ?demo=<estado>&power=0.7
const demo = new URLSearchParams(location.search);
if (demo.has("demo")) {
  setPhase(demo.get("demo"), {
    power: Number(demo.get("power") ?? 0.7),
    progress: demo.has("progress") ? Number(demo.get("progress")) : null,
    speechLevel: demo.has("speechLevel") ? Number(demo.get("speechLevel")) : -1,
  });
} else {
  refresh();
  setInterval(refresh, 2000);
}
})();
</script>
"""
