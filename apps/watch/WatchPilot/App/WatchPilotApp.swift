import SwiftUI
import WatchKit

/// Standalone watchOS app: no iOS companion, no WatchKit extension.
///
/// `WKWatchOnly` in Info.plist keeps it watch-only, and the application delegate is
/// `RuntimeCoordinator` because watchOS delivers background tasks, notification
/// callbacks and the extended-session lifecycle to the *application* delegate.
@main
struct WatchPilotApp: App {
    @WKApplicationDelegateAdaptor(RuntimeCoordinator.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .backgroundTask(.appRefresh("PROGRESS_POLL")) { _ in
            // The scheduler gives us seconds here: read the state once and get out.
            await AssistantController.shared.refreshActiveTask()
            RuntimeCoordinator.shared.scheduleBackgroundRefresh(after: 300)
        }
        .onChange(of: scenePhase) { _, newPhase in
            AssistantController.shared.handleScenePhase(newPhase == .active)
        }
    }
}
