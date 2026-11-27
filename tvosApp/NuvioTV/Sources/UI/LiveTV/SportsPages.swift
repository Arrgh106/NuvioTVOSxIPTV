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
/// league of yours, then its table (each group, its zones in colour, the
/// teams you follow marked).
struct SportsTablesView: View {
    @ObservedObject private var store = SportsStore.shared
    @ObservedObject private var settings = SportsSettings.shared
    @State private var leagueID: String?

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
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(list) { item in
                        Button {
                            leagueID = item.id
                        } label: {
                            Text(item.name).font(.system(size: 20, weight: item.id == league?.id ? .bold : .regular))
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 12)
            }
            .focusSection()
            if let league {
                table(league)
                    .task(id: league.id) { await store.loadStandings(league) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func table(_ league: League) -> some View {
        if let standings = store.standings[league.id] {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(standings.groups, id: \.name) { group in
                        if standings.groups.count > 1 {
                            Text(group.name).font(.system(size: 24, weight: .bold)).padding(.top, 14)
                        }
                        head(standings)
                        ForEach(group.rows, id: \.id) { row in
                            SportsTableRowView(row: row, columns: standings.columns, mine: isMine(row, league: league))
                        }
                    }
                }
                .frame(maxWidth: 1300)
                .padding(.horizontal, 60)
                .padding(.bottom, 40)
            }
            .focusSection()
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isMine(_ row: SportsStandingsRow, league: League) -> Bool {
        settings.isFollowed(TeamInfo(leagueId: league.id, id: row.id, name: row.name, fullName: row.name, abbr: ""))
    }

    private func head(_ standings: SportsStandings) -> some View {
        HStack(spacing: 0) {
            Text("#").frame(width: 60, alignment: .leading)
            Text("").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(standings.columns, id: \.key) { column in
                Text(column.label).frame(width: 90)
            }
        }
        .font(.system(size: 18, weight: .bold))
        .foregroundColor(.white.opacity(0.55))
        .padding(.horizontal, 16)
    }
}

/// A line of a table: focusable, so the remote scrolls through it.
private struct SportsTableRowView: View {
    let row: SportsStandingsRow
    let columns: [SportsStandingsColumn]
    let mine: Bool
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(row.zone.map { Color(sportsARGB: $0.color) } ?? .clear)
                    .frame(width: 5, height: 34)
                    .padding(.trailing, 10)
                Text("\(row.pos)").frame(width: 45, alignment: .leading)
                if let url = SportsTeamLogo.url(row.logo, size: 34) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fit) }
                    }
                    .frame(width: 34, height: 34)
                    .padding(.trailing, 14)
                }
                Text(row.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.key) { column in
                    Text(row.values[column.key] ?? "").frame(width: 90).monospacedDigit()
                }
            }
            .font(.system(size: 22, weight: mine ? .heavy : .regular))
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(focused ? Color.white : (mine ? Color.white.opacity(0.16) : Color.clear)))
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
    }
}
