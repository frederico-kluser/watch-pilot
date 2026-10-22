import Foundation
import UserNotifications
import WatchKit

/// Owns every contract the watchOS scheduler gives us.
///
/// Why a singleton: `WKExtendedRuntimeSession` is deallocated when nothing holds a
/// strong reference, and watchOS then logs "WKExtendedRuntimeObject was dealloced
/// while running" and kills the session. One long-lived object owns the session and
/// is the delegate of it.
///
/// The honest reality of watchOS (verified against the watchOS 27 SDK) is that a
/// 3-second polling loop only runs while the app is frontmost. Once the wrist goes
/// down the app is suspended: the extended session keeps the *contract* alive for up
/// to an hour (``WKBackgroundModes`` = `physical-therapy`), but the scheduler grants
/// only seconds of CPU at a time to background tasks. Completion is therefore
/// notification-driven — the hub pushes to the phone through iMessage, which the
/// watch mirrors — with polling resuming the moment the app is foreground again.
@MainActor
final class RuntimeCoordinator: NSObject, ObservableObject {
    static let shared = RuntimeCoordinator()

    /// Fired when the system wakes us and a task is in flight.
    var onBackgroundPoll: (() async -> Void)?

    @Published private(set) var extendedSessionState: WKExtendedRuntimeSessionState = .notStarted
    @Published private(set) var notificationPermission: UNAuthorizationStatus = .notDetermined

    private var extendedSession: WKExtendedRuntimeSession?
    private var urlSessionTasks: [String: WKURLSessionRefreshBackgroundTask] = [:]
    private var backgroundURLSession: URLSession?

    static let backgroundSessionIdentifier = "me.kluser.watchpilot.bgpoll"

    // MARK: - Extended runtime

    /// Must be called while the app is active: watchOS refuses to start a session
    /// from the background (`MustBeActiveToStartOrSchedule`).
    func startExtendedRuntimeIfNeeded() {
        if let session = extendedSession, session.state == .running || session.state == .scheduled {
            return
        }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        extendedSession = session
        extendedSessionState = session.state
    }

    func stopExtendedRuntime() {
        guard let session = extendedSession else { return }
        if session.state == .running || session.state == .scheduled {
            session.invalidate()
        }
        extendedSession = nil
        extendedSessionState = .notStarted
    }

    /// Ask the scheduler for a wake-up. The budget is small (roughly four refreshes
    /// per hour, and only with a complication on the active face) so callers must
    /// treat this as best effort, not as a timer.
    func scheduleBackgroundRefresh(after seconds: TimeInterval = 120) {
        let fireDate = Date().addingTimeInterval(seconds)
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: fireDate,
            userInfo: "PROGRESS_POLL" as NSString
        ) { error in
            if let error {
                print("[WatchPilot] background refresh recusado: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Notifications

    /// Read the current permission state. Deliberately does **not** prompt: asking
    /// for notifications before the app has done anything for the user is a
    /// well-known trust killer, so the prompt is deferred until the first answer
    /// actually arrives (see `requestPermissionIfNeeded`).
    func bootstrapNotifications() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        notificationPermission = await center.notificationSettings().authorizationStatus
    }

    /// Prompt for notification permission at the first moment it is justified: a
    /// task just completed, so there is something to notify about.
    func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        notificationPermission = await center.notificationSettings().authorizationStatus
    }

    /// A local notification lets the user know the answer arrived even if they
    /// lowered their wrist while the hub was thinking.
    func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        WKInterfaceDevice.current().play(.success)
    }

    // MARK: - Background URLSession (deferred fetch when the app is suspended)

    func scheduleBackgroundPoll(url: URL, headers: [String: String]) {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        backgroundURLSession = session
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.timeoutInterval = 60
        session.downloadTask(with: request).resume()
    }

    func complete(_ task: WKURLSessionRefreshBackgroundTask) {
        task.setTaskCompletedWithSnapshot(false)
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension RuntimeCoordinator: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            self.extendedSessionState = extendedRuntimeSession.state
            print("[WatchPilot] sessão estendida ativa até \(String(describing: extendedRuntimeSession.expirationDate))")
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            WKInterfaceDevice.current().play(.retry)
            self.scheduleBackgroundRefresh(after: 90)
        }
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: (any Error)?
    ) {
        Task { @MainActor in
            self.extendedSessionState = .notStarted
            print("[WatchPilot] sessão estendida invalidada (\(reason.rawValue)) \(String(describing: error))")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension RuntimeCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - URLSessionDownloadDelegate

extension RuntimeCoordinator: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let data = try? Data(contentsOf: location),
              let status = try? JSONDecoder().decode(TaskStatus.self, from: data)
        else { return }
        Task { @MainActor in
            AssistantController.shared.apply(status)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        Task { @MainActor in
            if let identifier = session.configuration.identifier,
               let backgroundTask = self.urlSessionTasks.removeValue(forKey: identifier) {
                self.complete(backgroundTask)
            }
        }
    }
}

// MARK: - App delegate (background task plumbing)

extension RuntimeCoordinator: WKApplicationDelegate {
    nonisolated func applicationDidFinishLaunching() {
        Task { @MainActor in
            await self.bootstrapNotifications()
        }
    }

    nonisolated func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let urlTask as WKURLSessionRefreshBackgroundTask:
                Task { @MainActor in
                    self.urlSessionTasks[urlTask.sessionIdentifier] = urlTask
                    let configuration = URLSessionConfiguration.background(withIdentifier: urlTask.sessionIdentifier)
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.backgroundURLSession = session
                }
            case let refresh as WKApplicationRefreshBackgroundTask:
                Task { @MainActor in
                    if let handler = self.onBackgroundPoll {
                        await handler()
                    }
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    nonisolated func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            await AssistantController.shared.registerDeviceToken(token)
        }
    }

    nonisolated func didFailToRegisterForRemoteNotificationsWithError(_ error: any Error) {
        print("[WatchPilot] APNs indisponível (esperado com Personal Team): \(error.localizedDescription)")
    }
}
