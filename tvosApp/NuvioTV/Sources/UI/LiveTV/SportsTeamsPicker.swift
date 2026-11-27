import SwiftUI

/// Fork (Live TV step 17d): the one place for the teams you follow
/// (Settings → Sports, the Sports page's gear and My Teams): the teams you
/// follow, then every league with a table to add one from (football by
/// country), each team with its star. A Nuvio settings sheet.
struct SportsTeamsPicker: View {
    @ObservedObject private var settings = SportsSettings.shared
    @ObservedObject private var store = SportsStore.shared
    @Environment(\.dismiss) private var dismiss
    /// The teams you follow as the sheet opened, and the ones added since:
    /// one unfollowed stays (its star empty), so the list doesn't jump.
    @State private var listed: [TeamInfo] = []
    @State private var open: Set<Sport> = []
    @State private var openAreas: Set<String> = []
    @State private var openLeagues: Set<String> = []

    var body: some View {
        // Only competitions with a table (cups have none: known before
        // anything is asked, so nothing vanishes once opened).
        let leagues = SportsCatalog.all.filter { $0.hasFeed && $0.kind == .teams && !store.noTable.contains($0.id) }
        let sports = settings.visibleSports.filter { sport in leagues.contains { $0.sport == sport } }
        LiveTVSheetPage(
            title: L10n.string("livetv_sports_my_teams_title", fallback: "My Teams"),
            subtitle: L10n.string("livetv_sports_my_teams_detail",
                                  fallback: "Their games show in My Teams, their lines are marked in tables. Press a team to follow it or not.")
        ) {
            if !listed.isEmpty {
                heading(L10n.string("livetv_sports_following", fallback: "Following"))
                ForEach(listed, id: \.key) { team in
                    SportsTeamRow(team: team, subtitle: SportsCatalog.league(team.leagueId)?.name ?? "")
                }
            }
            heading(L10n.string("livetv_sports_add_team", fallback: "Add a Team"))
            ForEach(sports, id: \.self) { sport in
                let list = leagues.filter { $0.sport == sport }
                SportsGroupRow(
                    title: sport.label,
                    subtitle: L10n.format("livetv_sports_leagues_number_format", fallback: "%d leagues", list.count),
                    isOpen: open.contains(sport),
                    action: { toggle(&open, sport) }
                ) {
                    Text(sport.icon).font(.system(size: 30))
                }
                if open.contains(sport) {
                    if sport == .football {
                        ForEach(SportsTeams.orderedAreas(Set(list.map(SportsTeams.footballArea)), country: settings.footballCountry), id: \.self) { area in
                            let inArea = list.filter { SportsTeams.footballArea($0) == area }
                            let info = SportsTeams.areaName(area)
                            SportsGroupRow(
                                title: info.name,
                                subtitle: L10n.format("livetv_sports_leagues_number_format", fallback: "%d leagues", inArea.count),
                                isOpen: openAreas.contains(area),
                                action: { toggle(&openAreas, area) }
                            ) {
                                Text(info.flag).font(.system(size: 30))
                            }
                            .padding(.leading, 40)
                            if openAreas.contains(area) {
                                leagueRows(inArea, indent: 80)
                            }
                        }
                    } else {
                        leagueRows(list, indent: 40)
                    }
                }
            }
        }
        .onAppear { listed = settings.followed }
        .onChange(of: settings.followed) { _, now in
            for team in now where !listed.contains(where: { $0.key == team.key }) { listed.append(team) }
        }
        .onExitCommand { dismiss() }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    /// A league (opens to its teams, from its table) per row.
    @ViewBuilder
    private func leagueRows(_ list: [League], indent: CGFloat) -> some View {
        ForEach(list) { league in
            SportsGroupRow(
                title: league.name,
                subtitle: nil,
                isOpen: openLeagues.contains(league.id),
                action: {
                    toggle(&openLeagues, league.id)
                    if openLeagues.contains(league.id) { Task { await store.loadStandings(league) } }
                }
            ) {
                SportsLeagueLogo(league: league, logo: store.leagueLogos[league.id], size: 46)
            }
            .padding(.leading, indent)
            .onAppear { store.wantLogo(league) }
            if openLeagues.contains(league.id) {
                if let table = store.standings[league.id] {
                    ForEach(Self.teams(table, league: league), id: \.key) { team in
                        SportsTeamRow(team: team, subtitle: league.name)
                            .padding(.leading, indent + 40)
                    }
                } else {
                    Text(L10n.string("livetv_sports_getting_teams", fallback: "Getting the teams…"))
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, indent + 40)
                }
            }
        }
    }

