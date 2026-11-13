import Foundation

/// The provider's movies and series (step 12, Android's "VOD"):
/// what's kept of each, and how a title in Nuvio finds its copy at the
/// provider. Pure, so the logic tests run it on Linux.
enum OnDemandKind: String, Sendable, CaseIterable {
    case movie
    case series
}

struct OnDemandItem: Sendable, Equatable {
    let kind: OnDemandKind
    /// `stream_id` (movies) or `series_id` (series).
    let id: Int
    let name: String
    /// `OnDemandTitle.key(name)`: what titles are matched by.
    let key: String
    let categoryID: String
    /// Movies: `container_extension`.
    let ext: String?
    let tmdb: Int?
    let year: Int?
    /// `stream_icon` / `cover` (web links only).
    var icon: String? = nil
    /// When the provider added it (seconds since 1970).
    var added: Int? = nil
    var rating: String? = nil
}

/// Ids of the provider's titles in Nuvio (step 12b): `ondemand:movie:5`,
/// `ondemand:series:7`, episodes `ondemand:series:7:1:2`.
enum OnDemandID {
    static let prefix = "ondemand:"

    static func make(_ kind: OnDemandKind, _ id: Int) -> String {
        "\(prefix)\(kind.rawValue):\(id)"
    }

    static func episode(seriesID: Int, season: Int, episode: Int) -> String {
        "\(prefix)series:\(seriesID):\(season):\(episode)"
    }

    /// Kind and id of a title or episode id (season and episode as well).
    static func parse(_ value: String) -> (kind: OnDemandKind, id: Int, season: Int?, episode: Int?)? {
        guard value.hasPrefix(prefix) else { return nil }
        let parts = value.dropFirst(prefix.count).split(separator: ":").map(String.init)
        guard parts.count >= 2, let kind = OnDemandKind(rawValue: parts[0]), let id = Int(parts[1]) else { return nil }
        let season = parts.count >= 4 ? Int(parts[2]) : nil
        let episode = parts.count >= 4 ? Int(parts[3]) : nil
        return (kind, id, season, episode)
    }
}

/// One episode from `get_series_info`.
struct OnDemandEpisode: Sendable, Equatable {
    let id: Int
    let season: Int
    let episode: Int
    let ext: String
    let title: String
}

enum OnDemandTitle {
    /// Words that say nothing about which title it is.
    private static let noise: Set<String> = [
        "4k", "uhd", "fhd", "hd", "sd", "hq", "2160p", "1080p", "720p", "480p", "hevc", "x265", "x264", "h264", "h265",
        "multi", "sub", "subs", "dub", "dubbed", "vostfr", "remux", "bluray", "webrip", "webdl", "hdr", "dv", "imax",
    ]

