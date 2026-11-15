import Foundation

/// What a Stalker / Ministra portal needs from you (step 13e), as Android's
/// `StalkerConfig`: the portal and the MAC address the provider registered,
/// a login on portals that ask for one, and device ids on the few that
/// check them. Kept in the Keychain as a whole (the MAC is the login).
struct LiveTVStalkerConfig: Codable, Equatable, Sendable {
    var portal: String
    var mac: String
    var username: String = ""
    var password: String = ""
    var serialNumber: String = ""
    var deviceID: String = ""
    var deviceID2: String = ""
    var signature: String = ""
    var timezone: String = "UTC"
    var language: String = "en"

    /// "00:1A:79:…" in upper case with colons, nil when it isn't a MAC.
    static func normalisedMAC(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: ":").uppercased()
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return cleaned
    }
}

/// The portal protocol's rules with no networking (Linux tests), as
/// Android's `StalkerWire`: where the portal answers, request links, the
/// `js` envelope, stream commands and guide times.
enum LiveTVStalkerWire {
    /// Where the portal may answer, likeliest first: the link as given
    /// when it names a file, then `portal.php` and `server/load.php` under
    /// its folder (a `/c/` link is the portal's web page).
    static func endpoints(portal: String) -> [String] {
        guard var components = URLComponents(string: portal.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else { return [] }
        components.fragment = nil
        let path = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        let lower = path.lowercased()
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let explicit = last.contains(".") && !lower.hasSuffix("/c")
        let base: String
        if lower.hasSuffix("/c/index.html") || lower.hasSuffix("/c/index.php"),
           let range = lower.range(of: "/c/", options: .backwards) {
            base = String(path[..<range.lowerBound])
        } else if lower.hasSuffix("/server/load.php") {
            base = String(path.dropLast("/server/load.php".count))
        } else if lower.hasSuffix("/portal.php") {
            base = String(path.dropLast("/portal.php".count))
        } else if lower.hasSuffix("/c") {
            base = String(path.dropLast(2))
        } else if explicit {
            base = path.split(separator: "/").dropLast().map { "/" + $0 }.joined()
        } else {
            base = path
        }
        func at(_ value: String) -> String? {
            var copy = components
            copy.percentEncodedPath = value
            copy.query = nil
            return copy.string
        }
        var result: [String] = []
        if explicit, let given = components.string { result.append(given) }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        for candidate in [at(trimmed + "/portal.php"), at(trimmed + "/server/load.php"),
                          trimmed.isEmpty ? at("/stalker_portal/server/load.php") : nil] {
            if let candidate, !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    /// The installation's folder ("…/stalker_portal/"): referer and the
    /// base of relative media paths.
    static func installationBase(_ endpoint: String) -> String {
        guard var components = URLComponents(string: endpoint) else { return endpoint }
        let path = components.percentEncodedPath
        if path.lowercased().hasSuffix("/server/load.php") {
            components.percentEncodedPath = String(path.dropLast("server/load.php".count))
        } else if let slash = path.lastIndex(of: "/") {
            components.percentEncodedPath = String(path[...slash])
        } else {
            components.percentEncodedPath = "/"
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? endpoint
    }

    /// "http://host:port".
    static func origin(_ endpoint: String) -> String {
        guard var components = URLComponents(string: endpoint) else { return endpoint }
        components.percentEncodedPath = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? endpoint
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }

    /// The portal link with the request's parameters (and the portal's
    /// own `JsHttpRequest`).
    static func requestURL(endpoint: String, parameters: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        let replaced = Set(parameters.map(\.0) + ["JsHttpRequest"])
        var items = (components.queryItems ?? []).filter { !replaced.contains($0.name) }
        items += parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        items.append(URLQueryItem(name: "JsHttpRequest", value: "1-xml"))
        components.queryItems = items
        // "+" in a value (a password, a time zone) would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.fragment = nil
        return components.url
    }

    /// The headers of a MAG box, as portals expect them.
    static func headers(config: LiveTVStalkerConfig, endpoint: String, token: String?) -> [String: String] {
        let mac = (LiveTVStalkerConfig.normalisedMAC(config.mac) ?? config.mac)
        func escaped(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? text
        }
        var headers = [
            "Accept": "application/json",
            "User-Agent": userAgent,
            "X-User-Agent": "Model: MAG250; Link: Ethernet",
            "Referer": installationBase(endpoint) + "c/",
            "Cookie": "mac=\(escaped(mac)); stb_lang=\(escaped(config.language)); timezone=\(escaped(config.timezone))",
        ]
        if !config.serialNumber.isEmpty { headers["SN"] = config.serialNumber }
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer " + token }
        return headers
    }

    static let userAgent = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG250 stbapp ver: 2 rev: 250 Safari/533.3"

    // MARK: Answers

    enum Answer {
        case value(Any)
        /// The portal wants a new session (token gone, not authorised).
        case unauthorised
        case invalid
    }

    /// `{"js": …}`: what's inside, or why there's nothing usable.
    static func unwrap(_ data: Data) -> Answer {
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if isAuthMessage(body) { return .unauthorised }
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any],
              let js = root["js"] else { return .invalid }
        if let message = js as? String, isAuthMessage(message) { return .unauthorised }
        if let envelope = js as? [String: Any], let error = Self.text(envelope, "error", "message"), isAuthMessage(error) {
            return .unauthorised
        }
        return .value(js)
    }

    static func isAuthMessage(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmed = cleaned.hasSuffix(".") ? String(cleaned.dropLast()) : cleaned
        return ["authorization failed", "authentication failed", "not authorized", "unauthorized",
                "invalid token", "token expired", "access denied"].contains(trimmed)
    }

    /// The rows of a list answer: an array, `data` (array or keyed), or
    /// an object of objects.
    static func rows(_ value: Any) -> [[String: Any]]? {
        if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        guard let object = value as? [String: Any] else { return nil }
        if let data = object["data"] {
            if let array = data as? [Any] { return array.compactMap { $0 as? [String: Any] } }
            if let keyed = data as? [String: Any] { return keyed.values.compactMap { $0 as? [String: Any] } }
            return nil
        }
        let values = Array(object.values)
        return values.allSatisfy({ $0 is [String: Any] }) ? values.compactMap { $0 as? [String: Any] } : nil
    }

    /// A field as text (numbers too), the first of `keys` that's set.
    static func text(_ row: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            switch row[key] {
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            case let int as Int:
                return String(int)
            case let double as Double:
                return double == double.rounded() && abs(double) < 1e15 ? String(Int64(double)) : String(double)
            default:
                continue
            }
        }
        return nil
    }

    static func flag(_ row: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            switch row[key] {
            case let bool as Bool: return bool
            case let int as Int: return int != 0
            case let string as String:
                switch string.lowercased() {
                case "1", "true": return true
                case "0", "false": return false
                default: continue
                }
            default: continue
            }
        }
        return nil
    }

    // MARK: Streams

    /// "ffmpeg http://…" → "http://…" (the box's player prefixes).
    static func stripWrapper(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return trimmed }
        let prefix = trimmed[..<space].lowercased()
        return ["ffmpeg", "ffrt", "ffrt2", "ffrt3", "ffrt4", "auto"].contains(prefix)
            ? trimmed[space...].trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// The command as a link that plays as it is, if it is one (not a
    /// placeholder host the portal fills in with `create_link`).
    static func direct(_ command: String) -> URL? {
        let raw = stripWrapper(command)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty,
              !isPlaceholder(host) else { return nil }
        return url
    }

    /// What `create_link` gave, as a full link: absolute, protocol-relative,
    /// or a path under the installation.
    static func resolved(_ command: String, endpoint: String) -> URL? {
        let raw = stripWrapper(command)
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }) else { return nil }
        let absolute: String
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            absolute = raw
        } else if raw.hasPrefix("//") {
            absolute = (URL(string: endpoint)?.scheme ?? "http") + ":" + raw
        } else if raw.hasPrefix("/") {
            let basePath = URL(string: installationBase(endpoint))?.path ?? ""
            let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            let path = raw.split(separator: "?").first.map(String.init) ?? raw
            let prefixed = trimmedBase.isEmpty || path == trimmedBase || path.hasPrefix(trimmedBase + "/")
            absolute = origin(endpoint) + (prefixed ? raw : trimmedBase + raw)
        } else if !(raw.split(separator: "/").first ?? "").contains(":") {
            absolute = installationBase(endpoint) + raw
        } else {
            return nil
        }
        guard let url = URL(string: absolute), let host = url.host, !isPlaceholder(host) else { return nil }
        return url
    }

    /// A picture link: absolute, or under the portal.
    static func image(_ value: String?, endpoint: String) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return raw }
        if raw.hasPrefix("//") { return (URL(string: endpoint)?.scheme ?? "http") + ":" + raw }
        if raw.hasPrefix("/") { return origin(endpoint) + raw }
        return installationBase(endpoint) + raw
    }

    private static func isPlaceholder(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h == "0.0.0.0" || h.hasPrefix("127.")
    }

    // MARK: Guide

    /// A guide time: Unix seconds (or ms), or "2026-11-15 20:15:00" in the
    /// portal's time zone.
    static func timestamp(_ value: String, zone: TimeZone) -> Date? {
        if let number = Int64(value) {
            guard number > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(number >= 100_000_000_000 ? number / 1000 : number))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// One programme of `get_epg_info`, if it has a channel, times and a title.
    struct Programme: Equatable {
        var channel: String
        var start: Date
        var stop: Date
        var title: String
        var description: String?
    }

    /// The programmes of a `get_epg_info` answer: `data` keyed by channel
    /// (lists), or one list with `ch_id` in every row.
    static func programmes(_ value: Any, zone: TimeZone) -> [Programme] {
        var result: [Programme] = []
        func add(_ row: [String: Any], channel: String?) {
            guard let id = text(row, "ch_id", "channel_id") ?? channel,
                  let startText = text(row, "start_timestamp") ?? text(row, "start", "time"),
                  let stopText = text(row, "stop_timestamp", "end_timestamp") ?? text(row, "stop", "time_to"),
                  let start = timestamp(startText, zone: zone), let stop = timestamp(stopText, zone: zone),
                  stop > start, let title = text(row, "name", "title") else { return }
            result.append(Programme(channel: id, start: start, stop: stop, title: title,
                                    description: text(row, "descr", "description", "plot")))
        }
        let data = (value as? [String: Any]).flatMap { $0["data"] } ?? value
        if let list = data as? [Any] {
            for case let row as [String: Any] in list { add(row, channel: nil) }
        } else if let keyed = data as? [String: Any] {
            for (channel, rows) in keyed {
                let list = (rows as? [Any])
                    ?? ((rows as? [String: Any]).flatMap { ($0["data"] ?? $0["epg"] ?? $0["items"]) as? [Any] }) ?? []
                for case let row as [String: Any] in list { add(row, channel: channel) }
            }
        }
        return result
    }

    /// XMLTV time: "20261115201500 +0000".
    static func xmltvTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d +0000",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func xmlEscaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // Characters XML 1.0 doesn't allow (control codes) go.
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20,
                   scalar != "\n", scalar != "\t", scalar != "\r" { continue }
                out.append(character)
            }
        }
        return out
    }
}

