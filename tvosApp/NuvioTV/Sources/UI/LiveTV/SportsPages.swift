import SwiftUI

/// Fork (Live TV step 17d): My Teams, as Android's My Sports: a row per
/// team you follow (its badge, name and place in its table), its last
/// results and coming games, opening on the next one. Teams are chosen in
/// one place (Edit My Teams, Settings → Sports).
struct SportsMyTeamsView: View {
    let now: Date
    let onOpen: (SportsEvent) -> Void
    /// The game in focus (the page's backdrop).
    var onFocus: (SportsEvent) -> Void = { _ in }

    @ObservedObject private var store = SportsStore.shared
    @ObservedObject private var settings = SportsSettings.shared
    @State private var editing = false

    /// Your teams, but not of sports you turned off.
    private var teams: [TeamInfo] {
        settings.followed.filter { team in SportsCatalog.league(team.leagueId).map { settings.isSportShown($0.sport) } ?? true }
    }

    var body: some View {
        Group {
            if teams.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "star")
                        .font(.system(size: 60))
                        .foregroundColor(.white.opacity(0.6))
                    Text(L10n.string("livetv_sports_my_teams_empty",
                                     fallback: "Choose your teams: their games show up here, with their place in the table."))
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 800)
                    Button { editing = true } label: {
                        Label(L10n.string("livetv_sports_choose_teams", fallback: "Choose Teams"), systemImage: "star")
                            .font(.system(size: 22, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 34) {
                        Button { editing = true } label: {
                            Label(L10n.string("livetv_sports_edit_teams", fallback: "Edit My Teams"), systemImage: "star")
                                .font(.system(size: 20, weight: .semibold))
                        }
                        .padding(.horizontal, 60)
                        ForEach(teams, id: \.key) { team in
                            teamRow(team)
                        }
                    }
                    .padding(.vertical, 24)
                }
            }
        }
        .sheet(isPresented: $editing) { SportsTeamsPicker() }
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
                                                   now: now, withDate: true, onFocus: { onFocus(event) }, onOpen: { onOpen(event) })
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
/// game, top players; a star by the teams you follow.
struct SportsTablesView: View {
    /// The team in focus (the page's backdrop).
    var onFocus: (TeamInfo) -> Void = { _ in }
    @ObservedObject private var store = SportsStore.shared
    @ObservedObject private var settings = SportsSettings.shared
    @State private var leagueID: String?
    @State private var focusedRow: SportsStandingsRow?

    /// Leagues that may have tables: the ones shown and the ones of your
    /// teams (sports you turned off left out).
    private var candidates: [League] {
        var list = settings.shownLeagues.filter { $0.kind == .teams }
        for team in settings.followed {
            if let league = SportsCatalog.league(team.leagueId), settings.isSportShown(league.sport), !list.contains(league) {
                list.insert(league, at: 0)
            }
        }
        return list
    }

