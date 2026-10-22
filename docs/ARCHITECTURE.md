# Architecture

How Watch Pilot is put together, why each boundary sits where it does, and which
assumptions from the original specification had to be replaced after testing against
the real SDKs.

## 1. Goals and non-goals

**Goals**

1. Speak a short command into an Apple Watch; get an answer back on the wrist.
2. Never send raw speech to a third party: transcription happens on hardware you own.
3. Survive the watchOS scheduler instead of pretending it does not exist.
4. Authenticate every request with something the watch can generate by itself.
5. Work at $0 of Apple licensing (sideload with a Personal Team), and get better if a
   paid membership exists.

**Non-goals**

- Being a general chatbot, or holding a long conversation on a 40 mm screen.
- Streaming partial transcripts back to the watch while the user is still speaking.
- Running on Android, the iPhone, or a cloud VPS.

## 2. Topology

```
┌───────────────────────────┐
│  watchOS app (standalone) │
│  WatchPilot.app           │
│                           │
│  VoiceRecorder ──► HAL    │  AVAudioRecorder · 16 kHz · mono · AAC
│  TotpGenerator ──► header │  RFC 6238 · SHA1 · 6 · 30 s
│  HubClient     ──► HTTPS  │  multipart upload + polling
│  RuntimeCoordinator       │  WKExtendedRuntimeSession · background refresh
│  AnimatedAssistantOrb     │  TimelineView + Canvas @30 Hz
└────────────┬──────────────┘
             │  POST /api/v1/assistant/audio        (X-Watch-TOTP)
             │  GET  /api/v1/assistant/progress/{id} (X-Watch-TOTP)
             ▼
┌───────────────────────────────────────────────────────────────┐
│  Mac mini M1 — FastAPI hub (:8765, loopback only)             │
│                                                               │
│  security.py    TOTP verify · monotonic replay guard · rate   │
│  transcribe.py  wtx-transcribe → yap → Shortcuts → mock       │
│  llm.py         OpenRouter · xiaomi/mimo-v2.6-pro · effort max│
│  tasks.py       task registry · progress · timings            │
│  notify.py      local · log · iMessage · APNs · webhook       │
│  web.py         TOTP login + dashboard (server-rendered)      │
└────────────┬──────────────────────────────────┬───────────────┘
             │ subprocess                       │ HTTPS/2
             ▼                                  ▼
   wtx-transcribe (Swift,              OpenRouter /chat/completions
   SpeechAnalyzer, on-device)          provider: deepinfra → xiaomi → novita
```

The hub binds **127.0.0.1 only**. Public reachability is a Cloudflare tunnel route,
never a listening socket on `0.0.0.0`.

## 3. Request lifecycle

A single voice command, with the measured timings from the reference machine:

| Step | Where | Time |
| --- | --- | --- |
| Record 6.4 s of speech | watch | 6 400 ms (real time) |
| `POST /assistant/audio` (39.8 KB m4a) | watch → hub | 120–900 ms |
| `wtx-transcribe` | Mac mini CPU/ANE | **230–344 ms** |
| `POST /chat/completions` | Mac mini → OpenRouter | 0.4 s TTFT, 7.6–11.9 s total |
| Poll to `completed` | watch → hub | 3 s cadence |
| Total | | **8–12 s** |

The HTTP handler returns `202` with the task record immediately; the pipeline runs in
an `asyncio` task, so the watch never holds a long request open. Progress only moves
when a real stage finishes (10 % → 45 % → 85 % → 100 %).

## 4. The watch app

### 4.1 State machine

`AssistantPhase` is the single source of truth for both the orb and the copy:

```
idle ──tap──► listening(power) ──tap──► uploading ──► waiting(progress, step) ──► answering(reply)
   ▲                                            │                                   │
   └──────────────── failed(message) ◄──────────┴───────────────────────────────────┘
```

Every state carries what the UI needs to say something true: the normalised input
power while recording, the percentage and the current step while the hub works, the
answer itself when it lands.

### 4.2 Recording

`AVAudioRecorder` with `kAudioFormatMPEG4AAC`, 16 kHz, mono, 48 kbit/s. The file lands
in `Documents/InProgress/` rather than `tmp/`, because watchOS may unlink a temporary
descriptor when a recording is interrupted and the audio is still needed afterwards.
Old takes are pruned on launch. Metering (`updateMeters()` +
`averagePower(forChannel:)`) feeds the orb at ~30 Hz from a `Task` loop, not a `Timer`.

### 4.3 TOTP on the wrist

