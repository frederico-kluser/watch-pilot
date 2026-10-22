---
id: Q2
title: "Q2 — Background execution contract on modern watchOS"
target: "watchOS 27 (SDK watchOS 27.0, Xcode 27.1), standalone Apple Watch app, Apple Watch SE"
status: answered
confidence: high
verified_environment:
  host: "Mac mini M1 (minim1), macOS 27.0 (26A428)"
  xcode: "27.1 (27A9269)"
  sdk: "WatchOS27.0.sdk (watchos27.0), WatchSimulator27.0.sdk"
  ios_sdk: "iPhoneOS27.1.sdk (cross-check only)"
date: 2026-10-22
method: "Tavily CLI (pool exhausted, see §10) + Apple documentation JSON endpoints + local watchOS 27.0 SDK headers + StackExchange API"
---

# Q2 — Background execution contract on modern watchOS (watchOS 27)

**Scope.** What a *standalone* watchOS app (no companion iOS app) can do while not frontmost, on
watchOS 27 / Apple Watch SE. Every finding carries a confidence tag:

> **[high]** verified against Apple's current documentation *and/or* the shipped watchOS 27.0 SDK headers.
> **[moderate]** stated by one authoritative source, or inferred with a small gap.
> **[low]** community/indirect evidence only.

Legend for source tags: `[S#]` → §9. Two kinds of sources are used deliberately:
Apple's documentation JSON endpoints (rendered text of the exact pages) and the **local watchOS 27.0
SDK headers**, which are the ground truth for availability/deprecation in watchOS 27.

---

## 0. Executive answer

1. A watchOS app gets **no continuous background execution**. It is frontmost, or suspended. The only
   ways to keep executing are: an **extended runtime session** (10 min – 1 h, health/therapy/alarm
   session types only), a **background session** (workout / audio / location, must be started in the
   foreground), **background URLSession transfers** (out-of-process), and **short background tasks**
   (app refresh, push, WatchConnectivity, Bluetooth) measured in *seconds*. **[high]** [S1][S2][S3][S10]
2. The only mode that yields a **1-hour background window** is the extended runtime session type
   `physical-therapy` (`WKBackgroundModes = physical-therapy`). `mindfulness` is also 1 h but runs
   **frontmost**. `self-care` = 10 min frontmost; `alarm` = 30 min background, schedulable up to 36 h.
   **[high]** [S1][S9]
3. Extended runtime sessions **must be started (or scheduled) while the app is active**; starting from
   the background fails with `WKExtendedRuntimeSessionErrorMustBeActiveToStartOrSchedule` (=3).
   **[high]** [S1][S17]
4. Background app refresh budget: **~4 tasks/hour** for an app that has a complication on the *active*
   watch face (budget shared by all complications on that face), **a few seconds** of runtime per task.
   Without a complication on the active face, Apple documents no allocation of background execution
   time at all. **[high]** [S3][S4]
5. `scheduleBackgroundRefresh(withPreferredDate:userInfo:scheduledCompletion:)` is **alive and not
   deprecated in watchOS 27** (watchOS 7.0+ on `WKApplication`). What *is* deprecated is `WKExtension`
   itself (since watchOS 9.2, replaced by `WKApplication`). **[high]** [S5][S24][S17]
6. **No — an app cannot poll HTTP every 3 seconds while the wrist is down.** When the wrist drops the
   app leaves the foreground; without an active session it is suspended within seconds and its timers
   and in-flight `URLSession` tasks stop. A 3 s poll cadence is only achievable *while the app is
   frontmost* and, at best, during an extended runtime session. **[high]** [S1][S2][S8][S6]
7. **Yes — standalone ("Apple Watch-only") apps can receive remote (APNs) notifications directly**,
   since watchOS 6. Apple's own guidance for a watch-only app is *"Always send remote notifications to
   Apple Watch."* Requires the Push Notifications capability (`aps-environment`, watchOS 3.0+), the
   `remote-notification` background mode for silent pushes, and `registerForRemoteNotifications()`.
   **[high]** [S13][S14][S15][S25]
8. watchOS 26/27 introduced **no public WatchKit background-execution change**: zero WatchKit symbols
   are introduced at 26.0 or 27.0 in the SDK. `BGTaskScheduler` remains **unavailable on watchOS**, and
   **no `AudioWorkoutSession` API exists** in the watchOS 27 or iOS 27.1 SDKs. **[high]** [S17][S18]

---

## 1. Background modes available to a standalone watchOS app today

