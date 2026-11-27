import Foundation

/// A team's best player in one thing ("Goals", "Assists"), with a small
/// picture: ESPN's headshot when it has one, else the shirt number (and the
/// country's flag).
struct SportsTeamLeader: Codable, Hashable, Sendable {
    let category: String
    let name: String
    let value: String
    var headshot: String? = nil
    var jersey: String? = nil
    var flag: String? = nil
}

/// What a team's leaders list names before the player is asked for.
struct SportsLeaderPick: Hashable, Sendable {
    let category: String
    let value: String
    let athleteURL: URL
}

/// Fork (Live TV step 17d): what the Tables page and My Teams show of a
/// team besides its table line: its season (from its schedule), its top
/// players (ESPN's leaders; OpenLigaDB's goals for the 3. Liga), and the
/// countries football's leagues are sorted into.
enum SportsTeams {
    private typealias JSON = [String: Any]

    // MARK: Season and leaders (ESPN)

    /// The season a team's schedule is of: its year and type.
    static func scheduleSeason(_ data: Data) -> (year: Int, type: Int)? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              let season = (root["season"] as? JSON) ?? (root["requestedSeason"] as? JSON),
              let year = number(season["year"]) else { return nil }
        return (year, number(season["type"]) ?? 2)
    }

    /// ESPN's core API list of a team's leaders. Football's seasons have one
    /// type ("1") whatever the schedule calls it.
    static func leadersURL(_ league: League, teamID: String, year: Int, type: Int) -> URL? {
        guard let path = league.espnPath, let slash = path.firstIndex(of: "/") else { return nil }
        let sport = path[..<slash], name = path[path.index(after: slash)...]
        let kind = sport == "soccer" || type > 4 ? 1 : type
        return URL(string: "https://sports.core.api.espn.com/v2/sports/\(sport)/leagues/\(name)/seasons/\(year)/types/\(kind)/teams/\(teamID)/leaders")
    }

    /// The first `limit` kinds of leader (football: goals, assists), each
    /// with its best player; one kind once (ESPN lists goals twice).
    static func parseLeaders(_ data: Data, limit: Int = 2) -> [SportsLeaderPick] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return [] }
        var seen: Set<String> = []
        var picks: [SportsLeaderPick] = []
        for category in root["categories"] as? [JSON] ?? [] {
            guard picks.count < limit, let name = category["displayName"] as? String, !seen.contains(name),
                  let top = (category["leaders"] as? [JSON])?.first,
                  let ref = (top["athlete"] as? JSON)?["$ref"] as? String,
                  let url = URL(string: ref.replacingOccurrences(of: "http://", with: "https://")) else { continue }
            seen.insert(name)
            let value = (top["value"] as? Double) ?? (top["value"] as? Int).map(Double.init) ?? 0
            guard value > 0 else { continue }
            picks.append(SportsLeaderPick(category: name, value: format(value), athleteURL: url))
        }
        return picks
    }

    /// The pick with the player's name and picture.
    static func leader(_ pick: SportsLeaderPick, athlete data: Data) -> SportsTeamLeader? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              let name = (root["displayName"] as? String) ?? (root["fullName"] as? String) else { return nil }
        return SportsTeamLeader(
            category: pick.category, name: name, value: pick.value,
            headshot: (root["headshot"] as? JSON)?["href"] as? String,
            jersey: (root["jersey"] as? String)?.nilIfBlank,
            flag: (root["flag"] as? JSON)?["href"] as? String)
    }

    /// "5" for 5.0, "27.3" for 27.25.
    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func number(_ any: Any?) -> Int? {
        if let int = any as? Int { return int }
        if let double = any as? Double { return Int(double) }
        if let text = any as? String { return Int(text) }
        return nil
    }

    // MARK: Top scorers (OpenLigaDB)

    /// A team's top scorer from the season's goals (OpenLigaDB has no
    /// assists): own goals don't count, penalties do. Volunteers type the
    /// names: goals without one are left out, one player's spellings
    /// ("J. Potocnik", "Jaka Cuber Potocnik") count as one (same initial and
    /// surname, the longest name shown), and with so many names missing a
    /// lone goal tells nothing: two at least.
    static func openLigaScorers(team: String, goals: [[SportsScoringPlay]]) -> [SportsTeamLeader] {
        var count: [String: Int] = [:]
        var names: [String: String] = [:]
        for play in goals.joined() where play.team == team && !play.text.contains("(o.g.)") {
            let name = play.text.replacingOccurrences(of: " (pen.)", with: "").trimmingCharacters(in: .whitespaces)
            guard let key = scorerKey(name) else { continue }
            count[key, default: 0] += 1
            if name.count > (names[key]?.count ?? 0) { names[key] = name }
        }
        guard let best = count.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
              best.value >= 2, let name = names[best.key] else { return [] }
        return [SportsTeamLeader(category: "Goals", name: name, value: String(best.value))]
    }

    /// "j|potocnik" for "Jaka Cuber Potocnik", "J. Potocnik" and "Jaka
    /// Potocnik"; a single name stands for itself; no letters, nil.
    static func scorerKey(_ name: String) -> String? {
        let words = name.split { $0 == " " || $0 == "." }.map(String.init).filter { !$0.isEmpty }
        guard let last = words.last, last.contains(where: \.isLetter) else { return nil }
        let surname = last.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard words.count > 1, let initial = words.first?.first else { return surname }
        return String(initial).lowercased() + "|" + surname
    }

    // MARK: Football by country

    /// A football league's country or confederation: ESPN's code ("ger",
    /// "eng", "uefa"…); the 3. Liga is Germany's.
    static func footballArea(_ league: League) -> String {
        if league.onOpenLiga { return "ger" }
        guard let path = league.espnPath, path.hasPrefix("soccer/") else { return "other" }
        return String(path.dropFirst("soccer/".count).split(separator: ".").first ?? "other")
    }

    /// The name and flag of an area.
    static func areaName(_ code: String) -> (name: String, flag: String) {
        areas[code] ?? (code.uppercased(), "⚽️")
    }

    /// The areas in order: your country, the confederations, then the
    /// countries A to Z.
    static func orderedAreas(_ codes: Set<String>, country: String) -> [String] {
        let own = SportsCatalog.espnCountry[country.uppercased()]
        let international = ["uefa", "fifa", "conmebol", "concacaf", "afc", "caf", "club"]
        let first = own.map { codes.contains($0) ? [$0] : [] } ?? []
        let middle = international.filter { codes.contains($0) && $0 != own }
        let rest = codes.subtracting(first).subtracting(middle).sorted { areaName($0).name < areaName($1).name }
        return first + middle + rest
    }

    private static let areas: [String: (name: String, flag: String)] = [
        "uefa": ("Europe (UEFA)", "🇪🇺"), "fifa": ("World (FIFA)", "🌍"), "conmebol": ("South America (CONMEBOL)", "🌎"),
        "concacaf": ("North & Central America (Concacaf)", "🌎"), "afc": ("Asia (AFC)", "🌏"), "caf": ("Africa (CAF)", "🌍"),
        "club": ("Club Friendlies", "🤝"),
        "arg": ("Argentina", "🇦🇷"), "aus": ("Australia", "🇦🇺"), "aut": ("Austria", "🇦🇹"), "bel": ("Belgium", "🇧🇪"),
        "bol": ("Bolivia", "🇧🇴"), "bra": ("Brazil", "🇧🇷"), "can": ("Canada", "🇨🇦"), "chi": ("Chile", "🇨🇱"),
        "chn": ("China", "🇨🇳"), "col": ("Colombia", "🇨🇴"), "crc": ("Costa Rica", "🇨🇷"), "den": ("Denmark", "🇩🇰"),
        "ecu": ("Ecuador", "🇪🇨"), "eng": ("England", "🏴󠁧󠁢󠁥󠁮󠁧󠁿"), "esp": ("Spain", "🇪🇸"), "fra": ("France", "🇫🇷"),
        "ger": ("Germany", "🇩🇪"), "gre": ("Greece", "🇬🇷"), "gua": ("Guatemala", "🇬🇹"), "hon": ("Honduras", "🇭🇳"),
        "ind": ("India", "🇮🇳"), "ita": ("Italy", "🇮🇹"), "jpn": ("Japan", "🇯🇵"), "ksa": ("Saudi Arabia", "🇸🇦"),
        "mex": ("Mexico", "🇲🇽"), "ned": ("Netherlands", "🇳🇱"), "nor": ("Norway", "🇳🇴"), "par": ("Paraguay", "🇵🇾"),
        "per": ("Peru", "🇵🇪"), "por": ("Portugal", "🇵🇹"), "rsa": ("South Africa", "🇿🇦"), "rus": ("Russia", "🇷🇺"),
        "sco": ("Scotland", "🏴󠁧󠁢󠁳󠁣󠁴󠁿"), "slv": ("El Salvador", "🇸🇻"), "swe": ("Sweden", "🇸🇪"), "tur": ("Türkiye", "🇹🇷"),
        "uru": ("Uruguay", "🇺🇾"), "usa": ("United States", "🇺🇸"), "ven": ("Venezuela", "🇻🇪"),
        "sui": ("Switzerland", "🇨🇭"), "pol": ("Poland", "🇵🇱"), "cze": ("Czechia", "🇨🇿"), "irl": ("Ireland", "🇮🇪"),
    ]
}
