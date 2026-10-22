# Setup

Everything needed to go from a clean Mac mini to a working watch, in the order that
fails less.

## 0. Prerequisites

```bash
xcodebuild -version          # Xcode 26+ (27.1 on the reference machine)
sw_vers                      # macOS 26+ (SpeechAnalyzer); 27.0 on the reference
brew install xcodegen        # generates the watch project
uv --version || brew install uv
```

An **OpenRouter key** (`sk-or-v1-…`) and, optionally, a **Cloudflare zone** you can
create tunnels in.

## 1. The hub on the Mac mini

```bash
scripts/install-hub.sh
```

That script:

1. creates `server/.venv` (Python 3.13) and installs FastAPI/uvicorn/httpx;
2. builds `server/bin/wtx-transcribe` (the `SpeechAnalyzer` CLI);
3. writes `~/.config/watch-pilot/env` (0600) with your OpenRouter key;
4. prints the port, model, transcription locale and the `otpauth://` pairing URI;
5. installs the LaunchDaemon (see §5);
6. optionally publishes the subdomain (`--publish`).

Start it in the foreground while debugging:

```bash
scripts/run-hub.sh
curl -s http://127.0.0.1:8765/__health
```

### Talk to it

```bash
# current TOTP code
server/.venv/bin/python scripts/wp.py totp

# synthesise a Portuguese voice command, upload it, poll and print
server/.venv/bin/python scripts/wp.py ask "que reuniões tenho amanhã?"

# the same over the public tunnel
server/.venv/bin/python scripts/wp.py --base https://watch.kluser.me ask "olá"
```

`wp ask` uses the `Joana` (pt-PT) voice when it exists — an English voice reading
Portuguese is transcribed as gibberish, which is a useful negative test but a bad demo.

## 2. Pair the watch

The watch and the hub share one base32 secret, generated on first hub start at
`~/.config/watch-pilot/totp.secret` (0600).

```bash
server/.venv/bin/python scripts/wp.py pair     # secret + otpauth URI + QR
```

Add it to **Google Authenticator** (or any TOTP app) if you also want to log in to the
browser dashboard. For the watch itself, provision the secret at build time:

```bash
scripts/install-app.sh --pair          # writes apps/watch/WatchPilot/Pairing.plist (0600, git-ignored)
```

On first launch the app copies it into the watch Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and the bundled file is ignored
thereafter. A watch that has no secret shows a **Emparelhar** button that opens a field
where you can paste the secret.

## 3. Build and run the watch app

### Simulator (no signing, no watch)

```bash
xcodebuild -downloadPlatform watchOS          # ~3.8 GB, once
xcrun simctl create "WatchPilot Demo" \
  com.apple.CoreSimulator.SimDeviceType.Apple-Watch-SE-3-44mm \
  com.apple.CoreSimulator.SimRuntime.watchOS-27-0

cd apps/watch && xcodegen generate
xcodebuild -scheme WatchPilot -sdk watchsimulator27.0 -configuration Debug \
  -destination 'id=<UDID>' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The app reaches the hub over `http://localhost:8765` in the simulator
(`WPHubSimulatorURL` in Info.plist).

```bash
scripts/screenshot-states.sh          # renders all six states into docs/design/screenshots
```

### Physical Apple Watch SE

