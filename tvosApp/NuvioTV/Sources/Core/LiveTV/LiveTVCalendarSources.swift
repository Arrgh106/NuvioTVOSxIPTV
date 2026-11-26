import Foundation

// Fork: where the calendar's dates come from (step 16), as Android's
// `CalendarSources`: TVmaze for episodes (no key needed), TMDB for film
// release dates and wide pictures (Nuvio's TMDB key, when TMDB is on).
// Everything is kept on disk, so a calendar opens from what it knew.

/// A show as the calendar keeps it.
struct LiveTVCalendarShow: Codable, Sendable {
    let id: Int
    var name: String
    var status: String?
    var network: String?
    var streaming: Bool
    var image: String?
    var background: String?
    var imdb: String?
    /// "HH:mm" in the network's zone (TVmaze `schedule.time`).
    var scheduleTime: String?
    var networkZone: String?
    var episodes: [LiveTVCalendarEpisode]
    var fetchedAt: Date

    var ended: Bool { status == "Ended" }

    /// Fetched again: ended shows after a week, shows with an episode
    /// within a day and a half after 3 h, others after 20 h.
    func isStale(now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        if ended { return age > 7 * 86_400 }
        let near = episodes.contains { episode in
            guard let air = episode.airstamp else { return false }
            return abs(air.timeIntervalSince(now)) < 36 * 3600
        }
        return age > (near ? 3 * 3600 : 20 * 3600)
    }
}

