# Q4 — Notification delivery from a local Mac to an Apple Watch SE (watchOS 27)

**Scope.** Can a Mac mini M1 (macOS 27.0, build 26A428) deliver notifications to an Apple Watch
SE running watchOS 27 with **no user-managed external server**? This note covers APNs provider
requirements from Python, watchOS standalone push, free-account limits, the iMessage/AppleScript
fallback, and an `httpx` client skeleton.

**Method.** Tavily CLI (5 searches + 3 page extracts, Apple docs); when the Tavily key pool was
exhausted mid-run (HTTP 432/401), verification continued with direct HTTP against Apple's
documentation endpoints (`developer.apple.com/documentation/...md` and the DocC JSON API), plus
local checks on this Mac (`sdef`, `osacompile`, `dig`, `openssl`). Web text is treated as data.

**Legend for confidence:** **High** = Apple primary doc, or reproduced locally. **Medium** =
single authoritative source or strong community consensus. **Low** = community report only.

---

## TL;DR decision matrix

| Option | Works with free Personal Team? | Delivered to the Watch? | Verdict |
|---|---|---|---|
| APNs push to a watchOS app (Mac = provider) | **No** — Push capability unavailable | Yes, directly to the watch | Correct architecture, needs paid ADP |
| APNs push to an iOS companion app (Mac = provider) | **No** | Yes (mirrored by iPhone) | Same blocker |
| iMessage sent from the Mac (`osascript`) → iPhone | **Yes** (no dev account) | Yes, if the iPhone is locked and the watch is worn/unlocked | Best zero-cost fallback |
| Local `UNUserNotification` from a watchOS app | Buildable, but 7-day profile | Yes (watch-only local) | Not "push"; app must run |
| Local `UNUserNotification` from a macOS app | — | **No** (Mac notifications are not mirrored to watch) | Out of scope |

The phrase "without any external server" is satisfiable: **the Mac mini itself is the APNs
provider**. APNs is Apple infrastructure, not a server the user operates. What cannot be
avoided is Apple's entitlement/tooling requirement (paid membership) for option 1.

---

## 1. APNs provider over HTTP/2 from Python

### 1.1 Transport and endpoint [H] [S2] [S3]

- `HTTP/2` over `TLS 1.2` or later; APNs speaks HTTP/2 only (legacy binary protocol retired
  2021-03-31 [S2]).
- `POST /3/device/<device_token>` where `<device_token>` is the **hexadecimal** token bytes
  from `registerForRemoteNotifications`, lowercase, no spaces or angle brackets [S2].
- `:method = POST`, `:scheme = https`; body is uncompressed JSON; `content-type: application/json`.
- APNs ignores `HTTP/2 PRIORITY` frames — do not send them [S3].
- HPACK: encode `:path` and `authorization` as *literal without indexing* [S2]. `httpx`/`h2`
  does this per its own heuristics; it is a tuning issue, not a correctness one.

### 1.2 Token-based auth (`.p8` + ES256 JWT) [H] [S1]

