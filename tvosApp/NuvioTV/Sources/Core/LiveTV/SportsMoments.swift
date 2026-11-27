import Foundation

// Fork (Live TV step 17d): what happened in a game at a glance (goals,
// cards, substitutions, scores per sport), the line-ups as a picture, and
// the betting odds; all from ESPN's summary and scoreboard, every part
// optional.

/// The betting odds of a game, as decimals (2.10); US money lines are
/// turned into decimals and back for the US and Canada.
struct SportsOdds: Codable, Hashable, Sendable {
    var provider: String?
    var home: Double?
    var draw: Double?
    var away: Double?
    /// Over/under on the total ("2.5" goals, "48.5" points).
    var overUnder: Double?

    var isEmpty: Bool { home == nil && away == nil }

    /// "+150" or "-180" as a decimal (2.50, 1.56).
    static func decimal(american text: String?) -> Double? {
        guard let text, let value = Double(text.replacingOccurrences(of: "+", with: "")), value != 0 else { return nil }
        return value > 0 ? 1 + value / 100 : 1 + 100 / -value
    }

    /// 2.5 as "+150", 1.56 as "-179".
    static func american(_ decimal: Double) -> String {
        guard decimal > 1 else { return "–" }
        if decimal >= 2 { return "+" + String(Int(((decimal - 1) * 100).rounded())) }
        return "-" + String(Int((100 / (decimal - 1)).rounded()))
    }

    /// "2.10" in the locale's way ("2,10"), or "+110".
    static func text(_ decimal: Double?, us: Bool) -> String {
        guard let decimal else { return "–" }
        if us { return american(decimal) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: decimal)) ?? String(format: "%.2f", decimal)
    }

    /// The first provider with odds in a scoreboard's or summary's list:
    /// decimals (Bet 365) or money lines (DraftKings).
    static func parse(_ list: [[String: Any]]) -> SportsOdds? {
        for item in list {
            func object(_ any: Any?) -> [String: Any]? { any as? [String: Any] }
            func number(_ any: Any?) -> Double? {
                if let value = any as? Double { return value }
                if let value = any as? Int { return Double(value) }
                return (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init)
            }
            func line(_ side: String) -> Double? {
                let money = object(object(item["moneyline"])?[side])
                let text = (object(money?["close"])?["odds"] ?? object(money?["open"])?["odds"]).map { "\($0)" }
                return decimal(american: text)
            }
            var odds = SportsOdds(provider: (object(item["provider"])?["displayName"] ?? object(item["provider"])?["name"]) as? String)
            odds.home = number(object(item["homeTeamOdds"])?["value"]) ?? line("home")
                ?? decimal(american: (object(item["homeTeamOdds"])?["moneyLine"]).map { "\($0)" })
            odds.away = number(object(item["awayTeamOdds"])?["value"]) ?? line("away")
                ?? decimal(american: (object(item["awayTeamOdds"])?["moneyLine"]).map { "\($0)" })
            odds.draw = number(object(item["drawOdds"])?["value"]) ?? line("draw")
                ?? decimal(american: (object(item["drawOdds"])?["moneyLine"]).map { "\($0)" })
            odds.overUnder = number(item["overUnder"])
            if !odds.isEmpty { return odds }
        }
        return nil
    }
}

/// One thing that happened: a goal, a card, a substitution, a score.
struct SportsMoment: Hashable, Sendable {
    enum Kind: String, Sendable {
        case goal, ownGoal, penaltyGoal, penaltyMiss, yellow, red, yellowRed, sub, score, penalty
    }

    let kind: Kind
    /// "38'", "90'+2'", "4:12".
    let clock: String
    /// Half, period, quarter or inning (1…); 0 when unknown.
    let period: Int
    /// The home team's (true), the away team's (false), unknown (nil).
    let home: Bool?
    /// Who: the scorer, the player booked, the one coming on.
    let player: String?
    /// The assist, the player going off, "TD", "PPG", "2 min".
    let detail: String?
    /// The score after it, home first ("1–2").
    var score: String?

    var isGoal: Bool { [.goal, .ownGoal, .penaltyGoal].contains(kind) }
}