1. Xcode → *Settings → Accounts* → add your Apple ID (creates a **Personal Team**).
2. On the iPhone: *Settings → Privacy & Security → Developer Mode → on*, reboot.
3. Same on the watch.
4. Connect the iPhone by USB, open `apps/watch/WatchPilot.xcodeproj`.
5. Target **WatchPilot** → *Signing & Capabilities* → check *Automatically manage
   signing*, pick your Personal Team, set a unique bundle id
   (`me.kluser.watchpilot` is taken by this repo's default).
6. Select the watch as the run destination and Run.

Notes that save time:

- Personal Team builds **expire after 7 days** and you can have at most 3 sideloaded
  apps. Re-run from Xcode to renew.
- The app builds **unsigned** for CI with `CODE_SIGNING_ALLOWED=NO`; a device needs a
  team.
- Microphone, background modes and ATS local networking are **Info.plist keys**, not
  entitlements. You only need an `.entitlements` file for HealthKit, App Groups,
  Keychain sharing or push.

## 4. Publish `https://watch.kluser.me`

```bash
scripts/publish.sh
```

Two details make machine clients work here, and both are handled by the script:

1. **`--no-gate`** — no `?key=` cookie gate; the hub has its own TOTP.
2. **The zone TOTP gate must exempt this host.** The kluser.me zone puts a TOTP form
   in front of every route, which answers **401 to every non-GET request** — an Apple
   Watch cannot fill that form. `scripts/exempt-host.py` adds the host to
   `exempt` in the zone's `auth.json` (backup kept, 0600, hot-reload in 500 ms).

The route is **ephemeral**: it does not survive a reboot, and a later
`domain.py up` may prune it. Re-run `scripts/publish.sh` if the edge returns 404 —
the watch and CLI retry automatically.

Verify:

```bash
curl -s https://watch.kluser.me/__health
server/.venv/bin/python scripts/wp.py --base https://watch.kluser.me status
```

## 5. Persistence on macOS 27

`/Volumes/Ext2TB` is denied to launchd jobs by TCC — even as root. Only a session
coming from `sshd-keygen-wrapper` has Full Disk Access. `scripts/install-launchd.sh`
therefore installs a **LaunchDaemon** that opens a localhost-only SSH session with a
`command=`-restricted key, whose wrapper runs uvicorn:

```
/Library/LaunchDaemons/com.watchpilot.hub.plist   → ssh -i ~/.ssh/watchpilot_hub_ed25519
                                                     forced command ~/.local/bin/watch-pilot-hub.sh
                                                     → server/.venv/bin/python -m uvicorn app.main:app
```

```bash
sudo launchctl print system/com.watchpilot.hub | grep -E "state|pid"
tail -f ~/.local/state/watchpilot/uvicorn.log
```

If you keep the project on the internal disk, a plain LaunchAgent is enough — the SSH
indirection is only about TCC on removable volumes.

The same daemon also starts a **route watchdog** that re-asserts `watch.kluser.me` at
boot and whenever the tunnel route disappears, so the subdomain comes back on its own.
Full architecture, measured timings and the port map: [`INFRA.md`](INFRA.md).

## 6. Notifications

### Free route ($0): iMessage relay

Set the phone number in `~/.config/watch-pilot/env`:

```
WATCHPILOT_NOTIFY_CHANNELS=local,log,imessage
WATCHPILOT_IMESSAGE_PHONE=+351...
```

Messages.app must be signed in **in a GUI session**. The first `osascript` call raises
the macOS Automation prompt; approve it once. Background launchd jobs cannot be granted
that permission, so a hub started from the daemon will have to fall back to `local` +
`log` until you approve the prompt in an interactive session.

### Paid route: direct APNs

Requires an Apple Developer Program membership (a Personal Team has **no**
`aps-environment` at all).

```
WATCHPILOT_APNS_BUNDLE_ID=me.kluser.watchpilot
WATCHPILOT_APNS_KEY_ID=ABC123DEFG
WATCHPILOT_APNS_TEAM_ID=ABCDE12345
WATCHPILOT_APNS_KEY_PATH=/path/to/AuthKey_ABC123DEFG.p8
WATCHPILOT_APNS_USE_SANDBOX=true
```

The watch registers its token with `POST /api/v1/register-device`. The hub mints an
ES256 provider token (cached 45 minutes, inside Apple's 20–60 minute window) and sends
`alert`/priority 10 or `background`/priority 5 — the priority rule is enforced by APNs,
not advisory.

## 7. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `403 Error 1010` from the edge | Cloudflare blocks the client signature (`Python-urllib`) | Use the CLI/wat ch client, which sends `WatchPilot/0.1` |
| `401` on every API call from the watch | Zone TOTP gate intercepting non-GET | `scripts/exempt-host.py <zone-dir> watch.kluser.me` |
| `404 Nada publicado` intermittently | Ephemeral route pruned by another `up` | Re-run `scripts/publish.sh`; clients retry |
| Transcription returns punctuation | Wrong locale (Mac UI language ≠ spoken language) | `WATCHPILOT_TRANSCRIBE_LOCALE=pt-PT` |
| `wtx-transcribe` exits 4 | Speech assets missing for that locale | `server/bin/wtx-transcribe --install-assets --locale pt-PT` |
| Model answers "não consegui falar com o modelo" | Missing/invalid OpenRouter key | `~/.config/watch-pilot/env`, then restart |
| Watch says "Código TOTP recusado (replay)" | Clock skew or a reused window | Wait for the next 30 s window; check both devices' clocks |
| App dies with `dealloced while running` | Extended session lost its owner | Only `RuntimeCoordinator` may create sessions (it is a singleton) |
| `Operation not permitted` reading `/Volumes` from a daemon | TCC removable-volume policy | Use the local-SSH LaunchDaemon (§5) |
| Simulator: "runtime not registered … symlink" | `~/Library/Developer/CoreSimulator` is a symlink | Replace the symlink with a real directory and reinstall the runtime |