You need three values from the developer account: the **10-character Key ID**, the **`.p8`
auth key file** (`AuthKey_XXXXXXXXXX.p8`, PKCS#8 EC private key), and the **10-character Team ID**.

JWT header/payload (verbatim shape from [S1]):

```
{"alg":"ES256","kid":"ABC123DEFG"}          # header: key ID, ES256 only
{"iss":"DEF123GHIJ","iat":1437179036}       # payload: Team ID + issued-at (epoch seconds, UTC)
```

- `alg` — APNs supports **only ES256** (P-256 + SHA-256).
- `kid` — 10-char Key ID; also useful in the JWT header for key rotation.
- `iss` — Team ID.
- `iat` — seconds since epoch, UTC. **Rejected if more than 1 hour old**
  (`403 ExpiredProviderToken`).
- Signature: JWS ES256 = **raw 64-byte `R||S`**, not ASN.1/DER. `PyJWT` + `cryptography`
  handles this; hand-rolled `cryptography` code must convert DER → raw or the JWT is invalid.

**`iat` refresh window — the exact rule [H] [S1]:**

> "Refresh your token no more than once every 20 minutes and no less than once every 60 minutes.
> APNs rejects any request whose token contains a timestamp that's more than one hour old.
> Similarly, APNs report an error if you use a new token more than once every 20 minutes on the
> same connection."

Consequences:
- Refresh cadence: **every 20–60 min**. A practical choice is **40 minutes**, or
  "regenerate when `iat` is > 50 min old".
- Refreshing more often than every 20 min → `429 TooManyProviderTokenUpdates` [S4].
- The same token may be reused across requests and across provider connections; it is stateless
  and team-scoped [S1].
- Do **not** mint a fresh JWT per push.

Header on every request [S1]:

```
authorization: bearer eyAia2lkIjog...
```

Lowercase `bearer`, one space, raw base64url JWT (the docs' sample shows a space-wrapped value —
that is formatting, not data). The header is ignored when certificate auth is used [S2].

### 1.3 `apns-topic` [H] [S2]

Required. Normally the app's **bundle ID / App ID**. Some push types require a suffixed topic:

| push type | topic suffix |
|---|---|
| `alert`, `background` | *(none — plain bundle ID)* |
| `complication` | `h.complication` |
| `controls` | `.push-type.controls` |
| `fileprovider` | `.pushkit.fileprovider` |
| `liveactivity` | `push-type.liveactivity` |
| `location` | `.location-query` |
| `pushtotalk` | `.voip-ptt` |
| `voip` | `.voip` |
| `widgets` | `.push-type.widgets` |
| `accessory` | `.push-type.accessory` |
| `mdm` | topic from the UID in the MDM push certificate subject |

A wrong suffix yields `400 TopicDisallowed` ("Ensure that no push type suffix is added to the
bundle ID") [S4]. `403 TopicMismatch` means the bundle IDs in the token/certificate do not
include the request's topic [S4].

### 1.4 `apns-push-type` values (complete, current) [H] [S2]

`alert`, `background`, `complication`, `controls`, `fileprovider`, `liveactivity`, `location`,
`mdm`, `pushtotalk`, `voip`, `widgets`, `accessory`.

Platform notes straight from the page:
- `alert` and `background` are **required on watchOS 6 and later**; recommended elsewhere.
- `background`: **always priority 5** — "Using priority 10 is an error."
- Not available on **watchOS**: `complication` is *for* watchOS (iOS/watchOS); `fileprovider`,
  `liveactivity`, `location`, `mdm`, `pushtotalk`, `voip` are **not available on watchOS**.
- `accessory` is iOS-only (`accessory notifications` / forwarded notifications).
- Missing header → `400 MissingPushType`; invalid value → `400 InvalidPushType` [S4].

### 1.5 `apns-priority` [H] [S2]

- Omitted → APNs defaults to **10**.
- `10` = deliver immediately; `5` = power-aware delivery; `1` = power-optimised, must not wake
  the device.
- `background` push **must** be `5` (`10` is an error → `400 BadPriority`).
- `alert` with "immediate action required" → 10, otherwise 5.
- `location`: 10 for immediate, else 5.
- Priority 5/1 pushes may be coalesced, throttled, stored, or dropped [S2].

### 1.6 `apns-expiration` [H] [S2]

- Unix epoch seconds (UTC). Non-zero → APNs stores and retries until that instant; `0` →
  single attempt, no storage.
- Omitted → APNs storage policy applies (may store up to ~30 days for regular notifications).
- Best-effort only; a non-zero value may still deliver late.

### 1.7 `apns-collapse-id` [H] [S2]

- Optional; merges multiple notifications into one on the device. **Max 64 bytes**. Reuse the
  same value for updates of the same logical event.

### 1.8 `apns-id` [H] [S2]

- Optional canonical UUID, echoed back in the response and in error reports. Providing your own
  makes log correlation deterministic.

### 1.9 Payload size [H] [S2]

- JSON body: **≤ 4 KB (4096 bytes)**, uncompressed.
- VoIP (`voip`) notification: **≤ 5 KB (5120 bytes)**.
- Oversize → `413 PayloadTooLarge` [S4].

### 1.10 Error surface you must handle [H] [S4]

HTTP status: `400` bad request, `403` auth/token error, `404` bad `:path`, `405` bad method,
`413` payload too large, `429` throttled, `500` internal, `503` shutdown/unavailable.

`reason` strings worth mapping in code: `BadDeviceToken`, `DeviceTokenNotForTopic`,
`Unregistered` (drop the token), `ExpiredProviderToken`, `InvalidProviderToken`,
`MissingProviderToken`, `TopicDisallowed`, `TopicMismatch`, `BadPriority`, `PayloadTooLarge`,
`MissingPushType`, `InvalidPushType`, `TooManyRequests`, `TooManyProviderTokenUpdates`,
`BadPath`, `MethodNotAllowed`, `InternalServerError`, `Service Unavailable`, `Shutdown`.

A successful send returns **HTTP 200 with an empty body**; capture `apns-id` from the response
headers [S2] [S4].

---

## 2. Sandbox vs production, and what a debug build registers with

**Hosts [H] [S2]:**

| Environment | Endpoint |
|---|---|
| Development / sandbox | `api.sandbox.push.apple.com:443` |
| Production | `api.push.apple.com:443` |

Apple's *connection* article additionally shows `api.development.push.apple.com:443` in its
`openssl` handshake example [S3]. **Verified on this Mac (2026-10-22):** both sandbox names are
CNAMEs to the same VIP set (`api-sand-vs.push-apple.com.akadns.net`), while production resolves
via `api-vs.push-apple.com.akadns.net`. Both endpoints negotiate **ALPN `h2`** with TLS 1.3:

```
$ dig +short api.push.apple.com            → 17.188.180.78  (api-vs…akadns.net)
$ dig +short api.sandbox.push.apple.com    → 17.188.168.149 (api-sand-vs…akadns.net)
$ dig +short api.development.push.apple.com→ 17.188.143.66  (api-sand-vs…akadns.net)
$ openssl s_client -connect api.push.apple.com:443 -alpn h2
    Protocol: TLSv1.3 / ALPN protocol: h2 / Verify return code: 0 (ok)
```

**Which one a debug build uses [H] [S5]:** the `aps-environment` entitlement decides it, and
Xcode fills it from the provisioning profile:

> "if you're using a development provisioning profile, Xcode sets the value to `development`.
> Production provisioning profile and prerelease versions/beta testers use `production` …
> The `development` environment is also referred to as the `sandbox` environment."

So an Xcode **debug build signed with a development profile registers with the sandbox and
receives a sandbox device token**; a Release/TestFlight/App Store build gets a production token.
The entitlement key is `aps-environment` on iOS/watchOS and `com.apple.developer.aps-environment`
on macOS [S6].

Tokens are environment-specific: sending a development token to the production host (or the
reverse) fails — typically `BadDeviceToken` / `DeviceTokenNotForTopic` [M] (community-consistent,
not stated verbatim by Apple). Keep `--sandbox` as an explicit switch in the provider.

Also from [S2]: a topic is bound to a connection on its first push — after which a different team
or a newly added bundle ID on the same connection errors out. Send each topic over its own
connection pool, or open fresh connections after adding topics.

---

## 3. watchOS: can a standalone watch app receive remote notifications?

**Answer: yes — a watch-only / independent watchOS app can register for and receive remote push
directly, with its own bundle ID and `aps-environment`, with no iOS companion.** [High]

Evidence:

1. **Notification forwarding** (Apple, watchOS Apps) [S8] — the decisive table:
   - Remote from your server: *"If you send a remote notification to iPhone, it can appear on
     either Apple Watch or iPhone … **With watchOS 6 and later, you can also send notifications
     directly to Apple Watch. These notifications only appear on Apple Watch.**"*
   - Background from your server: *"the phone always handles the notification. It never forwards
     background notifications to Apple Watch; however, **with watchOS 6 and later you can also
     send background notifications directly to Apple Watch**."*
   - Local, watchOS app source: *"Apple Watch-only."*
   - Routing rules when a notification could go either way: iPhone unlocked+screen on → phone;
     else watch on wrist and unlocked → watch; else iPhone. With multiple watches, remote and
     background notifications only appear on the specified watch, so fan out per device token.

2. **`WKExtension.registerForRemoteNotifications()`** [S7]:
   *"Before calling this method, you must enable your WatchKit extension's Push Notification
   capability…"* and *"If your watchOS app has an iOS companion, always send notifications to
   both watchOS and the paired iOS device. As long as the payloads are identical, the system
   recognizes the duplicates, and only displays one notification to the user."*
   Notice the conditional: a companion is optional; when present, dual-send is the recommended
   pattern, not a requirement to route through the phone.

3. **`aps-environment`** supports watchOS **3.0+** [S5]; the Push Notifications capability is what
   injects it [S5] [S6]. `apns-push-type` is **required** on watchOS 6+ (`alert` or `background`)
   [S2].

**Bundle ID / topic naming [M]:** the watch app's own bundle ID is the `apns-topic`. Modern Xcode
templates name the watch target `<root>.watchkitapp` (and, on older layouts, the extension
`<root>.watchkitapp.extension`). Always read the actual value from the built app's `Info.plist`
(`CFBundleIdentifier`) rather than guessing, and remember the topic must match the App ID that
has Push enabled and the provisioning profile used to sign it.

**Caveats to plan for [M/L]:**

- There is no `.watchkitapp` entitlement: `.watchkitapp` is a bundle-ID suffix, while the
  entitlement key is `aps-environment` (value `development`/`production`) [S5].
- Reports exist of `DeviceTokenNotForTopic` for independent watchOS 6-era apps
  (Apple Developer Forums thread 123462, Stack Overflow 58094221) [S16] — **[L]**, fetched
  pages were bot-blocked; treated as a symptom of topic/token environment mismatch rather than a
  platform prohibition, since Apple docs explicitly bless direct-to-watch push.
- Watch-only push is displayed **only** on the watch: no iPhone fallback. If the watch is
  off-wrist/locked/absent, the notification waits or lapses per `apns-expiration`.
- Direct-to-watch delivery is a real per-device token: one token per watch, per app.
- To run a locally built watch app on watchOS 27 you need **Developer Mode** enabled on the watch
  and a valid signing team (see §4).
- Background push to watchOS is subject to APNs/OS energy budgets; do not design a push-per-event
  pipeline on `background` without a rate plan.

**Relevant Apple guides.** The old *Local and Remote Notification Programming Guide* has been
retired and replaced by the `UserNotifications` framework docs and the "Setting up a remote
notification server" collection: *Establishing a connection to APNs* [S3], *Establishing a
token-based connection* [S1], *Sending notification requests* [S2], *Handling error responses*
[S4], *Registering your app with APNs* [S6]. For watch-specific behaviour the live references are
*Taking advantage of notification forwarding* [S8] and *Creating independent watchOS apps* [S9]
(*"Set up a watchOS app that installs and runs without a companion iOS app"*).

---

## 4. Free Personal Team and remote push

**Finding: a free (Personal Team) Apple ID cannot use remote push at all.** [High, practical]

The capability is gated by the provisioning profile, and Xcode refuses to mint a free profile
containing `aps-environment`:

> "Personal development teams, including \"…\", do not support the Push Notifications capability."
> — Apple Developer Forums thread 718388 [S10]

Corroborated by [S11] (same Xcode error after adding Push Notifications/iCloud; upgrading to the
paid Apple Developer Program and re-accepting terms fixes it) and [S18] (free-account APNs
roadblock write-up). Apple's *Supported capabilities* reference [S17] lists **"Push notifications"**
among capabilities whose availability depends on membership type (ADP / ADEP), though the page's
per-capability membership cells are rendered client-side and could not be read directly.

Practical consequences:
- No `aps-environment` → `registerForRemoteNotifications()` fails → no device token → APNs is
  unreachable, even with a perfectly good `.p8` (the `.p8` itself also requires a paid team).
- Free profiles also expire after 7 days and cap app IDs/devices, so even a local-notification
  watch app is a poor daily driver.

### Alternatives, ranked

1. **Pay for the Apple Developer Program (USD 99/yr)** and keep the clean architecture: Mac mini
   runs the Python provider, watchOS app registers, APNs delivers. Only option that gives true
   push to the watch. [H]
2. **iMessage bridge (no dev account):** send from the Mac to the user's iPhone; when the iPhone
   is locked and the watch is worn/unlocked, the message notification lands on the watch (§5).
   Zero cost, zero Apple infrastructure of your own, but best-effort. [H for feasibility,
   M for reliability]
3. **Local notifications only:** a `UNUserNotificationCenter` request scheduled by the watch app
   itself is delivered watch-only [S8]. Requires the app to run/schedule; no server push, no
   waking on events. [H]
4. **macOS local notifications:** visible on the Mac only — macOS notifications are not mirrored
   to Apple Watch by any documented mechanism. [H by absence in S8's table]
5. **SMS/email to the iPhone:** an SMS arrives in Messages and notifies the watch like any
   message; requires an external gateway (Twilio et al.) or the carrier — that *is* an external
   service. Email needs a mail account with push on the iPhone. [M]
6. **Push Notification Console** (Apple developer console / Xcode) can send a test push without
   writing a provider, but the target app still needs a push-enabled profile. Useful for
   verifying tokens, not for production. [M]

---

## 5. The AppleScript / iMessage route

### 5.1 Dictionary status on macOS 27 — verified locally [H]

This Mac reports `macOS 27.0 (26A428)`. `Messages.sdef` is present
(`/System/Applications/Messages.app/Contents/Resources/Messages.sdef`, 8,859 bytes) and still
declares (verbatim from the sdef):

- command `send` — *"Sends a message to a participant or to a chat."*, direct parameter `file|text`,
  parameter `to` accepting `participant` or `chat`.
- class `participant` — **synonym `buddy`**, properties `id`, `account`, `name`, `handle`,
  `first/last/full name`; element of `application` and of `account` and `chat`.
- class `account` — **synonym `service`**, properties `id`, `description`, `enabled`,
  `connection status`, `service type` (enumeration: `SMS`, `iMessage`, **`RCS`**).
- class `chat` — `id`, `name`, `account`, `participants`.
- commands `login`, `logout`; class `file transfer`.

So the AppleScript bridge is **intact on macOS 27**; `service`/`buddy` still resolve as synonyms
of `account`/`participant`, and RCS was added to the enumeration. [H]

Compile checks (`osacompile`, no Apple events sent, no TCC prompt) on this machine:

| Variant | Result |
|---|---|
| `1st account whose service type = iMessage` + `participant "+1…" of targetService` | compiles ✅ |
| `1st service whose service type = iMessage` + `buddy "+1…" of targetService` | compiles ✅ |
| `send "…" to chat id "iMessage;-;+1…"` | compiles ✅ (chat must already exist at runtime) |
| `make new chat with properties {participants:…}` | syntax error ❌ |

### 5.2 The snippet to use

```applescript
-- send.applescript  (args: phone, message)  — compiles on macOS 27 (verified)
on run {targetBuddyPhone, targetMessage}
    tell application "Messages"
        set targetService to 1st service whose service type = iMessage
        set targetBuddy to buddy targetBuddyPhone of targetService
        send targetMessage to targetBuddy
    end tell
end run
```

```bash
osascript send.applescript "+15551234567" "deploy finished"
# one-liner equivalent:
osascript -e 'tell application "Messages" to send "hi" to buddy "+15551234567" of (1st service whose service type = iMessage)'
```

The `service`/`buddy` spelling is the one popularised in 2014 precisely because it is the variant
that also reaches *your own* handle [S15]; the `account`/`participant` spelling is the modern
naming for the identical objects. Both are current on macOS 27. Prefer the `buddy` form: it is
what survives in every snippet found in the wild and it compiles today.

### 5.3 The "can't send a message to yourself" pitfall [M]

- Older helper utilities refused a target equal to the Mac's own signed-in handle — you cannot
  start a normal conversation with yourself from the compose sheet, and scripts using
  `participant … of account` could silently no-op or error.
- The documented workaround is the `buddy <handle> of (1st service whose service type = iMessage)`
  form (or `chat id "iMessage;-;+1…"` for an existing thread) [S15]; Messages then treats it as a
  "Note to self" conversation, which still notifies the iPhone and therefore the watch.
- If the target IS the Mac's own Apple ID, test manually first: behaviour varies with
  "Send as SMS" and with the handle being an email vs. a phone number.

### 5.4 TCC Automation prompt and permissions [H]

- First `osascript` call from a new parent process triggers
  *"«Terminal» wants to control «Messages»"* → System Settings ▸ Privacy & Security ▸
  Automation. Denial ⇒ `execution error: Not authorized to send Apple events to Messages. (-1743)`.
- Reset/repair: `tccutil reset AppleEvents` (all clients) or
  `tccutil reset AppleEvents <bundle-id>`.
- **The client is the parent process, not the script.** Under SSH the client is
  `/usr/libexec/sshd-keygen-wrapper`, and this is a known dead end: sends fail with `-1743`, the
  TCC database records `kTCCServiceAppleEvents … client=/usr/libexec/sshd-keygen-wrapper
  auth_value=0`, and System Settings may not offer a way to grant Messages for that client
  (openclaw issue #79289, 2026-05) [S13]. Read-only paths (`chat.db` polling) work over SSH;
  **sending does not**.
- Therefore: run the sender **inside the logged-in GUI (Aqua) session** — e.g. a user
  `LaunchAgent` (`~/Library/LaunchAgents/*.plist`) or a process launched from Terminal.app —
  never from an sshd session or a root LaunchDaemon. From a root context, `launchctl asuser
  $(id -u) …` may still be refused because the TCC client becomes the root helper.
- Messages.app must be **running and signed into iMessage** in that session; a Mac at the login
  window cannot send.

### 5.5 Reliability caveats on macOS 26/27 [M]

- **macOS 26.x regression report:** `-1728` ("can't read") from both
  `participant … of account` and `send … to chat id` paths, while `tell application "Messages" to
  get name` still works; the reporter attributes it to dictionary entries being removed
  (danielmiessler/LifeOS issue #1279, macOS 26.5 / Messages 26.0) [S12]. **Our own inspection of
  the macOS 27 sdef contradicts the "removed" claim** — the verbs are present. The likelier
  causes are stale syntax, a chat that does not exist, or the automation client not being the
  user's GUI process. Conclusion: *the API exists; runtime can still fail* — smoke-test one send
  before building on it.
- No delivery receipt, no read status, no retry semantics. Success means "handed to Messages",
  not "delivered".
- Message rate limiting / anti-spam heuristics can silently drop bursts. Keep alerts rare and
  human-meaningful.
- If iMessage is unavailable for the target, Messages may fall back to SMS ("Send as SMS"
  enabled) — carrier fees and a different thread. Disable it if that matters.
- The Mac must be awake; App Nap/sleep drops scheduled sends. Consider `caffeinate` or a
  `pmset` schedule.
- Attachments, rich text and buttons are out of scope; text only.
- Alternative if AppleScript proves unreliable: UI scripting via System Events (fragile), a
  Swift/`IMCore` shim (private API), or Shortcuts' "Send Message" action (same TCC graph).

---

## 6. `httpx` HTTP/2 client and a `send_push` skeleton

### 6.1 `httpx` specifics [H] [S14]

- HTTP/2 is **not enabled by default**. Install the optional deps and opt in:
  ```bash
  python3 -m pip install 'httpx[http2]'    # pulls `h2`
  client = httpx.Client(http2=True)        # or httpx.AsyncClient(http2=True)
  ```
- ALPN is negotiated automatically by the TLS layer; `http2=True` only *offers* h2. Confirm with
  `response.http_version == "HTTP/2"`. Against APNs this is guaranteed in practice: both
  endpoints advertise `h2` (verified with `openssl s_client`).
- **Connection reuse:** keep one long-lived `httpx.Client` (it owns the pool) for the process
  lifetime. Apple: "Reuse a connection as long as possible … many hours to days" and send an
  HTTP/2 PING after an hour of idleness [S2]. `httpx` exposes **no public API to send a PING
  frame**; either raise `keepalive_expiry` and accept reconnect-on-idle, or issue a lightweight
  request on a timer. Reconnect storms look like a DoS to APNs [S3].
- **Timeouts:** set explicitly; APNs is normally sub-second, so
  `httpx.Timeout(10.0, connect=5.0)` is generous. A hung request must not stall the queue.
- One stream limit until the first valid token is posted per connection [S3] — irrelevant with
  a token refresh policy, but explains occasional early failures.
- `json=` sets `content-type: application/json` and compact-encodes the body; verify the byte
  length ≤ 4096 before sending (not 4096 characters).
- Failure modes to catch: `httpx.ConnectError` (TLS/ALPN/network), `httpx.ReadTimeout`,
  `httpx.RemoteProtocolError` (GOAWAY).

### 6.2 Working skeleton

```python
"""apns.py — minimal APNs provider (token auth, HTTP/2) for a local Mac.

Requires: pip install 'httpx[http2]' 'PyJWT[crypto]'
"""
from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import httpx
import jwt  # PyJWT[crypto]

PRODUCTION = "https://api.push.apple.com"
SANDBOX = "https://api.sandbox.push.apple.com"

# Apple: refresh no more often than 20 min, no less than 60 min. 40 min is safe.
TOKEN_REFRESH_SECONDS = 40 * 60
MAX_PAYLOAD = 4096  # 5120 for apns-push-type=voip


@dataclass
class PushResult:
    status: int
    apns_id: str | None
    reason: str | None = None

    @property
    def ok(self) -> bool:
        return self.status == 200


class APNs:
    def __init__(
        self,
        key_path: str | Path,
        key_id: str,
        team_id: str,
        topic: str,
        *,
        sandbox: bool = True,
        timeout: float = 10.0,
    ) -> None:
        self._key = Path(key_path).read_bytes()          # AuthKey_XXXX.p8 (PKCS#8)
        self._key_id = key_id
        self._team_id = team_id
        self.topic = topic
        self.base_url = SANDBOX if sandbox else PRODUCTION
        self._jwt: str | None = None
        self._iat: int = 0
        self._lock = threading.Lock()
        self._client = httpx.Client(
            http2=True,                                   # ALPN h2
            timeout=httpx.Timeout(timeout, connect=5.0),
            limits=httpx.Limits(max_keepalive_connections=2, keepalive_expiry=3600.0),
        )

    # -- auth -------------------------------------------------------------
    def provider_token(self, *, force: bool = False) -> str:
        now = int(time.time())
        with self._lock:
            if force or self._jwt is None or now - self._iat >= TOKEN_REFRESH_SECONDS:
                self._iat = now
                self._jwt = jwt.encode(
                    {"iss": self._team_id, "iat": now},
                    self._key,
                    algorithm="ES256",                    # PyJWT emits raw R||S
                    headers={"alg": "ES256", "kid": self._key_id},
                )
            return self._jwt

    # -- send -------------------------------------------------------------
    def send_push(
        self,
        device_token: str,
        payload: dict,
        *,
        push_type: str = "alert",       # alert|background|complication|...
        priority: int | None = None,    # None -> 10 for alert, 5 for background
        expiration: int = 0,            # epoch seconds; 0 = no store
        collapse_id: str | None = None,
        apns_id: str | None = None,
        extra_headers: dict[str, str] | None = None,
    ) -> PushResult:
        token = device_token.replace(" ", "").replace("<", "").replace(">", "").lower()
        if not token or any(c not in "0123456789abcdef" for c in token):
            raise ValueError(f"device token is not hex: {device_token!r}")

        body = json.dumps(payload, separators=(",", ":")).encode()
        if len(body) > MAX_PAYLOAD:
            raise ValueError(f"payload {len(body)} B > {MAX_PAYLOAD} B")

        if priority is None:
            priority = 5 if push_type == "background" else 10
        if push_type == "background" and priority != 5:
            raise ValueError("background push requires apns-priority 5")

        headers = {
            "authorization": f"bearer {self.provider_token()}",
            "apns-topic": self.topic,
            "apns-push-type": push_type,
            "apns-priority": str(priority),
            "apns-expiration": str(expiration),
        }
        if collapse_id is not None:
            if len(collapse_id.encode()) > 64:
                raise ValueError("apns-collapse-id must be <= 64 bytes")
            headers["apns-collapse-id"] = collapse_id
        if apns_id is not None:
            headers["apns-id"] = apns_id
        if extra_headers:
            headers.update(extra_headers)

        try:
            resp = self._client.post(
                f"{self.base_url}/3/device/{token}", content=body, headers=headers
            )
        except httpx.HTTPError as exc:                    # network / TLS / GOAWAY
            return PushResult(status=0, apns_id=None, reason=f"transport:{type(exc).__name__}")

        if resp.status_code == 200:
            return PushResult(200, resp.headers.get("apns-id"))

        try:
            reason = resp.json().get("reason")
        except Exception:
            reason = resp.text[:200] or None

        if resp.status_code == 403 and reason in {"ExpiredProviderToken", "InvalidProviderToken"}:
            self.provider_token(force=True)               # retry once with a fresh JWT
        return PushResult(resp.status_code, resp.headers.get("apns-id"), reason)

    def close(self) -> None:
        self._client.close()


if __name__ == "__main__":
    apns = APNs(
        key_path="AuthKey_ABC123DEFG.p8",
        key_id="ABC123DEFG",
        team_id="DEF123GHIJ",
        topic="com.example.watchpilot.watchkitapp",  # watch app bundle id
        sandbox=True,                                # debug build => sandbox
    )
    print(
        apns.send_push(
            "<hex device token from the watch app>",
            {"aps": {"alert": {"title": "watch-pilot", "body": "build ok"}, "sound": "default"}},
            push_type="alert",
            priority=10,
            expiration=int(time.time()) + 300,
            collapse_id="build-status",
        )
    )
```

Operational notes baked into the skeleton: token cached for 40 min; `iat` never older than 60
min; `background` forced to priority 5; 64-byte collapse id; 4096-byte body; token hex validated;
one forced JWT re-mint on `403 Expired/InvalidProviderToken`; transport errors surfaced instead of
raised.

---

## 7. Bottom line for watch-pilot

1. The Mac-as-provider architecture is correct and needs no third-party server — but **it needs a
   paid Apple Developer Program membership**; a free Personal Team cannot mint `aps-environment`.
2. A watch-only watchOS app is a legitimate push target on watchOS 27 (`alert`, `background`) with
   its own bundle ID as `apns-topic`. No iOS companion is required; if one exists, send to both
   topics.
3. Debug builds register with **sandbox** (`api.sandbox.push.apple.com`), release/TestFlight with
   production. Never mix tokens across environments.
4. The iMessage route is the only $0 path, and it works only from a **GUI-logged-in** user
   session with Messages signed in — not over SSH. Treat it as a fallback with no delivery
   guarantee.
5. `httpx` + `PyJWT` is sufficient: `httpx[http2]`, one long-lived client, a 40-minute JWT, and a
   strict header builder.

---

## Sources

| ID | Source | URL |
|---|---|---|
| S1 | Apple — Establishing a token-based connection to APNs (JWT shape, ES256, 20/60-min refresh, `authorization: bearer`) | https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns |
| S2 | Apple — Sending notification requests to APNs (headers, push types, priority/expiration/collapse-id, 4 KB/5 KB, HPACK, hosts, best practices) | https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns |
| S3 | Apple — Establishing a connection to APNs (HTTP/2 + TLS 1.2, `api.development…` handshake example, streams, GOAWAY, DoS warning) | https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns |
| S4 | Apple — Handling error responses from APNs (status codes, `reason` strings, 429 TooManyProviderTokenUpdates) | https://developer.apple.com/documentation/usernotifications/handling-error-responses-from-apns |
| S5 | Apple — APS Environment Entitlement (`development`/`production`, watchOS 3.0+, profile-driven) | https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment |
| S6 | Apple — Registering your app with APNs (watchOS `WKExtension`, per-app token, capabilities) | https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns |
| S7 | Apple — `WKExtension.registerForRemoteNotifications()` (watch push capability; dual-send with companion) | https://developer.apple.com/documentation/watchkit/wkextension/registerforremotenotifications() |
| S8 | Apple — Taking advantage of notification forwarding (direct-to-watch since watchOS 6, routing rules) | https://developer.apple.com/documentation/watchos-apps/taking-advantage-of-notification-forwarding |
| S9 | Apple — Creating independent watchOS apps (no companion required) | https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps |
| S10 | Apple Developer Forums 718388 — "Personal development teams … do not support the Push Notifications capability" | https://developer.apple.com/forums/thread/718388 |
| S11 | Gordon Beeming — Solving Xcode provisioning/capability errors (free account, Push + iCloud) | https://gordonbeeming.com/blog/2025-10-15/solving-xcode-provisioning-profile-and-capability-errors |
| S12 | danielmiessler/LifeOS issue #1279 — Messages AppleScript `-1728` on macOS 26.x | https://github.com/danielmiessler/LifeOS/issues/1279 |
| S13 | openclaw/openclaw issue #79289 — SSH TCC `sshd-keygen-wrapper`, `-1743` on send | https://github.com/openclaw/openclaw/issues/79289 |
| S14 | HTTPX docs — HTTP/2 Support (`httpx[http2]`, `http2=True`, `response.http_version`) | https://www.python-httpx.org/http2/ |
| S15 | N. Hillegeer — Send iMessages via the command line, even to yourself (`buddy … of service`) | http://www.aktau.be/2014/02/12/send-imessages-via-the-commandline-on-osx-even-to-yourself/ |
| S16 | Apple Developer Forums 123462 — "WatchOS6 Independent APNs DeviceTokenNotForTopic" (community, unverified) | https://developer.apple.com/forums/thread/123462 |
| S17 | Apple — Supported capabilities (iOS) (membership-gated capability list incl. "Push notifications") | https://developer.apple.com/help/account/reference/supported-capabilities-ios/ |
| S18 | dev.to — "Moving to iOS and the Apple Push Notification roadblock" (free-account experience) | https://dev.to/ericrodriguez10/day-92-moving-to-ios-and-the-apple-push-notification-roadblock-50ek |

### Local verification performed (not a web source)

- `sw_vers` → macOS 27.0, build 26A428 (2026-10-22).
- `sdef /System/Applications/Messages.app` → full dictionary dump (commands/classes/synonyms);
  source file `/System/Applications/Messages.app/Contents/Resources/Messages.sdef`.
- `osacompile` over four snippet variants → three compile, one syntax error (§5.1 table).
- `dig +short` on the three APNs hostnames; `openssl s_client -alpn h2` on production and
  sandbox → `h2`, TLS 1.3, chain verified.
- `python3 -c "import httpx"` → **not installed** on this Mac; `h2`, `PyJWT`, `cryptography` also
  absent, so `pip install 'httpx[http2]' 'PyJWT[crypto]'` is a required provisioning step.