/// A player of a line-up: where he plays and what he did.
struct SportsLineupPlayer: Hashable, Sendable {
    let name: String
    let shortName: String
    let jersey: String?
    /// ESPN's position ("G", "CD-L", "RB", "AM-R", "F"; "PG", "C").
    let position: String?
    let formationPlace: Int
    let starter: Bool
    var goals = 0
    var yellow = false
    var red = false
    /// Minute he went off or came on.
    var subbedOff: String?
    var subbedOn: String?
    var photo: String?
}

enum SportsMoments {
    private typealias JSON = [String: Any]

    private static func s(_ object: JSON?, _ key: String) -> String? {
        guard let value = object?[key] else { return nil }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func o(_ object: JSON?, _ key: String) -> JSON? { object?[key] as? JSON }
    private static func a(_ object: JSON?, _ key: String) -> [JSON] { object?[key] as? [JSON] ?? [] }
    private static func period(_ p: JSON) -> Int { (o(p, "period")?["number"] as? NSNumber)?.intValue ?? 0 }

    // MARK: Timeline

    /// The game's moments, oldest first. Football and rugby: ESPN's key
    /// events (goals with their assists, cards, substitutions); the others:
    /// the scoring plays (and hockey's penalties). The score after each goal
    /// is counted, and dropped again if it doesn't end on the final score.
    static func parse(_ data: Data, sport: Sport, homeId: String?, finalHome: String?, finalAway: String?) -> [SportsMoment] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return [] }
        return parse(root, sport: sport, homeId: homeId, finalHome: finalHome, finalAway: finalAway)
    }

    static func parse(_ root: [String: Any], sport: Sport, homeId: String?, finalHome: String?, finalAway: String?) -> [SportsMoment] {
        func side(_ p: JSON) -> Bool? {
            guard let id = s(o(p, "team"), "id"), let homeId else { return nil }
            return id == homeId
        }
        var out: [SportsMoment] = []
        let keyEvents = a(root, "keyEvents")
        if sport == .football || sport == .rugby, !keyEvents.isEmpty {
            for p in keyEvents {
                let slug = (s(o(p, "type"), "type") ?? s(o(p, "type"), "text") ?? "").lowercased().replacingOccurrences(of: " ", with: "-")
                let people = a(p, "participants").compactMap { s(o($0, "athlete"), "displayName") }
                let kind: SportsMoment.Kind
                var detail = people.count > 1 ? people[1] : nil
                if slug.contains("own-goal") {
                    kind = .ownGoal
                } else if slug.hasPrefix("penalty"), slug.contains("miss") || slug.contains("saved") {
                    kind = .penaltyMiss
                } else if slug.hasPrefix("penalty"), slug.contains("scored") {
                    kind = .penaltyGoal
                } else if slug.hasPrefix("goal") {
                    kind = .goal
                } else if slug.contains("yellow-red") || slug.contains("second-yellow") {
                    kind = .yellowRed
                } else if slug.contains("yellow") {
                    kind = .yellow
                } else if slug.contains("red-card") {
                    kind = .red
                } else if slug.contains("substitution") {
                    kind = .sub
                } else if sport == .rugby, let label = rugbyLabel(slug) {
                    kind = .score
                    detail = label
                } else {
                    continue
                }
                if [.yellow, .red, .yellowRed].contains(kind) { detail = nil }
                out.append(SportsMoment(kind: kind, clock: s(o(p, "clock"), "displayValue") ?? "", period: period(p),
                                        home: side(p), player: people.first, detail: detail))
            }
            if sport == .football { countGoals(&out, finalHome: finalHome, finalAway: finalAway) }
            return out
        }
        for p in a(root, "scoringPlays") {
            let tag = s(o(p, "scoringType"), "abbreviation") ?? s(o(p, "type"), "abbreviation")
            let home = s(p, "homeScore"), away = s(p, "awayScore")
            out.append(SportsMoment(kind: .score, clock: s(o(p, "clock"), "displayValue") ?? "", period: period(p),
                                    home: side(p), player: s(p, "text"), detail: tag,
                                    score: home.flatMap { h in away.map { "\(h)–\($0)" } }))
        }
        let plays = a(root, "plays")
        if out.isEmpty {
            for p in plays where (p["scoringPlay"] as? Bool) == true {
                let home = s(p, "homeScore"), away = s(p, "awayScore")
                out.append(SportsMoment(kind: .score, clock: s(o(p, "clock"), "displayValue") ?? "", period: period(p),
                                        home: side(p), player: s(p, "text"), detail: nil,
                                        score: home.flatMap { h in away.map { "\(h)–\($0)" } }))
            }
        }
        if sport == .hockey {
            for p in plays where (s(o(p, "type"), "text") ?? "").lowercased() == "penalty" {
                out.append(SportsMoment(kind: .penalty, clock: s(o(p, "clock"), "displayValue") ?? "", period: period(p),
                                        home: side(p), player: s(p, "text"), detail: nil))
            }
            out.sort { ($0.period, minutes($0.clock, countdown: true)) < ($1.period, minutes($1.clock, countdown: true)) }
        }
        return out
    }

    private static func rugbyLabel(_ slug: String) -> String? {
        if slug.contains("try") { return "Try" }
        if slug.contains("conversion") { return "Conversion" }
        if slug.contains("drop") { return "Drop Goal" }
        if slug.contains("penalty") { return "Penalty" }
        return nil
    }

    /// The clock as minutes for sorting ("4:12" counts down in hockey).
    private static func minutes(_ clock: String, countdown: Bool) -> Double {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return 0 }
        let value = parts[0] + parts[1] / 60
        return countdown ? 20 - value : value
    }

    /// The score after each goal ("1–0"); none at all when the count
    /// doesn't end on the final score (an own goal booked the other way).
    static func countGoals(_ moments: inout [SportsMoment], finalHome: String?, finalAway: String?) {
        var home = 0, away = 0
        for index in moments.indices where moments[index].isGoal {
            guard let side = moments[index].home, moments[index].period < 5 else { continue }
            if side { home += 1 } else { away += 1 }
            moments[index].score = "\(home)–\(away)"
        }
        let finalH = finalHome.flatMap { Int($0) }, finalA = finalAway.flatMap { Int($0) }
        if let finalH, let finalA, finalH != home || finalA != away {
            for index in moments.indices { moments[index].score = nil }
        }
    }

    // MARK: Line-ups

    /// Each team's players (starters and bench, with goals, cards and
    /// substitutions), from the summary's rosters (football) or box score
    /// (basketball, hockey…), by team id.
    static func lineups(_ root: [String: Any]) -> [String: (formation: String?, players: [SportsLineupPlayer])] {
        var out: [String: (formation: String?, players: [SportsLineupPlayer])] = [:]
        for r in a(root, "rosters") {
            guard let id = s(o(r, "team"), "id") else { continue }
            let players = a(r, "roster").compactMap { p -> SportsLineupPlayer? in
                let athlete = o(p, "athlete")
                guard let name = s(athlete, "displayName") ?? s(athlete, "shortName") else { return nil }
                var player = SportsLineupPlayer(
                    name: name, shortName: s(athlete, "shortName") ?? name, jersey: s(p, "jersey") ?? s(athlete, "jersey"),
                    position: s(o(p, "position"), "abbreviation"), formationPlace: Int(s(p, "formationPlace") ?? "") ?? 0,
                    starter: (p["starter"] as? Bool) == true, photo: s(o(athlete, "headshot"), "href"))
                for play in a(p, "plays") {
                    let clock = s(o(play, "clock"), "displayValue")
                    if (play["didScore"] as? Bool) == true, (play["ownGoal"] as? Bool) != true { player.goals += 1 }
                    if (play["yellowCard"] as? Bool) == true { player.yellow = true }
                    if (play["redCard"] as? Bool) == true { player.red = true }
                    if (play["substitution"] as? Bool) == true {
                        if (p["subbedIn"] as? Bool) == true { player.subbedOn = clock } else { player.subbedOff = clock }
                    }
                }
                return player
            }
            if !players.isEmpty { out[id] = (s(r, "formation"), players) }
        }
        guard out.isEmpty else { return out }
        // Basketball, hockey and the rest: the box score's players.
        for t in a(o(root, "boxscore"), "players") {
            guard let id = s(o(t, "team"), "id") else { continue }
            var seen: Set<String> = []
            var players: [SportsLineupPlayer] = []
            for group in a(t, "statistics") {
                for p in a(group, "athletes") {
                    let athlete = o(p, "athlete")
                    guard let name = s(athlete, "displayName"), seen.insert(name).inserted else { continue }
                    players.append(SportsLineupPlayer(
                        name: name, shortName: s(athlete, "shortName") ?? name, jersey: s(athlete, "jersey"),
                        position: s(o(athlete, "position"), "abbreviation"), formationPlace: 0,
                        starter: (p["starter"] as? Bool) == true, photo: s(o(athlete, "headshot"), "href")))
                }
            }
            if !players.isEmpty { out[id] = (nil, players) }
        }
        return out
    }

    /// How far back a football position plays (0 the back line) and where
    /// across: -2 the left flank (LB), -1 left of centre (CD-L), 0 the
    /// middle, 1 and 2 to the right.
    static func footballSpot(_ position: String?) -> (depth: Double, side: Int)? {
        guard let raw = position?.uppercased(), !raw.isEmpty, raw != "SUB" else { return nil }
        let parts = raw.split(separator: "-").map(String.init)
        let base = parts[0]
        var side = 0
        if parts.count > 1 { side = parts[1] == "L" ? -1 : (parts[1] == "R" ? 1 : 0) }
        if side == 0, ["LCB", "LF"].contains(base) { side = -1 }
        if side == 0, ["RCB", "RF"].contains(base) { side = 1 }
        if side == 0, ["LB", "LM", "LW", "LWB"].contains(base) { side = -2 }
        if side == 0, ["RB", "RM", "RW", "RWB"].contains(base) { side = 2 }
        let depth: Double
        switch base {
        case "G", "GK": return (-1, 0)
        case "CD", "CB", "LB", "RB", "SW", "D", "LCB", "RCB": depth = 0
        case "LWB", "RWB", "WB": depth = 1.5
        case "DM", "CDM": depth = 1
        case "CM", "M", "LM", "RM": depth = 2
        case "AM", "CAM": depth = 3
        case "LW", "RW", "W": depth = 3.5
        case "F", "CF", "ST", "S", "LF", "RF": depth = 4
        default: return nil
        }
        return (depth, side)
    }

    /// Football starters in rows from the goalkeeper forward, each row left
    /// to right; the formation's numbers ("4-2-3-1") cut the rows when they
    /// add up, else positions alike share a row. Nil when the positions
    /// can't place eleven players (the list is shown instead).
    static func pitchRows(_ starters: [SportsLineupPlayer], formation: String?) -> [[SportsLineupPlayer]]? {
        guard starters.count >= 7 else { return nil }
        var keeper: [SportsLineupPlayer] = []
        var field: [(player: SportsLineupPlayer, depth: Double, side: Int)] = []
        for player in starters {
            guard let spot = footballSpot(player.position) else { return nil }
            if spot.depth < 0 { keeper.append(player) } else { field.append((player, spot.depth, spot.side)) }
        }
        guard keeper.count == 1 else { return nil }
        field.sort { ($0.depth, $0.side, $0.player.formationPlace) < ($1.depth, $1.side, $1.player.formationPlace) }
        let counts = (formation ?? "").split(separator: "-").compactMap { Int($0) }
        var rows: [[(player: SportsLineupPlayer, depth: Double, side: Int)]] = []
        if !counts.isEmpty, counts.reduce(0, +) == field.count {
            var start = 0
            for count in counts {
                rows.append(Array(field[start..<start + count]))
                start += count
            }
        } else {
            for item in field {
                if let last = rows.last?.last, abs(last.depth - item.depth) < 0.6 { rows[rows.count - 1].append(item) } else { rows.append([item]) }
            }
        }
        return [keeper] + rows.map { row in row.sorted { ($0.side, $0.player.formationPlace) < ($1.side, $1.player.formationPlace) }.map(\.player) }
    }

    /// Other sports' starters by position, front to back as they're read:
    /// basketball guards, forwards, centre; hockey forwards, defence, goalie.
    static func groupRows(_ starters: [SportsLineupPlayer], sport: Sport) -> [[SportsLineupPlayer]] {
        func rank(_ position: String?) -> Int {
            let p = (position ?? "").uppercased()
            switch sport {
            case .basketball:
                if p.contains("C") && !p.contains("G") { return 2 }
                if p.contains("F") { return 1 }
                return 0
            case .hockey:
                if p == "G" { return 2 }
                if p == "D" { return 1 }
                return 0
            default:
                return 0
            }
        }
        let grouped = Dictionary(grouping: starters) { rank($0.position) }
        return grouped.keys.sorted().compactMap { grouped[$0] }
    }
}
