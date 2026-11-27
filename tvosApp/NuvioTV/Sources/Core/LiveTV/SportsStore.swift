import Combine
import Foundation

/// Fork (Live TV step 17a): the Sports page's settings, per profile.
@MainActor
final class SportsSettings: ObservableObject {
    static let shared = SportsSettings()

    private enum Key {
        static let region = "livetv.sports.region"
        static let hideScores = "livetv.sports.hideScores"
        static let scores = "livetv.sports.scores"
        static let changedLeagues = "livetv.sports.changedLeagues"
        static let followed = "livetv.sports.followed"
    }

    /// Which scores show (17d): all, all but the live ones (results
    /// yes, running games no), or none.
    enum ScoreMode: String, CaseIterable {
        case all, hideLive, hideAll

        var title: String {
            switch self {
            case .all: return L10n.string("livetv_sports_scores_all", fallback: "Show All Scores")
            case .hideLive: return L10n.string("livetv_sports_scores_hide_live", fallback: "Hide Live Scores")
            case .hideAll: return L10n.string("livetv_sports_scores_hide_all", fallback: "Hide All Scores")
            }
        }
    }

    /// "" = from the Apple TV's country.
    @Published var region: String { didSet { ProfileSettings.current.set(region, forKey: Key.region) } }
    @Published var scoreMode: ScoreMode { didSet { ProfileSettings.current.set(scoreMode.rawValue, forKey: Key.scores) } }
    /// Leagues taken off ("id") or added ("+id") in All Events.
    @Published var changedLeagues: Set<String> {
        didSet { ProfileSettings.current.set(Array(changedLeagues).sorted(), forKey: Key.changedLeagues) }
    }
    /// The teams you follow (17d), as Android's SportsFollows.
    @Published private(set) var followed: [TeamInfo] {
        didSet { ProfileSettings.current.set(try? JSONEncoder().encode(followed), forKey: Key.followed) }
    }

    private init() {
        let store = ProfileSettings.current
        region = store.string(forKey: Key.region) ?? ""
        scoreMode = Self.scoreMode(store)
        changedLeagues = Set(store.stringArray(forKey: Key.changedLeagues) ?? [])
        followed = Self.followed(store)
    }

    /// The profile changed: its own settings.
    func reload() {
        let store = ProfileSettings.current
        region = store.string(forKey: Key.region) ?? ""
        scoreMode = Self.scoreMode(store)
        changedLeagues = Set(store.stringArray(forKey: Key.changedLeagues) ?? [])
        followed = Self.followed(store)
    }

    private static func scoreMode(_ store: UserDefaults) -> ScoreMode {
        if let raw = store.string(forKey: Key.scores), let mode = ScoreMode(rawValue: raw) { return mode }
        // 17b's Hide Scores switch.
        return store.bool(forKey: Key.hideScores) ? .hideAll : .all
    }

    private static func followed(_ store: UserDefaults) -> [TeamInfo] {
        guard let data = store.data(forKey: Key.followed) else { return [] }
        return (try? JSONDecoder().decode([TeamInfo].self, from: data)) ?? []
    }

    /// A game's scores are hidden (Hide Live Scores: only while it's on).
    func hides(_ event: SportsEvent) -> Bool {
        switch scoreMode {
        case .all: return false
        case .hideLive: return event.state == .live
        case .hideAll: return true
        }
    }

    static var country: String { Locale.current.region?.identifier ?? "US" }

    var effectiveRegion: String { region.isEmpty ? SportsCatalog.region(ofCountry: Self.country) : region }

    func isShown(_ league: League) -> Bool {
        SportsCatalog.shown(league, region: effectiveRegion, country: Self.country, changed: changedLeagues)
    }

    func toggle(_ league: League) {
        changedLeagues = SportsCatalog.toggled(league, region: effectiveRegion, country: Self.country, changed: changedLeagues)
    }

    /// The leagues All Events shows, in the region's order (your own
    /// country's football first among football).
    var shownLeagues: [League] {
        let order = SportsCatalog.sportsOrder(region: effectiveRegion)
        let region = effectiveRegion
        let country = SportsCatalog.isCountry(region) ? region : Self.country
        func home(_ league: League) -> Int {
            league.sport == .football && SportsCatalog.inRegion(league, region: "", country: country) ? 0 : 1
        }
        return SportsCatalog.all.filter { $0.hasFeed && isShown($0) }
            .enumerated()
            .sorted {
                (order.firstIndex(of: $0.element.sport) ?? 99, home($0.element), $0.offset)
                    < (order.firstIndex(of: $1.element.sport) ?? 99, home($1.element), $1.offset)
            }
            .map(\.element)
    }

