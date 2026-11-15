import Foundation

/// Why a Stalker portal didn't work (step 13e), worded as Android's.
enum LiveTVStalkerError: LocalizedError, Equatable {
    case invalidPortal
    case invalidMAC
    case unreachable(Int?)
    case invalidResponse
    case unsupported
    case loginRequired
    case blocked
    case rejected
    case noLink
    case notArchived

    var errorDescription: String? {
        switch self {
        case .invalidPortal:
            return L10n.string("livetv_stalker_error_portal", fallback: "Enter the portal address starting with http:// or https://")
        case .invalidMAC:
            return L10n.string("livetv_stalker_error_mac", fallback: "Enter the MAC address as 00:1A:79:12:34:56")
        case .unreachable(let status):
            let text = L10n.string("livetv_stalker_error_network", fallback: "The portal could not be reached.")
            return status.map { text + " (HTTP \($0))" } ?? text
        case .invalidResponse:
            return L10n.string("livetv_stalker_error_response", fallback: "The portal returned an invalid answer. Check the address.")
        case .unsupported:
            return L10n.string("livetv_stalker_error_unsupported", fallback: "This portal doesn't support it.")
        case .loginRequired:
            return L10n.string("livetv_stalker_error_login", fallback: "This portal needs the username and password from your provider.")
        case .blocked:
            return L10n.string("livetv_stalker_error_blocked", fallback: "The provider has blocked or disabled this account.")
        case .rejected:
            return L10n.string("livetv_stalker_error_rejected", fallback: "The portal rejected this MAC address or login.")
        case .noLink:
            return L10n.string("livetv_stalker_error_link", fallback: "The portal gave no link to play.")
        case .notArchived:
            return L10n.string("livetv_stalker_error_archive", fallback: "The portal's archive has no recording of this show.")
        }
    }
}

