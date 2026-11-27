import Foundation

/// Fork (Live TV step 17c): more about a game, for its page, from ESPN's
/// summary (`summary?event=`), as Android's SportsExtras and parseSummary.
/// Every part is optional: ESPN gives different things for different sports
/// and at different times; a part it doesn't give isn't shown.
struct SportsScoringPlay: Hashable, Sendable {
    /// "2nd 4:12", "67'".
    let clock: String
    let team: String?
    let text: String
    let awayScore: String?
    let homeScore: String?
}

/// One team stat side by side ("POSSESSION 54% · 46%"); numbers for the bars.
struct SportsStatLine: Hashable, Sendable {
    let label: String
    let away: String
    let home: String
    let awayValue: Double?
    let homeValue: Double?
}

/// A game's leader: "PASSING · Patrick Mahomes · 22/31, 236 YDS".
struct SportsPerformer: Hashable, Sendable {
    let category: String
    let name: String
    let line: String
    let teamId: String?
    let photo: String?
    let position: String?
}

/// A team's last results, newest last ("W", "L", "D").
struct SportsFormRow: Hashable, Sendable {
    let teamId: String?
    let team: String
    let results: [String]
}

/// One earlier meeting ("Everton 0–2 Arsenal").
struct SportsMeeting: Hashable, Sendable {
    let date: Date?
    let text: String
}

/// A line of the league table; `mine`: one of this game's teams.
struct SportsTableRow: Hashable, Sendable {
    let pos: String
    let team: String
    let a: String
    let b: String
    let c: String
    let mine: Bool
    /// The other team's group, above its first row.
    var group: String? = nil
}

/// A team's starting line-up.
struct SportsLineup: Hashable, Sendable {
    let team: String
    let teamId: String?
    let formation: String?
    let players: [String]
}

struct SportsGameExtras: Sendable {
    var plays: [SportsScoringPlay] = []
    var stats: [SportsStatLine] = []
    var performers: [SportsPerformer] = []
    var form: [SportsFormRow] = []
    var meetings: [SportsMeeting] = []
    var tableTitle: String?
    var tableHead: [String] = []
    var table: [SportsTableRow] = []
    var venue: String?
    var city: String?
    var tempF: Int?
    var conditions: String?
    var referee: String?
    var attendance: Int?
    /// Chances in percent: before the game ESPN's prediction, during it
    /// the latest win probability.
    var homeWin: Double?
    var awayWin: Double?
    var draw: Double?
    /// The home team's chance through the game (0…1), oldest first.
    var winHistory: [Double] = []
    var lineups: [SportsLineup] = []

    var hasInfo: Bool { venue != nil || tempF != nil || referee != nil || attendance != nil }
    var hasOdds: Bool { homeWin != nil && awayWin != nil }
}

enum SportsSummary {
    static func url(_ league: League, espnId: String) -> URL? {
        guard let path = league.espnPath else { return nil }
        return URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/summary?event=\(espnId)")
    }

    private typealias JSON = [String: Any]

    private static func s(_ object: JSON?, _ key: String) -> String? {
        guard let value = object?[key] else { return nil }
        let text: String?
        if let string = value as? String { text = string } else if let number = value as? NSNumber { text = number.stringValue } else { text = nil }
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty, text != "null" else { return nil }
        return text
    }

    private static func o(_ object: JSON?, _ key: String) -> JSON? { object?[key] as? JSON }
    private static func a(_ object: JSON?, _ key: String) -> [JSON] { object?[key] as? [JSON] ?? [] }

    /// "54.2%", "24:12", "4-11", "331": a number for the bars.
    static func number(_ text: String?) -> Double? {
        guard var t = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if t.hasSuffix("%") { t.removeLast() }
        let parts = t.split(separator: ":")
        if parts.count == 2, let m = Double(parts[0]), parts[1].count == 2, let sec = Double(parts[1]) { return m * 60 + sec }
        var head = ""
        for (i, ch) in t.enumerated() {
            if ch.isNumber || ch == "." || (i == 0 && ch == "-") { head.append(ch) } else { break }
        }
        return Double(head)
    }

    private static func periodLabel(_ p: Int) -> String {
        switch p {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(p)th"
        }
    }

    static func parse(_ data: Data, event: SportsEvent, sport: Sport) -> SportsGameExtras {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return SportsGameExtras() }
        let homeId = event.home?.team.id
        let awayId = event.away?.team.id
        var names: [String: String] = [:]
        for side in event.sides { names[side.team.id] = side.team.name }
        func nameOf(_ id: String?, _ fallback: String?) -> String { id.flatMap { names[$0] } ?? fallback ?? "" }