    var body: some View {
        // Cups have no table.
        let list = candidates.filter { !store.noTable.contains($0.id) }
        let league = list.first { $0.id == leagueID } ?? list.first
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(list) { item in
                        SportsLeagueChip(league: item, logo: store.leagueLogos[item.id], selected: item.id == league?.id) {
                            leagueID = item.id
                            focusedRow = nil
                        }
                        .onAppear { store.wantLogo(item) }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 14)
            }
            .scrollClipDisabledIfAvailable()
            .focusSection()
            if let league {
                content(league)
                    .task(id: league.id) { await store.loadStandings(league) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Every league's table side by side: switching is instant (a
        // competition without one is asked too, in case it has one now).
        .task(id: candidates.map(\.id)) { await store.loadStandings(candidates) }
    }

    @ViewBuilder
    private func content(_ league: League) -> some View {
        if let standings = store.standings[league.id] {
            HStack(alignment: .top, spacing: 30) {
                SportsStandingsTable(standings: standings, league: league, onFocus: { row in
                    focusedRow = row
                    onFocus(row.team(in: league))
                })
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

    private func team(_ row: SportsStandingsRow, league: League) -> TeamInfo {
        row.team(in: league)
    }

    /// The team in focus: badge, place, numbers, last result, next game.
    @ViewBuilder
    private func teamPanel(_ row: SportsStandingsRow?, league: League, standings: SportsStandings) -> some View {
        if let row {
            let info = team(row, league: league)
            let games = store.games(of: info)
            let last = games.last { $0.state == .post }
            let next = games.first { $0.state == .pre || $0.state == .live }
            // ESPN's own colour for the team (its games have it).
            let colour = games.lazy.flatMap(\.sides).first { $0.team.id == info.id }?.team.color ?? info.color
            let form = Self.form(info, games: games)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    SportsTeamLogo(team: info, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.system(size: 30, weight: .bold)).lineLimit(2)
                        // The league's name; a group's only where there are groups.
                        Text(SportsStandings.ordinal(row.pos) + " · "
                             + (standings.groups.count > 1 ? standings.find(row.id)?.group.name ?? league.name : league.name))
                            .lineLimit(1)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(LiveTVTheme.accent)
                    }
                    Spacer(minLength: 12)
                    SportsFollowBadge(team: info, size: 40)
                }
                if let zone = row.zone {
                    Label(zone.label, systemImage: "flag.fill")
                        .font(.system(size: 19))
                        .foregroundColor(Color(sportsARGB: zone.color))
                }
                // Every number on one line ("42:19" too), sharing the width.
                HStack(spacing: 8) {
                    ForEach(standings.columns, id: \.key) { column in
                        if let value = row.values[column.key] {
                            VStack(spacing: 4) {
                                Text(value)
                                    .font(.system(size: 28, weight: .heavy))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                Text(column.label)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                if let last {
                    SportsGameLine(label: L10n.string("livetv_sports_last_game", fallback: "Last"), event: last, team: info,
                                   hideScore: settings.hides(last))
                }
                if let next {
                    SportsGameLine(label: L10n.string("livetv_sports_next_game", fallback: "Next"), event: next, team: info,
                                   hideScore: settings.hides(next))
                }
                // Top scorer and top assists (other sports: their first two
                // leaders), with a small picture.
                ForEach(store.teamLeaders[info.key] ?? [], id: \.category) { leader in
                    HStack(spacing: 14) {
                        SportsPlayerPhoto(leader: leader, color: colour.map { Color(sportsARGB: $0) } ?? .gray, team: row.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leader.category.uppercased())
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white.opacity(0.5))
                            Text(leader.name).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(leader.value).font(.system(size: 26, weight: .heavy)).monospacedDigit()
                    }
                }
                // The last five results, the newest on the right.
                if !form.isEmpty, settings.scoreMode != .hideAll {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("livetv_sports_form", fallback: "Form").uppercased())
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                        SportsFormDots(results: form, size: 36)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Its games and top players, once focus rests on it a moment.
            .task(id: info.key) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                await store.loadTeam(info)
            }
            .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// The team's last five results ("W", "D", "L"), oldest first.
    static func form(_ team: TeamInfo, games: [SportsEvent]) -> [String] {
        games.filter { $0.state == .post && $0.hasScore }.suffix(5).compactMap { game in
            guard let mine = game.sides.first(where: { $0.team.id == team.id }),
                  let other = game.sides.first(where: { $0.team.id != team.id }),
                  let us = Double(mine.score ?? ""), let them = Double(other.score ?? "") else { return nil }
            return us > them ? "W" : (us < them ? "L" : "D")
        }
    }
}

/// "LAST · Sat 22 Nov", then both teams with their logos and the score
/// (or the kick-off) between them; the team of the panel brighter, the
/// result's letter on its colour.
struct SportsGameLine: View {
    let label: String
    let event: SportsEvent
    let team: TeamInfo
    let hideScore: Bool

    var body: some View {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(event.state == .pre ? "EEE d MMM jmm" : "EEE d MMM")
        let sport = SportsCatalog.league(event.leagueId)?.sport ?? .football
        let sides = event.ordered(sport)
        let showScore = event.hasScore && !hideScore
        let result = showScore ? SportsTablesView.form(team, games: [event]).first : nil
        return VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased() + " · " + formatter.string(from: event.start))
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
            if sides.count == 2 {
                HStack(spacing: 10) {
                    side(sides[0], alignRight: false)
                    Text(showScore ? "\(sides[0].score ?? "")–\(sides[1].score ?? "")"
                                   : (event.state == .pre && event.hasTime ? SportsView.clock(event.start) : "–"))
                        .font(.system(size: 21, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    side(sides[1], alignRight: true)
                    if let result {
                        Text(SportsFormDots.letter(result))
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundColor(result == "D" ? .black : .white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(SportsFormDots.color(result)))
                    }
                }
            } else {
                Text(event.title).font(.system(size: 21, weight: .semibold)).lineLimit(1)
            }
        }
    }

    private func side(_ side: SportsSide, alignRight: Bool) -> some View {
        let mine = side.team.id == team.id
        return HStack(spacing: 8) {
            if !alignRight { SportsTeamLogo(team: side.team, size: 32) }
            Text(side.team.name)
                .font(.system(size: 19, weight: mine ? .bold : .medium))
                .foregroundColor(.white.opacity(mine ? 1 : 0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if alignRight { SportsTeamLogo(team: side.team, size: 32) }
        }
        .frame(maxWidth: .infinity, alignment: alignRight ? .trailing : .leading)
    }
}

/// A league table on a glass panel, the same on the Tables page and a
/// game's page: each group, zones as a coloured edge with their names
/// below, the teams you follow starred, the game's teams marked (and
/// scrolled to), every other row shaded.
struct SportsStandingsTable: View {
    let standings: SportsStandings
    let league: League
    /// The game's teams (a game's page).
    var highlight: Set<String> = []
    var onFocus: (SportsStandingsRow) -> Void = { _ in }
    @ObservedObject private var settings = SportsSettings.shared

    var body: some View {
        let zones = Array(Set(standings.groups.flatMap { $0.rows.compactMap(\.zone) })).sorted { $0.label < $1.label }
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(standings.groups, id: \.name) { group in
                        if standings.groups.count > 1 {
                            Text(group.name)
                                .font(.system(size: 24, weight: .bold))
                                .padding(.top, 18)
                                .padding(.bottom, 6)
                                .padding(.horizontal, 20)
                        }
                        head
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                            SportsTableRowView(row: row, columns: standings.columns,
                                               mine: settings.isFollowed(row.team(in: league)),
                                               marked: highlight.contains(row.id),
                                               shaded: index % 2 == 1, onFocus: { onFocus(row) })
                                .id(row.id)
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
            .onAppear {
                // The game's first team in view.
                let first = standings.groups.flatMap(\.rows).first { highlight.contains($0.id) }
                if let first { proxy.scrollTo(first.id, anchor: .center) }
            }
        }
        .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var head: some View {
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
}

/// A line of a table: focusable (the remote scrolls through it), the
/// zone as a coloured edge, every other line shaded.
private struct SportsTableRowView: View {
    let row: SportsStandingsRow
    let columns: [SportsStandingsColumn]
    let mine: Bool
    /// One of the game's teams (a game's page).
    var marked = false
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
                        SportsImage(url: url) { Color.clear }
                    }
                }
                .frame(width: 38, height: 38)
                .padding(.trailing, 16)
                HStack(spacing: 10) {
                    Text(row.name).lineLimit(1)
                    // A team you follow.
                    if mine {
                        Image(systemName: "star.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(focused ? .black : LiveTVTheme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.key) { column in
                    Text(row.values[column.key] ?? "")
                        .font(.system(size: 22, weight: column.key == "points" ? .heavy : .regular))
                        .monospacedDigit()
                        .frame(width: Self.width(column.key))
                }
            }
            .font(.system(size: 22, weight: mine || marked ? .heavy : .semibold))
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(focused ? Color.white : (marked ? LiveTVTheme.accent.opacity(0.34)
                        : (mine ? LiveTVTheme.accent.opacity(0.22) : Color.white.opacity(shaded ? 0.045 : 0)))))
            .padding(.horizontal, 6)
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
        .onChange(of: focused) { _, now in if now { onFocus() } }
    }
}

/// A league to pick on the Tables page: its logo and name on Nuvio's pill.
private struct SportsLeagueChip: View {
    let league: League
    let logo: String?
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SportsLeagueLogo(league: league, logo: logo, size: 28)
                Text(league.name).font(.system(size: 20, weight: selected ? .bold : .semibold)).lineLimit(1)
            }
            .foregroundColor(focused ? .black : (selected ? LiveTVTheme.accent : .white.opacity(0.9)))
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(Capsule().fill(focused ? Color.white : (selected ? Color.white.opacity(0.24) : Color.white.opacity(0.1))))
            .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0 : 0.14), lineWidth: 1))
            .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 10, y: 4)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}