| # | Mechanism | API | Runtime granted | Requirements / notes | Conf. |
|---|---|---|---|---|---|
| 1 | **Extended runtime session** | `WKExtendedRuntimeSession` (`+session`, watchOS 6.0+) | 10 min / 1 h / 1 h / 30 min by type | One extended-runtime type per app via `WKBackgroundModes`; **must start while active**; delegate mandatory; system may cancel on sustained high CPU | [high] [S1][S7][S9][S17] |
| 2 | **Background URLSession transfer** | `URLSessionConfiguration.background(withIdentifier:)` (watchOS 2.0+) + `WKURLSessionRefreshBackgroundTask` | Transfer runs **in a separate process**, survives app termination; wake-ups are budgeted | Up to **4** `WKURLSessionRefreshBackgroundTask` per hour (with complication on active face); schedule ≥ **15 min** apart via `earliestBeginDate`; `isDiscretionary`, `sessionSendsLaunchEvents` | [high] [S6][S18] |
| 3 | **Background app refresh task** | `WKApplicationRefreshBackgroundTask` + `WKApplication.scheduleBackgroundRefresh(withPreferredDate:userInfo:scheduledCompletion:)` (watchOS 7.0+) | **A few seconds** | ~4 tasks/h, only if a complication is on the active watch face; one pending refresh at a time; ignored if the app is foreground at fire time | [high] [S3][S4][S5][S17] |
| 4 | **SwiftUI background task** | `Scene.backgroundTask(_:action:)` → `.appRefresh(_:)` / `.appRefresh` (watchOS 9.0+) | Same seconds-scale window; closure returning == task completed | Preferred API since watchOS 9; still driven by the WatchKit refresh task (not by `BGTaskScheduler`, which does not exist on watchOS) | [high] [S16][S4][S18] |
| 5 | **Workout session** | `HKWorkoutSession` (HealthKit) + `workout-processing` mode | **Until the session ends** (unbounded) | Must be started **in the foreground**; app keeps receiving sensor/HealthKit data in the background; audio/haptics allowed; excessive CPU ⇒ system suspension | [high] [S10][S12][S2] |
| 6 | **Long-form audio** | `AVAudioSession` category `.playback`, **policy `.longFormAudio`** + Audio background mode | As long as audio plays | watchOS **requires a Bluetooth audio route** for long-form audio (system may show a route picker); the Audio background mode sets `UIBackgroundModes` in the extension | [high] [S11][S10][S26] |
| 7 | **Background location** | `CLLocationManager.allowsBackgroundLocationUpdates` + Location updates mode | Until the session ends | Must be started in the foreground; same status-bar indicator behaviour as audio/workout | [high] [S10][S2] |
| 8 | **Background (silent) push** | APNs `content-available:1` + `remote-notification` mode → `didReceiveRemoteNotification(_:fetchCompletionHandler:)` | **30 seconds** | `apns-push-type: background`, `apns-priority: 5`; delivery not guaranteed; Apple advises **≤2–3 per hour**; only the newest held notification survives | [high] [S10][S20][S13] |
| 9 | **Complication push (PushKit)** | `PKPushRegistry` + `PKPushRegistryDelegate` | Wake to update complications | Separate channel from `UNUserNotificationCenter`; Apple's background-execution guide documents `PKPushRegistryDelegate` as the way to push complication updates | [moderate] [S2][S23] |
| 10 | **WatchConnectivity / Bluetooth / Siri-intent tasks** | `WKWatchConnectivityRefreshBackgroundTask`, `WKBluetoothAlertRefreshBackgroundTask` (watchOS 9.0+), `WKIntentDidRunRefreshBackgroundTask`, `WKRelevantShortcutRefreshBackgroundTask` | Seconds | Bluetooth background scans/timely alerts are capped at **5 per rolling 24 h**; budget refreshes when the user launches the app | [high] [S3][S17] |

**What does *not* exist on watchOS** (checked in the shipped SDK, not just docs):

* `BGTaskScheduler` and every `BGTask*` type are declared `API_UNAVAILABLE(watchos)` in
  `BackgroundTasks.framework` — so no `BGAppRefreshTask`, no `BGProcessingTask`, and **no
  `BGContinuedProcessingTask`** (the iOS 26 "continue in background after the user leaves" API) on
  Apple Watch. **[high]** [S18]
* No `Speech.framework` in the watchOS 27 SDK (only `SoundAnalysis.framework`) — relevant to the
  project's transcription plan, though outside Q2. **[high]** [S17]
* No public API for periodic ("every N seconds") background HTTP. **[high]** [S2][S3]

---

## 2. `WKExtendedRuntimeSession` — the exact rules

### 2.1 Session types, runtimes and scheduling

| Session type (`WKBackgroundModes` value) | Runtime position | Schedulable | Time limit |
|---|---|---|---|
| `self-care` | **Frontmost** | No | **10 minutes** |
| `mindfulness` | **Frontmost** | No | **1 hour** |
| `physical-therapy` | **Background** | No | **1 hour** |
| `alarm` (smart alarm) | **Background** | **Yes — any time within the next 36 h** | **30 minutes** |