// MARK: - Movies, series and catch-up (step 13f)

extension LiveTVStalkerWire {
    /// What playing a title (or finding its episodes) needs, kept with it
    /// in the VOD index (`OnDemandItem.play`), as Android's
    /// `StalkerStreamRef`: the portal's id and command, never a link.
    struct VODRef: Codable, Equatable, Sendable {
        /// The portal's id of the title (movie, series, season or episode).
        var id: String
        var cmd: String = ""
        /// Series: "c" a portal's own series list, "v" a series inside the
        /// movie list (`is_series`); nil for a movie or an episode.
        var variant: String? = nil
        /// Episode numbers of a series ("1,2,3"), or the one of an episode.
        var selectors: String? = nil
        var movieID: String? = nil
        var seasonID: String? = nil
        var hasFiles: Bool? = nil
        /// Played as it is (the portal says no temporary link is needed).
        var fixed: Bool? = nil
        /// The portal's description, for Details.
        var plot: String? = nil

        func encoded() -> String {
            (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }

        static func decode(_ text: String?) -> VODRef? {
            guard let text, !text.isEmpty else { return nil }
            return try? JSONDecoder().decode(VODRef.self, from: Data(text.utf8))
        }
    }

    /// One movie or series of a list.
    struct VODEntry: Equatable, Sendable, Codable {
        var title: String
        var ref: VODRef
        var categoryID: String
        var year: String?
        var poster: String?
        var rating: String?
        var tmdb: Int?
        var added: Int?
        var isSeries: Bool
    }

