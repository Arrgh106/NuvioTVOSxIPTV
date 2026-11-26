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
    /// Shows you took out of the calendar (16c, Hidden).
    @Published private(set) var hidden: [LiveTVCalendarHidden] = []
    /// Titles with the bell rung (16c, Following).
    @Published private(set) var followed: [LiveTVCalendarFollowed] = []
    /// Every show with a new episode today in your country (16c).
    @Published private(set) var airing: [LiveTVCalendarEntry] = []
    @Published private(set) var airingLoading = false
    private var airingDay: String?
    private var lastSeen: [String: Seen] = [:]
    private var followObserver: NSObjectProtocol?
    private var followTask: Task<Void, Never>?
    private static let hiddenKey = "livetv.calendar.hidden"
    /// Airing today leaves these out (as Android's "News & talk shows").
    private static let skippedTypes: Set<String> = ["News", "Talk Show", "Sports", "Panel Show"]

    init() {
        hidden = Self.loadHidden()
        // The bell rung or silenced (here, on a page, in Nuvio's calendar):
        // the calendar follows.
        followObserver = NotificationCenter.default.addObserver(
            forName: CalendarManualFollowStore.changedNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { LiveTVCalendarStore.shared.followsChanged() }
        }
    }

    /// Asked again once the build running now is done (a change came in).
    private var rebuildAfter = false

    private func followsChanged() {
        // Following shows the change at once; the episodes come with the
        // next build (after the one running now, if any).
        followed = CalendarManualFollowStore.items().values
            .map { item in
                let imdb = NuvioMeta.canonicalImdbID(from: item.imdbId ?? item.id)
                return LiveTVCalendarFollowed(id: imdb ?? item.id, imdb: imdb, tmdb: item.tmdbId, series: item.kind == .series,
                                              title: item.name ?? item.id, poster: item.posterURL, background: nil)
            }
            .filter { !isHidden($0.id, imdb: $0.imdb) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        guard builtOnce else { return }
        if isLoading {
            rebuildAfter = true
            return
        }
        followTask?.cancel()
        followTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.build(fetch: true, force: false)
        }
    }

    // MARK: Hidden (16c)

    private static func loadHidden() -> [LiveTVCalendarHidden] {
        guard let data = ProfileSettings.current.data(forKey: hiddenKey),
              let list = try? JSONDecoder().decode([LiveTVCalendarHidden].self, from: data) else { return [] }
        return list
    }

    private func saveHidden() {
        if let data = try? JSONEncoder().encode(hidden) { ProfileSettings.current.set(data, forKey: Self.hiddenKey) }
    }

    /// "Hide this show from the Calendar" (it comes back from Hidden).
    func hide(_ entry: LiveTVCalendarEntry) {
        guard !hidden.contains(where: { $0.id == entry.contentID }) else { return }
        hidden.append(LiveTVCalendarHidden(id: entry.contentID, name: entry.title))
        saveHidden()
        entries.removeAll { $0.contentID == entry.contentID }
        airing.removeAll { $0.contentID == entry.contentID }
    }

    func unhide(_ id: String) {
        hidden.removeAll { $0.id == id }
        saveHidden()
        build(fetch: false, force: false)
        airingDay = nil
    }

    private func isHidden(_ id: String, imdb: String?) -> Bool {
        hidden.contains { $0.id == id || (imdb != nil && $0.id == imdb) }
    }

    // MARK: Airing today (16c)

    /// TVmaze's schedule of today in the calendar's country (TV and
    /// streaming; kept 2 h), without news, talk, sports and panel shows.
    func loadAiring(force: Bool = false) {
        let zone = LiveTVCalendarSettings.timeZone
        let now = Date()
        let today = LiveTVCalendarLogic.day(of: now, in: zone)
        let languages = LiveTVCalendarSettings.airingLanguages
        let made = LiveTVSettings.shared.calendarAiringLanguages + "|" + LiveTVCalendarSettings.country
        if !force, airingDay == today, airingMadeWith == made, !airing.isEmpty || airingLoading { return }
        airingMadeWith = made
        airingLoading = true
        let country = LiveTVCalendarSettings.country
        Task { [weak self] in
            let list = await LiveTVCalendarSources.shared.airingToday(country: country, date: today, force: force)
            guard let self else { return }
            let follows = Set(self.followed.map(\.id))
            let stamp = ISO8601DateFormatter()
            var result: [LiveTVCalendarEntry] = []
            var seenShows = Set<String>()
            for item in list {
                guard let body = (item["show"] as? [String: Any]) ?? ((item["_embedded"] as? [String: Any])?["show"] as? [String: Any]),
                      let id = body["id"] as? Int, let number = item["number"] as? Int, let season = item["season"] as? Int,
                      let airdate = item["airdate"] as? String, !airdate.isEmpty else { continue }
                if let type = body["type"] as? String, Self.skippedTypes.contains(type) { continue }
                // TV in your country is shown (it's dubbed there); streaming
                // from elsewhere only in your languages.
                if let languages, let language = body["language"] as? String, !languages.contains(language) {
                    let local = ((body["network"] as? [String: Any])?["country"] as? [String: Any])?["code"] as? String
                    let web = ((body["webChannel"] as? [String: Any])?["country"] as? [String: Any])?["code"] as? String
                    if local != country, web != country { continue }
                }
                let imdb = (body["externals"] as? [String: Any])?["imdb"] as? String
                let contentID = imdb ?? "tvmaze:\(id)"
                guard !self.isHidden(contentID, imdb: imdb), seenShows.insert("\(contentID)|\(season)|\(number)").inserted else { continue }
                let network = body["network"] as? [String: Any]
                let web = body["webChannel"] as? [String: Any]
                let image = body["image"] as? [String: Any]
                let picture = item["image"] as? [String: Any]
                let airtime = (item["airtime"] as? String) ?? ""
                let show = LiveTVCalendarShow(
                    id: id, name: (body["name"] as? String) ?? "", status: body["status"] as? String,
                    network: (network?["name"] as? String) ?? (web?["name"] as? String),
                    streaming: network == nil && web != nil,
                    image: (image?["original"] as? String) ?? (image?["medium"] as? String),
                    background: nil, imdb: imdb,
                    scheduleTime: (body["schedule"] as? [String: Any])?["time"] as? String,
                    networkZone: (network?["country"] as? [String: Any])?["timezone"] as? String,
                    episodes: [LiveTVCalendarEpisode(
                        season: season, number: number,
                        name: LiveTVCalendarLogic.episodeName(item["name"] as? String),
                        airstamp: airtime.isEmpty ? nil : (item["airstamp"] as? String).flatMap(stamp.date(from:)),
                        airdate: airdate, runtime: item["runtime"] as? Int,
                        image: (picture?["original"] as? String) ?? (picture?["medium"] as? String),
                        summary: LiveTVCalendarLogic.plainText(item["summary"] as? String), seasonEpisodes: nil)],
                    fetchedAt: Date())
                var reasons: Set<LiveTVCalendarReason> = [.airingToday]
                if follows.contains(contentID) || (imdb.map { follows.contains($0) } ?? false) { reasons.insert(.bell) }
                let candidate = Candidate(id: contentID, imdb: imdb, tmdb: nil, series: true, name: show.name,
                                          poster: show.image, background: nil, year: nil, reasons: reasons)
                let art = imdb == nil ? nil : await LiveTVCalendarSources.shared.art(imdb: imdb!, fetch: false)
                result += self.cards(show: show, candidate: candidate, contentID: contentID, art: art, seen: self.lastSeen,
                                     window: (airdate, airdate), today: today, now: now, zone: zone)
            }
            // As Android: TV by time first, streaming after it.
            self.airing = result.sorted {
                if $0.streaming != $1.streaming { return !$0.streaming }
                if ($0.air ?? .distantFuture) != ($1.air ?? .distantFuture) {
                    return ($0.air ?? .distantFuture) < ($1.air ?? .distantFuture)
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            self.airingDay = today
            self.airingLoading = false
            // Then the pictures and logos TMDB has for shows not asked yet.
            guard LiveTVCalendarSources.tmdbReady else { return }
            var missing: [String] = []
            for entry in self.airing where entry.contentID.hasPrefix("tt") && entry.titleLogo == nil && entry.networkLogo == nil {
                if !missing.contains(entry.contentID) { missing.append(entry.contentID) }
            }
            // In the list's order, shown each dozen (the first cards at once).
            var start = 0
            while start < missing.count {
                let part = Array(missing[start..<min(start + 12, missing.count)])
                start += part.count
                let found = await Self.askArt(part)
                guard self.airingDay == today, !Task.isCancelled else { return }
                if found.isEmpty { continue }
                self.airing = self.airing.map { entry in
                    guard let art = found[entry.contentID] else { return entry }
                    var entry = entry
                    entry.background = entry.background ?? art.backdrop
                    entry.networkLogo = entry.networkLogo ?? art.logo
                    entry.titleLogo = entry.titleLogo ?? art.titleLogo
                    return entry
                }
            }
        }
    }

    private var task: Task<Void, Never>?
    private var airingMadeWith: String?
    private var builtOnce = false
    /// The settings the cards were made with (a change in Settings: made
    /// again).
    private var builtWith: String?

    /// At most this many shows and films, as Android.
    private static let maxShows = 400
    private static let maxMovies = 200
    private static let daysBack = 30
    private static let daysAhead = 120

    /// Something is playing: the calendar doesn't ask the network then (set
    /// by the app).
    static var isPlaying: () -> Bool = { false }
    private var warmed = false

    /// At app start, as Android: the cards from the disk after 3 s, fresh
    /// ones after 40 s, then every 3 h; never while something plays.
    func warmUp() {
        guard !warmed else { return }
        warmed = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            if !self.builtOnce { self.build(fetch: false, force: false) }
            try? await Task.sleep(nanoseconds: 40_000_000_000)
            while !Task.isCancelled {
                if Self.isPlaying() {
                    try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                    continue
                }
                if self.updatedAt.map({ Date().timeIntervalSince($0) > 30 * 60 }) ?? true {
                    self.build(fetch: true, force: false)
                }
                try? await Task.sleep(nanoseconds: 3 * 3600 * 1_000_000_000)
            }
        }
    }

    /// The calendar screen opened: what's on disk at once, then fresh data
    /// when it's older than 30 minutes.
    func opened() {
        let country = builtWith?.split(separator: "|").last.map(String.init)
        if !builtOnce || builtWith != LiveTVCalendarSettings.signature {
            // Another country: its film dates are asked for.
            build(fetch: country != nil && country != LiveTVCalendarSettings.country, force: false)
        }
        if updatedAt.map({ Date().timeIntervalSince($0) > 30 * 60 }) ?? true { build(fetch: true, force: false) }
    }

    /// Refresh: what changed on TVmaze (its list of changes says which).
    func refresh() { build(fetch: true, force: false) }

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
        // Shows you hid stay out; the ones with the bell make Following.
        let all = order.compactMap { byKey[$0] }.filter { !isHidden($0.id, imdb: $0.imdb) }
        followed = all.filter { $0.reasons.contains(.bell) }.map { candidate in
            LiveTVCalendarFollowed(id: candidate.imdb ?? candidate.id, imdb: candidate.imdb, tmdb: candidate.tmdb,
                                   series: candidate.series, title: candidate.name,
                                   poster: candidate.poster, background: candidate.background)
        }
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
        builtWith = LiveTVCalendarSettings.signature
        hidden = Self.loadHidden()
        isLoading = fetch
        task = Task { [weak self] in
            guard let self else { return }
            let continueWatching = await CalendarLibrarySource.fetchContinueWatchingItems()
            guard !Task.isCancelled else { return }
            let watched = WatchedStore.visibleItems()
            let (shows, movies) = self.candidates(continueWatching: continueWatching, watched: watched)
            let seen = self.seen(continueWatching: continueWatching, watched: watched)
            self.lastSeen = seen
            self.isEmptySource = shows.isEmpty && movies.isEmpty
            let built = await self.make(shows: shows, movies: movies, seen: seen, fetch: fetch, force: force)
            guard !Task.isCancelled else { return }
            self.entries = built
            if fetch { self.updatedAt = Date() }
            self.isLoading = false
            self.progress = nil
            if self.rebuildAfter {
                self.rebuildAfter = false
                self.build(fetch: true, force: false)
            }
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
        var arts: [String: LiveTVCalendarSources.Art] = [:]
        if fetch { await sources.loadUpdates() }
        // TMDB's pictures and logos while TVmaze is asked (another server).
        var known: [String] = []
        for imdb in (shows + movies).compactMap(\.imdb) {
            if let art = await sources.art(imdb: imdb, fetch: false), art.version == 3 { arts[imdb] = art } else { known.append(imdb) }
        }
        let early = known
        let artTask: Task<[String: LiveTVCalendarSources.Art], Never>? = fetch && !early.isEmpty
            ? Task { await Self.askArt(early) } : nil
        let now = Date()
        let today = LiveTVCalendarLogic.day(of: now, in: zone)
        let from = LiveTVCalendarLogic.day(today, plus: -Self.daysBack)
        let to = LiveTVCalendarLogic.day(today, plus: Self.daysAhead)
        var result: [LiveTVCalendarEntry] = []
        var usedShows = Set<Int>()

        // A first load: TVmaze's schedule of coming episodes gives the
        // shows on air at once (cards in seconds, no lookup for them); each
        // show is still asked after, those on air first.
        var ordered = shows
        var provisional: [LiveTVCalendarEntry] = []
        if fetch {
            var unknown = 0
            for candidate in shows {
                if await sources.tvmazeID(imdb: candidate.imdb, tmdb: candidate.tmdb, fetch: false) == nil { unknown += 1 }
            }
            if unknown > 20 {
                let coming = await sources.comingShows()
                for candidate in shows {
                    guard let imdb = candidate.imdb, let show = coming[imdb], !(await sources.isKept(show.id)) else { continue }
                    provisional += cards(show: show, candidate: candidate, contentID: imdb, art: arts[imdb],
                                         seen: seen, window: (from, to), today: today, now: now, zone: zone)
                }
                ordered = shows.filter { $0.imdb.map { coming[$0] != nil } ?? false }
                    + shows.filter { !($0.imdb.map { coming[$0] != nil } ?? false) }
                if !provisional.isEmpty { entries = Self.merged(provisional + previous) }
            }
        }

        for (index, candidate) in ordered.enumerated() {
            if Task.isCancelled { return result }
            if fetch, index % 5 == 0 {
                progress = (index, ordered.count)
                if index > 0 {
                    entries = Self.merged(result + (provisional + previous).filter { !asked.contains($0.contentID) })
                }
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
            // TMDB's picture and logo: what's known now, the rest asked for
            // after TVmaze (side by side, not one by one in between).
            var art = arts[contentID]
            if art == nil, contentID.hasPrefix("tt") { art = await sources.art(imdb: contentID, fetch: false) }
            if art == nil, contentID.hasPrefix("tt"), fetch, !early.contains(contentID), artToAsk.count < 300 {
                artToAsk.append(contentID)
            }
            result += cards(show: show, candidate: candidate, contentID: contentID, art: art,
                            seen: seen, window: (from, to), today: today, now: now, zone: zone)
        }
        // Shows that weren't asked (cancelled, no id): their cards from the
        // schedule stay.
        result += provisional.filter { !asked.contains($0.contentID) }

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
                    summary: record.about, day: card.day, titleLogo: candidate.imdb.flatMap { arts[$0]?.titleLogo },
                    tags: [card.tag], note: card.note, reasons: candidate.reasons))
            }
        }
        guard !Task.isCancelled else { return Self.merged(result) }
        var found: [String: LiveTVCalendarSources.Art] = [:]
        if let artTask {
            entries = Self.merged(result)
            found = await artTask.value
        }
        if !artToAsk.isEmpty, !Task.isCancelled {
            entries = Self.merged(result)
            found.merge(await Self.askArt(artToAsk)) { first, _ in first }
        }
        if !found.isEmpty {
            result = result.map { entry in
                guard let art = found[entry.contentID] else { return entry }
                var changed = entry
                if changed.background == nil { changed.background = art.backdrop }
                if changed.kind == .episode { changed.networkLogo = art.logo }
                changed.titleLogo = art.titleLogo
                return changed
            }
        }
        return Self.merged(result)
    }

    /// A show's cards in the window: one per episode, or per drop of
    /// several.
    private func cards(show: LiveTVCalendarShow, candidate: Candidate, contentID: String,
                       art: LiveTVCalendarSources.Art?, seen: [String: Seen], window: (from: String, to: String),
                       today: String, now: Date, zone: TimeZone) -> [LiveTVCalendarEntry] {
        let watchedOf = seen[candidate.id] ?? candidate.imdb.flatMap { seen[$0] }
        let hideSpoilers = LiveTVCalendarSettings.hideSpoilers
        let background = candidate.background ?? show.background ?? art?.backdrop
        let highest = show.episodes.map(\.season).max() ?? 0
        let inside = show.episodes.filter { $0.airdate >= window.from && $0.airdate <= window.to }
        var result: [LiveTVCalendarEntry] = []
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
                air: air, day: day, network: show.network, networkLogo: art?.logo, titleLogo: art?.titleLogo,
                streaming: show.streaming,
                tags: tags, reasons: candidate.reasons, watched: watched, runtime: first.runtime)
            if hideSpoilers, let furthest = watchedOf?.furthest, !watched {
                entry.spoiler = LiveTVCalendarLogic.isAhead(season: first.season, episode: first.number, furthest: furthest)
            }
            result.append(entry)
        }
        return result
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
    /// hidden (Settings → Calendar; on by default, as Android).
    @MainActor static var hideSpoilers: Bool { LiveTVSettings.shared.calendarHideSpoilers }

    /// The country for film release dates (Settings → Calendar; the Apple
    /// TV's region by default).
    @MainActor static var country: String {
        let chosen = LiveTVSettings.shared.calendarCountry
        return chosen.isEmpty ? Locale.current.region?.identifier ?? "US" : chosen
    }

    /// The ratings shown on the card in focus, in the app's rating order.
    @MainActor static var ratingVisuals: [TvRatingVisual] {
        let chosen = Set(LiveTVSettings.shared.calendarRatings.split(separator: ",").map(String.init))
        return AddonRatingsService.sortRatings(TvRatingVisual.all.filter { chosen.contains($0.source) }, by: { $0.source })
    }

    /// The languages a country's people speak, in TVmaze's words
    /// ("German"); English for none known.
    static func languages(of country: String) -> Set<String> {
        let english = Locale(identifier: "en")
        var result = Set<String>()
        for id in Locale.availableIdentifiers {
            let locale = Locale(identifier: id)
            guard locale.region?.identifier == country, let code = locale.language.languageCode?.identifier,
                  let name = english.localizedString(forLanguageCode: code) else { continue }
            result.insert(name)
        }
        return result.isEmpty ? ["English"] : result
    }

    /// Airing today's streaming in these languages (nil: all).
    @MainActor static var airingLanguages: Set<String>? {
        switch LiveTVSettings.shared.calendarAiringLanguages {
        case "all": return nil
        case "local": return languages(of: country)
        default: return languages(of: country).union(["English"])
        }
    }

    /// "German", "German and English", "all languages", in the app's language.
    @MainActor static var airingLanguagesLabel: String {
        let main = Locale.current.localizedString(forLanguageCode: mainLanguageCode) ?? mainLanguageCode
        switch LiveTVSettings.shared.calendarAiringLanguages {
        case "all": return L10n.string("livetv_cal_lang_all", fallback: "all languages")
        case "local": return main
        default:
            return L10n.format("livetv_cal_lang_and_english_format", fallback: "%@ and English", main)
        }
    }

    /// The country's first language ("de" for DE).
    @MainActor static var mainLanguageCode: String {
        let country = country
        if Locale.current.region?.identifier == country, let code = Locale.current.language.languageCode?.identifier {
            return code
        }
        for id in Locale.availableIdentifiers.sorted() {
            let locale = Locale(identifier: id)
            if locale.region?.identifier == country, let code = locale.language.languageCode?.identifier { return code }
        }
        return "en"
    }

    /// What the cards depend on in Settings: a change makes them again.
    @MainActor static var signature: String {
        "\(ProfileSettings.activeProfileID ?? "")|\(timeZone.identifier)|\(hideSpoilers)|\(country)"
    }

    /// The time zone of the calendar's days and times: the Apple TV's, or
    /// the one chosen in Settings → Live TV → Calendar.
    @MainActor static var timeZone: TimeZone {
        let id = LiveTVSettings.shared.calendarTimeZone
        return id.isEmpty ? .current : TimeZone(identifier: id) ?? .current
    }

    /// List, Week or Month (kept per profile, as Android's calendarView).
    static var view: String {
        get { ProfileSettings.current.string(forKey: viewKey) ?? "list" }
        set { ProfileSettings.current.set(newValue, forKey: viewKey) }
    }
    static let viewKey = "livetv.calendar.view"

    static var unwatchedOnly: Bool {
        get { (ProfileSettings.current.object(forKey: unwatchedOnlyKey) as? Bool) ?? false }
        set { ProfileSettings.current.set(newValue, forKey: unwatchedOnlyKey) }
    }
}

/// A show taken out of the calendar (16c).
struct LiveTVCalendarHidden: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// A title with the bell rung (16c, Following).
struct LiveTVCalendarFollowed: Identifiable, Equatable, Sendable {
    let id: String
    let imdb: String?
    let tmdb: Int?
    let series: Bool
    let title: String
    let poster: String?
    let background: String?
}
