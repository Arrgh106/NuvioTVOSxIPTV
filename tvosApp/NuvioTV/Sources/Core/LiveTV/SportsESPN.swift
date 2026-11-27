import Foundation

/// ESPN's free scoreboard (no key), as Android's SportsFeeds:
/// `site.api.espn.com/apis/site/v2/sports/{path}/scoreboard?dates=YYYYMMDD`.
/// One day per request (a range is refused), days in US Eastern time.
enum SportsESPN {
    static func scoreboardURL(_ league: League, day: String) -> URL? {
        guard let path = league.espnPath else { return nil }
        return URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard?dates=\(day)&limit=1000\(league.espnQuery)")
    }

    static let eastern = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600)!

    /// ESPN's day of a moment ("20261127", US Eastern).
    static func espnDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The ESPN days a day of yours spans (one or two: Berlin's evening is
    /// still the same day in New York, its night the next).
    static func espnDays(from start: Date, to end: Date) -> [String] {
        var result: [String] = []
        for day in [espnDay(start), espnDay(end.addingTimeInterval(-1))] where !result.contains(day) {
            result.append(day)
        }
        return result
    }

    // MARK: Parsing

    private static let isoFormatters: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = $0
        return formatter
    }

    static func parseISO(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func hexColor(_ text: String?) -> UInt32? {
        guard var hex = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return 0xFF00_0000 | value
    }

    /// No colours in the feed (small clubs): a steady one from the name.
    static func clubColor(_ name: String) -> UInt32 {
        let colours: [UInt32] = [0xFF1F4E79, 0xFF7A1F1F, 0xFF1E5631, 0xFF4B2C6F, 0xFF8C4A00, 0xFF0F5257, 0xFF5A3E1B, 0xFF283044]
        var hash: UInt32 = 5381
        for byte in name.lowercased().utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return colours[Int(hash % UInt32(colours.count))]
    }

    private static func str(_ object: [String: Any]?, _ key: String) -> String? {
        guard let value = object?[key] else { return nil }
        let text: String?
        if let string = value as? String { text = string } else if let number = value as? NSNumber { text = number.stringValue } else { text = nil }
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty, text != "null" else { return nil }
        return text
    }

    private static func dict(_ object: [String: Any]?, _ key: String) -> [String: Any]? { object?[key] as? [String: Any] }
    private static func list(_ object: [String: Any]?, _ key: String) -> [[String: Any]] { object?[key] as? [[String: Any]] ?? [] }

    static func team(_ league: League, _ t: [String: Any]?, athlete: [String: Any]? = nil) -> TeamInfo? {
        if let t {
            guard let id = str(t, "id"),
                  let name = str(t, "shortDisplayName") ?? str(t, "name") ?? str(t, "displayName") else { return nil }
            let logo = str(t, "logo") ?? pickLogo(list(t, "logos"))
            let alt = hexColor(str(t, "alternateColor"))
            return TeamInfo(
                leagueId: league.id, id: id, name: name,
                fullName: str(t, "displayName") ?? str(t, "name") ?? "",
                abbr: str(t, "abbreviation") ?? "",
                location: str(t, "location"),
                color: hexColor(str(t, "color")) ?? (alt == nil ? clubColor(str(t, "displayName") ?? str(t, "name") ?? id) : nil),
                altColor: alt,
                logo: logo,
                record: str(list(dict(t, "record"), "items").first, "summary"))
        }
        if let athlete, let name = str(athlete, "displayName") ?? str(athlete, "fullName") {
            return TeamInfo(
                leagueId: league.id, id: str(athlete, "id") ?? name, name: str(athlete, "shortName") ?? name,
                fullName: name, abbr: String((name.split(separator: " ").last ?? "").prefix(3)).uppercased(),
                location: nil, color: nil, altColor: nil,
                logo: str(dict(athlete, "headshot"), "href") ?? str(dict(athlete, "flag"), "href"))
        }
        return nil
    }

    /// The normal logo (not the one for dark backgrounds: ours sit on a
    /// light disc).
    private static func pickLogo(_ logos: [[String: Any]]) -> String? {
        var first: String?
        for logo in logos {
            guard let href = str(logo, "href") else { continue }
            if first == nil { first = href }
            let rel = logo["rel"] as? [String] ?? []
            if rel.contains("default") && !rel.contains("dark") { return href }
        }
        return first
    }

    /// ESPN's core API page of a league (its name and logos).
    static func coreLeagueURL(_ league: League) -> URL? {
        guard let path = league.espnPath, let slash = path.firstIndex(of: "/") else { return nil }
        return URL(string: "https://sports.core.api.espn.com/v2/sports/\(path[..<slash])/leagues/\(path[path.index(after: slash)...])")
    }

    /// A league's logo from the core API (not ESPN's own placeholder icon),
    /// else from a known address (cricket).
    static func coreLeagueLogo(_ league: League, data: Data) -> String? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let logos = (root?["logos"] as? [[String: Any]] ?? []).compactMap { $0["href"] as? String }
            .filter { !$0.contains("ESPN-icon") }
        if let first = logos.first { return first.replacingOccurrences(of: "http://", with: "https://") }
        return patternLogo(league)
    }

    /// Leagues whose logo sits at a known address (cricket: by its id).
    static func patternLogo(_ league: League) -> String? {
        guard let path = league.espnPath, path.hasPrefix("cricket/"), path != "cricket/panel" else { return nil }
        return "https://a.espncdn.com/i/leaguelogos/cricket/500/\(path.dropFirst("cricket/".count)).png"
    }

    /// The league's logo from a scoreboard (the one for dark backgrounds).
    static func leagueLogo(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let logos = (root["leagues"] as? [[String: Any]])?.first?["logos"] as? [[String: Any]] else { return nil }
        var pick: String?
        for logo in logos {
            guard let href = logo["href"] as? String, href.hasPrefix("http") else { continue }
            if pick == nil { pick = href }
            if (logo["rel"] as? [String] ?? []).contains("dark") { return href }
        }
        return pick
    }

    static func parseScoreboard(_ league: League, data: Data, now: Date = Date()) -> [SportsEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return list(root, "events").compactMap { parseEvent(league, $0, now: now) }
    }

    /// A team's schedule: each game under its own competition when the
    /// feed says which (a Champions League game in Dortmund's schedule).
    static func parseSchedule(_ league: League, data: Data, now: Date = Date()) -> [SportsEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let prefix = league.espnPath?.split(separator: "/").first else { return [] }
        return list(root, "events").compactMap { ev in
            let slug = str(dict(ev, "league"), "slug") ?? str(dict(list(ev, "competitions").first, "league"), "slug")
            let own = slug.flatMap { SportsCatalog.league("\(prefix)/\($0)") }.flatMap { $0.onESPN ? $0 : nil } ?? league
            return parseEvent(own, ev, now: now)
        }
    }

    private static let offWords = ["POSTPONED", "CANCEL", "SUSPENDED", "FORFEIT", "ABANDON"]

    static func parseEvent(_ league: League, _ ev: [String: Any], now: Date = Date()) -> SportsEvent? {
        guard let espnId = str(ev, "id"), let start = parseISO(str(ev, "date")) else { return nil }
        let end = parseISO(str(ev, "endDate"))
        let comp = list(ev, "competitions").first
        // An event with sessions (practice, qualifying, race): the event's own status.
        let st = league.kind == .event ? (dict(ev, "status") ?? dict(comp, "status")) : (dict(comp, "status") ?? dict(ev, "status"))
        let type = dict(st, "type")
        let stateRaw = str(type, "state")
        let name = str(type, "name") ?? ""
        let state: GameState
        if offWords.contains(where: { name.uppercased().contains($0) }) {
            state = .off
        } else if stateRaw == "in" {
            state = .live
        } else if stateRaw == "post" {
            state = .post
        } else {
            state = .pre
        }
        // Cricket says where the match stands ("India need 45 runs").
        let short = (league.sport == .cricket ? (str(st, "summary") ?? str(dict(ev, "status"), "summary")) : nil)
            ?? str(type, "shortDetail") ?? str(type, "detail")
        let status: String?
        switch state {
        case .live: status = short.map(clockLast)
        case .post: status = short ?? "Final"
        case .off: status = str(type, "description") ?? "Postponed"
        case .pre: status = nil
        }
        let period = (st?["period"] as? NSNumber)?.intValue ?? 0
        let clock = (st?["clock"] as? NSNumber)?.doubleValue
        let progress = state == .live ? progressOf(league, period: period, clock: clock, displayClock: str(st, "displayClock")) : nil

        // Best first: national channels, the home team's, the away team's;
        // apps and websites after real channels.
        var ranked: [(name: String, rank: Int)] = []
        func marketRank(_ market: String?) -> Int {
            switch market?.lowercased() {
            case "national": return 0
            case "home": return 1
            case "away": return 2
            default: return 3
            }
        }
        for broadcast in list(comp, "broadcasts") {
            let rank = marketRank(str(broadcast, "market"))
            for name in broadcast["names"] as? [String] ?? [] { ranked.append((name, rank)) }
        }
        for broadcast in list(comp, "geoBroadcasts") {
            let rank = marketRank(str(dict(broadcast, "market"), "type"))
            if let name = str(dict(broadcast, "media"), "shortName") { ranked.append((name, rank)) }
        }
        func isApp(_ name: String) -> Bool {
            let n = name.lowercased()
            return n.hasSuffix(" app") || n.contains(".com") || n.contains("league pass") || n.hasSuffix("+")
        }
        var broadcasts: [String] = []
        for item in ranked.enumerated().sorted(by: { a, b in
            (a.element.rank, isApp(a.element.name) ? 1 : 0, a.offset) < (b.element.rank, isApp(b.element.name) ? 1 : 0, b.offset)
        }) where !broadcasts.contains(item.element.name) {
            broadcasts.append(item.element.name)
        }
        let venue = str(dict(comp, "venue"), "fullName") ?? str(dict(ev, "circuit"), "fullName")
        let city = str(dict(dict(comp, "venue"), "address"), "city") ?? str(dict(dict(ev, "circuit"), "address"), "city")
        let week = ((dict(ev, "week")?["number"] as? NSNumber)?.intValue).flatMap { $0 > 0 ? "Week \($0)" : nil }
        let headline = str(list(comp, "notes").first, "headline")

        if league.kind == .event {
            let multiDay = end.map { $0.timeIntervalSince(start) > 20 * 3600 } ?? false
            // A tournament that runs for days isn't over (or not started)
            // between its first day and its last.
            let underWay = multiDay && end.map { $0.addingTimeInterval(24 * 3600) > now } == true && start <= now
            let shown = underWay && (state == .post || state == .pre) ? GameState.live : state
            var note: String?
            if multiDay, let end {
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
                note = "Until " + formatter.string(from: end)
            }
            return SportsEvent(
                id: "espn:\(league.id):\(espnId)", leagueId: league.id, start: start, hasTime: !multiDay, state: shown,
                title: str(ev, "name") ?? str(ev, "shortName") ?? league.name,
                subtitle: [headline, venue].compactMap { $0 }.joined(separator: " · ").nilIfBlank,
                status: status, away: nil, home: nil, broadcasts: broadcasts, espnId: espnId, note: note, end: end,
                venue: venue, city: city)
        }

        var home: SportsSide?
        var away: SportsSide?
        for co in list(comp, "competitors") {
            guard let team = team(league, dict(co, "team"), athlete: dict(co, "athlete")) else { continue }
            var score: String?
            if let object = co["score"] as? [String: Any] {
                score = str(object, "displayValue")
            } else if let text = co["score"] as? String, !text.isEmpty {
                score = text
            } else if let number = co["score"] as? NSNumber {
                score = String(number.intValue)
            }
            if state == .pre { score = nil }
            let periods: [String] = list(co, "linescores").compactMap { line in
                str(line, "displayValue") ?? (line["value"] as? NSNumber).map { String($0.intValue) }
            }
            let side = SportsSide(
                team: team, score: score, record: str(list(co, "records").first, "summary"),
                winner: (co["winner"] as? Bool) ?? false, home: str(co, "homeAway") == "home", periods: periods)
            if side.home && home == nil { home = side } else if away == nil { away = side } else if home == nil { home = side }
        }
        guard let h = home, let a = away else { return nil }
        var situation: String?
        if state == .live, let s = dict(comp, "situation"),
           let downDistance = str(s, "downDistanceText") ?? str(s, "shortDownDistanceText") {
            let who = [h, a].first { $0.team.id == str(s, "possession") }?.team.abbr
            situation = who.map { "\($0) ball · \(downDistance)" } ?? downDistance
        }
        let title = league.sport.homeFirst ? "\(h.team.name) v \(a.team.name)" : "\(a.team.name) at \(h.team.name)"
        return SportsEvent(
            id: "espn:\(league.id):\(espnId)", leagueId: league.id, start: start, hasTime: true, state: state,
            title: title, subtitle: [headline, week, venue].compactMap { $0 }.joined(separator: " · ").nilIfBlank,
            status: status, away: a, home: h, broadcasts: broadcasts, situation: situation, progress: progress,
            espnId: espnId, venue: venue, city: city)
    }

    /// "4:12 - 3rd" reads "3rd · 4:12".
    static func clockLast(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d{1,2}:\d{2}(?:\.\d)?)\s*-\s*(.+)$"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let clock = Range(match.range(at: 1), in: text), let rest = Range(match.range(at: 2), in: text) else { return text }
        return "\(text[rest]) · \(text[clock])"
    }

    /// How far through the game the clock is (0…1).
    static func progressOf(_ league: League, period: Int, clock: Double?, displayClock: String?) -> Double? {
        guard period > 0 else { return nil }
        func countdown(_ periods: Int, _ length: Double) -> Double? {
            guard let clock else { return nil }
            let done = Double(min(period - 1, periods)) * length + (length - min(max(clock, 0), length))
            return min(max(done / (Double(periods) * length), 0), 1)
        }
        switch league.sport {
        case .americanFootball: return countdown(4, 900)
        case .basketball:
            switch league.id {
            case "basketball/nba": return countdown(4, 720)
            case "basketball/mens-college-basketball": return countdown(2, 1200)
            default: return countdown(4, 600)
            }
        case .hockey: return countdown(3, 1200)
        case .baseball: return min(max((Double(period) - 0.5) / 9, 0), 1)
        case .football:
            guard let displayClock, let minute = Double(displayClock.prefix { $0.isNumber }) else { return nil }
            return min(max(minute / 90, 0), 1)
        default: return nil
        }
    }
}

extension String {
    /// Nil for "" (and only spaces).
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