**[high]** — verbatim table in [S1]; values enumerated in the `WKBackgroundModes` key reference [S9];
limits and scheduling also encoded in the SDK (`ScheduledTooFarInAdvance` = 2, "sessions can't be
scheduled more than 36 hours in advance") [S17].

Frontmost sessions keep running with the screen **off**, and end when the time limit expires, the app
invalidates, **or the user leaves the app** (digital crown, notification tap, app switcher).
Background sessions keep running even if the user dismisses the app or opens another app. **[high]** [S1]

**The 1-hour background window is granted by `physical-therapy`** — it is the only extended-runtime
type that is both `Background` and 1 hour. **[high]** [S1][S9]

### 2.2 Can only one type be enabled?

> "You can only enable one of the extended runtime session modes (`self-care`, `mindfulness`,
> `physical-therapy`, or `alarm`). However, you can enable both an extended runtime session mode and the
> `workout-processing` mode." — `WKBackgroundModes` [S9]

`WKBackgroundModes` possible values (watchOS 3.0+): `workout-processing`, `self-care`, `mindfulness`,
`physical-therapy`, `alarm`, `underwater-depth`. **[high]** [S9]
Note the distinction: the extended-runtime types live in **`WKBackgroundModes`**; audio / location /
remote-notification modes are the generic **`UIBackgroundModes`** (watchOS 4.0+) in the extension's
Info.plist. **[high]** [S9][S26][S11]

### 2.3 The foreground-start rule

* "You must always start or schedule the extended runtime session when your app state is in the
  **active** state." **[high]** [S1]
* SDK error codes: `MustBeActiveToStartOrSchedule = 3` ("the app must be active to start or schedule a
  session"), `NotYetStarted = 4`, `ExceededResourceLimits = 5`, **`BARDisabled = 6`** ("the BAR switch
  for the application is disabled" — i.e. Background App Refresh off for the app kills extended runtime
  sessions too), `NotApprovedToStartSession = 7` ("missing a valid plist key or entitlement"),
  `NotApprovedToSchedule = 8`. **[high]** [S17]
* Same rule for background sessions in general: "Your app must start the session in the foreground, but
  the session continues to run when your app transitions to the background." (Audio / Location /
  Workout processing) **[high]** [S10]
* Scheduling (`start(at:)`) must also be done while active, but the session then starts at the
  appointed date regardless of app state; the system relaunches the app and calls the application
  delegate's `handleExtendedRuntimeSession(_:)`. **If no delegate is set before that method returns, the
  system ends the session.** **[high]** [S1][S17]
* Only **one** session at a time (`SessionInProgress`), and only **one** schedulable session at a time;
  to reschedule, invalidate first. **[high]** [S1][S17]
* `invalidate()` on a scheduled session can only be called while the app is **active**; for a running
  session it can be called at any time. Also: *"Once `invalidate` is called on a session, it can no
  longer run"* → create a fresh session object for the next run. **[high]** [S1][S17]

### 2.4 What happens on invalidation

`extendedRuntimeSession(_:didInvalidateWith:error:)` is called both when a session **fails to start**
and when a running session **ends**. Reasons (`WKExtendedRuntimeSessionInvalidationReason`):

| Reason | Meaning |
|---|---|
| `None` | Ended normally (typically `invalidate()`) |
| `SessionInProgress` | Another session for this app is already running |
| `Expired` | Hit its time limit |
| `ResignedFrontmost` | **Frontmost sessions only**: user pressed the crown, tapped a notification, switched apps, or another app came to the foreground |
| `SuppressedBySystem` | The watch is in a state that does not currently allow this session type |
| `Error` (-1) | Abnormal end; inspect the `NSError` (`WKExtendedRuntimeSessionErrorDomain`) |

**[high]** [S17] (reasons enumerated in the header); invalidation behaviour also documented in [S1].

`expirationDate` remains valid after invalidation, so it can be used for diagnostics; `state` becomes
`.invalid`. `extendedRuntimeSessionWillExpire(_:)` fires shortly before the limit so the app can finish
work. **[high]** [S17]

### 2.5 The "`WKExtendedRuntimeObject was dealloced while running`" pitfall

Exact console output (from a real report):

```
-[WKExtendedRuntimeSession dealloc]:285: WKExtendedRuntimeObject was dealloced while running.
Invalidating the session 46EB2DE0-311C-41D0-93BE-46FE744B685A
```

A sibling message exists for the scheduled case: `...was dealloced while scheduled. Invalidating the
session ...`.

**Cause.** The session object has **no strong owner**. The class only keeps a `weak` delegate [S17];
if the session is created as a local/temporary (a view `struct` re-created on every redraw, a function
local, a `@State`-less helper), ARC releases it and the framework invalidates the session *while it is
supposed to be running* — the app silently loses all extra runtime and is suspended at the next wrist
drop. This bites SwiftUI apps in particular, because view structs are transient.

