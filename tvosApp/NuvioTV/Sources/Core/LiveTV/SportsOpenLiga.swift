import Foundation

/// Fork (Live TV step 17d): OpenLigaDB (api.openligadb.de, free, no key),
/// for German football ESPN doesn't carry: the 3. Liga. One request gives a
/// whole season (kick-offs, scores, goals with scorers); another the table.
enum SportsOpenLiga {
    /// "openligadb/bl3" -> "bl3".
    static func shortcut(_ league: League) -> String? {
        league.id.hasPrefix("openligadb/") ? String(league.id.dropFirst("openligadb/".count)) : nil
    }

    /// The season a date is in (it starts in July): 2026 for 2026/27.
    static func season(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let c = calendar.dateComponents([.year, .month], from: date)
        return (c.month ?? 1) >= 7 ? (c.year ?? 2026) : (c.year ?? 2026) - 1
    }

    static func matchesURL(_ league: League, season: Int) -> URL? {
        shortcut(league).flatMap { URL(string: "https://api.openligadb.de/getmatchdata/\($0)/\(season)") }
    }

    static func tableURL(_ league: League, season: Int) -> URL? {
        shortcut(league).flatMap { URL(string: "https://api.openligadb.de/getbltable/\($0)/\(season)") }
    }

    /// Wikipedia's SVG logos as PNG thumbnails (SVG doesn't show).
    static func logo(_ link: String?) -> String? {
        guard let link, !link.isEmpty else { return nil }
        let marker = "upload.wikimedia.org/wikipedia/"
        guard link.lowercased().hasSuffix(".svg"), let range = link.range(of: marker) else { return link }
        // .../wikipedia/en/c/c8/Name.svg -> .../wikipedia/en/thumb/c/c8/Name.svg/250px-Name.svg.png
        let rest = link[range.upperBound...]
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let file = rest.split(separator: "/").last else { return link }
        return "https://" + marker + parts[0] + "/thumb/" + parts[1] + "/250px-" + file + ".png"
    }

    private typealias JSON = [String: Any]

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

