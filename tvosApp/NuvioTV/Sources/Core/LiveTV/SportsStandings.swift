import Foundation

/// Fork (Live TV step 17d): league tables, as Android's SportsStandings:
/// ESPN's `apis/v2/sports/{path}/standings` (divisions for the NFL, NBA,
/// NHL and MLB), or OpenLigaDB's table.
struct SportsStandingsColumn: Hashable, Sendable {
    let key: String
    let label: String
}

/// What a place in the table leads to (Champions League, relegation…).
struct SportsStandingsZone: Hashable, Sendable {
    let label: String
    let color: UInt32
}

struct SportsStandingsRow: Hashable, Sendable {
    let id: String
    let name: String
    let shortName: String
    let logo: String?
    let pos: Int
    /// Column key -> what to show.
    let values: [String: String]
    var zone: SportsStandingsZone? = nil
}

struct SportsStandingsGroup: Hashable, Sendable {
    let name: String
    let rows: [SportsStandingsRow]
}

struct SportsStandings: Sendable {
    enum Kind: String, Sendable { case table, record, hockey, racing }

    let leagueId: String
    let kind: Kind
    let columns: [SportsStandingsColumn]
    let groups: [SportsStandingsGroup]

    static let tableColumns = [
        SportsStandingsColumn(key: "gamesPlayed", label: "P"), SportsStandingsColumn(key: "wins", label: "W"),
        SportsStandingsColumn(key: "ties", label: "D"), SportsStandingsColumn(key: "losses", label: "L"),
        SportsStandingsColumn(key: "goals", label: "GOALS"),
        SportsStandingsColumn(key: "pointDifferential", label: "GD"), SportsStandingsColumn(key: "points", label: "PTS"),
    ]

    /// A team's group and row.
    func find(_ teamID: String) -> (group: SportsStandingsGroup, row: SportsStandingsRow)? {
        for group in groups {
            if let row = group.rows.first(where: { $0.id == teamID }) { return (group, row) }
        }
        return nil
    }

    /// "2nd in Bundesliga".
    func placeText(_ teamID: String) -> String? {
        guard let found = find(teamID) else { return nil }
        return Self.ordinal(found.row.pos) + " · " + found.group.name
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    static func espnURL(_ league: League) -> URL? {
        guard let path = league.espnPath else { return nil }
        let divisions = ["football/nfl", "basketball/nba", "hockey/nhl", "baseball/mlb"].contains(path)
        return URL(string: "https://site.api.espn.com/apis/v2/sports/\(path)/standings" + (divisions ? "?level=3" : ""))
    }

    private typealias JSON = [String: Any]

    private static func s(_ object: JSON?, _ key: String) -> String? {
        guard let value = object?[key] else { return nil }
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty, text != "null" else { return nil }
        return text
    }

    static func parseESPN(_ league: League, data: Data) -> SportsStandings? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
        var leaves: [(name: String, node: JSON)] = []
        func walk(_ node: JSON) {
            if let entries = (node["standings"] as? JSON)?["entries"] as? [JSON], !entries.isEmpty {
                leaves.append((s(node, "name") ?? s(node, "abbreviation") ?? league.name, node))
            }
            for child in node["children"] as? [JSON] ?? [] { walk(child) }
        }
        walk(root)
        guard let first = leaves.first else { return nil }
        let firstEntry = ((first.node["standings"] as? JSON)?["entries"] as? [JSON])?.first
        let athletes = firstEntry?["athlete"] != nil
        let used = athletes ? [first] : leaves
        var statNames = Set<String>()
        for leaf in used {
            for stat in (((leaf.node["standings"] as? JSON)?["entries"] as? [JSON])?.first?["stats"] as? [JSON]) ?? [] {
                if let name = s(stat, "name") { statNames.insert(name) }
            }
        }
        let kind: Kind
        if athletes {
            kind = .racing
        } else if statNames.contains("otLosses") {
            kind = .hockey
        } else if league.sport == .football || (statNames.contains("points") && statNames.contains("ties") && !statNames.contains("winPercent")) {
            kind = .table
        } else {
            kind = .record
        }
        let groups = used.map { leaf in
            SportsStandingsGroup(name: leaf.name, rows: rows(((leaf.node["standings"] as? JSON)?["entries"] as? [JSON]) ?? [], kind: kind))
        }
        let columns: [SportsStandingsColumn]
        switch kind {
        case .table: columns = tableColumns
        case .hockey:
            columns = [("gamesPlayed", "GP"), ("wins", "W"), ("losses", "L"), ("otLosses", "OTL"), ("points", "PTS"), ("streak", "STRK")]
                .map { SportsStandingsColumn(key: $0.0, label: $0.1) }
        case .racing:
            columns = [SportsStandingsColumn(key: "points", label: "PTS")]
        case .record:
            columns = [("wins", "W"), ("losses", "L"), ("winPercent", "PCT"), ("gamesBehind", "GB"), ("streak", "STRK")]
                .map { SportsStandingsColumn(key: $0.0, label: $0.1) }
        }
        // Only columns the feed filled in.
        let filled = columns.filter { column in groups.contains { $0.rows.contains { !($0.values[column.key] ?? "").isEmpty } } }
        return SportsStandings(leagueId: league.id, kind: kind, columns: filled, groups: groups)
    }

