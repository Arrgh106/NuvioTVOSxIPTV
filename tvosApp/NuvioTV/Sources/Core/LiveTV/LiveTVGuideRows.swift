import Foundation

extension XtreamProgram: LiveTVTimed {}

/// Programmes per guide row (LIVE_TV_DESIGN.md, step 1). Loaded only for
/// rows that come on screen, off the main thread, from the stored full guide;
/// channels the guide doesn't cover fall back to the provider's short EPG
/// (now/next). Kept in memory, so scrolling back costs nothing.
@MainActor
final class LiveTVGuideRows {
    static let shared = LiveTVGuideRows()

    private struct Entry {
        let programmes: [XtreamProgram]
        let loadedAt: Date
        /// From the short EPG: only now/next, asked again sooner.
        let partial: Bool
    }

    private var entries: [Int: Entry] = [:]
    private var order: [Int] = []
    private var inFlight: [Int: Task<Entry, Never>] = [:]
    private var guideObserver: NSObjectProtocol?
    private var profileObserver: NSObjectProtocol?
    private static let capacity = 800

    private init() {
        // A new full guide replaces everything loaded so far.
        guideObserver = NotificationCenter.default.addObserver(
            forName: LiveTVGuide.updatedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.entries.removeAll()
                self?.order.removeAll()
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
            }
        }
        // Another profile (another provider): stream ids mean other channels.
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileSettings.activeProfileChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.entries.removeAll()
                self?.order.removeAll()
            }
        }
    }

    /// Posted when cached rows were dropped (new guide); visible rows reload.
    static let changedNotification = Notification.Name("nuvio.tv.livetv.guiderows.changed")

    /// Cached programmes only, no loading: to draw a row right away.
    func cached(_ channel: XtreamLiveChannel) -> [XtreamProgram]? {
        guard let entry = entries[channel.streamID], isFresh(entry) else { return nil }
        return entry.programmes
    }

    func programmes(for channel: XtreamLiveChannel) async -> [XtreamProgram] {
        if let cached = cached(channel) { return cached }
        let id = channel.streamID
        let task: Task<Entry, Never>
        if let running = inFlight[id] {
            task = running
        } else {
            let epgID = channel.epgChannelID?.trimmingCharacters(in: .whitespaces)
            let reader = LiveTVGuide.shared.reader()
            task = Task { @MainActor in
                if let epgID, !epgID.isEmpty, let reader {
                    let now = Date()
                    // From the current half hour to the end of the stored
                    // guide; channels with catch-up from as far back as it goes.
                    let from = LiveTVCatchup.earliest(archiveDays: channel.archiveDays, now: now)
                        ?? LiveTVTimeline.floorSlot(now)
                    let to = now.addingTimeInterval(LiveTVGuide.futureWindow)
                    let list = await Task.detached(priority: .userInitiated) {
                        reader.programmes(channel: epgID, from: from, to: to, limit: 900)
                    }.value
                    if !list.isEmpty {
                        return Entry(programmes: list, loadedAt: Date(), partial: false)
                    }
                }
                let nowNext = await LiveTVEPG.shared.nowNext(for: id)
                let list = [nowNext?.now, nowNext?.next].compactMap { $0 }
                return Entry(programmes: list, loadedAt: Date(), partial: true)
            }
            inFlight[id] = task
        }
        let entry = await task.value
        inFlight[id] = nil
        store(entry, for: id)
        return entries[id]?.programmes ?? entry.programmes
    }

    private func store(_ entry: Entry, for id: Int) {
        if entries[id] == nil { order.append(id) }
        entries[id] = Entry(programmes: Self.withoutDuplicates(entry.programmes), loadedAt: entry.loadedAt, partial: entry.partial)
        if order.count > Self.capacity {
            let drop = order.prefix(order.count - Self.capacity)
            for key in drop { entries[key] = nil }
            order.removeFirst(drop.count)
        }
    }

    /// Some providers list every show twice (the same start and title from
    /// two guide sources): once is enough.
    nonisolated static func withoutDuplicates(_ list: [XtreamProgram]) -> [XtreamProgram] {
        var seen = Set<String>()
        return list.filter { seen.insert("\($0.start.timeIntervalSince1970)|\($0.title)").inserted }
    }

    /// The full guide is refreshed every 12 h; rows are re-read after 6 h so
    /// the start stays near now. Now/next only: until the current one ends.
    private func isFresh(_ entry: Entry) -> Bool {
        let now = Date()
        if entry.partial {
            if let current = entry.programmes.first(where: { $0.isOn(at: entry.loadedAt) }) {
                return now < current.end
            }
            return now.timeIntervalSince(entry.loadedAt) < 30 * 60
        }
        return now.timeIntervalSince(entry.loadedAt) < 6 * 3600
    }
}