**Fix.** Own exactly one session in a long-lived object (singleton / app-level observable), set the
delegate before `start()`, and guard on `state` (`.scheduled`, `.running`) instead of creating a second
session on relaunch. Two community reports in the same thread confirm both the "running" and the
"while scheduled" variants and the singleton remedy. **[moderate]** — reproduced text + accepted
workaround from a developer Q&A [S19]; the ARC/weak-delegate mechanism is inferred from the SDK header
[**high**, S17].

**Additional pitfall (documented, not community):** "If your app sustains high CPU usage over a period
of time, the system may cancel the session" — surfaced as `ExceededResourceLimits` (=5). A tight
network poll loop inside an extended runtime session is exactly the pattern that risks this. **[high]**
[S1][S17]

### 2.6 Auto-launch (watchOS 9+)

`+requestAutoLaunchAuthorizationStatus(completion:)` + `WKExtendedRuntimeSessionAutoLaunchAuthorization
Status` lets an app become the *default responder* for its session type, so the system can launch it when
conditions for that type are met (the smart-alarm use case). Errors: `MustBeActiveToPrompt` (=9),
`UnsupportedSessionType` (=10). **[high]** [S17]

---

## 3. The real background app refresh budget

### 3.1 How often can an app refresh?

* `WKApplicationRefreshBackgroundTask`: *"In general, the system performs approximately **four tasks per
  hour** for each app with a complication on the active watch face. **All the complications on the
  current watch face share this budget.** After you exhaust the budget, the system delays your requests
  until more time becomes available."* **[high]** [S4]
* `WKURLSessionRefreshBackgroundTask`: *"If your app has a complication on the active watch face, it can
  receive up to **four** `WKURLSessionRefreshBackgroundTask` tasks per hour. To avoid throttling, use
  `earliestBeginDate` to schedule background URL session tasks no closer than **15 minutes** apart."*
  **[high]** [S6]
* Gate condition: *"For the system to allocate background execution time to your app, your app must have
  a complication on the active watch face."* If the system grants time, it fires no earlier than
  `preferredDate`, but may defer/throttle freely. **[high]** [S3]
* Throttling is also system-wide: no tasks when battery is low or during high-priority activities
  (workout, navigation). **[high]** [S3]
* Per-task runtime is *"a few seconds"* — overrun risks `EXC_CRASH (SIGKILL)`. Use
  `expirationHandler` / `withTaskCancellationHandler` to bail out. **[high]** [S3][S16]
* Other documented caps: **5** Bluetooth background scans / timely alerts per rolling 24 h [S3];
  background pushes *"don't try to send more than two or three per hour"*, delivery not guaranteed [S20].

**Does a complication change it?** Yes — it is the *precondition*. Without a complication on the active
face Apple documents no background execution allotment; with one, the app joins a ~4/hour pool shared
with the other complications on that same face. **[high]** [S3][S4]

**[moderate] Historical note.** Older Apple documentation and several third-party write-ups describe a
*second*, separate allotment of "approximately one task per hour for each app in the dock (including the
most recently used app)", shared among docked apps. The current watchOS 27 pages no longer contain that
sentence — only the four-per-hour/complication rule is documented today. Treat "dock budget" as
legacy/unverified. [S4][S3]; secondary: [S28]

### 3.2 Is `scheduleBackgroundRefresh` still available / deprecated?

* Available, **not deprecated** in watchOS 27: `WKApplication.scheduleBackgroundRefresh(withPreferredDate:
  userInfo:scheduledCompletion:)` — introduced watchOS 7.0, no deprecation flag in the doc metadata, and
  no `WK_DEPRECATED*` attribute in `WKBackgroundTask.h` of `WatchOS27.0.sdk`. **[high]** [S5][S17]
* The **deprecated** thing nearby is `WKExtension` itself: `WK_DEPRECATED_WITH_REPLACEMENT(2.0, 9.2,
  "WKApplication")` — i.e. since watchOS 9.2 use `WKApplication`, not `WKExtension`. **[high]** [S17][S24]
* Also not deprecated: `WKApplicationRefreshBackgroundTask` (watchOS 3.0+), SwiftUI
  `Scene.backgroundTask(_:action:)` (watchOS 9.0+), `WKURLSessionRefreshBackgroundTask`. **[high]** [S4][S16][S6]
