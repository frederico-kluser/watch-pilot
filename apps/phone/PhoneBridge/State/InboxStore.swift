import Foundation
import Observation
import UserNotifications

/// Notification management for the bridge.
///
/// The rule the owner set: **the app always checks and manages notifications, and
/// always hits the endpoint when it needs to fetch one.** So this store polls
/// `GET /api/v1/inbox` on a timer (and immediately on demand), turns unseen items
/// into local notifications, keeps a read/hidden ledger locally, and can push a
/// notification back through `POST /api/v1/notify`.
@MainActor
@Observable
final class InboxStore {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let body: String
        let date: Date
        var read: Bool
    }

    private(set) var items: [Item] = []
    private(set) var lastFetch: Date?
    private(set) var lastError: String = ""
    private(set) var fetching = false
    /// Set when the app wants the UI to jump to the notification tab.
    var needsAttention = false

    private let client: HubClient
    private var timer: Task<Void, Never>?
    private var seenIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? []) }
        set { UserDefaults.standard.standardArrayStore(newValue.sorted(), forKey: Self.seenKey) }
    }

    private static let seenKey = "WPBridgeSeenNotifications"
    private static let readKey = "WPBridgeReadNotifications"

    init(client: HubClient = .live()) {
        self.client = client
    }

    func start(interval: TimeInterval = 60) {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    var unreadCount: Int { items.filter { !$0.read }.count }

    /// Hit the notification endpoint and merge whatever comes back.
    func fetch() async {
        guard !fetching else { return }
        fetching = true
        defer { fetching = false }

        do {
            let remote = try await client.inbox(limit: 40)
            let readIDs = Set(UserDefaults.standard.stringArray(forKey: Self.readKey) ?? [])
            var fresh = 0
            items = remote.map { raw in
                let item = Item(
                    id: raw.id,
                    title: raw.title,
                    body: raw.body,
                    date: Date(timeIntervalSince1970: raw.createdAt),
                    read: readIDs.contains(raw.id) || seenIDs.contains(raw.id)
                )
                if !seenIDs.contains(raw.id) { fresh += 1 }
                return item
            }
            seenIDs = seenIDs.union(remote.map(\.id))
            lastFetch = Date()
            lastError = ""
            NSLog("INBOX: %d itens do endpoint (%d novos)", items.count, fresh)
            if fresh > 0 {
                needsAttention = true
                await notifyLocally(newItems: items.prefix(fresh))
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].read = true
        var readIDs = Set(UserDefaults.standard.stringArray(forKey: Self.readKey) ?? [])
        readIDs.insert(id)
        UserDefaults.standard.set(readIDs.sorted(), forKey: Self.readKey)
    }

    func markAllRead() {
        for index in items.indices { items[index].read = true }
        UserDefaults.standard.set(items.map(\.id), forKey: Self.readKey)
    }

    /// Push a notification back through the hub endpoint (management goes both ways).
    func send(title: String, body: String) async throws {
        let record = try await client.notify(title: title, body: body)
        let item = Item(
            id: record.id, title: record.title, body: record.body,
            date: Date(timeIntervalSince1970: record.createdAt), read: true
        )
        items.insert(item, at: 0)
    }

    // MARK: - Local notifications

    /// Ask for the notification permission — only from a user action, never at launch.
    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private func notifyLocally(newItems: ArraySlice<Item>) async {
        // Debug hook for screenshot scripts (same flag as the watch app).
        if ProcessInfo.processInfo.arguments.contains("-WPNoNotifications") { return }
        let center = UNUserNotificationCenter.current()
        // The permission is requested from the UI, not here: only post when granted.
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for item in newItems {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: item.id,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

private extension UserDefaults {
    func standardArrayStore(_ value: [String], forKey key: String) {
        set(value, forKey: key)
    }
}