        var extras = SportsGameExtras()
        extras.plays = plays(root)
        extras.stats = stats(root, sport: sport, homeId: homeId)
        extras.performers = performers(root)
        extras.form = form(root, nameOf)
        extras.meetings = meetings(root, nameOf)
        extras.lineups = lineups(root, nameOf)
        table(root, into: &extras, ids: Set([homeId, awayId].compactMap { $0 }), teamNames: Set(names.values))
        info(root, into: &extras)
        odds(root, into: &extras)
        return extras
    }

    // MARK: Scoring

    static func plays(_ data: Data) -> [SportsScoringPlay] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return [] }
        return plays(root)
    }

    private static func scoreText(_ value: Any?) -> String? {
        if let n = value as? NSNumber { return n.stringValue }
        return value as? String
    }

    private static func plays(_ root: JSON) -> [SportsScoringPlay] {
        var out: [SportsScoringPlay] = []
        for p in a(root, "scoringPlays") {
            let period = (o(p, "period")?["number"] as? NSNumber)?.intValue ?? 0
            let clock = [period > 0 ? periodLabel(period) : nil, s(o(p, "clock"), "displayValue")].compactMap { $0 }.joined(separator: " ")
            let type = s(o(p, "scoringType"), "abbreviation") ?? s(o(p, "type"), "abbreviation")
            out.append(SportsScoringPlay(
                clock: clock, team: s(o(p, "team"), "abbreviation") ?? s(o(p, "team"), "displayName"),
                text: [type, s(p, "text")].compactMap { $0 }.joined(separator: " · "),
                awayScore: scoreText(p["awayScore"]), homeScore: scoreText(p["homeScore"])))
        }
        // Hockey, baseball, basketball: every play, the scoring ones marked.
        if out.isEmpty {
            var abbrs: [String: String] = [:]
            for c in a(list(o(root, "header"), "competitions").first, "competitors") {
                if let t = o(c, "team"), let id = s(t, "id") { abbrs[id] = s(t, "abbreviation") ?? s(t, "shortDisplayName") }
            }
            for p in a(root, "plays") where (p["scoringPlay"] as? Bool) == true {
                let per = o(p, "period")
                var periodText = s(per, "displayValue")
                for word in [" Period", " Quarter", " Half"] {
                    if let range = periodText?.range(of: word, options: [.caseInsensitive, .anchored, .backwards]) {
                        periodText?.removeSubrange(range)
                    }
                }
                if periodText == nil, let n = (per?["number"] as? NSNumber)?.intValue, n > 0 { periodText = periodLabel(n) }
                let clock = s(o(p, "clock"), "displayValue")
                let team = s(o(p, "team"), "abbreviation") ?? s(o(p, "team"), "id").flatMap { abbrs[$0] }
                out.append(SportsScoringPlay(
                    clock: [periodText, (clock != "0:00" || periodText == nil) ? clock : nil].compactMap { $0 }.joined(separator: " "),
                    team: team, text: s(p, "text") ?? s(o(p, "type"), "text") ?? "Score",
                    awayScore: scoreText(p["awayScore"]), homeScore: scoreText(p["homeScore"])))
            }
        }
        // Football and rugby: goals and tries among the key events.
        if out.isEmpty {
            let scored = ["goal", "try", "conversion", "scored", "touchdown"]
            let notScored = ["missed", "no goal", "disallowed", "saved", "attempt"]
            for p in a(root, "keyEvents") {
                let kind = (s(o(p, "type"), "text") ?? "").lowercased()
                let goal = (p["scoringPlay"] as? Bool) == true
                    || (scored.contains { kind.contains($0) } && !notScored.contains { kind.contains($0) })
                guard goal else { continue }
                out.append(SportsScoringPlay(
                    clock: s(o(p, "clock"), "displayValue") ?? "",
                    team: s(o(p, "team"), "abbreviation") ?? s(o(p, "team"), "displayName"),
                    text: s(p, "text") ?? s(o(p, "type"), "text") ?? "Goal", awayScore: nil, homeScore: nil))
            }
        }
        // Some summaries (college sports) list the moments under the header.
        if out.isEmpty {
            for p in a(list(o(root, "header"), "competitions").first, "details") where (p["scoringPlay"] as? Bool) == true {
                let who = a(p, "athletesInvolved").first.flatMap { s($0, "displayName") ?? s($0, "shortName") }
                out.append(SportsScoringPlay(
                    clock: s(o(p, "clock"), "displayValue") ?? "",
                    team: s(o(p, "team"), "abbreviation") ?? s(o(p, "team"), "displayName"),
                    text: [s(o(p, "type"), "text"), who].compactMap { $0 }.joined(separator: " · ").nilIfBlank ?? "Score",
                    awayScore: nil, homeScore: nil))
            }
        }
        return out
    }

    private static func list(_ object: JSON?, _ key: String) -> [JSON] { a(object, key) }

    // MARK: Team stats

    /// The stats worth a line, per sport (ESPN's names); others fill in up
    /// to six.
    private static func preferred(_ sport: Sport) -> [String] {
        switch sport {
        case .americanFootball: return ["totalYards", "netPassingYards", "rushingYards", "turnovers", "possessionTime", "thirdDownEff"]
        case .football: return ["possessionPct", "totalShots", "shotsOnTarget", "wonCorners", "foulsCommitted", "saves"]
        case .basketball: return ["fieldGoalPct", "threePointFieldGoalPct", "totalRebounds", "assists", "turnovers", "steals"]
        case .hockey: return ["shotsTotal", "powerPlayGoals", "hits", "blockedShots", "takeaways", "faceoffPercent"]
        case .baseball: return ["hits", "runs", "errors", "homeRuns", "strikeouts", "walks"]
        default: return []
        }
    }

    private static func stats(_ root: JSON, sport: Sport, homeId: String?) -> [SportsStatLine] {
        let teams = a(o(root, "boxscore"), "teams")
        guard teams.count == 2 else { return [] }
        func isHome(_ t: JSON) -> Bool { s(t, "homeAway") == "home" || (homeId != nil && s(o(t, "team"), "id") == homeId) }
        let homeIndex = teams.firstIndex(where: isHome) ?? 1
        let home = teams[homeIndex]
        let away = teams[homeIndex == 0 ? 1 : 0]
        func flat(_ t: JSON) -> (order: [String], values: [String: (label: String, value: String)]) {
            var order: [String] = []
            var values: [String: (label: String, value: String)] = [:]
            func add(_ x: JSON) {
                guard let name = s(x, "name"), let value = s(x, "displayValue"), values[name] == nil else { return }
                order.append(name)
                values[name] = (s(x, "label") ?? s(x, "displayName") ?? name, value)
            }
            for x in a(t, "statistics") {
                if let inner = x["stats"] as? [JSON] { inner.forEach(add) } else { add(x) }
            }
            return (order, values)
        }
        let h = flat(home)
        let w = flat(away)
        var keys = preferred(sport).filter { h.values[$0] != nil && w.values[$0] != nil }
        if keys.count < 4 {
            for key in h.order where w.values[key] != nil && !keys.contains(key) && keys.count < 6 { keys.append(key) }
        }
        return keys.prefix(6).compactMap { key in
            guard let hv = h.values[key], let av = w.values[key] else { return nil }
            return SportsStatLine(label: hv.label.uppercased(), away: av.value, home: hv.value,
                                  awayValue: number(av.value), homeValue: number(hv.value))
        }
    }

    // MARK: Leaders

    private static func performers(_ root: JSON) -> [SportsPerformer] {
        let byTeam: [[SportsPerformer]] = a(root, "leaders").map { t in
            let teamId = s(o(t, "team"), "id")
            var seen = Set<String>()
            var list: [SportsPerformer] = []
            for cat in a(t, "leaders") {
                guard let top = a(cat, "leaders").first, let athlete = o(top, "athlete"),
                      let name = s(athlete, "displayName") ?? s(athlete, "shortName") else { continue }
                let category = (s(cat, "shortDisplayName") ?? s(cat, "displayName") ?? s(cat, "name") ?? "").uppercased()
                    .replacingOccurrences(of: " YARDS", with: "").replacingOccurrences(of: "YARDS", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard seen.insert(category).inserted, list.count < 5 else { continue }
                list.append(SportsPerformer(
                    category: category, name: name, line: s(top, "displayValue") ?? "", teamId: teamId,
                    photo: s(o(athlete, "headshot"), "href"),
                    position: s(o(athlete, "position"), "abbreviation") ?? s(o(athlete, "position"), "displayName")))
            }
            return list
        }
        // Each kind both teams have, each team's leader in turn.
        var out: [SportsPerformer] = []
        var seen = Set<String>()
        for i in 0..<5 {
            for list in byTeam where i < list.count {
                if seen.insert(list[i].name + list[i].category).inserted { out.append(list[i]) }
            }
        }
        return out
    }

    // MARK: Form and meetings

    private static func form(_ root: JSON, _ nameOf: (String?, String?) -> String) -> [SportsFormRow] {
        var lists = a(root, "lastFiveGames")
        if lists.isEmpty { lists = a(o(root, "boxscore"), "form") }
        return lists.compactMap { t -> SportsFormRow? in
            let team = o(t, "team")
            let id = s(team, "id")
            let results = a(t, "events").compactMap { s($0, "gameResult").map { String($0.uppercased().prefix(1)) } }
            guard !results.isEmpty else { return nil }
            return SportsFormRow(teamId: id, team: nameOf(id, s(team, "displayName") ?? s(team, "shortDisplayName")),
                                 results: Array(results.prefix(5).reversed()))
        }.prefix(2).map { $0 }
    }

    private static func meetings(_ root: JSON, _ nameOf: (String?, String?) -> String) -> [SportsMeeting] {
        guard let t = a(root, "headToHeadGames").first else { return [] }
        let teamId = s(o(t, "team"), "id")
        let teamName = nameOf(teamId, s(o(t, "team"), "displayName"))
        return a(t, "events").compactMap { e -> SportsMeeting? in
            let opp = o(e, "opponent")
            let oppName = nameOf(s(opp, "id"), s(opp, "displayName") ?? s(opp, "abbreviation"))
            let text: String
            if let hs = s(e, "homeTeamScore"), let ascore = s(e, "awayTeamScore") {
                text = s(e, "homeTeamId") == teamId ? "\(teamName) \(hs)–\(ascore) \(oppName)" : "\(oppName) \(hs)–\(ascore) \(teamName)"
            } else if let score = s(e, "score") {
                text = "\(teamName) \(score) \(oppName)"
            } else {
                return nil
            }
            return SportsMeeting(date: SportsESPN.parseISO(s(e, "gameDate").map { String($0.prefix(16)) + "Z" }), text: text)
        }.prefix(3).map { $0 }
    }

    // MARK: Line-ups

    private static func lineups(_ root: JSON, _ nameOf: (String?, String?) -> String) -> [SportsLineup] {
        a(root, "rosters").compactMap { r -> SportsLineup? in
            let team = o(r, "team")
            let starters = a(r, "roster").filter { ($0["starter"] as? Bool) == true }.compactMap { p -> String? in
                guard let n = s(o(p, "athlete"), "shortName") ?? s(o(p, "athlete"), "displayName") else { return nil }
                return [s(p, "jersey"), n].compactMap { $0 }.joined(separator: " ")
            }
            guard starters.count >= 5 else { return nil }
            return SportsLineup(team: nameOf(s(team, "id"), s(team, "displayName")), teamId: s(team, "id"),
                                formation: s(r, "formation"), players: starters)
        }.prefix(2).map { $0 }
    }

    // MARK: Table

    /// The top three and the rows around this game's teams (a small group
    /// whole); two groups when the teams are in different ones.
    private static func table(_ root: JSON, into extras: inout SportsGameExtras, ids: Set<String>, teamNames: Set<String>) {
        guard let st = o(root, "standings") else { return }
        let groups = a(st, "groups")
        func entries(_ g: JSON) -> [JSON] { a(o(g, "standings"), "entries") }
        func isMine(_ en: JSON) -> Bool {
            if let id = s(en, "id"), ids.contains(id) { return true }
            if let name = s(en, "team") ?? s(o(en, "team"), "displayName") { return teamNames.contains(name) }
            return false
        }
        var mineGroups = Array(groups.filter { entries($0).contains(where: isMine) }.prefix(2))
        if mineGroups.isEmpty, let first = groups.first { mineGroups = [first] }
        guard !mineGroups.isEmpty, !mineGroups.allSatisfy({ entries($0).isEmpty }) else { return }
        func stat(_ en: JSON, _ names: String...) -> String? {
            let stats = a(en, "stats")
            for name in names {
                if let x = stats.first(where: { s($0, "name") == name || s($0, "type") == name }), let v = s(x, "displayValue") { return v }
            }
            return nil
        }
        let soccerLike = mineGroups.flatMap(entries).contains { stat($0, "points") != nil && stat($0, "gamesPlayed") != nil }
        let head = soccerLike ? ["P", "GD", "Pts"] : ["W", "L", "PCT"]
        func rows(_ g: JSON) -> [SportsTableRow] {
            entries(g).enumerated().map { i, en in
                let name = s(en, "team") ?? s(o(en, "team"), "displayName") ?? "?"
                let pos = stat(en, "rank", "position") ?? String(i + 1)
                return soccerLike
                    ? SportsTableRow(pos: pos, team: name, a: stat(en, "gamesPlayed") ?? "", b: stat(en, "pointDifferential", "differential") ?? "",
                                     c: stat(en, "points") ?? "", mine: isMine(en))
                    : SportsTableRow(pos: pos, team: name, a: stat(en, "wins") ?? "", b: stat(en, "losses") ?? "",
                                     c: stat(en, "winPercent", "leagueWinPercent") ?? "", mine: isMine(en))
            }
        }
        func cut(_ rows: [SportsTableRow], _ limit: Int) -> [SportsTableRow] {
            guard rows.count > limit else { return rows }
            var keep: Set<Int> = [0, 1, 2]
            for (i, row) in rows.enumerated() where row.mine { keep.formUnion([i - 1, i, i + 1]) }
            return Array(keep.filter { rows.indices.contains($0) }.sorted().map { rows[$0] }.prefix(limit))
        }
        let limit = mineGroups.count > 1 ? 5 : 8
        var slice: [SportsTableRow] = []
        for (gi, g) in mineGroups.enumerated() {
            var part = cut(rows(g), limit)
            if gi > 0, !part.isEmpty { part[0].group = s(g, "header") ?? s(g, "name") ?? "" }
            slice += part
        }
        guard !slice.isEmpty else { return }
        extras.tableTitle = s(mineGroups[0], "header") ?? s(st, "header")
        extras.tableHead = head
        extras.table = slice
    }

    // MARK: Info and chances

    private static func info(_ root: JSON, into extras: inout SportsGameExtras) {
        guard let gi = o(root, "gameInfo") else { return }
        let venue = o(gi, "venue")
        let address = o(venue, "address")
        let weather = o(gi, "weather")
        let refs = a(gi, "officials")
        let ref = refs.first { s(o($0, "position"), "name")?.lowercased() == "referee" }
            ?? refs.min { ((($0["order"] as? NSNumber)?.intValue) ?? 99) < ((($1["order"] as? NSNumber)?.intValue) ?? 99) }
        extras.venue = s(venue, "fullName")
        extras.city = [s(address, "city"), s(address, "state") ?? s(address, "country")].compactMap { $0 }
            .joined(separator: ", ").nilIfBlank
        extras.tempF = (weather?["temperature"] as? NSNumber)?.intValue
        extras.conditions = s(weather, "displayValue")
        extras.referee = ref.flatMap { s($0, "displayName") ?? s($0, "fullName") }
        if let attendance = (gi["attendance"] as? NSNumber)?.intValue, attendance > 0 { extras.attendance = attendance }
    }

    private static func odds(_ root: JSON, into extras: inout SportsGameExtras) {
        let probabilities = a(root, "winprobability")
        let history = probabilities.compactMap { ($0["homeWinPercentage"] as? NSNumber)?.doubleValue }
        extras.winHistory = history.count <= 60 ? history : (0..<60).map { history[$0 * (history.count - 1) / 59] }
        var home: Double?
        var away: Double?
        var draw: Double?
        if let p = o(root, "predictor") {
            home = s(o(p, "homeTeam"), "gameProjection").flatMap(Double.init)
            away = s(o(p, "awayTeam"), "gameProjection").flatMap(Double.init)
            draw = s(p, "tieProjection").flatMap(Double.init) ?? s(o(p, "homeTeam"), "tieProjection").flatMap(Double.init)
        }
        // During the game the latest probability wins over the prediction.
        if let last = probabilities.last, let h = (last["homeWinPercentage"] as? NSNumber)?.doubleValue {
            let t = ((last["tiePercentage"] as? NSNumber)?.doubleValue ?? 0) * 100
            home = h * 100
            draw = t > 0.5 ? t : nil
            away = max(0, 100 - h * 100 - t)
        }
        if draw == nil, let home, let away, 100 - home - away > 1 { draw = 100 - home - away }
        extras.homeWin = home
        extras.awayWin = away
        extras.draw = draw
    }
}