    private static func rows(_ entries: [JSON], kind: Kind) -> [SportsStandingsRow] {
        let rows: [SportsStandingsRow] = entries.compactMap { entry in
            let who = (entry["team"] as? JSON) ?? (entry["athlete"] as? JSON)
            guard let who, let id = s(who, "id"), let name = s(who, "displayName") ?? s(who, "name") else { return nil }
            var values: [String: String] = [:]
            var rank = 0
            for stat in entry["stats"] as? [JSON] ?? [] {
                guard let key = s(stat, "name") else { continue }
                if key == "rank", let n = (stat["value"] as? NSNumber)?.intValue { rank = n }
                if values[key] == nil, let shown = s(stat, "displayValue")?.trimmingCharacters(in: .whitespaces) { values[key] = shown }
            }
            if kind == .racing, let points = values["championshipPts"] { values["points"] = points }
            if values["goals"] == nil, let pf = values["pointsFor"], let pa = values["pointsAgainst"] { values["goals"] = "\(pf):\(pa)" }
            if values["gamesBehind"] == "-" { values["gamesBehind"] = "–" }
            let note = entry["note"] as? JSON
            let zone = s(note, "description").map { description in
                SportsStandingsZone(label: description, color: SportsESPN.hexColor(s(note, "color")) ?? 0xFF4A90D9)
            }
            let logo = s((who["logos"] as? [JSON])?.first, "href") ?? s(who["flag"] as? JSON, "href")
            return SportsStandingsRow(id: id, name: name, shortName: s(who, "shortDisplayName") ?? s(who, "shortName") ?? name,
                                      logo: logo, pos: rank, values: values, zone: zone)
        }
        let ranked = rows.allSatisfy { $0.pos > 0 } ? rows.sorted { $0.pos < $1.pos } : rows
        return ranked.enumerated().map { index, row in
            row.pos > 0 ? row : SportsStandingsRow(id: row.id, name: row.name, shortName: row.shortName, logo: row.logo,
                                                   pos: index + 1, values: row.values, zone: row.zone)
        }
    }

    /// The top three and the rows around this game's teams, for a game's
    /// page (as Android's mini table).
    func around(_ teamIDs: Set<String>) -> (title: String?, head: [String], rows: [SportsTableRow]) {
        let mine = groups.filter { $0.rows.contains { teamIDs.contains($0.id) } }
        let used = Array((mine.isEmpty ? Array(groups.prefix(1)) : mine).prefix(2))
        let limit = used.count > 1 ? 5 : 8
        let soccer = kind == .table
        var result: [SportsTableRow] = []
        for (gi, group) in used.enumerated() {
            var keep: Set<Int> = [0, 1, 2]
            for (i, row) in group.rows.enumerated() where teamIDs.contains(row.id) { keep.formUnion([i - 1, i, i + 1]) }
            let picked = group.rows.count <= limit ? group.rows
                : Array(keep.filter { group.rows.indices.contains($0) }.sorted().map { group.rows[$0] }.prefix(limit))
            for (i, row) in picked.enumerated() {
                var line = soccer
                    ? SportsTableRow(pos: String(row.pos), team: row.name, a: row.values["gamesPlayed"] ?? "",
                                     b: row.values["pointDifferential"] ?? "", c: row.values["points"] ?? "", mine: teamIDs.contains(row.id))
                    : SportsTableRow(pos: String(row.pos), team: row.name, a: row.values["wins"] ?? "",
                                     b: row.values["losses"] ?? "", c: row.values["winPercent"] ?? "", mine: teamIDs.contains(row.id))
                if gi > 0, i == 0 { line.group = group.name }
                result.append(line)
            }
        }
        return (used.first?.name, soccer ? ["P", "GD", "Pts"] : ["W", "L", "PCT"], result)
    }
}