`TotpGenerator` implements RFC 6238 with CryptoKit's `HMAC<Insecure.SHA1>` — no
third-party dependency. A fresh code is generated for **every** request
(`X-Watch-TOTP`), so the shared secret is never transmitted after pairing. The secret
lives in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
(readable when the wrist is down, never migrated off the device). For unsigned
development builds the Keychain can be unavailable, so `SecretStore` falls back to a
bundled `Pairing.plist` (git-ignored) and then `UserDefaults`, and reports which
source it used.

### 4.4 Runtime contracts — what is real

This is the part where the original specification needed surgery.

| Mechanism | What it actually gives you |
| --- | --- |
| Foreground polling | A real 3-second loop, as long as the app is on screen |
| `WKExtendedRuntimeSession` (`physical-therapy`) | Up to **1 hour** past screen-off, but only *seconds* of CPU per wake |
| Background `URLSession` | A separate process that finishes the transfer even if the app is purged; ~4 wake-ups/hour |
| `scheduleBackgroundRefresh` / `.backgroundTask(.appRefresh)` | A few seconds of runtime, budgeted by the scheduler (~4/hour, and only with a complication on the active face) |
| Local `UNUserNotification` | Works; posted by the app when it learns the answer |
| Silent push | Exactly 30 s of execution, 2–3 per hour, no delivery guarantee; requires a paid membership |

Consequences baked into the code:

- Polling **stops honestly** when the app is suspended. Nothing pretends otherwise.
- The extended session is started while the app is frontmost (watchOS refuses
  otherwise: `MustBeActiveToStartOrSchedule`) and is owned by a singleton, because a
  session that loses its last strong reference logs
  `WKExtendedRuntimeObject was dealloced while running` and dies.
- Completion is delivered as a **local notification** plus a haptic the moment the
  task settles; the hub additionally fans out an iMessage (zero cost) or an APNs alert
  (paid) so the wrist hears about it with the app suspended.
- Only **one** extended-session type is allowed per app, and `physical-therapy` is the
  only one that grants an hour in the background. It is declared in `WKBackgroundModes`
  because this is a personal, sideloaded app; a public App Store release would have to
  revisit that choice against App Review.

### 4.5 The orb

`TimelineView(.animation)` + `Canvas`, no `Timer`, no state churn. One continuous
glow, a sphere body with a top-left light, a rim stroke and a pulsing core. Listening
adds 20 radial voice bars, waiting adds a progress ring, uploading adds three orbiting
sparks. Reduce Motion pauses the timeline.

## 5. The hub

### 5.1 Authentication

`X-Watch-TOTP` (or `?totp=`) on every `/api/*` request; the browser gets a signed
`wp_session` cookie after posting the same kind of code to `/__totp__`.

The replay guard is **monotonic with a bounded reuse**: a counter older than the last
accepted one is refused (a sniffed code dies as soon as the watch moves on), while the
current counter may be reused up to 24 times so that polling every three seconds does
not need a new code per request. Watch and browser keep separate cursors so they never
starve each other. Five failures in 300 s block the client for the window.

Codes are validated before any comparison that could throw: `isascii()` first, because
`str.isdigit()` accepts full-width digits and `hmac.compare_digest` refuses non-ASCII —
that pair used to be a remote 500.

### 5.2 Transcription

`wtx-transcribe` (~90 KB of Swift, built with `swiftc -O -parse-as-library`) drives
`SpeechAnalyzer` + `SpeechTranscriber`, prints the transcript (or JSON with segment
timestamps) and exits. It runs from a bare binary: no app bundle, no `Info.plist`, no
TCC prompt. Fallbacks in order: `yap` (Homebrew, same framework), a Shortcuts action,
and — only when explicitly enabled — a mock stub that keeps the demo alive on a
machine without speech assets.

The locale is forced (`pt-PT` by default) rather than inherited: the Mac's UI language
is English, and `Locale.current` mis-detected the language and returned punctuation
instead of words.

### 5.3 Reasoning

`POST https://openrouter.ai/api/v1/chat/completions` with:

```json
{
  "model": "xiaomi/mimo-v2.6-pro",
  "models": ["xiaomi/mimo-v2.6-pro", "xiaomi/mimo-v2.5-pro", "xiaomi/mimo-v2.6-flash"],
  "reasoning": {"effort": "max"},
  "provider": {
    "order": ["deepinfra/fp8", "xiaomi/fp8", "novita/fp8"],
    "quantizations": ["fp8"],
    "preferred_max_latency": {"p50": 5, "p90": 15},
    "allow_fallbacks": true
  }
}
```

