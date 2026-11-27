import Foundation

/// Fork (Live TV step 17): the Sports page, as Android's (NuvioPlusIPTV's
/// livetv/sports). The sports everything is sorted into.
enum Sport: String, CaseIterable, Codable, Sendable {
    case americanFootball, basketball, hockey, baseball, football, rugby, fighting, racing, golf, tennis, cricket,
         darts, snooker, wrestling, aussieRules, volleyball, lacrosse, gaelic, netball, handball, other

    var label: String {
        switch self {
        case .americanFootball: return "American Football"
        case .basketball: return "Basketball"
        case .hockey: return "Hockey"
        case .baseball: return "Baseball"
        case .football: return "Football"
        case .rugby: return "Rugby"
        case .fighting: return "Fighting"
        case .racing: return "Racing"
        case .golf: return "Golf"
        case .tennis: return "Tennis"
        case .cricket: return "Cricket"
        case .darts: return "Darts"
        case .snooker: return "Snooker"
        case .wrestling: return "Wrestling"
        case .aussieRules: return "Aussie Rules"
        case .volleyball: return "Volleyball"
        case .lacrosse: return "Lacrosse"
        case .gaelic: return "Gaelic Games"
        case .netball: return "Netball"
        case .handball: return "Handball"
        case .other: return "More Sports"
        }
    }

    var icon: String {
        switch self {
        case .americanFootball: return "🏈"
        case .basketball: return "🏀"
        case .hockey: return "🏒"
        case .baseball: return "⚾"
        case .football: return "⚽"
        case .rugby, .aussieRules: return "🏉"
        case .fighting: return "🥊"
        case .racing: return "🏁"
        case .golf: return "⛳"
        case .tennis: return "🎾"
        case .cricket: return "🏏"
        case .darts: return "🎯"
        case .snooker: return "🎱"
        case .wrestling: return "💪"
        case .volleyball: return "🏐"
        case .lacrosse: return "🥍"
        case .gaelic: return "☘️"
        case .netball, .handball: return "🤾"
        case .other: return "🏅"
        }
    }

    /// Home team first with "v" (UK style) instead of away team first
    /// with "at" (US style).
    var homeFirst: Bool { [.football, .rugby, .cricket, .aussieRules, .handball].contains(self) }
}

/// Two teams, or one event with many competitors (a race, a fight card).
enum LeagueKind: String, Codable, Sendable { case teams, event }

/// One competition the Sports page knows. `espnPath`: its ESPN feed
/// ("football/nfl"), nil for one found only in the guide; `regions`: where
/// it's shown by default ("US", "UK", "IE", "CA", "AU", "OTHER").
struct League: Identifiable, Hashable, Sendable {
    let id: String
    let sport: Sport
    let name: String
    let short: String
    var espnPath: String? = nil
    var kind: LeagueKind = .teams
    var guideWords: [String] = []
    var regions: Set<String> = League.allRegions
    /// Usual length in minutes, for the time bar.
    var minutes: Int = 180
    var schoolNames: Bool = false
    /// Extra ESPN query (college: every game, not only the ranked ones).
    var espnQuery: String = ""
    var guideOnly: Bool = false
    var fixtureSlug: String? = nil
    /// The league tag's colour (0xAARRGGBB).
    var color: UInt32 = 0xFF2A2F3A
    var liveByDefault: Bool = false
    var national: Bool = false
    var women: Bool = false

    static let allRegions: Set<String> = ["US", "UK", "IE", "CA", "AU", "OTHER"]

    /// OpenLigaDB has it (German football ESPN lacks: the 3. Liga).
    var onOpenLiga: Bool { id.hasPrefix("openligadb/") }

    /// Its games can be asked for (ESPN or OpenLigaDB).
    var hasFeed: Bool { onESPN || onOpenLiga }

    /// ESPN's scoreboard has it (the other feeds come later).
    var onESPN: Bool {
        guard let path = espnPath else { return false }
        return !path.hasPrefix("hockeytech/") && !path.hasPrefix("milb/") && path != "cricket/panel"
    }
}

