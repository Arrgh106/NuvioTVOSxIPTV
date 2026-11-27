import SwiftUI

/// Fork (Live TV step 17d): My Teams, as Android's My Sports: a row per
/// team you follow (its badge, name and place in its table), its last
/// results and coming games, opening on the next one. Follow a team on a
/// game's page.
struct SportsMyTeamsView: View {
    let now: Date
    let onOpen: (SportsEvent) -> Void

    @ObservedObject private var store = SportsStore.shared
    @ObservedObject private var settings = SportsSettings.shared

    var body: some View {
        Group {
            if settings.followed.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "star")
                        .font(.system(size: 60))
                        .foregroundColor(.white.opacity(0.6))
                    Text(L10n.string("livetv_sports_my_teams_empty",
                                     fallback: "Open a game and choose Follow under a team: its games show up here, with its place in the table."))
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 800)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 34) {
                        ForEach(settings.followed, id: \.key) { team in
                            teamRow(team)
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .task {
            store.loadFollowed()
            for league in Set(settings.followed.compactMap { SportsCatalog.league($0.leagueId) }) {
                await store.loadStandings(league)
            }
        }
    }

    private func teamRow(_ team: TeamInfo) -> some View {
        let league = SportsCatalog.league(team.leagueId)
        let games = store.games(of: team, now: now)
        // The last two results, then what's coming.
        let past = games.filter { $0.state == .post || $0.state == .off }.suffix(2)
        let coming = games.filter { $0.state == .live || $0.state == .pre }.prefix(6)
        let shown = Array(past) + Array(coming)
        let first = coming.first?.id
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                SportsTeamLogo(team: team, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(team.fullName.isEmpty ? team.name : team.fullName)
                        .font(.system(size: 28, weight: .bold))
                    Text([league?.name, store.standings[team.leagueId]?.placeText(team.id)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 19))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 60)
            if shown.isEmpty {
                Text(L10n.string("livetv_sports_team_loading", fallback: "Getting the games…"))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 28) {
                            ForEach(shown) { event in
                                if let league = SportsCatalog.league(event.leagueId) {
                                    SportsGameCard(event: event, league: league, width: 380, hideScores: settings.hides(event),
                                                   now: now, withDate: true, onFocus: {}, onOpen: { onOpen(event) })
                                        .id(event.id)
                                }
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.vertical, 14)
                    }
                    .onAppear { if let first { proxy.scrollTo(first, anchor: .leading) } }
                }
            }
        }
    }
}

/// Fork (Live TV step 17d): the Tables page, as Android's: a button per
/// league of yours (with its logo), then its table on a glass panel (each
/// group, zones as a coloured edge with their names below, the teams you
/// follow marked, every other row shaded) and on the right the team in
/// focus: its badge, place, points, record, goals, last result and next
/// game, and Follow.
struct SportsTablesView: View {
    @ObservedObject private var store = SportsStore.shared
    @ObservedObject private var settings = SportsSettings.shared
    @State private var leagueID: String?
    @State private var focusedRow: SportsStandingsRow?

    /// Leagues with tables: the ones shown and the ones of your teams.
    private var leagues: [League] {
        var list = settings.shownLeagues.filter { $0.kind == .teams }
        for team in settings.followed {
            if let league = SportsCatalog.league(team.leagueId), !list.contains(league) { list.insert(league, at: 0) }
        }
        return list
    }

