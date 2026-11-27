import Combine
import Foundation

/// Fork (Live TV step 17a): the Sports page's settings, per profile.
@MainActor
final class SportsSettings: ObservableObject {
    static let shared = SportsSettings()

    private enum Key {
        static let region = "livetv.sports.region"
        static let hideScores = "livetv.sports.hideScores"
        static let changedLeagues = "livetv.sports.changedLeagues"
    }

    /// "" = from the Apple TV's country.
    @Published var region: String { didSet { ProfileSettings.current.set(region, forKey: Key.region) } }
    /// Scores blanked everywhere (watching later).
    @Published var hideScores: Bool { didSet { ProfileSettings.current.set(hideScores, forKey: Key.hideScores) } }
    /// Leagues taken off ("id") or added ("+id") in All Events.
    @Published var changedLeagues: Set<String> {
        didSet { ProfileSettings.current.set(Array(changedLeagues).sorted(), forKey: Key.changedLeagues) }
    }

    private init() {
        let store = ProfileSettings.current
        region = store.string(forKey: Key.region) ?? ""
        hideScores = store.bool(forKey: Key.hideScores)
        changedLeagues = Set(store.stringArray(forKey: Key.changedLeagues) ?? [])
    }

    /// The profile changed: its own settings.
    func reload() {
        let store = ProfileSettings.current
        region = store.string(forKey: Key.region) ?? ""
        hideScores = store.bool(forKey: Key.hideScores)
        changedLeagues = Set(store.stringArray(forKey: Key.changedLeagues) ?? [])
    }

    static var country: String { Locale.current.region?.identifier ?? "US" }

    var effectiveRegion: String { region.isEmpty ? SportsCatalog.region(ofCountry: Self.country) : region }

    func isShown(_ league: League) -> Bool {
        SportsCatalog.shown(league, region: effectiveRegion, country: Self.country, changed: changedLeagues)
    }

    func toggle(_ league: League) {
        changedLeagues = SportsCatalog.toggled(league, region: effectiveRegion, country: Self.country, changed: changedLeagues)
    }

    /// The leagues All Events shows (ESPN's for now), in the region's order.
    var shownLeagues: [League] {
        let order = SportsCatalog.sportsOrder(region: effectiveRegion)
        return SportsCatalog.leagues.filter { $0.onESPN && isShown($0) }
            .enumerated()
            .sorted { (order.firstIndex(of: $0.element.sport) ?? 99, $0.offset) < (order.firstIndex(of: $1.element.sport) ?? 99, $1.offset) }
            .map(\.element)
    }
}

/// Fork (Live TV step 17a): today's games and the days around, from ESPN's
/// scoreboard, as Android's SportsRepository: one request per league and
/// ESPN day, kept on disk; while the page is open, leagues with a game on
/// are asked again every 30 s, the others every 10 minutes (other days
/// less often).
@MainActor
final class SportsStore: ObservableObject {
    static let shared = SportsStore()

    /// The page's days: a week back to a week ahead (as Android's).
    static let daysBack = 7
    static let daysAhead = 7

    /// Games by "league|ESPN day".
    @Published private(set) var boards: [String: Board] = [:]
    @Published private(set) var leagueLogos: [String: String] = [:]
    /// Leagues still being asked for the day shown.
    @Published private(set) var pending = 0
    /// The day shown: 0 today, -1 yesterday…
    @Published var dayOffset = 0 { didSet { if dayOffset != oldValue { poke() } } }

    struct Board: Codable {
        var fetchedAt: Date
        var events: [SportsEvent]
    }

    private struct Saved: Codable {
        var boards: [String: Board]
        var logos: [String: String]
    }