    /// Provider tags before the title ("EN - ", "|DE| ", "[US] ", "NF: "):
    /// a short leading part, cut off at " - ", "|" or ":".
    static func leadingTag(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for separator in [" - ", "|", ": ", " : "] {
            guard let range = trimmed.range(of: separator) else { continue }
            let head = trimmed[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " |[]"))
            let rest = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !head.isEmpty, !rest.isEmpty, head.split(separator: " ").count <= 4, head.count <= 24 else { continue }
            return head.lowercased()
        }
        return nil
    }

    /// Tags that start many names of one catalog (as Android: at least
    /// max(15, total / 500) times): those come off before matching.
    static func learnTags(_ names: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for name in names {
            if let tag = leadingTag(name) { counts[tag, default: 0] += 1 }
        }
        let needed = max(15, names.count / 500)
        return Set(counts.filter { $0.value >= needed }.map(\.key))
    }

    /// The name without a learned tag, brackets ("[US]", "(2021)"), a year
    /// at the end and quality words; lowercased letters and digits only.
    static func key(_ name: String, tags: Set<String> = []) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|"), let close = text.dropFirst().firstIndex(of: "|") {
            text = String(text[text.index(after: close)...])
        }
        if let tag = leadingTag(text), tags.contains(tag) {
            for separator in [" - ", "|", ": ", " : "] {
                if let range = text.range(of: separator) {
                    text = String(text[range.upperBound...])
                    break
                }
            }
        }
        text = stripBrackets(text.lowercased())
        var words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        words.removeAll { noise.contains($0) }
        if words.count > 1, let last = words.last, isYear(last) { words.removeLast() }
        return words.joined()
    }

    /// A year in brackets or at the end of the name; "1917" or "2001: A
    /// Space Odyssey" alone are titles, not years.
    static func yearInName(_ name: String) -> Int? {
        let text = name.trimmingCharacters(in: .whitespaces)
        if let open = text.lastIndex(where: { $0 == "(" || $0 == "[" }) {
            let inside = text[text.index(after: open)...].prefix(4)
            if isYear(String(inside)) { return Int(inside) }
        }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count > 1, let last = words.last, isYear(String(last)) { return Int(last) }
        return nil
    }

    /// The first 19xx / 20xx year in a date or year field, not after next year.
    static func year(field: String?, now: Date = Date()) -> Int? {
        guard let field else { return nil }
        let digits = Array(field)
        guard digits.count >= 4 else { return nil }
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: now)
        for start in 0...(digits.count - 4) {
            let candidate = String(digits[start..<(start + 4)])
            if isYear(candidate), let year = Int(candidate), year <= thisYear + 1 { return year }
        }
        return nil
    }

    static func isYear(_ text: String) -> Bool {
        text.count == 4 && (text.hasPrefix("19") || text.hasPrefix("20")) && text.allSatisfy(\.isNumber)
    }

    private static func stripBrackets(_ text: String) -> String {
        var out = ""
        var depth = 0
        for char in text {
            if char == "(" || char == "[" || char == "{" { depth += 1; out.append(" "); continue }
            if char == ")" || char == "]" || char == "}" { depth = max(0, depth - 1); out.append(" "); continue }
            if depth == 0 { out.append(char) }
        }
        return out
    }

    /// The name to search other catalogs with: without a learned tag,
    /// brackets, a year at the end and quality words ("EN - Dune (2021) 4K"
    /// → "Dune").
    static func searchName(_ name: String, tags: Set<String> = []) -> String {
        var text = name.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|"), let close = text.dropFirst().firstIndex(of: "|") {
            text = String(text[text.index(after: close)...])
        }
        if let tag = leadingTag(text), tags.contains(tag) {
            for separator in [" - ", "|", ": ", " : "] {
                if let range = text.range(of: separator) {
                    text = String(text[range.upperBound...])
                    break
                }
            }
        }
        text = stripBrackets(text)
        var words = text.split(separator: " ").map(String.init)
        words.removeAll { noise.contains($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
        if words.count > 1, let last = words.last, isYear(last) { words.removeLast() }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -|:"))
    }

    /// "4K", "1080p", "720p" or nil, read from the provider's name.
    static func quality(_ name: String) -> String? {
        let lower = name.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !words.isDisjoint(with: ["4k", "uhd", "2160p"]) { return "4K" }
        if !words.isDisjoint(with: ["1080p", "fhd"]) { return "1080p" }
        if !words.isDisjoint(with: ["720p", "hd"]) { return "720p" }
        if words.contains("sd") || words.contains("480p") { return "SD" }
        return nil
    }

    static func qualityRank(_ quality: String?) -> Int {
        switch quality {
        case "4K": return 0
        case "1080p": return 1
        case "720p": return 2
        case "SD": return 4
        default: return 3
        }
    }
}