    var body: some View {
        let list = leagues
        let league = list.first { $0.id == leagueID } ?? list.first
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(list) { item in
                        Button {
                            leagueID = item.id
                            focusedRow = nil
                        } label: {
                            HStack(spacing: 10) {
                                SportsLeagueLogo(league: item, logo: store.leagueLogos[item.id], size: 28)
                                Text(item.name).font(.system(size: 20, weight: item.id == league?.id ? .bold : .regular))
                            }
                        }
                        .onAppear { store.wantLogo(item) }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 12)
            }
            .focusSection()
            if let league {
                content(league)
                    .task(id: league.id) { await store.loadStandings(league) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func content(_ league: League) -> some View {
        if let standings = store.standings[league.id] {
            HStack(alignment: .top, spacing: 30) {
                table(standings, league: league)
                    .frame(width: 1130)
                    .focusSection()
                teamPanel(focusedRow ?? standings.groups.first?.rows.first, league: league, standings: standings)
                    .focusSection()
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 30)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func table(_ standings: SportsStandings, league: League) -> some View {
        let zones = Array(Set(standings.groups.flatMap { $0.rows.compactMap(\.zone) })).sorted { $0.label < $1.label }
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(standings.groups, id: \.name) { group in
                    if standings.groups.count > 1 {
                        Text(group.name)
                            .font(.system(size: 24, weight: .bold))
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                            .padding(.horizontal, 20)
                    }
                    head(standings)
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        SportsTableRowView(row: row, columns: standings.columns, mine: isMine(row, league: league),
                                           shaded: index % 2 == 1, onFocus: { focusedRow = row })
                    }
                }
                if !zones.isEmpty {
                    // What the coloured edges mean.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(zones, id: \.label) { zone in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3).fill(Color(sportsARGB: zone.color)).frame(width: 18, height: 18)
                                Text(zone.label).font(.system(size: 18)).foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .padding(.vertical, 12)
        }
        .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func isMine(_ row: SportsStandingsRow, league: League) -> Bool {
        settings.isFollowed(team(row, league: league))
    }

    private func team(_ row: SportsStandingsRow, league: League) -> TeamInfo {
        TeamInfo(leagueId: league.id, id: row.id, name: row.shortName, fullName: row.name, abbr: "",
                 color: SportsESPN.clubColor(row.name), logo: row.logo)
    }

    private func head(_ standings: SportsStandings) -> some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 66, alignment: .leading)
            Text(L10n.string("livetv_sports_team", fallback: "Team")).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(standings.columns, id: \.key) { column in
                Text(column.label).frame(width: SportsTableRowView.width(column.key))
            }
        }
        .font(.system(size: 17, weight: .bold))
        .foregroundColor(.white.opacity(0.5))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// The team in focus: badge, place, numbers, last result, next game.
    @ViewBuilder
    private func teamPanel(_ row: SportsStandingsRow?, league: League, standings: SportsStandings) -> some View {
        if let row {
            let info = team(row, league: league)
            let games = store.games(of: info)
            let last = games.last { $0.state == .post }
            let next = games.first { $0.state == .pre || $0.state == .live }
            let on = settings.isFollowed(info)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    SportsTeamLogo(team: info, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.system(size: 30, weight: .bold)).lineLimit(2)
                        Text(SportsStandings.ordinal(row.pos) + " · " + (standings.find(row.id)?.group.name ?? league.name))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(LiveTVTheme.accent)
                    }
                }
                if let zone = row.zone {
                    Label(zone.label, systemImage: "flag.fill")
                        .font(.system(size: 19))
                        .foregroundColor(Color(sportsARGB: zone.color))
                }
                HStack(spacing: 14) {
                    ForEach(standings.columns, id: \.key) { column in
                        if let value = row.values[column.key] {
                            VStack(spacing: 4) {
                                Text(value).font(.system(size: 28, weight: .heavy)).monospacedDigit()
                                Text(column.label).font(.system(size: 15, weight: .bold)).foregroundColor(.white.opacity(0.5))
                            }
                            .frame(minWidth: 64)
                        }
                    }
                }
                if let last {
                    gameLine(L10n.string("livetv_sports_last_game", fallback: "Last"), last, team: info)
                }
                if let next {
                    gameLine(L10n.string("livetv_sports_next_game", fallback: "Next"), next, team: info)
                }
                Button {
                    settings.toggleFollow(info)
                } label: {
                    Label(on ? L10n.format("livetv_sports_following_format", fallback: "Following %@", row.shortName)
                             : L10n.format("livetv_sports_follow_format", fallback: "Follow %@", row.shortName),
                          systemImage: on ? "star.fill" : "star")
                        .font(.system(size: 20))
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// "Last  Sat 22 Nov · Duisburg 2–0 Rostock".
    private func gameLine(_ label: String, _ event: SportsEvent, team: TeamInfo) -> some View {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(event.state == .pre ? "EEE d MMM jmm" : "EEE d MMM")
        let hide = settings.hides(event)
        let score = event.hasScore && !hide ? "\(event.home?.score ?? "")–\(event.away?.score ?? "")" : "v"
        let text = "\(event.home?.team.name ?? "") \(score) \(event.away?.team.name ?? "")"
        return VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased() + " · " + formatter.string(from: event.start))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
            Text(text).font(.system(size: 21, weight: .semibold)).lineLimit(1)
        }
    }
}

/// A line of a table: focusable (the remote scrolls through it), the
/// zone as a coloured edge, every other line shaded.
private struct SportsTableRowView: View {
    let row: SportsStandingsRow
    let columns: [SportsStandingsColumn]
    let mine: Bool
    var shaded = false
    var onFocus: () -> Void = {}
    @FocusState private var focused: Bool

    /// Wider columns for the goals ("42:19") and the points.
    static func width(_ key: String) -> CGFloat {
        switch key {
        case "goals": return 100
        case "points": return 78
        case "winPercent", "streak": return 84
        default: return 62
        }
    }

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(row.zone.map { Color(sportsARGB: $0.color) } ?? .clear)
                    .frame(width: 6, height: 40)
                    .padding(.trailing, 14)
                Text("\(row.pos)")
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 46, alignment: .leading)
                ZStack {
                    if let url = SportsTeamLogo.url(row.logo, size: 38) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fit) }
                        }
                    }
                }
                .frame(width: 38, height: 38)
                .padding(.trailing, 16)
                Text(row.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.key) { column in
                    Text(row.values[column.key] ?? "")
                        .font(.system(size: 22, weight: column.key == "points" ? .heavy : .regular))
                        .monospacedDigit()
                        .frame(width: Self.width(column.key))
                }
            }
            .font(.system(size: 22, weight: mine ? .heavy : .semibold))
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(focused ? Color.white : (mine ? LiveTVTheme.accent.opacity(0.22) : Color.white.opacity(shaded ? 0.045 : 0))))
            .padding(.horizontal, 6)
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
        .onChange(of: focused) { _, now in if now { onFocus() } }
    }
}
