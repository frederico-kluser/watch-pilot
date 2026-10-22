# Design

The interface is one screen with one job. On a 40 mm watch the expensive resources
are glance time and attention, not pixels — so the design optimises for "can I tell
what it is doing in under a second, and does it ever lie to me".

## Shape

The screen **is** the visor of a Cyberdyne T-800 — full-bleed, no chrome of our own
and **no text**: everything the visor has to say is carried by colour, motion and
sound.

```
┌────────────────────────┐
│ T-800           10:09  │   model on the system clock's row
│╭──────────────────────╮│   targeting frame, edge to edge
││▲ CYBERDYNE   ⌐ ┤ticks││   corner brackets · ruler ticks + scanner
│││  ( T-800 )      │   ││   reticle ring + the skull (overflows it)
││╰ ⌞      ⌟ ┘ ┤ticks   ││   red crosshairs · data glyphs
│╰──────────────────────╯│
│ ░░▒▒████▒▒░░▒▒██████▒▒  │   dot-matrix waveform (the mic / the voice)
└────────────────────────┘
```

The HUD itself is the only button: a tap performs the state's action (record →
send → cancel). The visor is drawn in a 190×231 pt space that is scaled to **cover**
the screen (`max(w/190, h/231)`), so there is no letterboxing margin on any watch.

There used to be a caption under the waveform (headline, transcript, provenance).
It is gone by design: the answer arrives as **audio**, and the visor answers with
its eyes and its jaw. The full text is still reachable — tapping while the T-800
answers opens the answer sheet — but nothing is printed on the visor.

## State → colour → face

| State | Pose | Face | Tap does |
| --- | --- | --- | --- |
| idle | ember eyes, slow head scan, calm waveform | calm, waiting | starts recording |
| listening | wide bright eyes, brackets pulse, waveform is the mic power | dilated, leaning in | sends |
| uploading | gaze up, scanline sweeps the ring | looking up | cancels |
| waiting | searching scan, progress arc on the ring | scanning for a target | cancels |
| answering | jaw talks, waveform speaks, eyes at full glow | talking, full glow | opens the read sheet |
| failed | dimmed chrome, right eye flickers out, HUD glitches | torn, jaw slack | retries / records again |

## Principles applied (and where the audit pushed back)

A full audit against 195 research-backed principles is in
[`design/ux-audit.json`](design/ux-audit.json) with a readable summary in
[`design/ux-audit.md`](design/ux-audit.md). Score at review time: **43/100 (fair)**,
1 critical and 6 warnings. The critical finding and the four warnings that mattered
were fixed:

1. **Critical — the answer had no route to its full text.** It was being shrunk to
   ~9.4 pt and ellipsised. The visor now speaks; the full text lives behind a tap
   while the T-800 answers, with its transcript and timings.
2. **Retry did not retry.** "Tentar de novo" called `resetSession()`, throwing the task
   away. Now, if a task is still pending, the button says *Ver estado* and re-polls;
   only a command with nothing pending starts a new recording.
3. **No way out of a 120-second wait.** The busy state now offers a real *Cancelar*.
4. **The transcript was invisible**, so a misrecognition looked like a confident wrong
   answer. `"Ouvi: …"` now appears as soon as the hub returns it.
5. **Dynamic Type.** Text uses semantic styles with a cap, instead of fixed 9.5 pt.

Two audit findings were deliberately **not** acted on, because they were wrong or
inapplicable: contrast is measured at 6.0–14.3:1 (no violation), and the 44 pt target
rule is already satisfied. The debug-only smoke-test copy is not user-facing.

## Changing the animation

The animation has its own skill: **`watch-pilot-animation-agent-skill`**
(`~/Agent-Skills/watch-pilot-animation-agent-skill`). It explains what was used,
maps every symbol to a file and line, and has recipes for changing the face, the body,
the geometry, the timing and the colours — plus a doctor that verifies one pose per
state, the frame size and the palette contrast:

```bash
python3 ~/Agent-Skills/watch-pilot-animation-agent-skill/scripts/anim-doctor.py --build
```

## The character instead of a Memoji

Animoji/Memoji cannot be rendered by third parties (private framework; no ARKit or
RealityKit on watchOS — see [`research/Q8-memoji-animoji.md`](research/Q8-memoji-animoji.md)),
so the avatar is a **T-800 endoskeleton skull** — and it is not drawn by hand: it is
**traced from the reference visor** (`design/reference/t800-visor.jpg`) so it matches
the mockup to the pixel (MAE 5.2 inside the skull, 1.4 % of pixels off by more than
45/255). The tracer (`scripts/design/trace-head.py`) emits 17 flat-metal layers plus
the silhouette into `T800HeadArt.swift`; the renderer (`T800Head.swift`) paints them
in *unit space* and animates:

* **pupils** — procedural, so they glow, dilate, look around and flicker out;
* **jaw** — the lower group (teeth, mandible, chin panels) drops into a black mouth
  cavity; pistons and cheek struts come from the same traced art;
* **head** — sweep (yaw with foreshortening), tilt, lean-in, nod on the syllables;
* **failure** — the head tears into 12 displaced slices while the chrome dims.

Every difference between states is a number in `AvatarPose` (eye glow/scale/look,
jaw, speech level, yaw, chrome, glitch); there is no `switch` in the drawing code.
The HUD around it (reticle ring, corner brackets, ruler ticks, scanner marks,
glyphs, Cyberdyne logo, dot-matrix waveform) is part of the same canvas.

The head's geometry, the measured grid and the **animation contract** (which signals
the functionality has to feed — mainly `speechLevel`, the real playback level) are
in [`design/t800-head.md`](design/t800-head.md).
[`design/t800-head.gif`](design/t800-head.gif) is a real recording of the simulator
talking; [`design/watchpilot-flow.gif`](design/watchpilot-flow.gif) is the older
end-to-end hub run.

## Motion

`TimelineView(.animation)` drives a `Canvas` at 30 Hz — no `Timer`, no per-frame
state change. Reduce Motion pauses the timeline, and the state is still legible
because colour and copy carry it. The jaw, the pupils and the dot-matrix waveform are the elements that
move with the voice (mic power while listening, speech cadence while answering);
everything else — the rotating ring, the scanning tick marks, the head sweep, the
jaw — breathes on slow, mutually non-multiple periods so the visor never loops
visibly.

## Why the whole visor is the button

Fitts's law says the biggest target should do the main thing — and the biggest
target is the screen itself. The HUD performs the state's action on tap, and the
footnote always says what a tap does right now ("toca para cancelar", "toca para
abrir a resposta completa"), so the affordance is copy, not chrome. In the `failed`
state a tap retries the pending task (or starts a new recording when none is
pending) — recovery is always one tap away.

## Screenshots

Rendered from the simulator with `scripts/screenshot-states.sh`:

| | | |
| --- | --- | --- |
| ![idle](design/screenshots/01-idle.png) | ![listening](design/screenshots/02-listening.png) | ![thinking](design/screenshots/03-thinking.png) |
| ![answer](design/screenshots/04-answer.png) | ![error](design/screenshots/05-error.png) | ![hub](design/screenshots/06-live-hub.png) |

Todas as imagens usam `-WPDemoPhase <estado>` para congelar o visor num estado;
a 06 é a prova de ligação ao hub por TOTP dentro do watchOS.