enum OnDemandMatch {
    /// The provider's copies of a title: by TMDB id when both sides have
    /// one, otherwise by name with the year within one (or unknown on either
    /// side). Best quality first, at most `limit`.
    static func copies(
        of candidates: [OnDemandItem], name: String, year: Int?, tmdb: Int?, limit: Int = 6
    ) -> [OnDemandItem] {
        let key = OnDemandTitle.key(name)
        var found: [OnDemandItem] = []
        if let tmdb {
            found = candidates.filter { $0.tmdb == tmdb }
        }
        if found.isEmpty, !key.isEmpty {
            found = candidates.filter { item in
                // A copy with another TMDB id is another title of that name.
                if let tmdb, let itemTMDB = item.tmdb, itemTMDB != tmdb { return false }
                guard item.key == key else { return false }
                guard let year, let itemYear = item.year else { return true }
                return abs(year - itemYear) <= 1
            }
        }
        var seen = Set<Int>()
        return found
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let l = OnDemandTitle.qualityRank(OnDemandTitle.quality(lhs.name))
                let r = OnDemandTitle.qualityRank(OnDemandTitle.quality(rhs.name))
                if l != r { return l < r }
                return lhs.name != rhs.name ? lhs.name < rhs.name : lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The catalog title that is this provider title: the same match key,
    /// the year within one when both are known (the closest year first).
    static func pick(_ results: [(id: String, name: String, year: Int?)], key: String, year: Int?) -> String? {
        let same = results.filter { result in
            guard OnDemandTitle.key(result.name) == key else { return false }
            guard let year, let resultYear = result.year else { return true }
            return abs(year - resultYear) <= 1
        }
        guard let year else { return same.first?.id }
        return same.min { abs(($0.year ?? year) - year) < abs(($1.year ?? year) - year) }?.id
    }

    /// The episode in a series' list. When the provider has only one
    /// season, the episode number alone is enough (as on Android).
    static func episode(_ episodes: [OnDemandEpisode], season: Int, episode: Int) -> OnDemandEpisode? {
        if let exact = episodes.first(where: { $0.season == season && $0.episode == episode }) { return exact }
        let seasons = Set(episodes.map(\.season))
        guard seasons.count == 1 else { return nil }
        return episodes.first { $0.episode == episode }
    }
}

enum OnDemandParse {
    /// `get_series_info` → its episodes, by season then number.
    static func episodes(_ data: Data) -> [OnDemandEpisode] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var lists: [(String, [[String: Any]])] = []
        if let bySeason = root["episodes"] as? [String: Any] {
            for (key, value) in bySeason {
                if let list = value as? [[String: Any]] { lists.append((key, list)) }
            }
        } else if let flat = root["episodes"] as? [[String: Any]] {
            lists.append(("", flat))
        }
        var out: [OnDemandEpisode] = []
        for (seasonKey, list) in lists {
            for (index, entry) in list.enumerated() {
                guard let id = int(entry["id"]) else { continue }
                let season = int(entry["season"]) ?? Int(seasonKey) ?? 1
                let number = int(entry["episode_num"]) ?? index + 1
                let ext = (entry["container_extension"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
                let title = (entry["title"] as? String) ?? "Episode \(number)"
                out.append(OnDemandEpisode(id: id, season: season, episode: number, ext: ext, title: title))
            }
        }
        return out.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    /// Ids and numbers come as numbers or strings, depending on the panel.
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let text as String: return Int(text.trimmingCharacters(in: .whitespaces))
        case let number as NSNumber: return number.intValue
        default: return nil
        }
    }
}

/// One entry of `get_vod_streams` / `get_series`, read leniently: panels
/// send ids and years as numbers or strings, and some fields are missing.
struct OnDemandRawItem: Decodable, Sendable {
    let id: Int?
    let name: String
    let categoryID: String
    let ext: String?
    let tmdb: Int?
    let yearField: String?
    let icon: String?
    let added: Int?
    let rating: String?

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func text(_ key: String) -> String? {
            let k = Key(key)
            if let value = try? c.decodeIfPresent(String.self, forKey: k) { return value }
            if let value = try? c.decodeIfPresent(Int.self, forKey: k) { return String(value) }
            if let value = try? c.decodeIfPresent(Double.self, forKey: k) { return String(Int(value)) }
            return nil
        }
        func number(_ key: String) -> Int? {
            text(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        id = number("stream_id") ?? number("series_id")
        let rawName = (text("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = rawName.isEmpty ? (text("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : rawName
        categoryID = text("category_id") ?? ""
        let extension_ = text("container_extension")?.trimmingCharacters(in: .whitespaces)
        ext = extension_?.isEmpty == false ? extension_ : nil
        let tmdbID = number("tmdb") ?? number("tmdb_id")
        tmdb = tmdbID == 0 ? nil : tmdbID
        yearField = ["year", "releaseDate", "release_date"].compactMap { text($0) }.first { !$0.isEmpty }
        let picture = (text("stream_icon") ?? text("cover"))?.trimmingCharacters(in: .whitespaces)
        icon = picture?.lowercased().hasPrefix("http") == true ? picture : nil
        added = number("added") ?? number("last_modified")
        let score = text("rating")?.trimmingCharacters(in: .whitespaces)
        rating = score == nil || score == "" || score == "0" ? nil : score
    }
}

extension OnDemandParse {
    /// A whole list → items with their match keys (tags learned from the
    /// list itself). Entries without id or name are left out.
    static func items(_ data: Data, kind: OnDemandKind) -> [OnDemandItem]? {
        list(data, kind: kind)?.items
    }

    /// The items and the tags learned from them.
    static func list(_ data: Data, kind: OnDemandKind) -> (items: [OnDemandItem], tags: Set<String>)? {
        guard let raw = try? JSONDecoder().decode([OnDemandRawItem].self, from: data) else { return nil }
        let usable = raw.filter { $0.id != nil && !$0.name.isEmpty }
        let tags = OnDemandTitle.learnTags(usable.map(\.name))
        let items = usable.map { entry in
            OnDemandItem(
                kind: kind, id: entry.id!, name: entry.name,
                key: OnDemandTitle.key(entry.name, tags: tags),
                categoryID: entry.categoryID, ext: entry.ext, tmdb: entry.tmdb,
                year: OnDemandTitle.year(field: entry.yearField) ?? OnDemandTitle.yearInName(entry.name),
                icon: entry.icon, added: entry.added, rating: entry.rating)
        }
        return (items, tags)
    }
}

// MARK: Search, duplicates (step 12c)

extension OnDemandTitle {
    /// What's typed in search as parts of match keys ("The Dark Knight
    /// 2008" → ["dark", "knight"]): words that never make it into a key
    /// (noise, a year after other words) are left out.
    static func searchWords(_ query: String) -> [String] {
        var words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !noise.contains($0) }
        if words.count > 1 { words.removeAll { isYear($0) } }
        return words
    }
}

/// "Merge Duplicates", as Android: the same TMDB id, or the same name with
/// the same year (a copy without a year matches any year), is one title.
/// The first copy seen stays; its details still offer every copy.
struct OnDemandDedupe: Sendable {
    private var tmdbSeen: Set<String> = []
    /// Kind and key → the years seen with it (0: none).
    private var years: [String: Set<Int>] = [:]

    init() {}

    mutating func isNew(_ item: OnDemandItem) -> Bool {
        let tmdbKey = item.tmdb.map { "\(item.kind.rawValue):\($0)" }
        if let tmdbKey, tmdbSeen.contains(tmdbKey) { return false }
        let nameKey = "\(item.kind.rawValue):\(item.key)"
        let year = item.year ?? 0
        if !item.key.isEmpty, let seen = years[nameKey],
           year == 0 || seen.contains(0) || seen.contains(year) {
            return false
        }
        if let tmdbKey { tmdbSeen.insert(tmdbKey) }
        if !item.key.isEmpty { years[nameKey, default: []].insert(year) }
        return true
    }

    mutating func filter(_ items: [OnDemandItem]) -> [OnDemandItem] {
        items.filter { isNew($0) }
    }
}

enum OnDemandSearchMatch {
    /// Provider titles that none of `known` (the add-ons' search results)
    /// already is: not the same TMDB id, not the same name with the year
    /// within one.
    static func providerOnly(
        _ items: [OnDemandItem], known: [(name: String, year: Int?, tmdb: Int?)]
    ) -> [OnDemandItem] {
        let tmdbs = Set(known.compactMap(\.tmdb))
        var yearsByKey: [String: [Int?]] = [:]
        for entry in known {
            let key = OnDemandTitle.key(entry.name)
            if !key.isEmpty { yearsByKey[key, default: []].append(entry.year) }
        }
        return items.filter { item in
            if let tmdb = item.tmdb, tmdbs.contains(tmdb) { return false }
            guard let years = yearsByKey[item.key] else { return true }
            return !years.contains { year in
                guard let year, let itemYear = item.year else { return true }
                return abs(year - itemYear) <= 1
            }
        }
    }

    /// Some of each, as Android: a long list of movies doesn't hide the
    /// series.
    static func mix(movies: [OnDemandItem], series: [OnDemandItem], limit: Int) -> [OnDemandItem] {
        let takeMovies = min(movies.count, max(limit / 2, limit - series.count))
        let movieHalf = Array(movies.prefix(takeMovies))
        return movieHalf + series.prefix(max(0, limit - movieHalf.count))
    }
}
