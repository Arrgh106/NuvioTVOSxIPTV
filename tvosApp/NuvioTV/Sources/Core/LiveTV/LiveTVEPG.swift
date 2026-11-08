import Foundation

/// What's on now/next per channel, from the provider's short EPG. Fetched on
/// demand (visible list rows, the channel being watched) and kept in memory
/// until the current programme ends, so scrolling back costs nothing.
@MainActor
final class LiveTVEPG {
    static let shared = LiveTVEPG()

    struct NowNext: Equatable {
        let now: XtreamProgram?
        let next: XtreamProgram?
    }

    private struct Entry {
        let programs: [XtreamProgram]
        let fetchedAt: Date
    }

    private var entries: [Int: Entry] = [:]
    private var inFlight: [Int: Task<[XtreamProgram], Never>] = [:]
    private var accountID: String?
    private var client: XtreamClient?

    /// Cached answer only, no network: for configuring a cell right away.
    func cached(_ streamID: Int) -> NowNext? {
        guard let entry = entries[streamID], isFresh(entry) else { return nil }
        return Self.nowNext(entry.programs)
    }

    func nowNext(for streamID: Int) async -> NowNext? {
        if let cached = cached(streamID) { return cached }
        guard let client = currentClient() else { return nil }
        let task: Task<[XtreamProgram], Never>
        if let running = inFlight[streamID] {
            task = running
        } else {
            task = Task.detached(priority: .utility) {
                (try? await client.shortEPG(streamID: streamID, limit: 3)) ?? []
            }
            inFlight[streamID] = task
        }
        let programs = await task.value
        inFlight[streamID] = nil
        entries[streamID] = Entry(programs: programs, fetchedAt: Date())
        if entries.count > 2000 { entries.removeAll() }
        return Self.nowNext(programs)
    }

    // MARK: -

    /// Fresh until the programme that was on has ended; channels without EPG
    /// are asked again after 30 minutes.
    private func isFresh(_ entry: Entry) -> Bool {
        let now = Date()
        if let current = entry.programs.first(where: { $0.isOn(at: entry.fetchedAt) }) {
            return now < current.end
        }
        return now.timeIntervalSince(entry.fetchedAt) < 30 * 60
    }

    private static func nowNext(_ programs: [XtreamProgram]) -> NowNext {
        let date = Date()
        let now = programs.first { $0.isOn(at: date) }
        let next = programs.first { $0.start >= (now?.end ?? date) }
        return NowNext(now: now, next: next)
    }

    private func currentClient() -> XtreamClient? {
        guard let account = XtreamAccountStore.load() else { return nil }
        if account.id != accountID || client == nil {
            accountID = account.id
            entries.removeAll()
            client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))
        }
        return client
    }
}