`effort` is kept for forward compatibility but is **not forwarded** by OpenRouter (the
provider sees `reasoning: {"enabled": true}` regardless of `max` or `minimal`), so the
system prompt carries the depth instruction. `streamlake` is excluded: 9.3 % uptime.
Transient failures (408/429/5xx) retry with exponential backoff honouring
`Retry-After`; 4xx does not retry.

### 5.4 Notification fan-out

`POST /api/v1/notify` and the task pipeline both go through `notify.py`, which records
every notification in the inbox (`/api/v1/inbox`, plus `notifications.jsonl`) and
dispatches to the configured channels:

- `log` — always safe.
- `local` — `osascript display notification` on the Mac.
- `imessage` — Messages.app via AppleScript, to the iPhone number, which mirrors to the
  watch. Service is discovered at runtime (`1st service whose service type = iMessage`)
  and the recipient travels in `argv`, avoiding the "can't send a message to yourself"
  trap. Needs a GUI session: launchd jobs in the background cannot be granted the TCC
  Automation permission.
- `apns` — HTTP/2 to Apple with a `.p8` ES256 provider token cached for 45 minutes
  (Apple's window is 20–60 minutes), `apns-push-type: alert` with priority 10, or
  `background` with priority 5. Invalid tokens (`400`/`410`) are dropped automatically.
- `webhook` — JSON POST anywhere.

## 6. Security model

| Threat | Mitigation |
| --- | --- |
| Someone finds `watch.kluser.me` | Every route needs a valid TOTP; the unauthenticated surface is `/__health` |
| Replay of a captured code | Monotonic counter, bounded per-window reuse, per-key cursors |
| Brute force | 5 failures / 300 s → 429 for the window |
| Secret exfiltration from the watch | Keychain, `ThisDeviceOnly`, never leaves the device; `/pair` is loopback-only |
| Hub exposed to the LAN | Binds `127.0.0.1`; reachability is the tunnel only |
| Cloudflare bot fight blocking clients | Clients identify themselves; only `Python-urllib` is refused by the edge |
| Prompt injection in a transcript | The transcript is a *user* message with a fixed system prompt; it cannot grant tools, because there are no tools |
| Secrets in the repo | `.gitignore` covers `.env`, `*.p8`, `Pairing.plist`; CI runs a secret scan |

There is no tool execution. The model returns text; nothing it says is executed on the
Mac. That is a deliberate scope limit: it removes the entire class of "the LLM ran
`rm -rf`" failures.

## 7. Operations on macOS 27

Two platform traps shape the deployment:

1. **TCC vs removable volumes.** A launchd job — even as root — gets
   `Operation not permitted` under `/Volumes/Ext2TB`. Only a session from
   `sshd-keygen-wrapper` has Full Disk Access. So the daemon starts a
   localhost-only, forced-command SSH session that runs uvicorn
   (`scripts/install-launchd.sh`).
2. **Ephemeral tunnel routes.** The zone router prunes routes that do not belong to the
   current boot, and the Mac's own watchdog re-runs `up --name mac` periodically, which
   can drop the watch route and its CNAME. Clients therefore retry on transient 404/502,
   and `scripts/publish.sh` re-asserts the route.

## 8. What changed from the original specification

| Original claim | Reality | What the implementation does |
| --- | --- | --- |
| Poll every 3 s for up to an hour with the wrist down | The app is suspended when the wrist goes down; background tasks get seconds | Foreground polling + notification-driven completion + background refresh hints |
| `self-care` gives 10 min and `physical-therapy` 1 h, either can be used | Only one extended-session type per app; `physical-therapy` is the only 1 h background window and is purpose-bound | One declared type, documented trade-off |
| `SFSpeechRecognizer` exists on watchOS with a 1-minute limit | The watchOS 27 SDK ships **no** Speech.framework at all | The watch only records; the Mac mini transcribes |
| APNs push is required for timely delivery | A Personal Team has no `aps-environment` at all | iMessage relay as the $0 path; APNs as an opt-in paid path |
| A background task runs the polling loop | `.backgroundTask(.appRefresh)` gets seconds, budgeted | Used only to read state once, never as a timer |
| `reasoning.effort = "max"` forces deep thinking | Accepted but collapsed to a boolean before the provider | Depth instruction in the system prompt; `effort` kept for compatibility |

Each of these is backed by a file in [`research/`](research/) with the source and the
confidence level.