    // MARK: Teams you follow

    /// ESPN's football and rugby teams keep their id in every competition
    /// (Dortmund in the Bundesliga and the Champions League).
    static func sameTeam(_ a: TeamInfo, _ b: TeamInfo) -> Bool {
        if a.key == b.key { return true }
        guard a.id == b.id else { return false }
        func family(_ id: String) -> String? {
            if id.hasPrefix("soccer/") { return "soccer" }
            if id.hasPrefix("rugby/") { return "rugby" }
            return nil
        }
        return family(a.leagueId) != nil && family(a.leagueId) == family(b.leagueId)
    }

    func isFollowed(_ team: TeamInfo) -> Bool { followed.contains { Self.sameTeam($0, team) } }

    func toggleFollow(_ team: TeamInfo) {
        if isFollowed(team) {
            followed.removeAll { Self.sameTeam($0, team) }
        } else {
            followed.append(team)
        }
    }

    /// A game of a team you follow.
    func isMine(_ event: SportsEvent) -> Bool { event.sides.contains { isFollowed($0.team) } }
}

/// Fork (Live TV step 17a): today's games and the days around, from ESPN's
/// scoreboard, as Android's SportsRepository: one request per league and
/// ESPN day, kept on disk; while the page is open, leagues with a game on
/// are asked again every 30 s, the others every 10 minutes (other days
/// less often). The 3. Liga comes from OpenLigaDB (a season per request).
@MainActor
final class SportsStore: ObservableObject {
    static let shared = SportsStore()

    /// The page's days: a week back to a week ahead (as Android's).
    static let daysBack = 7
    static let daysAhead = 7

    /// Games by "league|ESPN day" (OpenLigaDB: "league|S2026", a season).
    @Published private(set) var boards: [String: Board] = [:]
    @Published private(set) var leagueLogos: [String: String] = [:]
    /// Leagues still being asked for the day shown.
    @Published private(set) var pending = 0
    /// The day shown: 0 today, -1 yesterday…
    @Published var dayOffset = 0 { didSet { if dayOffset != oldValue { poke() } } }
    /// The schedules of the teams you follow (by team key).
    @Published private(set) var schedules: [String: Board] = [:]
    /// League tables (by league id).
    @Published private(set) var standings: [String: SportsStandings] = [:]

    struct Board: Codable {
        var fetchedAt: Date
        var events: [SportsEvent]
    }

    private struct Saved: Codable {
        var boards: [String: Board]
        var logos: [String: String]
        var schedules: [String: Board]?
    }

    private var visible = false
    private var loop: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// OpenLigaDB's goals, by game id.
    private var openLigaGoals: [String: [SportsScoringPlay]] = [:]
    private var standingsAt: [String: Date] = [:]

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

    /// The boards a league's games of a day are in.
    private static func keys(_ league: League, day offset: Int, now: Date = Date()) -> [String] {
        if league.onOpenLiga { return [league.id + "|S\(SportsOpenLiga.season(dayStart(offset, now: now)))"] }
        return SportsESPN.espnDays(from: dayStart(offset, now: now), to: dayStart(offset + 1, now: now)).map { league.id + "|" + $0 }
    }