/// One portal session, shared by the channel list, playback and the guide
/// (step 13e), as Android's `StalkerClient`: handshake, profile (and
/// `do_auth` where the portal asks), then requests with the token; a token
/// the portal drops is renewed once.
actor LiveTVStalkerClient {
    struct Session {
        let endpoint: String
        let token: String?
    }

    let config: LiveTVStalkerConfig
    private var session: Session?
    private var pending: Task<Session, Error>?
    private let urlSession: URLSession

    init(config: LiveTVStalkerConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 10 * 60
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        urlSession = URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    /// Checks the portal and the MAC (Settings → Save).
    func authenticate() async throws {
        _ = try await acquire()
    }

    // MARK: Channels

    /// The genres and the live channels, as Xtream's lists for the guide.
    func liveList() async throws -> (categories: [XtreamCategory], channels: [XtreamLiveChannel]) {
        let active = try await acquire()
        let genres = (try? await authenticated([("type", "itv"), ("action", "get_genres")]))
            .flatMap(LiveTVStalkerWire.rows) ?? []
        let categories = genres.compactMap { row -> XtreamCategory? in
            guard let id = LiveTVStalkerWire.text(row, "id"), id != "*" else { return nil }
            return XtreamCategory(id: id, name: LiveTVStalkerWire.text(row, "title", "name") ?? id)
        }
        var rows: [[String: Any]]?
        if let all = try? await authenticated([("type", "itv"), ("action", "get_all_channels")]),
           let list = LiveTVStalkerWire.rows(all), !list.isEmpty {
            let total = (all as? [String: Any]).flatMap { LiveTVStalkerWire.text($0, "total_items") }.flatMap(Int.init)
            // Some portals give only the first page here.
            if total == nil || total! <= list.count { rows = list }
        }
        if rows == nil {
            rows = try await pages(type: "itv", extra: [("genre", "*"), ("sortby", "number")])
        }
        var used = Set<Int>()
        var channels: [XtreamLiveChannel] = []
        channels.reserveCapacity(min(rows?.count ?? 0, 200_000))
        for row in rows ?? [] {
            guard let id = LiveTVStalkerWire.text(row, "id") else { continue }
            var streamID = Int(id).flatMap { $0 > 0 && $0 < 0x7FFF_FFFF ? $0 : nil }
                ?? Int(LiveTVEPGSourceRules.fnv1a("stalker|" + id) & 0x7FFF_FFFF)
            while !used.insert(streamID).inserted { streamID = streamID == 0x7FFF_FFFE ? 1 : streamID + 1 }
            let command = LiveTVStalkerWire.text(row, "cmd") ?? ""
            // Played as it is only when the portal says so; else asked
            // for a link at play time (`create_link`).
            let fixed = LiveTVStalkerWire.flag(row, "use_http_tmp_link") == false
                && LiveTVStalkerWire.flag(row, "use_load_balancing") != true
                && LiveTVStalkerWire.direct(command) != nil
            var channel = XtreamLiveChannel(
                streamID: streamID,
                number: LiveTVStalkerWire.text(row, "number").flatMap(Int.init),
                name: LiveTVStalkerWire.text(row, "name", "title") ?? id,
                logoURL: LiveTVStalkerWire.image(LiveTVStalkerWire.text(row, "logo", "screenshot_uri"), endpoint: active.endpoint),
                epgChannelID: id,
                categoryID: LiveTVStalkerWire.text(row, "tv_genre_id", "genre_id"),
                // Catch-up (step 13f): the portal's archive.
                archiveDays: LiveTVStalkerWire.archiveDays(row))
            channel.streamURL = LiveTVStalker.playLink(command: command, fixed: fixed)
            channels.append(channel)
        }
        guard !channels.isEmpty else { throw LiveTVStalkerError.invalidResponse }
        return (categories, channels)
    }

    // MARK: Playback

    /// The link to play for a channel's command, and the headers it needs
    /// (the portal's only when the link is on the portal's server).
    func playback(command: String, fixed: Bool) async throws -> (URL, [String: String]) {
        let active = try await acquire()
        let url: URL
        if fixed, let direct = LiveTVStalkerWire.direct(command) {
            url = direct
        } else {
            let value = try await authenticated([
                ("type", "itv"), ("action", "create_link"), ("cmd", command), ("series", ""),
                ("forced_storage", ""), ("disable_ad", "0"), ("download", "0"),
            ])
            guard let object = value as? [String: Any],
                  let link = LiveTVStalkerWire.text(object, "cmd", "url"),
                  let resolved = LiveTVStalkerWire.resolved(link, endpoint: active.endpoint) else {
                throw LiveTVStalkerError.noLink
            }
            url = resolved
        }
        return (url, headers(for: url, session: session ?? active))
    }

    private func headers(for url: URL, session: Session) -> [String: String] {
        guard let portal = URL(string: session.endpoint), LiveTVStalkerWire.sameOrigin(portal, url) else {
            return ["User-Agent": LiveTVStalkerWire.userAgent]
        }
        let all = LiveTVStalkerWire.headers(config: config, endpoint: session.endpoint, token: session.token)
        return all.filter { ["Cookie", "Authorization", "SN", "User-Agent", "X-User-Agent", "Referer"].contains($0.key) }
    }

    // MARK: Movies and series (step 13f)

    /// Everything VOD reads from the portal, as Android's: the movie list
    /// (`type=vod`) and the series, from the portal's own series list
    /// (`type=series`, where there is one) and the series inside the movie
    /// list (`is_series`), with their categories. Series categories are
    /// "c:…" (own list) and "v:…" (movie list): the ids overlap.
    func vodCatalog(
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> (movies: [LiveTVStalkerWire.VODEntry], movieCategories: [XtreamCategory],
                       series: [LiveTVStalkerWire.VODEntry], seriesCategories: [XtreamCategory]) {
        let active = try await acquire()
        let zone = TimeZone(identifier: config.timezone) ?? .current
        let vodGenres = try await categories(type: "vod")
        let seriesGenres = (try? await categories(type: "series")) ?? []
        let rows = try await pages(type: "vod", extra: [], progress: progress)
        var movies: [LiveTVStalkerWire.VODEntry] = []
        var series: [LiveTVStalkerWire.VODEntry] = []
        for row in rows {
            guard var entry = LiveTVStalkerWire.vodEntry(row, endpoint: active.endpoint, zone: zone) else { continue }
            if entry.isSeries {
                entry.categoryID = "v:" + entry.categoryID
                series.append(entry)
            } else {
                movies.append(entry)
            }
        }
        // A portal without its own series list answers with an error.
        let read = rows.count
        let ownSeries = (try? await pages(type: "series", extra: [], progress: { count in progress(read + count) })) ?? []
        for row in ownSeries {
            guard var entry = LiveTVStalkerWire.vodEntry(row, endpoint: active.endpoint, zone: zone, variant: "c") else { continue }
            entry.categoryID = "c:" + entry.categoryID
            series.append(entry)
        }
        let seriesCategories = seriesGenres.map { XtreamCategory(id: "c:" + $0.id, name: $0.name) }
            + vodGenres.map { XtreamCategory(id: "v:" + $0.id, name: $0.name) }
        return (movies, Self.withOther(vodGenres, for: movies), series, Self.withOther(seriesCategories, for: series))
    }

    /// The categories, and "Other" for titles in none of them.
    private static func withOther(_ categories: [XtreamCategory], for entries: [LiveTVStalkerWire.VODEntry]) -> [XtreamCategory] {
        let known = Set(categories.map(\.id))
        var result = categories
        var added = Set<String>()
        for entry in entries where !known.contains(entry.categoryID) && added.insert(entry.categoryID).inserted {
            result.append(XtreamCategory(id: entry.categoryID, name: L10n.string("livetv_ondemand_other", fallback: "Other")))
        }
        return result
    }

    private func categories(type: String) async throws -> [XtreamCategory] {
        let value = try await authenticated([("type", type), ("action", "get_categories")])
        return (LiveTVStalkerWire.rows(value) ?? []).compactMap { row in
            guard let id = LiveTVStalkerWire.text(row, "id"), id != "*" else { return nil }
            return XtreamCategory(id: id, name: LiveTVStalkerWire.text(row, "title", "name") ?? id)
        }
    }

    /// A movie or episode: its file (a movie the portal keeps as files is
    /// looked up first), then a link from the portal unless it plays as it is.
    func vodPlayback(_ ref: LiveTVStalkerWire.VODRef) async throws -> (URL, [String: String]) {
        let active = try await acquire()
        var command = ref.cmd
        if ref.seasonID == nil, command.isEmpty || (ref.hasFiles == true && LiveTVStalkerWire.direct(command) == nil) {
            let files = try await pages(type: "vod", extra: [("movie_id", ref.movieID ?? ref.id)])
            // Several files for one movie: which one is unclear (Android
            // refuses too).
            guard files.count == 1, let file = LiveTVStalkerWire.text(files[0], "cmd") else { throw LiveTVStalkerError.noLink }
            command = file
        }
        if ref.fixed == true, let direct = LiveTVStalkerWire.direct(command) {
            return (direct, headers(for: direct, session: active))
        }
        let value = try await authenticated(LiveTVStalkerWire.vodLinkParameters(ref, command: command))
        guard let object = value as? [String: Any],
              (LiveTVStalkerWire.text(object, "error") ?? "0") == "0",
              let link = LiveTVStalkerWire.text(object, "cmd", "url"),
              let url = LiveTVStalkerWire.resolved(link, endpoint: (session ?? active).endpoint) else {
            throw LiveTVStalkerError.noLink
        }
        return (url, headers(for: url, session: session ?? active))
    }

    /// Every episode of a series, with its season and episode number.
    func episodes(
        of series: LiveTVStalkerWire.VODRef, title: String
    ) async throws -> [(season: Int, episode: Int, item: LiveTVStalkerWire.Episode)] {
        let active = try await acquire()
        var seasons: [LiveTVStalkerWire.Season]
        if let single = LiveTVStalkerWire.singleSeason(series, title: title) {
            seasons = [single]
        } else {
            let rows = try await pages(type: series.variant == "v" ? "vod" : "series", extra: [("movie_id", series.id)])
            seasons = LiveTVStalkerWire.seasons(rows, of: series)
        }
        var result: [(season: Int, episode: Int, item: LiveTVStalkerWire.Episode)] = []
        for (seasonIndex, season) in seasons.enumerated() {
            try Task.checkCancellation()
            let list: [LiveTVStalkerWire.Episode]
            if season.variant == "c" {
                list = LiveTVStalkerWire.classicEpisodes(season)
            } else {
                let rows = try await pages(type: "vod", extra: [("movie_id", season.movieID), ("season_id", season.id)])
                list = LiveTVStalkerWire.episodes(rows, of: season, endpoint: active.endpoint)
            }
            for (episodeIndex, episode) in list.enumerated() {
                result.append((season.number ?? seasonIndex + 1, episode.number ?? episodeIndex + 1, episode))
            }
        }
        return result
    }

    // MARK: Catch-up (step 13f)

    /// A past show of a channel: its recording in the portal's archive
    /// (that day's archive guide, the show starting then), as Android's.
    func archivePlayback(channelID: String, start: Date) async throws -> (URL, [String: String]) {
        let active = try await acquire()
        let zone = TimeZone(identifier: config.timezone) ?? .current
        let rows = try await pages(
            type: "epg", extra: [("ch_id", channelID), ("date", LiveTVStalkerWire.day(start, zone: zone))],
            action: "get_simple_data_table")
        guard let id = LiveTVStalkerWire.archivedShow(LiveTVStalkerWire.archivedShows(rows, zone: zone), start: start) else {
            throw LiveTVStalkerError.notArchived
        }
        let value = try await authenticated([
            ("type", "tv_archive"), ("action", "create_link"), ("cmd", LiveTVStalkerWire.archiveCommand(id)),
            ("series", ""), ("forced_storage", ""), ("disable_ad", "0"), ("download", "0"),
        ])
        guard let object = value as? [String: Any],
              (LiveTVStalkerWire.text(object, "error") ?? "0") == "0",
              let link = LiveTVStalkerWire.text(object, "cmd", "url"),
              let url = LiveTVStalkerWire.resolved(link, endpoint: (session ?? active).endpoint) else {
            throw LiveTVStalkerError.noLink
        }
        return (url, headers(for: url, session: session ?? active))
    }

    // MARK: Guide

    /// `get_epg_info` for the next `hours`, every channel at once.
    func guide(hours: Int) async throws -> [LiveTVStalkerWire.Programme] {
        let value = try await authenticated([("type", "itv"), ("action", "get_epg_info"), ("period", String(hours))])
        let zone = TimeZone(identifier: config.timezone) ?? .current
        return LiveTVStalkerWire.programmes(value, zone: zone)
    }

    // MARK: Session

    private func acquire() async throws -> Session {
        if let session { return session }
        if let pending { return try await pending.value }
        let task = Task { try await self.login() }
        pending = task
        defer { pending = nil }
        let fresh = try await task.value
        session = fresh
        return fresh
    }

    private func login() async throws -> Session {
        guard LiveTVStalkerConfig.normalisedMAC(config.mac) != nil else { throw LiveTVStalkerError.invalidMAC }
        let endpoints = LiveTVStalkerWire.endpoints(portal: config.portal)
        guard !endpoints.isEmpty else { throw LiveTVStalkerError.invalidPortal }
        var failure: Error = LiveTVStalkerError.invalidResponse
        for endpoint in endpoints {
            do {
                return try await login(at: endpoint)
            } catch LiveTVStalkerError.invalidResponse {
                failure = LiveTVStalkerError.invalidResponse
            } catch LiveTVStalkerError.unsupported {
                failure = LiveTVStalkerError.unsupported
            } catch Unauthorised.dropped {
                failure = LiveTVStalkerError.rejected
            } catch LiveTVStalkerError.unreachable(let status) where status != nil {
                // A missing page: the next form of the address.
                failure = LiveTVStalkerError.unreachable(status)
            }
        }
        throw failure
    }

    private func login(at endpoint: String) async throws -> Session {
        guard let handshake = try await call(endpoint, [("type", "stb"), ("action", "handshake"), ("token", "")], token: nil)
                as? [String: Any], handshake["token"] != nil else { throw LiveTVStalkerError.invalidResponse }
        let token = LiveTVStalkerWire.text(handshake, "token")
        var profile = try await self.profile(endpoint, token: token, second: false, handshake: handshake)
        switch LiveTVStalkerWire.text(profile, "status").flatMap(Int.init) {
        case 1:
            throw LiveTVStalkerError.blocked
        case 2:
            guard !config.username.isEmpty, !config.password.isEmpty else { throw LiveTVStalkerError.loginRequired }
            let answer = try await call(endpoint, [
                ("type", "stb"), ("action", "do_auth"), ("login", config.username), ("password", config.password),
            ] + deviceParameters, token: token)
            let accepted = (answer as? Bool) == true || (answer as? NSNumber)?.intValue == 1
                || ["true", "1"].contains((answer as? String)?.lowercased() ?? "")
            guard accepted else { throw LiveTVStalkerError.rejected }
            profile = try await self.profile(endpoint, token: token, second: true, handshake: handshake)
            switch LiveTVStalkerWire.text(profile, "status").flatMap(Int.init) {
            case 1: throw LiveTVStalkerError.blocked
            case 2: throw LiveTVStalkerError.rejected
            default: break
            }
        default:
            break
        }
        if let status = LiveTVStalkerWire.text(profile, "status").flatMap(Int.init), status != 0 {
            throw LiveTVStalkerError.rejected
        }
        return Session(endpoint: endpoint, token: token)
    }

    private func profile(_ endpoint: String, token: String?, second: Bool, handshake: [String: Any]) async throws -> [String: Any] {
        var metrics: [String: String] = [
            "mac": LiveTVStalkerConfig.normalisedMAC(config.mac) ?? config.mac, "model": "MAG250", "type": "STB",
        ]
        if !config.serialNumber.isEmpty { metrics["sn"] = config.serialNumber }
        if !config.deviceID.isEmpty { metrics["uid"] = config.deviceID }
        if let random = LiveTVStalkerWire.text(handshake, "random") { metrics["random"] = random }
        let metricsText = (try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var parameters: [(String, String)] = [
            ("type", "stb"), ("action", "get_profile"), ("stb_type", "MAG250"), ("hd", "1"),
            ("auth_second_step", second ? "1" : "0"), ("metrics", metricsText),
        ] + deviceParameters
        if let notValid = LiveTVStalkerWire.text(handshake, "not_valid") { parameters.append(("not_valid_token", notValid)) }
        guard let profile = try await call(endpoint, parameters, token: token) as? [String: Any] else {
            throw LiveTVStalkerError.invalidResponse
        }
        return profile
    }

    private var deviceParameters: [(String, String)] {
        var result: [(String, String)] = []
        if !config.serialNumber.isEmpty { result.append(("sn", config.serialNumber)) }
        if !config.deviceID.isEmpty { result.append(("device_id", config.deviceID)) }
        if !config.deviceID2.isEmpty { result.append(("device_id2", config.deviceID2)) }
        if !config.signature.isEmpty { result.append(("signature", config.signature)) }
        return result
    }

    /// A request with the session; a dropped token is renewed once.
    private func authenticated(_ parameters: [(String, String)]) async throws -> Any {
        for attempt in 0..<2 {
            let active = try await acquire()
            do {
                return try await call(active.endpoint, parameters, token: active.token)
            } catch Unauthorised.dropped {
                if attempt == 1 { throw LiveTVStalkerError.rejected }
                session = nil
            }
        }
        throw LiveTVStalkerError.rejected
    }

    /// Every page of a list (`get_ordered_list`), as Android's: until the
    /// total is in or a short page.
    private func pages(
        type: String, extra: [(String, String)], action: String = "get_ordered_list",
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        var seen = Set<String>()
        var total: Int?
        var pageSize: Int?
        for page in 1...2_000 {
            try Task.checkCancellation()
            let value = try await authenticated([("type", type), ("action", action), ("p", String(page))] + extra)
            let envelope = value as? [String: Any]
            guard let rows = LiveTVStalkerWire.rows(value) else { throw LiveTVStalkerError.invalidResponse }
            if let reported = envelope.flatMap({ LiveTVStalkerWire.text($0, "total_items") }).flatMap(Int.init) { total = reported }
            if let reported = envelope.flatMap({ LiveTVStalkerWire.text($0, "max_page_items") }).flatMap(Int.init), reported > 0 {
                pageSize = reported
            }
            if rows.isEmpty { break }
            var added = 0
            for row in rows {
                let id = LiveTVStalkerWire.text(row, "id") ?? UUID().uuidString
                if seen.insert(id).inserted {
                    result.append(row)
                    added += 1
                }
            }
            // A portal that sends the same page again: done.
            if added == 0 { break }
            progress?(result.count)
            if let total, result.count >= total { break }
            if value is [Any] { break }
            if let pageSize, rows.count < pageSize { break }
            if result.count > 500_000 { break }
        }
        return result
    }

    private enum Unauthorised: Error { case dropped }

    private func call(_ endpoint: String, _ parameters: [(String, String)], token: String?) async throws -> Any {
        guard let url = LiveTVStalkerWire.requestURL(endpoint: endpoint, parameters: parameters) else {
            throw LiveTVStalkerError.invalidPortal
        }
        var request = URLRequest(url: url)
        for (key, value) in LiveTVStalkerWire.headers(config: config, endpoint: endpoint, token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LiveTVStalkerError.unreachable(nil)
        }
        if let http = response as? HTTPURLResponse {
            if [401, 403].contains(http.statusCode) { throw Unauthorised.dropped }
            if [404, 405, 501].contains(http.statusCode) { throw LiveTVStalkerError.unsupported }
            guard (200..<300).contains(http.statusCode) else { throw LiveTVStalkerError.unreachable(http.statusCode) }
        }
        // Far above any real answer (a guide of a big portal is tens of MB).
        guard data.count < 256 * 1024 * 1024 else { throw LiveTVStalkerError.invalidResponse }
        switch LiveTVStalkerWire.unwrap(data) {
        case .value(let value): return value
        case .unauthorised: throw Unauthorised.dropped
        case .invalid: throw LiveTVStalkerError.invalidResponse
        }
    }
}

/// The portal's MAC and token go only to the portal: a redirect to
/// another server is not followed.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url, LiveTVStalkerWire.sameOrigin(from, to) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// The portals of the active profile's Stalker sources (step 13e): one
/// client each, the config from the Keychain.
enum LiveTVStalker {
    private static let lock = NSLock()
    private static var clients: [String: LiveTVStalkerClient] = [:]

    /// A source's portal settings (in the Keychain as one JSON).
    static func config(for sourceID: String) -> LiveTVStalkerConfig? {
        let secret = XtreamAccountStore.secret(id: sourceID)
        guard !secret.isEmpty else { return nil }
        return try? JSONDecoder().decode(LiveTVStalkerConfig.self, from: Data(secret.utf8))
    }

    static func encoded(_ config: LiveTVStalkerConfig) -> String {
        (try? JSONEncoder().encode(config)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// The source's client; a changed config gets a new session.
    static func client(sourceID: String) -> LiveTVStalkerClient? {
        guard let config = config(for: sourceID) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let existing = clients[sourceID], existing.config == config { return existing }
        let client = LiveTVStalkerClient(config: config)
        clients[sourceID] = client
        return client
    }

    // MARK: Play links

    /// What a Stalker channel keeps as its link: played through the
    /// portal (`resolve`) when it starts.
    static let scheme = "nuvio-stalker"

    static func playLink(command: String, fixed: Bool) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "cmd", value: command), URLQueryItem(name: "fixed", value: fixed ? "1" : "0")]
        return components.string ?? ""
    }

    /// A past show of a channel (catch-up, step 13f): found in the
    /// portal's archive when it plays.
    static func archiveLink(channelID: String, start: Date) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "archive"
        components.queryItems = [
            URLQueryItem(name: "ch", value: channelID),
            URLQueryItem(name: "start", value: String(Int(start.timeIntervalSince1970))),
        ]
        return components.url
    }

    /// The real link and headers for a channel's play or archive link. The
    /// source is the channel's (its slot).
    static func resolve(_ link: URL, sourceID: String) async throws -> (URL, [String: String]) {
        guard link.scheme == scheme,
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems,
              let client = client(sourceID: sourceID) else { throw LiveTVStalkerError.noLink }
        if link.host == "archive" {
            guard let channel = items.first(where: { $0.name == "ch" })?.value,
                  let start = items.first(where: { $0.name == "start" })?.value.flatMap(Double.init) else {
                throw LiveTVStalkerError.noLink
            }
            return try await client.archivePlayback(channelID: channel, start: Date(timeIntervalSince1970: start))
        }
        guard let command = items.first(where: { $0.name == "cmd" })?.value else { throw LiveTVStalkerError.noLink }
        let fixed = items.first(where: { $0.name == "fixed" })?.value == "1"
        return try await client.playback(command: command, fixed: fixed)
    }

    // MARK: Guide

    /// The guide feed of a Stalker source: written from `get_epg_info`
    /// as an XMLTV file, so it is read like any other guide.
    static func guideLink(sourceID: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "guide"
        components.queryItems = [URLQueryItem(name: "source", value: sourceID)]
        return components.url
    }

    static func isGuideLink(_ url: URL) -> Bool { url.scheme == scheme && url.host == "guide" }

    /// Asks the portal for the next days and writes them to `file`.
    static func writeGuide(_ link: URL, to file: URL) async throws {
        guard let sourceID = URLComponents(url: link, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "source" })?.value,
              let client = client(sourceID: sourceID) else { throw LiveTVStalkerError.invalidPortal }
        let programmes = try await client.guide(hours: 72)
        guard !programmes.isEmpty else { throw GuideError.empty }
        try await Task.detached(priority: .utility) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var buffer = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<tv>\n"
            func flush(_ force: Bool = false) {
                guard force || buffer.utf8.count > 1 << 20 else { return }
                handle.write(Data(buffer.utf8))
                buffer = ""
            }
            for id in Set(programmes.map(\.channel)).sorted() {
                let escaped = LiveTVStalkerWire.xmlEscaped(id)
                buffer += "<channel id=\"\(escaped)\"><display-name>\(escaped)</display-name></channel>\n"
                flush()
            }
            for programme in programmes {
                buffer += "<programme start=\"\(LiveTVStalkerWire.xmltvTime(programme.start))\" stop=\"\(LiveTVStalkerWire.xmltvTime(programme.stop))\" channel=\"\(LiveTVStalkerWire.xmlEscaped(programme.channel))\">"
                buffer += "<title>\(LiveTVStalkerWire.xmlEscaped(programme.title))</title>"
                if let description = programme.description {
                    buffer += "<desc>\(LiveTVStalkerWire.xmlEscaped(description))</desc>"
                }
                buffer += "</programme>\n"
                flush()
            }
            buffer += "</tv>\n"
            flush(true)
        }.value
    }
}

extension OnDemandStalker {
    /// What one read of a portal gave (`LiveTVStalkerClient.vodCatalog`,
    /// step 13f).
    struct Catalog: Sendable {
        var movies: [LiveTVStalkerWire.VODEntry]
        var movieCategories: [XtreamCategory]
        var series: [LiveTVStalkerWire.VODEntry]
        var seriesCategories: [XtreamCategory]
    }
}
