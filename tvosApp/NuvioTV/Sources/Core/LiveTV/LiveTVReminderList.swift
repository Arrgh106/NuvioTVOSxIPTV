import Foundation

/// A programme reminder (LIVE_TV_DESIGN.md, step 7), as Android's `Reminder`:
/// one show on one channel, known by the channel and the start time.
struct LiveTVReminder: Codable, Hashable, Identifiable {
    let channelID: Int
    let channelName: String
    let title: String
    let start: Date

    var id: String { "\(channelID)|\(Int(start.timeIntervalSince1970))" }
}

/// The reminders of a profile and when they're due. No UIKit, so the rules
/// have Linux tests (Tests/LiveTVLogic).
struct LiveTVReminderList: Equatable {
    /// As on Android: the prompt comes a minute before the start ...
    static let lead: TimeInterval = 60
    /// ... and up to ten minutes after it (the app was closed, a film ran).
    static let late: TimeInterval = 10 * 60
    /// Shows that started longer ago than this are dropped.
    static let grace: TimeInterval = 30 * 60

    private(set) var items: [LiveTVReminder] = []

    init(_ items: [LiveTVReminder] = []) {
        self.items = items.sorted { $0.start < $1.start }
    }

    func contains(channelID: Int, start: Date) -> Bool {
        items.contains { $0.channelID == channelID && $0.start == start }
    }

    /// Adds it, or removes it when it's set already. True when it's set now.
    @discardableResult
    mutating func toggle(_ reminder: LiveTVReminder) -> Bool {
        if contains(channelID: reminder.channelID, start: reminder.start) {
            remove(reminder)
            return false
        }
        items.append(reminder)
        items.sort { $0.start < $1.start }
        return true
    }

    mutating func remove(_ reminder: LiveTVReminder) {
        items.removeAll { $0.channelID == reminder.channelID && $0.start == reminder.start }
    }

    /// Drops shows that started more than `grace` ago. True when any went.
    @discardableResult
    mutating func prune(now: Date) -> Bool {
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.start) > Self.grace }
        return items.count != before
    }

    /// The first reminder to show now, leaving out those shown already.
    func due(now: Date, shown: Set<String>) -> LiveTVReminder? {
        items.first { reminder in
            !shown.contains(reminder.id)
                && now >= reminder.start.addingTimeInterval(-Self.lead)
                && now < reminder.start.addingTimeInterval(Self.late)
        }
    }

    /// Reminders still to come (or just started), for the list in Settings.
    func upcoming(now: Date) -> [LiveTVReminder] {
        items.filter { now < $0.start.addingTimeInterval(Self.late) }
    }
}