actor LiveTVCalendarSources {
    static let shared = LiveTVCalendarSources()

    private let folder: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("livetv-calendar", isDirectory: true)
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "NuvioTV"]
        return URLSession(configuration: configuration)
    }()

    /// TVmaze's lookups answer with a redirect to the show: its id is in
    /// the address, so the redirect isn't followed (one request, not two).
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let lookupSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "NuvioTV"]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// TVmaze's shows changed in the last week (id → when), asked once per
    /// build: a kept show that hasn't changed isn't asked again.
    private var updated: [Int: Date]?
    private var updatedAt: Date?

    private struct IDRecord: Codable {
        /// 0: TVmaze doesn't have it (asked again after a week).
        var id: Int
        var at: Date
    }

    private var ids: [String: IDRecord]?
    private var movies: [String: MovieRecord]?
    private var arts: [String: Art]?

    // MARK: Files

    private func url(_ name: String) -> URL? {
        guard let folder else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        guard let url = url(name) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Requests

    /// TVmaze, one request at a time with a pause between (it allows about
    /// 20 in 10 s); a 429 waits 10 s and tries once more.
    private func tvmaze(_ path: String) async -> Any? {
        guard let url = URL(string: "https://api.tvmaze.com" + path) else { return nil }
        for attempt in 0..<2 {
            await CalendarTvmazeRateLimiter.shared.wait()
            guard !Task.isCancelled, let (data, response) = try? await session.data(from: url),
                  let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
            if status == 429, attempt == 0 {
                await CalendarTvmazeRateLimiter.shared.pause(seconds: 10)
                continue
            }
            guard (200..<300).contains(status) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        return nil
    }

    /// TMDB is on with a key: film dates, pictures and logos come.
    @MainActor static var tmdbReady: Bool { tmdbKey != nil }

    /// Nuvio's TMDB key while TMDB is on (as every TMDB feature).
    @MainActor private static var tmdbKey: String? {
        let store = ProfileSettings.current
        let enabled = (store.object(forKey: SettingsKey.tmdbEnabled) as? Bool) ?? false
        let key = (TmdbDetailsService.currentApiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return enabled && !key.isEmpty ? key : nil
    }

    private func tmdb(_ path: String) async -> [String: Any]? {
        guard let key = await MainActor.run(body: { Self.tmdbKey }) else { return nil }
        let joiner = path.contains("?") ? "&" : "?"
        guard let url = URL(string: "https://api.themoviedb.org/3" + path + joiner + "api_key=" + key),
              let (data, response) = try? await session.data(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func https(_ link: String?) -> String? {
        guard let link, !link.isEmpty else { return nil }
        return link.hasPrefix("http://") ? "https://" + link.dropFirst("http://".count) : link
    }

    // MARK: TVmaze ids

    /// The TVmaze id of a show by its IMDb id (else TheTVDB's, through
    /// TMDB). `fetch` false: only what's known.
    func tvmazeID(imdb: String?, tmdb: Int?, fetch: Bool) async -> Int? {
        if ids == nil { ids = read([String: IDRecord].self, "tvmaze_ids.json") ?? [:] }
        let key = imdb ?? tmdb.map { "tmdb:\($0)" }
        guard let key else { return nil }
        if let known = ids?[key] {
            if known.id > 0 { return known.id }
            if !fetch || Date().timeIntervalSince(known.at) < 7 * 86_400 { return nil }
        }
        guard fetch else { return nil }
        var found: Int?
        if let imdb { found = await lookup("imdb=\(imdb)") }
        if found == nil, let tvdb = await tvdbID(imdb: imdb, tmdb: tmdb) { found = await lookup("thetvdb=\(tvdb)") }
        guard !Task.isCancelled else { return found }
        ids?[key] = IDRecord(id: found ?? 0, at: Date())
        if let ids { write(ids, "tvmaze_ids.json") }
        return found
    }

    /// A show's id from TVmaze's lookup: the redirect's address
    /// (".../shows/123"), or the body when it answers directly.
    private func lookup(_ query: String) async -> Int? {
        guard let url = URL(string: "https://api.tvmaze.com/lookup/shows?" + query) else { return nil }
        for attempt in 0..<2 {
            await CalendarTvmazeRateLimiter.shared.wait()
            guard !Task.isCancelled, let (data, response) = try? await lookupSession.data(from: url),
                  let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 429, attempt == 0 {
                await CalendarTvmazeRateLimiter.shared.pause(seconds: 10)
                continue
            }
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
               let range = location.range(of: #"/shows/(\d+)"#, options: .regularExpression) {
                return Int(location[range].dropFirst("/shows/".count))
            }
            guard (200..<300).contains(http.statusCode),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return body["id"] as? Int
        }
        return nil
    }

    /// Asks TVmaze once which shows changed in the last week (kept for the
    /// build; again after an hour).
    func loadUpdates() async {
        if let updatedAt, Date().timeIntervalSince(updatedAt) < 3600 { return }
        guard let body = await tvmaze("/updates/shows?since=week") as? [String: Any] else { return }
        var result: [Int: Date] = [:]
        for (key, value) in body {
            if let id = Int(key), let time = value as? Double { result[id] = Date(timeIntervalSince1970: time) }
        }
        updated = result
        updatedAt = Date()
    }

    private func tvdbID(imdb: String?, tmdb: Int?) async -> Int? {
        var show = tmdb
        if show == nil, let imdb, let found = await self.tmdb("/find/\(imdb)?external_source=imdb_id"),
           let first = (found["tv_results"] as? [[String: Any]])?.first {
            show = first["id"] as? Int
        }
        guard let show, let external = await self.tmdb("/tv/\(show)/external_ids") else { return nil }
        return external["tvdb_id"] as? Int
    }

    // MARK: Shows

    /// A show's last two seasons that matter for the window, in one
    /// request (seasons and episodes embedded); from the disk while it's
    /// fresh (`force`: always asked again; a failed ask keeps the old one).
    func show(_ id: Int, fetch: Bool, force: Bool) async -> LiveTVCalendarShow? {
        let name = "show_\(id).json"
        let cached = read(LiveTVCalendarShow.self, name)
        guard fetch, force || needsAsking(cached) else { return cached }
        guard let body = await tvmaze("/shows/\(id)?embed[]=images&embed[]=seasons&embed[]=episodes") as? [String: Any]
        else { return cached }
        let embedded = body["_embedded"] as? [String: Any]
        let network = body["network"] as? [String: Any]
        let web = body["webChannel"] as? [String: Any]
        let image = body["image"] as? [String: Any]
        let images = (embedded?["images"] as? [[String: Any]]) ?? []
        let backgrounds = images.filter { ($0["type"] as? String) == "background" }
        let background = backgrounds.first { ($0["main"] as? Bool) == true } ?? backgrounds.first
        let resolutions = background?["resolutions"] as? [String: Any]
        let backgroundURL = ((resolutions?["original"] as? [String: Any])?["url"] as? String)
            ?? ((resolutions?["medium"] as? [String: Any])?["url"] as? String)

        // Seasons around the window (from 40 days back to 130 ahead), the
        // last two of them.
        let today = LiveTVCalendarLogic.day(of: Date(), in: .current)
        let oldest = LiveTVCalendarLogic.day(today, plus: -40)
        let newest = LiveTVCalendarLogic.day(today, plus: 130)
        let seasons = ((embedded?["seasons"] as? [[String: Any]]) ?? []).filter { season in
            let premiere = season["premiereDate"] as? String
            let end = season["endDate"] as? String
            return (end == nil || end! >= oldest) && (premiere == nil || premiere! <= newest) && (premiere != nil || end == nil)
        }.suffix(2)
        var orders: [Int: Int?] = [:]
        for season in seasons {
            if let number = season["number"] as? Int { orders[number] = season["episodeOrder"] as? Int }
        }
        var episodes: [LiveTVCalendarEpisode] = []
        let stamp = ISO8601DateFormatter()
        for item in (embedded?["episodes"] as? [[String: Any]]) ?? [] {
            guard let number = item["number"] as? Int, let seasonNumber = item["season"] as? Int,
                  let order = orders[seasonNumber],
                  let airdate = item["airdate"] as? String, !airdate.isEmpty else { continue }
            let airtime = (item["airtime"] as? String) ?? ""
            let picture = item["image"] as? [String: Any]
            episodes.append(LiveTVCalendarEpisode(
                season: seasonNumber, number: number,
                name: LiveTVCalendarLogic.episodeName(item["name"] as? String),
                airstamp: airtime.isEmpty ? nil : (item["airstamp"] as? String).flatMap(stamp.date(from:)),
                airdate: airdate,
                runtime: item["runtime"] as? Int,
                image: Self.https((picture?["original"] as? String) ?? (picture?["medium"] as? String)),
                summary: LiveTVCalendarLogic.plainText(item["summary"] as? String),
                seasonEpisodes: order))
        }
        let show = LiveTVCalendarShow(
            id: id,
            name: (body["name"] as? String) ?? "",
            status: body["status"] as? String,
            network: (network?["name"] as? String) ?? (web?["name"] as? String),
            streaming: network == nil && web != nil,
            image: Self.https((image?["original"] as? String) ?? (image?["medium"] as? String)),
            background: Self.https(backgroundURL),
            imdb: (body["externals"] as? [String: Any])?["imdb"] as? String,
            scheduleTime: (body["schedule"] as? [String: Any])?["time"] as? String,
            networkZone: ((network?["country"] as? [String: Any])?["timezone"] as? String),
            episodes: episodes.sorted { ($0.season, $0.number) < ($1.season, $1.number) },
            fetchedAt: Date())
        guard !Task.isCancelled else { return cached ?? show }
        write(show, name)
        return show
    }

    /// TVmaze's schedule of coming episodes worldwide (one request, kept
    /// 12 h): the shows in it by IMDb id with their coming episodes. Their
    /// TVmaze ids are kept too, so they need no lookup. For a first load:
    /// coming episodes at once, before each show is asked.
    func comingShows() async -> [String: LiveTVCalendarShow] {
        let file = url("schedule_full.json")
        var data: Data?
        if let file, let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 12 * 3600 {
            data = try? Data(contentsOf: file)
        }
        if data == nil, let link = URL(string: "https://api.tvmaze.com/schedule/full") {
            await CalendarTvmazeRateLimiter.shared.wait()
            if let (body, response) = try? await session.data(from: link),
               let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) {
                data = body
                if let file { try? body.write(to: file, options: .atomic) }
            }
        }
        guard let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        if ids == nil { ids = read([String: IDRecord].self, "tvmaze_ids.json") ?? [:] }
        let stamp = ISO8601DateFormatter()
        var shows: [Int: LiveTVCalendarShow] = [:]
        var imdbOf: [Int: String] = [:]
        for item in list {
            guard let body = (item["_embedded"] as? [String: Any])?["show"] as? [String: Any],
                  let id = body["id"] as? Int,
                  let imdb = (body["externals"] as? [String: Any])?["imdb"] as? String, imdb.hasPrefix("tt"),
                  let number = item["number"] as? Int, let season = item["season"] as? Int,
                  let airdate = item["airdate"] as? String, !airdate.isEmpty else { continue }
            if shows[id] == nil {
                let network = body["network"] as? [String: Any]
                let web = body["webChannel"] as? [String: Any]
                let image = body["image"] as? [String: Any]
                shows[id] = LiveTVCalendarShow(
                    id: id, name: (body["name"] as? String) ?? "", status: body["status"] as? String,
                    network: (network?["name"] as? String) ?? (web?["name"] as? String),
                    streaming: network == nil && web != nil,
                    image: Self.https((image?["original"] as? String) ?? (image?["medium"] as? String)),
                    background: nil, imdb: imdb,
                    scheduleTime: (body["schedule"] as? [String: Any])?["time"] as? String,
                    networkZone: (network?["country"] as? [String: Any])?["timezone"] as? String,
                    episodes: [], fetchedAt: .distantPast)
                imdbOf[id] = imdb
                if (ids?[imdb]?.id ?? 0) == 0 { ids?[imdb] = IDRecord(id: id, at: Date()) }
            }
            let airtime = (item["airtime"] as? String) ?? ""
            let picture = item["image"] as? [String: Any]
            shows[id]?.episodes.append(LiveTVCalendarEpisode(
                season: season, number: number,
                name: LiveTVCalendarLogic.episodeName(item["name"] as? String),
                airstamp: airtime.isEmpty ? nil : (item["airstamp"] as? String).flatMap(stamp.date(from:)),
                airdate: airdate, runtime: item["runtime"] as? Int,
                image: Self.https((picture?["original"] as? String) ?? (picture?["medium"] as? String)),
                summary: LiveTVCalendarLogic.plainText(item["summary"] as? String),
                seasonEpisodes: nil))
        }
        if let ids { write(ids, "tvmaze_ids.json") }
        var result: [String: LiveTVCalendarShow] = [:]
        for (id, show) in shows {
            guard let imdb = imdbOf[id] else { continue }
            var sorted = show
            sorted.episodes.sort { ($0.season, $0.number) < ($1.season, $1.number) }
            result[imdb] = sorted
        }
        return result
    }

    /// Whether a show is kept on disk (any age).
    func isKept(_ id: Int) -> Bool {
        url("show_\(id).json").map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Asked again: not kept, changed on TVmaze since it was kept, or (no
    /// list of changes) old by the lifetimes above. A show kept before the
    /// week of changes is asked again too.
    private func needsAsking(_ cached: LiveTVCalendarShow?) -> Bool {
        guard let cached else { return true }
        guard let updated, let updatedAt else { return cached.isStale(now: Date()) }
        if updatedAt.timeIntervalSince(cached.fetchedAt) > 6 * 86_400 { return true }
        guard let changed = updated[cached.id] else { return false }
        return changed > cached.fetchedAt
    }

    // MARK: Films (TMDB)

    struct MovieRecord: Codable, Sendable {
        var at: Date
        var dates: LiveTVCalendarLogic.MovieDates
        var title: String?
        var poster: String?
        var background: String?
        var about: String?
    }

    /// A film's release dates in `country` (US when it has none there),
    /// with its title and pictures. Kept a day (a month once it's long out).
    func movie(imdb: String?, tmdb: Int?, country: String, fetch: Bool) async -> MovieRecord? {
        if movies == nil { movies = read([String: MovieRecord].self, "movies.json") ?? [:] }
        guard let base = imdb ?? tmdb.map({ "tmdb:\($0)" }) else { return nil }
        let key = base + "|" + country
        let cached = movies?[key]
        if let cached {
            let longOut = cached.dates.digital.map { $0 < LiveTVCalendarLogic.day(LiveTVCalendarLogic.day(of: Date(), in: .current), plus: -60) } ?? false
            let lifetime: TimeInterval = longOut ? 30 * 86_400 : 86_400
            if !fetch || Date().timeIntervalSince(cached.at) < lifetime { return cached }
        }
        guard fetch else { return nil }
        var id = tmdb
        if id == nil, let imdb, let found = await self.tmdb("/find/\(imdb)?external_source=imdb_id") {
            id = ((found["movie_results"] as? [[String: Any]])?.first)?["id"] as? Int
        }
        guard let id, let releases = await self.tmdb("/movie/\(id)/release_dates") else { return cached }
        let detail = await self.tmdb("/movie/\(id)")
        func dates(in country: String) -> LiveTVCalendarLogic.MovieDates {
            var result = LiveTVCalendarLogic.MovieDates()
            let entry = (releases["results"] as? [[String: Any]])?.first { ($0["iso_3166_1"] as? String) == country }
            for release in (entry?["release_dates"] as? [[String: Any]]) ?? [] {
                guard let type = release["type"] as? Int, let date = (release["release_date"] as? String)?.prefix(10) else { continue }
                let day = String(date)
                switch type {
                case 2, 3: result.theatrical = min(result.theatrical ?? day, day)
                case 4: result.digital = min(result.digital ?? day, day)
                case 5: result.disc = min(result.disc ?? day, day)
                default: break
                }
            }
            return result
        }
        var found = dates(in: country)
        if found.theatrical == nil, found.digital == nil, country != "US" { found = dates(in: "US") }
        if found.theatrical == nil, let release = detail?["release_date"] as? String, release.count >= 10 {
            found.theatrical = String(release.prefix(10))
        }
        let record = MovieRecord(
            at: Date(), dates: found,
            title: detail?["title"] as? String,
            poster: (detail?["poster_path"] as? String).map { "https://image.tmdb.org/t/p/w342" + $0 },
            background: (detail?["backdrop_path"] as? String).map { "https://image.tmdb.org/t/p/w1280" + $0 },
            about: detail?["overview"] as? String)
        movies?[key] = record
        if let movies { write(movies, "movies.json") }
        return record
    }

    /// What TMDB adds to a show: a wide picture (for shows with only a
    /// poster) and its network's logo (CBS, Netflix…). Kept for good.
    struct Art: Codable, Sendable {
        var backdrop: String?
        /// The network's logo.
        var logo: String?
        /// The show's or film's own logo.
        var titleLogo: String?
        /// 3: with the title logo, PNGs only (older ones are asked again).
        var version: Int?
    }

    /// `fetch` false: only what's known.
    func art(imdb: String, fetch: Bool) async -> Art? {
        if arts == nil { arts = read([String: Art].self, "art.json") ?? [:] }
        if let known = arts?[imdb], known.version == 3 || !fetch { return known }
        guard fetch, let found = await tmdb("/find/\(imdb)?external_source=imdb_id") else { return nil }
        var art = Art(version: 3)
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let images = "append_to_response=images&include_image_language=\(language),en,null"
        // The logo in your language, else English, else one without text.
        func titleLogo(_ detail: [String: Any]) -> String? {
            // PNGs only: the Apple TV's pictures can't draw SVG.
            let logos = (((detail["images"] as? [String: Any])?["logos"] as? [[String: Any]]) ?? [])
                .filter { ($0["file_path"] as? String)?.lowercased().hasSuffix(".png") == true }
            let pick = logos.first { ($0["iso_639_1"] as? String) == language }
                ?? logos.first { ($0["iso_639_1"] as? String) == "en" }
                ?? logos.first
            return (pick?["file_path"] as? String).map { "https://image.tmdb.org/t/p/w500" + $0 }
        }
        if let show = (found["tv_results"] as? [[String: Any]])?.first {
            art.backdrop = (show["backdrop_path"] as? String).map { "https://image.tmdb.org/t/p/w1280" + $0 }
            if let id = show["id"] as? Int, let detail = await tmdb("/tv/\(id)?\(images)") {
                let networks = (detail["networks"] as? [[String: Any]]) ?? []
                art.logo = networks.lazy.compactMap { $0["logo_path"] as? String }
                    .first { $0.lowercased().hasSuffix(".png") }
                    .map { "https://image.tmdb.org/t/p/w154" + $0 }
                art.titleLogo = titleLogo(detail)
            }
        } else if let movie = (found["movie_results"] as? [[String: Any]])?.first {
            art.backdrop = (movie["backdrop_path"] as? String).map { "https://image.tmdb.org/t/p/w1280" + $0 }
            if let id = movie["id"] as? Int, let detail = await tmdb("/movie/\(id)?\(images)") {
                art.titleLogo = titleLogo(detail)
            }
        }
        guard !Task.isCancelled else { return art }
        arts?[imdb] = art
        if let arts { write(arts, "art.json") }
        return art
    }

    /// Everything the calendar kept (a profile's sources changed a lot).
    func clear() {
        ids = nil
        movies = nil
        arts = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }
}
