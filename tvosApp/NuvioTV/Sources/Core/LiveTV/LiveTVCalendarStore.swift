import Foundation

/// The calendar's cards (step 16), as Android's `CalendarRepository`: the
/// shows and films you follow (the bell, Nuvio's calendar follows), keep
/// (Library) or watch (Continue Watching, watched episodes, Trakt), their
/// episodes from 30 days back to 120 ahead from TVmaze and films' dates from
/// TMDB. Built first from what's on disk (no network), then asked again
/// when it's older than 30 minutes or on Refresh.
@MainActor
final class LiveTVCalendarStore: ObservableObject {
    static let shared = LiveTVCalendarStore()

    @Published private(set) var entries: [LiveTVCalendarEntry] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isLoading = false
    /// Shows done / to do while it asks TVmaze.
    @Published private(set) var progress: (done: Int, total: Int)?
    /// No titles to follow yet.
    @Published private(set) var isEmptySource = false

    private var task: Task<Void, Never>?
    private var builtOnce = false
    /// The time zone the cards were made for (a change in Settings: made
    /// again).
    private var builtZone: String?

    /// At most this many shows and films, as Android.
    private static let maxShows = 400
    private static let maxMovies = 200
    private static let daysBack = 30
    private static let daysAhead = 120

    /// The calendar screen opened: what's on disk at once, then fresh data
    /// when it's older than 30 minutes.
    func opened() {
        if !builtOnce || builtZone != LiveTVCalendarSettings.timeZone.identifier { build(fetch: false, force: false) }
        if updatedAt.map({ Date().timeIntervalSince($0) > 30 * 60 }) ?? true { build(fetch: true, force: false) }
    }

    func refresh() { build(fetch: true, force: true) }

    // MARK: Candidates

    private struct Candidate {
        var id: String
        var imdb: String?
        var tmdb: Int?
        var series: Bool
        var name: String
        var poster: String?
        var background: String?
        var year: Int?
        var reasons: Set<LiveTVCalendarReason>
        var lastWatched: Date?
    }

    /// What you've watched of a title: marked episodes and the furthest one.
    private struct Seen {
        var marked: Set<String> = []
        var furthest: (season: Int, episode: Int)?

        mutating func add(season: Int, episode: Int, marked isMarked: Bool) {
            if isMarked { marked.insert("\(season):\(episode)") }
            if let furthest, (furthest.season, furthest.episode) >= (season, episode) { return }
            furthest = (season, episode)
        }
    }

    private static func imdb(_ value: String?) -> String? {
        guard let value, let id = NuvioMeta.canonicalImdbID(from: value), id.hasPrefix("tt") else { return nil }
        return id
    }

    private static func tmdb(from id: String) -> Int? {
        guard id.hasPrefix("tmdb:") else { return nil }
        return Int(id.dropFirst("tmdb:".count).prefix { $0.isNumber })
    }