    private var visible = false
    private var loop: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        load()
        SportsSettings.shared.$changedLeagues.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.poke() }
        }.store(in: &cancellables)
        SportsSettings.shared.$region.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.poke() }
        }.store(in: &cancellables)
    }

    // MARK: Days

    /// The calendar of the day tabs (the Apple TV's time zone).
    static var calendar: Calendar { Calendar.current }

    static func dayStart(_ offset: Int, now: Date = Date()) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    /// The games of a day, each league's in time order, the leagues in the
    /// region's order (stale copies of live games shown as ended).
    func games(day offset: Int, now: Date = Date()) -> [(league: League, events: [SportsEvent])] {
        let start = Self.dayStart(offset, now: now)
        let end = Self.dayStart(offset + 1, now: now)
        let days = SportsESPN.espnDays(from: start, to: end)
        var result: [(league: League, events: [SportsEvent])] = []
        for league in SportsSettings.shared.shownLeagues {
            var seen = Set<String>()
            var list: [SportsEvent] = []
            for day in days {
                for event in boards[league.id + "|" + day]?.events ?? [] where seen.insert(event.id).inserted {
                    let inDay = event.hasTime
                        ? (event.start >= start && event.start < end)
                        : (event.start < end && (event.end ?? event.start).addingTimeInterval(24 * 3600) > start)
                    if inDay { list.append(SportsStale.fix(event, sport: league.sport, now: now)) }
                }
            }
            if !list.isEmpty { result.append((league, list.sorted { $0.start < $1.start })) }
        }
        return result
    }

    // MARK: Asking

    /// The page is open (asks often) or closed (stops).
    func setVisible(_ on: Bool) {
        visible = on
        if on { poke() } else { loop?.cancel(); loop = nil }
    }

    /// Ask now what's due, then keep going while the page is open.
    func poke() {
        guard visible else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.round()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// Everything shown: asked again, whatever its age.
    func refresh() {
        let days = Self.espnDaysShown(dayOffset)
        for league in SportsSettings.shared.shownLeagues {
            for day in days { boards[league.id + "|" + day]?.fetchedAt = .distantPast }
        }
        poke()
    }

    private static func espnDaysShown(_ offset: Int) -> [String] {
        SportsESPN.espnDays(from: dayStart(offset), to: dayStart(offset + 1))
    }

    /// How long a board stays fresh: 30 s with a game on (or about to
    /// start), 10 min around today, longer for other days.
    private func maxAge(_ board: Board, offset: Int, now: Date) -> TimeInterval {
        let busy = board.events.contains { event in
            event.state == .live
                || (event.state == .pre && event.hasTime && event.start.timeIntervalSince(now) < 15 * 60
                    && now.timeIntervalSince(event.start) < 6 * 3600)
        }
        if busy { return 30 }
        if abs(offset) <= 1 { return 10 * 60 }
        return offset < 0 ? 6 * 3600 : 3 * 3600
    }

    private func round() async {
        let now = Date()
        let offset = dayOffset
        let days = Self.espnDaysShown(offset)
        var due: [(League, String)] = []
        for league in SportsSettings.shared.shownLeagues {
            for day in days {
                let key = league.id + "|" + day
                if let board = boards[key], now.timeIntervalSince(board.fetchedAt) < maxAge(board, offset: offset, now: now) {
                    continue
                }
                due.append((league, day))
            }
        }
        // Today's games first when other days are shown (they're live).
        guard !due.isEmpty else { return }
        pending = due.count
        // Four at a time; each league shows as it comes in.
        var index = 0
        while index < due.count, !Task.isCancelled {
            let part = Array(due[index..<min(index + 4, due.count)])
            index += part.count
            let results = await withTaskGroup(of: (String, Data?).self) { group in
                for (league, day) in part {
                    group.addTask { (league.id + "|" + day, await Self.fetch(league, day: day)) }
                }
                var all: [(String, Data?)] = []
                for await item in group { all.append(item) }
                return all
            }
            for (key, data) in results {
                guard let data, let league = SportsCatalog.league(String(key.split(separator: "|").first ?? "")) else { continue }
                let events = SportsESPN.parseScoreboard(league, data: data)
                boards[key] = Board(fetchedAt: Date(), events: events)
                if leagueLogos[league.id] == nil, let logo = SportsESPN.leagueLogo(data) { leagueLogos[league.id] = logo }
            }
            pending = max(0, due.count - index)
        }
        pending = 0
        scheduleSave()
    }

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    nonisolated private static func fetch(_ league: League, day: String) async -> Data? {
        guard let url = SportsESPN.scoreboardURL(league, day: day) else { return nil }
        return await fetch(url)
    }

    // MARK: A game's page (17c)

    private var summaries: [String: (at: Date, extras: SportsGameExtras)] = [:]

    /// A game as the latest board has it.
    func event(id: String) -> SportsEvent? {
        for board in boards.values {
            if let event = board.events.first(where: { $0.id == id }) {
                return SportsStale.fix(event, sport: SportsCatalog.league(event.leagueId)?.sport, now: Date())
            }
        }
        return nil
    }

    /// The summary of a game (scoring, stats, leaders, line-ups, table,
    /// info, chances): kept 25 s while it's on, 30 minutes otherwise (as
    /// Android's).
    func extras(for event: SportsEvent) async -> SportsGameExtras? {
        guard let espnId = event.espnId, let league = SportsCatalog.league(event.leagueId),
              let url = SportsSummary.url(league, espnId: espnId) else { return nil }
        let maxAge: TimeInterval = event.state == .live ? 25 : 30 * 60
        if let kept = summaries[event.id], Date().timeIntervalSince(kept.at) < maxAge { return kept.extras }
        guard let data = await Self.fetch(url) else { return summaries[event.id]?.extras }
        let extras = SportsSummary.parse(data, event: event, sport: league.sport)
        if summaries.count > 50 { summaries.removeAll() }
        summaries[event.id] = (Date(), extras)
        return extras
    }

    /// A game's league asked again now (its page, while it's on).
    func refreshGame(_ event: SportsEvent) async {
        guard let league = SportsCatalog.league(event.leagueId) else { return }
        let day = SportsESPN.espnDay(event.start)
        guard let data = await Self.fetch(league, day: day) else { return }
        boards[league.id + "|" + day] = Board(fetchedAt: Date(), events: SportsESPN.parseScoreboard(league, data: data))
    }

    nonisolated private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        // As Android: a desktop browser's name (ESPN answers it best).
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: Disk

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("livetv-sports-boards.json")
    }

    private func load() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        boards = saved.boards
        leagueLogos = saved.logos
    }

    /// Saved a moment after the last change; days far from today dropped.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            let keep = Set((-(Self.daysBack + 1)...(Self.daysAhead + 1)).flatMap { Self.espnDaysShown($0) })
            let kept = self.boards.filter { keep.contains(String($0.key.split(separator: "|").last ?? "")) }
            let saved = Saved(boards: kept, logos: self.leagueLogos)
            let url = Self.fileURL
            Task.detached(priority: .utility) {
                guard let url, let data = try? JSONEncoder().encode(saved) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