    /// The app's number for a portal id: the id itself when it is a small
    /// number (and no `salt`), else a stable hash (the salt keeps the movie
    /// list's series apart from the portal's own series list).
    static func number(for id: String, salt: String = "") -> Int {
        if salt.isEmpty, let value = Int(id), value > 0, value < 0x7FFF_FFFF { return value }
        return Int(LiveTVEPGSourceRules.fnv1a("stalker|\(salt)|" + id) & 0x7FFF_FFFE) + 1
    }

    /// The parts of a row a played title needs.
    static func ref(_ row: [String: Any], id: String) -> VODRef {
        let fixed = flag(row, "use_http_tmp_link") == false && flag(row, "use_load_balancing") != true
        return VODRef(
            id: id, cmd: text(row, "cmd") ?? "", variant: nil, selectors: selectors(row)?.joined(separator: ","),
            movieID: text(row, "video_id"), seasonID: text(row, "season_id"),
            hasFiles: flag(row, "has_files") == true ? true : nil, fixed: fixed ? true : nil)
    }

    /// The episode numbers a row lists (`series`: [1, 2, 3]).
    static func selectors(_ row: [String: Any]) -> [String]? {
        guard let list = row["series"] as? [Any] else { return nil }
        let numbers = list.compactMap { value -> String? in
            let text: String? = (value as? String) ?? (value as? Int).map(String.init)
                ?? (value as? Double).map { String(Int($0)) }
            guard let text, let number = Int(text), number > 0 else { return nil }
            return text
        }
        return numbers.isEmpty ? nil : numbers
    }