* Behavioural constraints: only one pending app-refresh task ("scheduling a second task cancels the
  first"), and the system ignores the task if the app is foreground at the scheduled time. **[high]** [S5]
* Docs' preference: *"In watchOS 9 and later, SwiftUI Background tasks are the preferred way to handle
  background tasks and interactions."* **[high]** [S4][S6]

---

## 4. Can the app poll HTTP every 3 seconds with the wrist down?

**No.** Not on a stock standalone app, and not even a 1-hour extended runtime session makes it a good
idea. What actually happens:

1. **Wrist down ⇒ background ⇒ suspended.** *"An app running on Apple Watch normally transitions to the
   background and becomes **suspended** when the user lowers their wrist."* [S1] The lifecycle table
   defines `Suspended` as *"The app is in memory but isn't executing code. The system may purge
   suspended apps at any time."* [S8] A `Timer`/`DispatchSourceTimer`/`Task.sleep` loop therefore does
   not fire while suspended; the app only resumes on the next foreground activation (or a granted
   background task / session).
2. **In-flight networking dies with the process state.** Apple's own wording: async uploads/downloads
   *"suspend with your app"*, whereas **background** URLSession transfers *"occur in a separate process
   and continue to transfer data even after your app terminates"*. For guaranteed delivery the app must
   use a background `URLSession` — which is budgeted at 4 wake-ups/hour and ≥15 min spacing, not 3 s.
   **[high]** [S6]
3. **Background tasks are seconds, not minutes.** App refresh ≈ a few seconds; silent push = **30 s**
   (then the app returns to suspended). **[high]** [S3][S10][S20]
4. **Extended runtime is the only multi-minute option**, and it is constrained: `physical-therapy`
   gives 1 h of *background* runtime, but (a) it is a purpose-bound session type, (b) the system
   cancels sessions that sustain high CPU (`ExceededResourceLimits`), and (c) the session ends on
   expiry/invalidate and must then be restarted **from an active app**. **[high]** [S1][S17]
5. **While frontmost, 3 s polling works** — the screen must stay on (or the app must hold an active
   extended runtime/workout/audio session; in those cases the watch re-displays your app when the wrist
   is raised and shows an indicator above the status bar). **[high]** [S10]

**Implication for the design:** treat "record → upload → poll progress" as a *foreground* transaction
(or as one covered by an explicit session), and make every step resumable, because the process can be
suspended — and its memory reclaimed — between any two lines of code.

---

## 5. Remote (APNs) notifications in a standalone watchOS app

**Supported — no iOS companion required. [high]**

* *"With **watchOS 6 and later**, you can send remote notifications directly to Apple Watch. Before
  sending a notification, you must register your watchOS app … Registering your app creates a unique
  device token for the watch. Use that token to send notifications directly to the watch."* [S13]
* Apple's routing table, verbatim: **"Apple Watch-only app → Always send remote notifications to Apple
  Watch."** (Independent app with an iOS app → send to both; dependent app → iPhone only or both; the
  system de-duplicates so the user sees one.) **[high]** [S13]
* Registration API: `WKApplication.registerForRemoteNotifications()` (**watchOS 7.0+**; the predecessor
  `WKExtension.registerForRemoteNotifications()` is watchOS 6.0+ but `WKExtension` is deprecated since
  9.2). Tokens arrive in the delegate: `didRegisterForRemoteNotificationsWithDeviceToken(_:)` /
  `didFailToRegisterForRemoteNotificationsWithError(_:)`. **[high]** [S25][S24][S14][S17]
* **Gotcha from the SDK header** (not obvious from the guides): *"these callbacks will be made only if
  the application has successfully registered for user notifications with `UNUserNotificationCenter`, or
  if it is enabled for Background App Refresh."* So call `UNUserNotificationCenter.requestAuthorization`
  **before** registering, or the device-token callback may never arrive. **[high]** [S17]

**What is required**

| Requirement | Detail | Conf. |
|---|---|---|
| Push Notifications capability → `aps-environment` entitlement | watchOS 3.0+; adds the entitlement to the app | [high] [S15][S14] |
| Push enabled for the App ID in the developer account | Per-bundle-ID switch | [high] [S14] |
| `UNUserNotificationCenter.requestAuthorization(options:)` | Prerequisite for the token callback (see above) | [high] [S13][S17] |
| User-visible alerts | Just send a normal alert payload to the watch token | [high] [S13] |
| **Silent / background** pushes | Add **Remote notification** background mode (`UIBackgroundModes`) to the **WatchKit extension**; payload `{"aps":{"content-available":1}}`; headers `apns-push-type: background` + `apns-priority: 5`; handler `didReceiveRemoteNotification(_:fetchCompletionHandler:)`; **30 s** budget; not guaranteed; ≤2–3/hour | [high] [S20][S10][S17] |
| Complication updates over push | `PKPushRegistry` path (PushKit) rather than `UNUserNotificationCenter` | [moderate] [S2][S23] |