/// A team (or athlete) as the feed describes it.
struct TeamInfo: Codable, Hashable, Sendable {
    let leagueId: String
    let id: String
    let name: String
    let fullName: String
    let abbr: String
    var location: String?
    var color: UInt32?
    var altColor: UInt32?
    var logo: String?
    var record: String?

    var key: String { leagueId + ":" + id }
}

/// One side of a game: who, and the score when there is one.
struct SportsSide: Codable, Hashable, Sendable {
    var team: TeamInfo
    var score: String?
    var record: String?
    var winner: Bool
    var home: Bool
    /// Score per quarter, period, inning or half.
    var periods: [String] = []
}

enum GameState: String, Codable, Sendable { case pre, live, post, off }

/// One line of a race result or leaderboard.
struct SportsStanding: Codable, Hashable, Sendable {
    let pos: String
    let name: String
    let detail: String?
}

struct SportsEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let leagueId: String
    let start: Date
    /// False for events with a date only (no start time).
    var hasTime: Bool
    var state: GameState
    var title: String
    var subtitle: String?
    /// "3rd · 4:12", "72'", "Final", "Halftime"… (the start time is shown
    /// from `start`).
    var status: String?
    var away: SportsSide?
    var home: SportsSide?
    /// Best first: national channels, then the home team's, then the
    /// away team's, apps last.
    var broadcasts: [String] = []
    /// "DET ball · 2nd & 7 at CHI 38".
    var situation: String?
    /// How far through the game (0…1), from the clock.
    var progress: Double?
    var espnId: String?
    /// "Until Sun 30 Nov" for a tournament.
    var note: String?
    var end: Date?
    var standings: [SportsStanding] = []

    var sides: [SportsSide] { [away, home].compactMap { $0 } }

    var hasScore: Bool {
        (state == .live || state == .post) && sides.count == 2
            && sides.allSatisfy { !($0.score ?? "").isEmpty }
    }

    /// The two sides in the order people say them: "Bears at Lions",
    /// "Liverpool v Man City".
    func ordered(_ sport: Sport) -> [SportsSide] {
        sport.homeFirst ? [home, away].compactMap { $0 } : [away, home].compactMap { $0 }
    }
}

/// Saved games can outlive the moment they were saved: a game saved at
/// halftime keeps saying "live". The clock spots such copies (as Android's
/// SportsStale).
enum SportsStale {
    private static let hour: TimeInterval = 3600

    /// The longest a game of this sport can stay live from its start.
    static func maxLive(_ sport: Sport?) -> TimeInterval {
        switch sport {
        case .cricket: return 6 * 24 * hour
        case .americanFootball: return 7 * hour
        case .baseball: return 9 * hour
        case .basketball, .hockey: return 6 * hour
        case .football, .rugby, .handball: return 5 * hour
        default: return 12 * hour
        }
    }

    static func isStaleLive(_ event: SportsEvent, sport: Sport?, now: Date) -> Bool {
        guard event.state == .live, event.hasTime else { return false }
        if let end = event.end { return now > end.addingTimeInterval(3 * hour) }
        guard event.sides.count == 2 else { return false }
        return now.timeIntervalSince(event.start) > maxLive(sport)
    }

    static func isStalePre(_ event: SportsEvent, now: Date) -> Bool {
        event.state == .pre && event.hasTime && event.sides.count == 2 && now.timeIntervalSince(event.start) > 6 * hour
    }

    /// The game as it can honestly be shown now: a stale live game is over
    /// (its last saved score may be a halftime score, so none is shown).
    static func fix(_ event: SportsEvent, sport: Sport?, now: Date) -> SportsEvent {
        guard isStaleLive(event, sport: sport, now: now) else { return event }
        var event = event
        event.state = .post
        event.status = "Ended"
        event.progress = nil
        event.situation = nil
        event.away?.score = nil
        event.away?.winner = false
        event.home?.score = nil
        event.home?.winner = false
        return event
    }
}