    /// The games of a day, each league's in time order, the leagues in the
    /// region's order (stale copies of live games shown as ended).
    func games(day offset: Int, now: Date = Date()) -> [(league: League, events: [SportsEvent])] {
        let start = Self.dayStart(offset, now: now)
        let end = Self.dayStart(offset + 1, now: now)
        var result: [(league: League, events: [SportsEvent])] = []
        for league in SportsSettings.shared.shownLeagues {
            var seen = Set<String>()
            var list: [SportsEvent] = []
            for key in Self.keys(league, day: offset, now: now) {
                for event in boards[key]?.events ?? [] where seen.insert(event.id).inserted {
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
        for league in SportsSettings.shared.shownLeagues {
            for key in Self.keys(league, day: dayOffset) { boards[key]?.fetchedAt = .distantPast }
        }
        for key in schedules.keys { schedules[key]?.fetchedAt = .distantPast }
        standingsAt.removeAll()
        poke()
    }

    private static func busy(_ events: [SportsEvent], now: Date) -> Bool {
        events.contains { event in
            event.state == .live
                || (event.state == .pre && event.hasTime && event.start.timeIntervalSince(now) < 15 * 60
                    && now.timeIntervalSince(event.start) < 6 * 3600)
        }
    }

    /// How long a board stays fresh: 30 s with a game on (or about to
    /// start; OpenLigaDB's season 60 s), 10 min around today, longer for
    /// other days (a season 30 min).
    private func maxAge(_ board: Board, league: League, offset: Int, now: Date) -> TimeInterval {
        if league.onOpenLiga { return Self.busy(board.events, now: now) ? 60 : 30 * 60 }
        if Self.busy(board.events, now: now) { return 30 }
        if abs(offset) <= 1 { return 10 * 60 }
        return offset < 0 ? 6 * 3600 : 3 * 3600
    }

    private func round() async {
        let now = Date()
        let offset = dayOffset
        var due: [(League, String)] = []
        for league in SportsSettings.shared.shownLeagues {
            for key in Self.keys(league, day: offset, now: now) {
                if let board = boards[key], now.timeIntervalSince(board.fetchedAt) < maxAge(board, league: league, offset: offset, now: now) {
                    continue
                }
                due.append((league, key))
            }
        }
        if !due.isEmpty {
            pending = due.count
            // Four at a time; each league shows as it comes in.
            var index = 0
            while index < due.count, !Task.isCancelled {
                let part = Array(due[index..<min(index + 4, due.count)])
                index += part.count
                let results = await withTaskGroup(of: (String, Data?).self) { group in
                    for (league, key) in part {
                        group.addTask { (key, await Self.fetchBoard(league, key: key)) }
                    }
                    var all: [(String, Data?)] = []
                    for await item in group { all.append(item) }
                    return all
                }
                for (key, data) in results {
                    guard let data, let league = SportsCatalog.league(String(key.split(separator: "|").first ?? "")) else { continue }
                    store(league, key: key, data: data)
                }
                pending = max(0, due.count - index)
            }
            pending = 0
        }
        await refreshSchedules(now: now)
        scheduleSave()
    }

    private func store(_ league: League, key: String, data: Data) {
        if league.onOpenLiga {
            let parsed = SportsOpenLiga.parseMatches(league, data: data)
            boards[key] = Board(fetchedAt: Date(), events: parsed.events)
            openLigaGoals.merge(parsed.goals) { _, new in new }
            return
        }
        boards[key] = Board(fetchedAt: Date(), events: SportsESPN.parseScoreboard(league, data: data))
        if leagueLogos[league.id] == nil, let logo = SportsESPN.leagueLogo(data) { leagueLogos[league.id] = logo }
    }

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// A board: an ESPN day ("league|20261127") or an OpenLigaDB season
    /// ("league|S2026").
    nonisolated private static func fetchBoard(_ league: League, key: String) async -> Data? {
        let tail = String(key.split(separator: "|").last ?? "")
        if league.onOpenLiga {
            guard tail.hasPrefix("S"), let season = Int(tail.dropFirst()),
                  let url = SportsOpenLiga.matchesURL(league, season: season) else { return nil }
            return await fetch(url)
        }
        guard let url = SportsESPN.scoreboardURL(league, day: tail) else { return nil }
        return await fetch(url)
    }

    // MARK: Teams you follow (17d)

    /// A team's schedule from ESPN (football: its results and its coming
    /// games, two requests), kept an hour (30 s with a game on).
    private func refreshSchedules(now: Date) async {
        for team in SportsSettings.shared.followed {
            guard let league = SportsCatalog.league(team.leagueId), league.onESPN, let path = league.espnPath else { continue }
            if let board = schedules[team.key],
               now.timeIntervalSince(board.fetchedAt) < (Self.busy(board.events, now: now) ? 30 : 3600) { continue }
            var events: [SportsEvent] = []
            let variants = league.sport == .football ? ["", "?fixture=true"] : [""]
            for variant in variants {
                guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/teams/\(team.id)/schedule\(variant)"),
                      let data = await Self.fetch(url) else { continue }
                events += SportsESPN.parseSchedule(league, data: data)
            }
            if !events.isEmpty || schedules[team.key] == nil {
                schedules[team.key] = Board(fetchedAt: Date(), events: events)
            }
        }
    }

    /// A followed team's games: the latest copy of each (a day's board
    /// over the schedule), in time order.
    func games(of team: TeamInfo, now: Date = Date()) -> [SportsEvent] {
        var byID: [String: SportsEvent] = [:]
        for event in schedules[team.key]?.events ?? [] { byID[event.id] = event }
        for board in boards.values {
            for event in board.events where event.sides.contains(where: { SportsSettings.sameTeam($0.team, team) }) {
                byID[event.id] = event
            }
        }
        return byID.values
            .map { SportsStale.fix($0, sport: SportsCatalog.league($0.leagueId)?.sport, now: now) }
            .sorted { $0.start < $1.start }
    }

    /// The teams you follow: their schedules asked now.
    func loadFollowed() {
        Task { await refreshSchedules(now: Date()) }
        for league in Set(SportsSettings.shared.followed.compactMap { SportsCatalog.league($0.leagueId) }) where league.onOpenLiga {
            let key = league.id + "|S\(SportsOpenLiga.season(Date()))"
            if boards[key] == nil {
                Task {
                    if let data = await Self.fetchBoard(league, key: key) { store(league, key: key, data: data) }
                }
            }
        }
    }

    // MARK: Tables (17d)

    /// A league's table (kept an hour).
    @discardableResult
    func loadStandings(_ league: League) async -> SportsStandings? {
        if let at = standingsAt[league.id], Date().timeIntervalSince(at) < 3600, let kept = standings[league.id] { return kept }
        let table: SportsStandings?
        if league.onOpenLiga {
            guard let url = SportsOpenLiga.tableURL(league, season: SportsOpenLiga.season(Date())),
                  let data = await Self.fetch(url) else { return standings[league.id] }
            table = SportsOpenLiga.parseTable(league, data: data)
        } else {
            guard let url = SportsStandings.espnURL(league), let data = await Self.fetch(url) else { return standings[league.id] }
            table = SportsStandings.parseESPN(league, data: data)
        }
        standingsAt[league.id] = Date()
        if let table { standings[league.id] = table }
        return table ?? standings[league.id]
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
        for board in schedules.values {
            if let event = board.events.first(where: { $0.id == id }) {
                return SportsStale.fix(event, sport: SportsCatalog.league(event.leagueId)?.sport, now: Date())
            }
        }
        return nil
    }

    /// The summary of a game (scoring, stats, leaders, line-ups, table,
    /// info, chances): kept 25 s while it's on, 30 minutes otherwise (as
    /// Android's). OpenLigaDB: its goals and the table.
    func extras(for event: SportsEvent) async -> SportsGameExtras? {
        guard let league = SportsCatalog.league(event.leagueId) else { return nil }
        if league.onOpenLiga {
            var extras = SportsGameExtras()
            extras.plays = openLigaGoals[event.id] ?? []
            if let table = await loadStandings(league) {
                let around = table.around(Set(event.sides.map(\.team.id)))
                extras.tableTitle = around.title
                extras.tableHead = around.head
                extras.table = around.rows
            }
            return extras
        }
        guard let espnId = event.espnId, let url = SportsSummary.url(league, espnId: espnId) else { return nil }
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
        let key = league.onOpenLiga ? league.id + "|S\(SportsOpenLiga.season(event.start))"
                                    : league.id + "|" + SportsESPN.espnDay(event.start)
        guard let data = await Self.fetchBoard(league, key: key) else { return }
        store(league, key: key, data: data)
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
        schedules = saved.schedules ?? [:]
    }

    /// Saved a moment after the last change; days far from today dropped.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            let keep = Set((-(Self.daysBack + 1)...(Self.daysAhead + 1)).flatMap {
                SportsESPN.espnDays(from: Self.dayStart($0), to: Self.dayStart($0 + 1))
            })
            let season = "S\(SportsOpenLiga.season(Date()))"
            let kept = self.boards.filter {
                let tail = String($0.key.split(separator: "|").last ?? "")
                return keep.contains(tail) || tail == season
            }
            let followed = Set(SportsSettings.shared.followed.map(\.key))
            let saved = Saved(boards: kept, logos: self.leagueLogos, schedules: self.schedules.filter { followed.contains($0.key) })
            let url = Self.fileURL
            Task.detached(priority: .utility) {
                guard let url, let data = try? JSONEncoder().encode(saved) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