`APNs` requires the **`apns-push-type`** header for Apple Watch sends ("The APNs server requires the
`apns-push-type` field when sending push notifications to Apple Watch"). **[high]** [S20]

---

## 6. watchOS 26 / 27-era changes a 2026 app must respect

1. **No change to the background-execution contract.** Grepping the whole `WatchKit.framework` of
   `WatchOS27.0.sdk` yields **zero** symbols introduced at watchOS 26.0 or 27.0, and no new
   `WKExtendedRuntimeSession` session type. The four types, the 10 min/1 h/1 h/30 min table, the 36 h
   scheduling window and the invalidation reasons are unchanged. **[high]** [S17][S1]
2. **`BGTaskScheduler` still does not exist on watchOS** — so the iOS 26 `BGContinuedProcessingTask`
   ("keep working after the user swipes the app away") is *not* available on Apple Watch. **[high]** [S18]
3. **`AudioWorkoutSession` does not exist** as a public API. Zero occurrences in the watchOS 27.0 SDK
   **and** the iOS 27.1 SDK. What exists for audio around workouts: the `workout-processing` background
   mode plus the Audio background mode, with the documented rule *"In order to play an audio clip, an
   active workout session must be running; any attempt to play background audio outside a workout
   session [is] invalid."* Long-form background audio uses `AVAudioSession` `.playback` +
   **`.longFormAudio`** policy with a Bluetooth route. **[high]** [S17][S12][S11]
4. **`WKExtension` is deprecated** (watchOS 9.2 → `WKApplication` / `WKApplicationDelegate`). New code
   should never touch it; note that several Apple *guides* still say "call `WKExtension`'s
   `registerForRemoteNotifications`", so docs and headers disagree — trust the header. **[high]** [S24][S17]
5. **watchOS 27 release notes contain nothing about background execution, refresh budgets or pushes.**
   Full-text scan of the page: exactly one "background" mention, and it is HealthKit's *background heart
   rate measurement* pausing while a third-party HR monitor is active; no "extended runtime" mention at
   all. The only remotely relevant entries are Siri/Workout-Buddy audio issues in *standalone watch-only*
   mode. **[high]** [S21] (watchOS 26 notes: **zero** mentions of "background" or "extended runtime". [S22])
6. **Extended-runtime authorisation surface is stable**, including `requestAutoLaunchAuthorizationStatus`
   (watchOS 9+) and the `BARDisabled` failure mode when the user turns off Background App Refresh for
   the app. **[high]** [S17]
7. **Sources to distrust (flagged during this research).** A 2026 "what's new in watchOS 27" content-farm
   page claims a new *"Live Background Sync"* WatchConnectivity API and *on-device Foundation Models for
   watchOS*. Both are false for a third-party app: `WatchConnectivity` has no 26/27 additions, and
   `FoundationModels` ships in the SDK but every declaration is annotated
   `@available(watchOS, unavailable)`. **[high]** [S27 vs S17/S18]
8. **Adjacent constraint worth knowing:** `Speech.framework` is absent from the watchOS 27 SDK (only
   `SoundAnalysis.framework`), which matters to this project's transcription plan. **[high]** [S17]

---

## 7. Consequences for watch-pilot (grounded in the above)

* A standalone watch app that records a command and then waits for Mac-mini progress **cannot** poll
  “every 3 s in the background”. Viable shapes: (a) do the poll **while frontmost** (screen on, app in
  the foreground); (b) wrap the transaction in an extended runtime session of type `physical-therapy`
  (1 h background) — but that is purpose-bound and may be rejected/misused, so treat it as a *risk*, not
  a design assumption; (c) invert the flow: **APNs silent/alert push from the hub to the watch**
  (`content-available` gives 30 s; alert pushes are not time-bounded but are user-visible), plus
  background URLSession for the audio upload; (d) `scheduleBackgroundRefresh` ≈ 4 wake-ups/h **only if**
  a complication is on the active watch face. **[high]** [S1][S3][S6][S20]
* Audio upload should use a **background** `URLSession` (separate process, survives suspension), with
  `earliestBeginDate` ≥15 min apart if repeated. **[high]** [S6]
* The hub's HTTP server must tolerate a client that disappears mid-request: idempotent endpoints,
  resumable job IDs, and no assumption that the watch stays connected. **[moderate]** — design inference
  from the suspension model [S1][S8].

---

## 8. Gaps / not verified

| # | Open item | Why it matters | Conf. |
|---|---|---|---|
| G1 | Whether an extended runtime session of type `physical-therapy` is accepted by App Review for a non-therapy app | This is the difference between "1 h of background" and "no 1 h" | unknown — no authoritative source retrieved; Apple's design guidance says *"Select a session type based on the app's intended use — not based on the features that the session provides"* [S1], which reads as a warning |
| G2 | Real-world firing frequency without a complication | Apple's wording ("must have a complication on the active watch face") may be stricter than practice; not testable in this session | [low] |
| G3 | Whether a **dock**-based 1/h allotment still exists on watchOS 27 | Removed from current docs; no authoritative confirmation found | [low] |
| G4 | Behaviour of `HKWorkoutSession` started from the background when HealthKit relaunches the app for an iPhone-started workout (`handleWorkoutConfiguration`) | Edge case; would need a device test | [moderate] |
| G5 | Exact 2027-era App Store policy text for background modes | Not retrieved | unknown |

---

## 9. Sources

**Apple documentation (current, watchOS 27 docs; fetched as Apple's documentation JSON and rendered)**

- **[S1]** Apple. *Using extended runtime sessions.* https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions — session-type table (10 min / 1 h / 1 h / 30 min, frontmost vs background, 36 h scheduling), foreground-start rule, CPU cancellation, `handleExtendedRuntimeSession`. Read in full.
- **[S2]** Apple. *Background execution.* https://developer.apple.com/documentation/watchkit/background-execution — taxonomy of background options; "primarily run in the foreground"; notification/PushKit wake-ups. Read in full.
- **[S3]** Apple. *Using background tasks.* https://developer.apple.com/documentation/watchkit/using-background-tasks — complication-on-active-face requirement, throttling, seconds of runtime, SIGKILL risk, 5-per-24 h Bluetooth budget, SwiftUI vs delegate. Read in full.
- **[S4]** Apple. *WKApplicationRefreshBackgroundTask.* https://developer.apple.com/documentation/watchkit/wkapplicationrefreshbackgroundtask — "approximately four tasks per hour", shared budget, SwiftUI preferred since watchOS 9. Read in full.
- **[S5]** Apple. *WKApplication.scheduleBackgroundRefresh(withPreferredDate:userInfo:scheduledCompletion:).* https://developer.apple.com/documentation/watchkit/wkapplication/schedulebackgroundrefresh(withpreferreddate:userinfo:scheduledcompletion:) — one pending task, ignored in foreground. Read in full.
- **[S6]** Apple. *WKURLSessionRefreshBackgroundTask.* https://developer.apple.com/documentation/watchkit/wkurlsessionrefreshbackgroundtask — 4 wake-ups/hour, 15-minute spacing, separate-process transfers. Read in full.
- **[S7]** Apple. *WKExtendedRuntimeSession.* https://developer.apple.com/documentation/watchkit/wkextendedruntimesession — one session type per app, selected via Background Modes capability. Read in full.
- **[S8]** Apple. *Life cycles.* https://developer.apple.com/documentation/watchkit/life-cycles — state table incl. `Suspended` = "isn't executing code"; 10-minute delivery window for background data. Read in full.
- **[S9]** Apple. *WKBackgroundModes.* https://developer.apple.com/documentation/bundleresources/information-property-list/wkbackgroundmodes — possible values and the "only one extended runtime mode" rule. Read in full.
- **[S10]** Apple. *Enabling Background Sessions.* https://developer.apple.com/documentation/watchkit/enabling-background-sessions — "must start the session in the foreground"; 30 s for background push; status-bar indicator. Read in full.
- **[S11]** Apple. *Playing Background Audio.* https://developer.apple.com/documentation/watchkit/playing-background-audio — Audio background mode, `.playback` + **`.longFormAudio`**, Bluetooth route requirement. Read in full.
- **[S12]** Apple. *Running workout sessions* (HealthKit). https://developer.apple.com/documentation/healthkit/running-workout-sessions — workout-processing background mode, background data + audio/haptics, CPU suspension, audio only with an active session. Read in full.
- **[S13]** Apple. *Enabling and receiving notifications* (watchOS). https://developer.apple.com/documentation/watchos-apps/enabling-and-receiving-notifications — watchOS 6+ direct-to-watch pushes, "Apple Watch-only app → always send to Apple Watch", `willPresent` delegate. Read in full.
- **[S14]** Apple. *Registering your app with APNs.* https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns — entitlements, App ID push switch, watchOS registration path, never cache tokens. Read in full.
- **[S15]** Apple. *aps-environment* entitlement. https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment — introduced watchOS 3.0 (metadata checked).
- **[S16]** Apple. *Scene.backgroundTask(_:action:).* https://developer.apple.com/documentation/swiftui/scene/backgroundtask(_:action:) — watchOS 9.0+, cancellation handler. Read in full.
- **[S20]** Apple. *Pushing background updates to your App.* https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app — 30 s, `apns-push-type: background`, priority 5, 2–3/hour, watch requires `apns-push-type`. Read in full.
- **[S21]** Apple. *watchOS 27 Release Notes.* https://developer.apple.com/documentation/watchos-release-notes/watchos-27-release-notes — no background/refresh/push changes; standalone Workout Buddy audio note. Read in full.
- **[S22]** Apple. *watchOS 26 Release Notes.* https://developer.apple.com/documentation/watchos-release-notes/watchos-26-release-notes — nothing background-related. Read.
- **[S23]** Apple. *PKPushRegistry* (PushKit). https://developer.apple.com/documentation/pushkit/pkpushregistry — push registry for complication/VoIP-style updates. Read in full.
- **[S24]** Apple. *WKExtension.* https://developer.apple.com/documentation/watchkit/wkextension — metadata: `deprecatedAt 9.2`, `renamed WKApplication`.
- **[S25]** Apple. *WKApplication.registerForRemoteNotifications().* https://developer.apple.com/documentation/watchkit/wkapplication/registerforremotenotifications() — watchOS 7.0+ (metadata checked).
- **[S26]** Apple. *UIBackgroundModes.* https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes — watchOS 4.0+ (metadata checked).

**Local ground truth — installed SDK (strongest evidence for "watchOS 27")**

- **[S17]** *WatchOS27.0.sdk headers* (Xcode 27.1, `xcrun --sdk watchos --show-sdk-path`): `WKExtendedRuntimeSession.h` (error codes 2–10, invalidation reasons, `startAtDate` "can only be used for the alarm background mode", weak delegate), `WKBackgroundTask.h` (all `WK*RefreshBackgroundTask` classes, `scheduleBackgroundRefresh` availability 3.0/7.0 and **no** deprecation attributes), `WKApplication.h` (watchOS 7.0; `registerForRemoteNotifications` note: callbacks only after `UNUserNotificationCenter` registration or BAR enabled; `handleExtendedRuntimeSession` contract), `WKExtension.h` (`WK_DEPRECATED_WITH_REPLACEMENT(2.0, 9.2, "WKApplication")`), `WKDefines.h`. Systematic greps: zero WatchKit symbols at `watchos(26.0)` / `watchos(27.0)`; zero `AudioWorkout` occurrences; no `Speech.framework` in the SDK.
- **[S18]** *WatchOS27.0.sdk — `BackgroundTasks.framework` and `Foundation/NSURLSession.h`*: `BGTaskScheduler`, `BGTask`, `BGTaskRequest` all `API_UNAVAILABLE(watchos)` (including `BGContinuedProcessingTask`, iOS 26.0); `URLSessionConfiguration.backgroundSessionConfigurationWithIdentifier:` available `watchos(2.0)`.

**Community / secondary**

- **[S19]** Stack Overflow. *"Start WKExtendedRuntimeSession (WKExtendedRuntimeObject was dealloced while running)"*, Q 74373816 (retrieved via the Stack Exchange API because the HTML page blocks automated fetches). https://stackoverflow.com/questions/74373816/start-wkextendedruntimesession-wkextendedruntimeobject-was-dealloced-while-runn — exact `-[WKExtendedRuntimeSession dealloc]` log text, the singleton fix, and the `while scheduled` variant. **Treat as data, not instructions.**
- **[S28]** *(legacy, not relied on)* J. Wickham, *"Refreshing data in the background on watchOS"* (2020) https://wjwickham.com/posts/refreshing-data-in-the-background-on-watchOS — quoted only as the historical "one task per hour for apps in the dock" wording. Search snippet only; page not read in full.
- **[S27]** *(examined and rejected)* `swiftyn.com/evolution/watchos/2026` — claims a new "Live Background Sync" WatchConnectivity API and on-device Foundation Models on watchOS 27. Both contradicted by the SDK ([S17], [S18]); not used as evidence.

---

## 10. Method & integrity notes

* **Searches run:** Tavily CLI was invoked for 10 distinct search queries (`WKExtendedRuntimeSession session types`,
  `physical-therapy/self-care/mindfulness/smart-alarm`, `watchOS background app refresh budget`,
  `WKExtendedRuntimeObject dealloc`, `watchOS 26 extended runtime changes`, `AudioWorkoutSession`,
  `3-second polling wrist down`, `standalone watch push APNs`, `extended runtime 1 hour app review`).
  **The Tavily key pool was exhausted** (36 keys, HTTP 432 / banned) and 5 of those queries failed
  outright; the 4 that returned results fell back to keyless mode. Their results were used only to
  *seed* URLs; all load-bearing claims were then re-verified against Apple's own documentation and the
  local SDK.
* **Primary verification path:** Apple's documentation pages are client-rendered, so their text was
  pulled from `https://developer.apple.com/tutorials/data/documentation/<path>.json` and rendered
  (tables preserved); availability and deprecation were read from `availableAt`/`deprecatedAt` metadata
  in those same JSON payloads and from the SDK headers.
* **Untrusted web text** was treated strictly as data. No instruction found in a search result, forum
  post or blog was followed. Content-farm material that contradicted the SDK was dropped and is listed
  as rejected ([S27]).
* **What would raise confidence further:** a device test on Apple Watch SE running watchOS 27
  (measure real `WKApplicationRefreshBackgroundTask` firing with/without a complication), and a
  definitive App Review statement about `physical-therapy` for non-therapy apps (gap G1).