    /// A row of the movie list (`type=vod`), or of the portal's series
    /// list (`type=series`, `variant` "c").
    static func vodEntry(_ row: [String: Any], endpoint: String, zone: TimeZone, variant: String? = nil) -> VODEntry? {
        guard let id = text(row, "id") else { return nil }
        let info = row["info"] as? [String: Any] ?? row
        let isSeries = variant != nil || flag(row, "is_series") == true
        var ref = Self.ref(row, id: id)
        if isSeries { ref.variant = variant ?? "v" }
        if let plot = text(info, "description", "plot") { ref.plot = String(plot.prefix(800)) }
        let poster = image(text(info, "movie_image", "cover", "screenshot_uri") ?? text(row, "screenshot_uri", "cover"),
                           endpoint: endpoint)
        let rating = text(info, "rating_imdb", "rating_kinopoisk", "rating").flatMap { $0 == "0" || $0 == "0.0" ? nil : $0 }
        let added = text(row, "added").flatMap { timestamp($0, zone: zone) }.map { Int($0.timeIntervalSince1970) }
        return VODEntry(
            title: text(row, "name", "title") ?? id, ref: ref,
            categoryID: text(row, "category_id") ?? "", year: text(info, "year"), poster: poster, rating: rating,
            tmdb: text(row, "tmdb_id", "tmdb").flatMap(Int.init), added: added, isSeries: isSeries)
    }

    /// A season of a series.
    struct Season: Equatable, Sendable {
        var id: String
        var name: String
        var movieID: String
        var variant: String
        var number: Int?
        var command: String?
        var selectors: [String]
    }

    /// An episode, with what plays it.
    struct Episode: Equatable, Sendable {
        var title: String
        var ref: VODRef
        var number: Int?
        var poster: String?
        var plot: String?
    }

    /// A series whose list row already names its episodes (older portals):
    /// one season of those.
    static func singleSeason(_ series: VODRef, title: String) -> Season? {
        guard series.variant == "c", let selectors = series.selectors, !selectors.isEmpty else { return nil }
        return Season(id: series.id, name: title, movieID: series.id, variant: "c", number: nil,
                      command: series.cmd, selectors: selectors.split(separator: ",").map(String.init))
    }

