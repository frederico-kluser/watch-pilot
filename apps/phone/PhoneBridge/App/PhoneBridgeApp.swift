import BackgroundTasks
import SwiftUI
import UserNotifications

/// T-800 Bridge — the iPhone side of Watch Pilot.
///
/// The phone is the bridge from start to finish: it watches the assistant chain
/// (Apple Watch → Mac mini hub), proves `watch.kluser.me` and `mac.kluser.me` are
/// online, manages the notification stream, and processes turns on-device with
/// Apple Intelligence. Everything it needs comes from the hub endpoints — it hits
/// the notification endpoint whenever it needs to fetch one.
@main
struct PhoneBridgeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task { await store.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.checkNow() }
            }
        }
    }
}

/// Owns the stores and the background refresh contract.
@MainActor
@Observable
final class AppStore {
    let monitor = StatusMonitor()
    let inbox = InboxStore()
    let intelligence: AppleIntelligence
    let turn: TurnController

    init() {
        let intel = AppleIntelligence()
        intelligence = intel
        turn = TurnController(intelligence: intel)
    }

    func bootstrap() async {
        UNUserNotificationCenter.current().delegate = NotificationRelay.shared
        registerBackgroundRefresh()
        intelligence.checkAvailability()
        monitor.start()
        inbox.start()
        scheduleBackgroundRefresh()
        await checkNow()
        // Debug/validation hook: run a full voice turn from a prepared audio file,
        // exactly as the microphone path would (emulated mic via generated audio).
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-WPTurnFile"),
           index + 1 < ProcessInfo.processInfo.arguments.count {
            let path = ProcessInfo.processInfo.arguments[index + 1]
            if let data = FileManager.default.contents(atPath: path) {
                NSLog("TURN-START: %@ (%d bytes)", path, data.count)
                await turn.run(data: data)
                NSLog("TURN-DONE: fase=%@ transcrição=%@ resposta=%@", String(describing: turn.phase), turn.transcript, turn.reply)
            }
        }
        // Debug hook for screenshot scripts: prove the Apple Intelligence path
        // by processing the last turn immediately after launch.
        if ProcessInfo.processInfo.arguments.contains("-WPProcessTurn") {
            let briefing = await intelligence.process(
                transcript: monitor.link.lastTranscript,
                reply: monitor.link.lastReply
            )
            // Console evidence for the screenshot/validation scripts.
            NSLog("BRIEFING-OUT: %@", briefing)
        }
    }

    /// "Sempre verifica": even suspended, the bridge re-checks the two routes and
    /// pulls any notification that appeared while it was away.
    private func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { [weak self] in
                await self?.backgroundRefresh()
                self?.scheduleBackgroundRefresh()
                refresh.setTaskCompleted(success: true)
            }
        }
    }

    private static let refreshID = "me.kluser.watchpilot.phone.refresh"

    func checkNow() async {
        await monitor.refresh()
        await inbox.fetch()
    }

    func backgroundRefresh() async {
        await monitor.refresh()
        await inbox.fetch()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "me.kluser.watchpilot.phone.refresh")
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Keeps local notifications working while the app is foregrounded.
final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRelay()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}