    private static func year(_ text: String?) -> Int? {
        guard let text, let range = text.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    private func candidates(continueWatching: [ContinueWatchingItem], watched: [WatchedStoreItem])
        -> (shows: [Candidate], movies: [Candidate]) {
        var order: [String] = []
        var byKey: [String: Candidate] = [:]
        func add(_ candidate: Candidate) {
            let key = candidate.imdb ?? candidate.id
            if var known = byKey[key] {
                known.reasons.formUnion(candidate.reasons)
                known.poster = known.poster ?? candidate.poster
                known.background = known.background ?? candidate.background
                known.tmdb = known.tmdb ?? candidate.tmdb
                if let last = candidate.lastWatched, known.lastWatched.map({ last > $0 }) ?? true { known.lastWatched = last }
                byKey[key] = known
            } else {
                order.append(key)
                byKey[key] = candidate
            }
        }
        // The bell: Nuvio's calendar follows.
        for item in CalendarManualFollowStore.items().values {
            add(Candidate(id: item.id, imdb: Self.imdb(item.imdbId ?? item.id), tmdb: item.tmdbId ?? Self.tmdb(from: item.id),
                          series: item.kind == .series, name: item.name ?? item.id, poster: item.posterURL,
                          year: item.year, reasons: [.bell]))
        }
        for item in LibraryStore.items().sorted(by: { $0.addedAt > $1.addedAt }) {
            let meta = item.meta
            let type = meta.type.lowercased()
            let series = ["series", "tv", "show", "anime"].contains(type)
            guard series || type == "movie" else { continue }
            add(Candidate(id: meta.id, imdb: Self.imdb(meta.imdbId ?? meta.id), tmdb: meta.tmdbId ?? Self.tmdb(from: meta.id),
                          series: series, name: meta.name, poster: meta.posterUrl, background: meta.backgroundUrl,
                          year: meta.year ?? Self.year(meta.releaseInfo), reasons: [.library]))
        }
        for item in continueWatching where item.meta.isSeries {
            let meta = item.meta
            add(Candidate(id: meta.id, imdb: Self.imdb(meta.imdbId ?? meta.id), tmdb: meta.tmdbId ?? Self.tmdb(from: meta.id),
                          series: true, name: meta.name, poster: meta.posterUrl, background: meta.backgroundUrl,
                          reasons: [.watching], lastWatched: item.lastWatchedAt))
        }
        for item in watched where item.season != nil && item.meta.isSeries {
            let meta = item.meta
            add(Candidate(id: meta.id, imdb: Self.imdb(meta.imdbId ?? meta.id), tmdb: meta.tmdbId ?? Self.tmdb(from: meta.id),
                          series: true, name: meta.name, poster: meta.posterUrl, background: meta.backgroundUrl,
                          reasons: [.watching], lastWatched: item.watchedAt))
        }
        let all = order.compactMap { byKey[$0] }
        let shows = all.filter(\.series).sorted { a, b in
            let rank = { (c: Candidate) in c.reasons.contains(.bell) ? 0 : (c.reasons.contains(.watching) ? 1 : 2) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return (a.lastWatched ?? .distantPast) > (b.lastWatched ?? .distantPast)
        }
        let thisYear = Calendar.current.component(.year, from: Date())
        let movies = all.filter { !$0.series && ($0.reasons.contains(.bell) || ($0.year ?? thisYear) >= thisYear - 1) }
        return (Array(shows.prefix(Self.maxShows)), Array(movies.prefix(Self.maxMovies)))
    }

    private func seen(continueWatching: [ContinueWatchingItem], watched: [WatchedStoreItem]) -> [String: Seen] {
        var result: [String: Seen] = [:]
        func keys(_ meta: NuvioMeta) -> [String] {
            [meta.id] + [Self.imdb(meta.imdbId ?? meta.id)].compactMap { $0 }
        }
        for item in watched {
            guard let season = item.season, let episode = item.episode else { continue }
            for key in keys(item.meta) { result[key, default: Seen()].add(season: season, episode: episode, marked: true) }
        }
        for item in continueWatching {
            guard let season = item.season, let episode = item.episode else { continue }
            let done = item.duration > 0 && item.position / item.duration >= 0.9
            for key in keys(item.meta) { result[key, default: Seen()].add(season: season, episode: episode, marked: done) }
        }
        return result
    }

    // MARK: Build

    /// `fetch` false: from the disk only. `force`: every show asked again.
    private func build(fetch: Bool, force: Bool) {
        if isLoading, !force { return }
        task?.cancel()
        builtOnce = true
        builtZone = LiveTVCalendarSettings.timeZone.identifier
        isLoading = fetch
        task = Task { [weak self] in
            guard let self else { return }
            let continueWatching = await CalendarLibrarySource.fetchContinueWatchingItems()
            guard !Task.isCancelled else { return }
            let watched = WatchedStore.visibleItems()
            let (shows, movies) = self.candidates(continueWatching: continueWatching, watched: watched)
            let seen = self.seen(continueWatching: continueWatching, watched: watched)
            self.isEmptySource = shows.isEmpty && movies.isEmpty
            let built = await self.make(shows: shows, movies: movies, seen: seen, fetch: fetch, force: force)
            guard !Task.isCancelled else { return }
            self.entries = built
            if fetch { self.updatedAt = Date() }
            self.isLoading = false
            self.progress = nil
        }
    }

    private func make(shows: [Candidate], movies: [Candidate], seen: [String: Seen],
                      fetch: Bool, force: Bool) async -> [LiveTVCalendarEntry] {
        let sources = LiveTVCalendarSources.shared
        let zone = LiveTVCalendarSettings.timeZone
        // Asking TVmaze: what's done shows at once, the cards of shows not
        // asked yet stay as they were.
        let previous = fetch ? entries : []
        var asked = Set<String>()
        var artToAsk: [String] = []
        let now = Date()
        let today = LiveTVCalendarLogic.day(of: now, in: zone)
        let from = LiveTVCalendarLogic.day(today, plus: -Self.daysBack)
        let to = LiveTVCalendarLogic.day(today, plus: Self.daysAhead)
        let hideSpoilers = LiveTVCalendarSettings.hideSpoilers
        var result: [LiveTVCalendarEntry] = []
        var usedShows = Set<Int>()

        for (index, candidate) in shows.enumerated() {
            if Task.isCancelled { return result }
            if fetch, index % 5 == 0 {
                progress = (index, shows.count)
                if index > 0 { entries = Self.merged(result + previous.filter { !asked.contains($0.contentID) }) }
            }
            let tvmazeID: Int?
            if candidate.id.hasPrefix("tvmaze:") {
                tvmazeID = Int(candidate.id.dropFirst("tvmaze:".count))
            } else {
                tvmazeID = await sources.tvmazeID(imdb: candidate.imdb, tmdb: candidate.tmdb, fetch: fetch)
            }
            guard let tvmazeID, usedShows.insert(tvmazeID).inserted,
                  let show = await sources.show(tvmazeID, fetch: fetch, force: force) else { continue }
            let contentID = candidate.imdb ?? Self.imdb(show.imdb) ?? candidate.id
            asked.insert(contentID)
            let watchedOf = seen[candidate.id] ?? candidate.imdb.flatMap { seen[$0] }
            // TMDB's picture and logo: what's known now, the rest asked for
            // after TVmaze (side by side, not one by one in between).
            let art = contentID.hasPrefix("tt") ? await sources.art(imdb: contentID, fetch: false) : nil
            if art == nil, contentID.hasPrefix("tt"), fetch, artToAsk.count < 300 { artToAsk.append(contentID) }
            let background = candidate.background ?? show.background ?? art?.backdrop
            let highest = show.episodes.map(\.season).max() ?? 0
            let inside = show.episodes.filter { $0.airdate >= from && $0.airdate <= to }
            for group in LiveTVCalendarLogic.grouped(inside, streaming: show.streaming) {
                guard let first = group.first, let last = group.last else { continue }
                let air = LiveTVCalendarLogic.localAir(
                    listed: first.airstamp, networkZone: show.networkZone, scheduleTime: show.scheduleTime,
                    streaming: show.streaming, local: zone)
                let day = air.map { LiveTVCalendarLogic.day(of: $0, in: zone) } ?? first.airdate
                let watched = LiveTVCalendarLogic.isWatched(
                    season: last.season, episode: last.number,
                    marked: watchedOf?.marked ?? [], furthest: watchedOf?.furthest)
                var tags = LiveTVCalendarLogic.tags(first: first, last: last, showEnded: show.ended, highestSeason: highest)
                let aired = (air ?? LiveTVCalendarLogic.start(of: day, in: zone) ?? now) <= now
                if LiveTVCalendarLogic.isNew(aired: aired, watched: watched, day: day, today: today) { tags.insert(.new, at: 0) }
                let single = group.count == 1
                var entry = LiveTVCalendarEntry(
                    key: "ep|\(contentID)|\(first.season)|\(first.number)",
                    kind: .episode, contentID: contentID, title: candidate.name.isEmpty ? show.name : candidate.name,
                    poster: candidate.poster ?? show.image, background: background,
                    season: first.season, episode: first.number,
                    lastEpisode: single ? nil : last.number,
                    episodeTitle: single ? first.name : nil,
                    episodeImage: first.image,
                    summary: single ? first.summary : nil,
                    air: air, day: day, network: show.network, networkLogo: art?.logo, streaming: show.streaming,
                    tags: tags, reasons: candidate.reasons, watched: watched, runtime: first.runtime)
                if hideSpoilers, let furthest = watchedOf?.furthest, !watched {
                    entry.spoiler = LiveTVCalendarLogic.isAhead(season: first.season, episode: first.number, furthest: furthest)
                }
                result.append(entry)
            }
        }

        let country = LiveTVCalendarSettings.country
        for candidate in movies {
            if Task.isCancelled { return result }
            guard let record = await sources.movie(imdb: candidate.imdb, tmdb: candidate.tmdb, country: country, fetch: fetch) else { continue }
            let contentID = candidate.imdb ?? candidate.id
            let cards = LiveTVCalendarLogic.movieCards(record.dates, from: from, to: to) { tag, day in
                Self.movieNote(tag, day)
            }
            for card in cards {
                result.append(LiveTVCalendarEntry(
                    key: "mv|\(contentID)|\(card.tag.rawValue)",
                    kind: .movie, contentID: contentID, title: record.title ?? candidate.name,
                    poster: candidate.poster ?? record.poster, background: candidate.background ?? record.background,
                    summary: record.about, day: card.day, tags: [card.tag], note: card.note,
                    reasons: candidate.reasons))
            }
        }
        if !artToAsk.isEmpty, !Task.isCancelled {
            entries = Self.merged(result)
            let found = await Self.askArt(artToAsk)
            result = result.map { entry in
                guard let art = found[entry.contentID] else { return entry }
                var changed = entry
                if changed.background == nil { changed.background = art.backdrop }
                if changed.kind == .episode { changed.networkLogo = art.logo }
                return changed
            }
        }
        return Self.merged(result)
    }

    /// TMDB's pictures and logos, a few at a time.
    private static func askArt(_ ids: [String]) async -> [String: LiveTVCalendarSources.Art] {
        await withTaskGroup(of: (String, LiveTVCalendarSources.Art?).self) { group in
            var found: [String: LiveTVCalendarSources.Art] = [:]
            var next = 0
            func start() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { (id, await LiveTVCalendarSources.shared.art(imdb: id, fetch: true)) }
            }
            for _ in 0..<6 { start() }
            while let (id, art) = await group.next() {
                if let art { found[id] = art }
                start()
            }
            return found
        }
    }

    /// One card per key (a title in two lists), every reason kept, in the
    /// calendar's order.
    private static func merged(_ entries: [LiveTVCalendarEntry]) -> [LiveTVCalendarEntry] {
        var byKey: [String: LiveTVCalendarEntry] = [:]
        for entry in entries {
            if var known = byKey[entry.key] {
                known.reasons.formUnion(entry.reasons)
                byKey[entry.key] = known
            } else {
                byKey[entry.key] = entry
            }
        }
        return LiveTVCalendarLogic.sorted(Array(byKey.values))
    }

    /// "At home Oct 2", "In theaters Oct 2"; no home date yet: says so.
    private static func movieNote(_ tag: LiveTVCalendarTag, _ day: String) -> String {
        guard let date = LiveTVCalendarLogic.start(of: day, in: LiveTVCalendarSettings.timeZone) else {
            return L10n.string("livetv_cal_not_home_yet", fallback: "Not out to watch at home yet")
        }
        let formatter = DateFormatter()
        formatter.timeZone = LiveTVCalendarSettings.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let when = formatter.string(from: date)
        switch tag {
        case .atHome: return L10n.format("livetv_cal_at_home_format", fallback: "At home %@", when)
        case .inTheaters: return L10n.format("livetv_cal_in_theaters_format", fallback: "In theaters %@", when)
        default: return when
        }
    }
}

/// The calendar's options (Settings come in step 16e).
enum LiveTVCalendarSettings {
    static let hideSpoilersKey = "livetv.calendar.hideSpoilers"
    static let countryKey = "livetv.calendar.country"
    static let unwatchedOnlyKey = "livetv.calendar.unwatchedOnly"

    /// Titles, pictures and text of episodes past what you've watched stay
    /// hidden (on by default, as Android).
    static var hideSpoilers: Bool {
        (ProfileSettings.current.object(forKey: hideSpoilersKey) as? Bool) ?? true
    }

    /// The country for film release dates: the Apple TV's region.
    static var country: String {
        ProfileSettings.current.string(forKey: countryKey) ?? Locale.current.region?.identifier ?? "US"
    }

    /// The time zone of the calendar's days and times: the Apple TV's, or
    /// the one chosen in Settings → Live TV → Calendar.
    @MainActor static var timeZone: TimeZone {
        let id = LiveTVSettings.shared.calendarTimeZone
        return id.isEmpty ? .current : TimeZone(identifier: id) ?? .current
    }

    static var unwatchedOnly: Bool {
        get { (ProfileSettings.current.object(forKey: unwatchedOnlyKey) as? Bool) ?? false }
        set { ProfileSettings.current.set(newValue, forKey: unwatchedOnlyKey) }
    }
}