    /// The season rows of a series (`get_ordered_list` with `movie_id`).
    static func seasons(_ rows: [[String: Any]], of series: VODRef) -> [Season] {
        rows.compactMap { row in
            guard let id = text(row, "id") else { return nil }
            let number = text(row, "season_number", "number").flatMap(Int.init)
            if series.variant == "v" {
                guard flag(row, "is_season") != false else { return nil }
                return Season(id: id, name: text(row, "name", "title") ?? "", movieID: text(row, "video_id") ?? series.id,
                              variant: "v", number: number, command: text(row, "cmd"), selectors: [])
            }
            return Season(id: id, name: text(row, "name", "title") ?? "", movieID: series.id, variant: "c",
                          number: number, command: text(row, "cmd") ?? series.cmd, selectors: selectors(row) ?? [])
        }
    }

    /// A portal series' episodes: the season's numbers, each played with
    /// the season's command, as Android's classic series.
    static func classicEpisodes(_ season: Season) -> [Episode] {
        guard let command = season.command, !command.isEmpty else { return [] }
        return season.selectors.map { selector in
            Episode(title: "", ref: VODRef(id: "\(season.movieID):\(season.id):\(selector)", cmd: command,
                                           selectors: selector, movieID: season.movieID, seasonID: season.id),
                    number: Int(selector), poster: nil, plot: nil)
        }
    }

    /// The episode rows of a season in the movie list.
    static func episodes(_ rows: [[String: Any]], of season: Season, endpoint: String) -> [Episode] {
        rows.compactMap { row in
            guard let id = text(row, "id"), flag(row, "is_episode") != false else { return nil }
            let selector = text(row, "series_number", "episode_num", "number") ?? id
            var ref = Self.ref(row, id: id)
            ref.selectors = selector
            ref.movieID = season.movieID
            ref.seasonID = season.id
            return Episode(title: text(row, "name", "title") ?? "", ref: ref, number: Int(selector),
                           poster: image(text(row, "cover", "screenshot_uri"), endpoint: endpoint),
                           plot: text(row, "description", "plot"))
        }
    }

    /// The `create_link` parameters for a movie or an episode.
    static func vodLinkParameters(_ ref: VODRef, command: String) -> [(String, String)] {
        var parameters: [(String, String)] = [
            ("type", "vod"), ("action", "create_link"), ("cmd", command), ("series", ref.selectors ?? ""),
            ("forced_storage", ""), ("disable_ad", "0"), ("download", "0"),
        ]
        if let movie = ref.movieID { parameters.append(("movie_id", movie)) }
        if let season = ref.seasonID { parameters.append(("season_id", season)) }
        return parameters
    }

    // MARK: Catch-up

    /// A channel's archive in days: `tv_archive` on and a length.
    static func archiveDays(_ row: [String: Any]) -> Int {
        guard flag(row, "tv_archive", "archive") == true,
              let days = text(row, "tv_archive_duration", "archive_duration").flatMap(Int.init), days > 0 else { return 0 }
        return min(days, 36_500)
    }

    /// A show of the archive's guide (`get_simple_data_table`).
    struct ArchivedShow: Equatable {
        var id: String
        var start: Date
        var archived: Bool
    }

    static func archivedShows(_ rows: [[String: Any]], zone: TimeZone) -> [ArchivedShow] {
        rows.compactMap { row in
            guard let id = text(row, "id", "program_id"),
                  let startText = text(row, "start_timestamp") ?? text(row, "start", "time"),
                  let start = timestamp(startText, zone: zone) else { return nil }
            return ArchivedShow(id: id, start: start, archived: flag(row, "mark_archive", "is_archive", "archive") == true)
        }
    }

    /// The archived show that starts when the guide says (within five
    /// minutes: the guide and the archive can differ a little).
    static func archivedShow(_ shows: [ArchivedShow], start: Date) -> String? {
        shows
            .filter { $0.archived && isArchiveID($0.id) && abs($0.start.timeIntervalSince(start)) <= 300 }
            .min { abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start)) }?
            .id
    }

    /// Ids that go into a command as they are (letters, digits, - and _).
    static func isArchiveID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 256 && id.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }

    /// The command for an archived show, as Android's.
    static func archiveCommand(_ id: String) -> String { "auto /media/\(id).mpg" }

    /// "2026-11-15" in the portal's time zone.
    static func day(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