    /// A table's teams A to Z, each once (divisions list a team once each).
    private static func teams(_ table: SportsStandings, league: League) -> [TeamInfo] {
        var seen: Set<String> = []
        return table.groups.flatMap(\.rows)
            .filter { seen.insert($0.id).inserted }
            .map { $0.team(in: league) }
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

/// A team you can follow: its logo, name and league, and its star (filled
/// when followed). Pressing it follows or unfollows.
struct SportsTeamRow: View {
    let team: TeamInfo
    let subtitle: String
    @ObservedObject private var settings = SportsSettings.shared
    @FocusState private var focused: Bool

    var body: some View {
        let on = settings.isFollowed(team)
        Button {
            settings.toggleFollow(team)
        } label: {
            LiveTVSettingsRows.rowShell(isFocused: focused, accentColor: LiveTVTheme.accent) {
                SportsTeamLogo(team: team, size: 46)
                LiveTVSettingsRows.rowText(title: team.fullName.isEmpty ? team.name : team.fullName, subtitle: subtitle)
                Spacer(minLength: 24)
                Image(systemName: on ? "star.fill" : "star")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(on ? LiveTVTheme.accent : .white.opacity(0.5))
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .accessibilityLabel(on ? L10n.format("livetv_sports_following_format", fallback: "Following %@", team.name)
                               : L10n.format("livetv_sports_follow_format", fallback: "Follow %@", team.name))
    }
}

/// A row that opens and closes what's under it (a sport, a country, a
/// league), in Nuvio's settings-row look.
struct SportsGroupRow<Leading: View>: View {
    let title: String
    let subtitle: String?
    let isOpen: Bool
    let action: () -> Void
    @ViewBuilder let leading: Leading
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            LiveTVSettingsRows.rowShell(isFocused: focused, accentColor: LiveTVTheme.accent) {
                leading.frame(width: 46, height: 46)
                SportsRowTitle(title: title, subtitle: subtitle)
                Spacer(minLength: 24)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(LiveTVTheme.accent)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
    }
}

/// A row's title (and subtitle when there is one) in Nuvio's settings type.
struct SportsRowTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        if let subtitle, !subtitle.isEmpty {
            LiveTVSettingsRows.rowText(title: title, subtitle: subtitle)
        } else {
            Text(title)
                .font(.appFont(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
    }
}

/// Settings → Sports → Sports: which sports the Sports page shows (its
/// chips, All Events, Tables, the pickers) and in which order. A sport
/// turned off keeps its leagues and teams for when it's turned on again.
struct SportsSportsPicker: View {
    @ObservedObject private var settings = SportsSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sports = settings.orderedSports.filter { sport in SportsCatalog.all.contains { $0.sport == sport && $0.hasFeed } }
        LiveTVSheetPage(
            title: L10n.string("livetv_sports_sports_title", fallback: "Sports"),
            subtitle: L10n.string("livetv_sports_sports_detail",
                                  fallback: "Press a sport to show or hide it; the arrows move it up or down the Sports page.")
        ) {
            ForEach(Array(sports.enumerated()), id: \.element) { index, sport in
                HStack(spacing: 12) {
                    SportsSportRow(sport: sport)
                    SportsMoveButton(systemImage: "chevron.up", enabled: index > 0) { settings.moveSport(sport, by: -1, among: sports) }
                    SportsMoveButton(systemImage: "chevron.down", enabled: index < sports.count - 1) { settings.moveSport(sport, by: 1, among: sports) }
                }
                .focusSection()
            }
        }
        .onExitCommand { dismiss() }
    }
}

private struct SportsSportRow: View {
    let sport: Sport
    @ObservedObject private var settings = SportsSettings.shared
    @FocusState private var focused: Bool

    var body: some View {
        let on = settings.isSportShown(sport)
        Button {
            settings.toggleSport(sport)
        } label: {
            LiveTVSettingsRows.rowShell(isFocused: focused, accentColor: LiveTVTheme.accent) {
                Text(sport.icon).font(.system(size: 30)).frame(width: 46, height: 46)
                SportsRowTitle(title: sport.label)
                Spacer(minLength: 24)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(on ? LiveTVTheme.accent : .white.opacity(0.4))
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
    }
}

private struct SportsMoveButton: View {
    let systemImage: String
    let enabled: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(focused ? .black : .white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 64, height: 64)
                .background(Circle().fill(focused ? Color.white : Color.white.opacity(0.1)))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .disabled(!enabled)
        .scaleEffect(focused ? 1.08 : 1)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// A picture from the app's image cache (Nuvio's own, kept in memory): a
/// row scrolled back into view shows it at once, without asking again.
struct SportsImage<Placeholder: View>: View {
    let url: URL?
    var fill = false
    @ViewBuilder let placeholder: Placeholder
    @State private var loaded: Loaded?

    private struct Loaded {
        let url: URL
        let image: UIImage
    }

    var body: some View {
        let image = loaded.flatMap { $0.url == url ? $0.image : nil }
            ?? url.flatMap { BackdropImageCache.shared.cachedImage(for: $0) }
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url, BackdropImageCache.shared.cachedImage(for: url) == nil else { return }
            if let image = await BackdropImageCache.shared.image(for: url, minimumBytes: 0) {
                loaded = Loaded(url: url, image: image)
            }
        }
    }
}

/// A team's top player: their photo when ESPN has one, else the shirt
/// number on the team's colour; the country's flag in the corner.
struct SportsPlayerPhoto: View {
    let leader: SportsTeamLeader
    let color: Color
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            Circle().fill(color)
            if let url = leader.headshot.flatMap(URL.init(string:)) {
                SportsImage(url: url, fill: true) { number }
            } else {
                number
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if let url = leader.flag.flatMap(URL.init(string:)) {
                SportsImage(url: url, fill: true) { Color.clear }
                    .frame(width: size * 0.42, height: size * 0.42)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
                    .offset(x: 4, y: 4)
            }
        }
    }

    private var number: some View {
        Text(leader.jersey ?? String(leader.name.prefix(1)))
            .font(.system(size: size * 0.4, weight: .heavy))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

extension SportsStandingsRow {
    /// The team on this line.
    func team(in league: League) -> TeamInfo {
        TeamInfo(leagueId: league.id, id: id, name: shortName, fullName: name, abbr: "",
                 color: SportsESPN.clubColor(name), logo: logo)
    }
}