    private static func team(_ league: League, _ t: JSON?) -> TeamInfo? {
        guard let t, let id = int(t["teamId"]), let name = t["teamName"] as? String else { return nil }
        let short = (t["shortName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        return TeamInfo(leagueId: league.id, id: String(id), name: short, fullName: name,
                        abbr: (t["tla"] as? String) ?? String(short.prefix(3)).uppercased(), location: nil,
                        color: SportsESPN.clubColor(name), altColor: nil, logo: logo(t["teamIconUrl"] as? String))
    }

    /// A season's games, with the goals of each (by game id).
    static func parseMatches(_ league: League, data: Data, now: Date = Date())
        -> (events: [SportsEvent], goals: [String: [SportsScoringPlay]]) {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [JSON] else { return ([], [:]) }
        var events: [SportsEvent] = []
        var goals: [String: [SportsScoringPlay]] = [:]
        for m in list {
            guard let matchID = int(m["matchID"]), let start = SportsESPN.parseISO(m["matchDateTimeUTC"] as? String),
                  let home = team(league, m["team1"] as? JSON), let away = team(league, m["team2"] as? JSON) else { continue }
            let finished = (m["matchIsFinished"] as? Bool) ?? false
            let started = start <= now
            let state: GameState = finished ? .post : (started ? .live : .pre)
            let results = m["matchResults"] as? [JSON] ?? []
            let final = results.first { int($0["resultTypeID"]) == 2 } ?? results.last
            let goalList = m["goals"] as? [JSON] ?? []
            var homeScore: Int?
            var awayScore: Int?
            if let last = goalList.last, let h = int(last["scoreTeam1"]), let a = int(last["scoreTeam2"]) {
                homeScore = h
                awayScore = a
            }
            if finished, let final, let h = int(final["pointsTeam1"]), let a = int(final["pointsTeam2"]) {
                homeScore = h
                awayScore = a
            }
            if state == .live, homeScore == nil { homeScore = 0; awayScore = 0 }
            let id = "\(league.id):\(matchID)"
            var status: String?
            switch state {
            case .post: status = "FT"
            case .live:
                let played = Int(now.timeIntervalSince(start) / 60)
                status = played < 47 ? "\(max(played, 1))'" : (played < 62 ? "HT" : "\(min(played - 15, 90))'")
            default: status = nil
            }
            let round = (m["group"] as? JSON)?["groupName"] as? String
            let homeSide = SportsSide(team: home, score: homeScore.map(String.init), record: nil,
                                      winner: finished && (homeScore ?? 0) > (awayScore ?? 0), home: true)
            let awaySide = SportsSide(team: away, score: awayScore.map(String.init), record: nil,
                                      winner: finished && (awayScore ?? 0) > (homeScore ?? 0), home: false)
            let progress: Double? = state == .live ? min(max(now.timeIntervalSince(start) / (105 * 60), 0), 1) : nil
            events.append(SportsEvent(
                id: id, leagueId: league.id, start: start, hasTime: true, state: state,
                title: "\(home.name) v \(away.name)", subtitle: round, status: status, away: awaySide, home: homeSide,
                progress: progress, espnId: nil))
            goals[id] = goalList.compactMap { g -> SportsScoringPlay? in
                guard let scorer = g["goalGetterName"] as? String else { return nil }
                let teamID = int(g["scoringTeamId"]).map(String.init)
                let who = teamID == home.id ? home.name : (teamID == away.id ? away.name : nil)
                var text = scorer
                if (g["isPenalty"] as? Bool) == true { text += " (pen.)" }
                if (g["isOwnGoal"] as? Bool) == true { text += " (o.g.)" }
                return SportsScoringPlay(
                    clock: int(g["matchMinute"]).map { "\($0)'" } ?? "", team: who, text: text,
                    awayScore: int(g["scoreTeam2"]).map(String.init), homeScore: int(g["scoreTeam1"]).map(String.init))
            }
        }
        return (events, goals)
    }

    /// A game's goals as the Overview's timeline: penalties and own goals
    /// marked, the score after each (OpenLigaDB has no cards or
    /// substitutions).
    static func moments(_ goals: [SportsScoringPlay], home: String?) -> [SportsMoment] {
        goals.map { play in
            let own = play.text.contains("(o.g.)"), penalty = play.text.contains("(pen.)")
            let name = play.text.replacingOccurrences(of: " (o.g.)", with: "").replacingOccurrences(of: " (pen.)", with: "")
            let minute = Int(play.clock.filter(\.isNumber)) ?? 0
            return SportsMoment(
                kind: own ? .ownGoal : (penalty ? .penaltyGoal : .goal), clock: play.clock, period: minute > 45 ? 2 : 1,
                home: play.team.map { $0 == home }, player: name.nilIfBlank, detail: nil,
                score: play.homeScore.flatMap { h in play.awayScore.map { "\(h)–\($0)" } })
        }
    }

    /// The league table.
    static func parseTable(_ league: League, data: Data) -> SportsStandings? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [JSON], !list.isEmpty else { return nil }
        let rows: [SportsStandingsRow] = list.enumerated().compactMap { index, t in
            guard let id = int(t["teamInfoId"]) ?? int(t["teamId"]), let name = t["teamName"] as? String else { return nil }
            var values: [String: String] = [:]
            for (key, field) in [("gamesPlayed", "matches"), ("wins", "won"), ("ties", "draw"), ("losses", "lost"), ("points", "points")] {
                if let n = int(t[field]) { values[key] = String(n) }
            }
            if let diff = int(t["goalDiff"]) { values["pointDifferential"] = diff > 0 ? "+\(diff)" : String(diff) }
            if let g = int(t["goals"]), let o = int(t["opponentGoals"]) { values["goals"] = "\(g):\(o)" }
            return SportsStandingsRow(id: String(id), name: name, shortName: (t["shortName"] as? String) ?? name,
                                      logo: logo(t["teamIconUrl"] as? String), pos: index + 1, values: values)
        }
        return SportsStandings(leagueId: league.id, kind: .table, columns: SportsStandings.tableColumns,
                               groups: [SportsStandingsGroup(name: league.name, rows: rows)])
    }
}
