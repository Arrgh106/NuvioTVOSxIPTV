import SwiftUI

/// Fork (Live TV step 17c): a game's page, as Android's GamePage: the
/// teams' colours behind, both teams big with the score, the state and the
/// countdown before it starts, then tabs (Overview, Stats, Leaders,
/// Line-ups, Table, Form, Info) from ESPN's summary. Asked again every
/// 30 s while the game is on. Before kick-off (or with Hide Scores) only
/// what tells nothing of the result.
struct SportsGamePage: View {
    let eventID: String

    @ObservedObject private var store = SportsStore.shared
    @ObservedObject private var settings = SportsSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var extras: SportsGameExtras?
    @State private var tab: Tab = .overview
    @State private var now = Date()
    @Namespace private var focusSpace

    enum Tab: String, CaseIterable, Identifiable {
        case overview, stats, leaders, lineups, table, form, info
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return L10n.string("livetv_sports_tab_overview", fallback: "Overview")
            case .stats: return L10n.string("livetv_sports_tab_stats", fallback: "Stats")
            case .leaders: return L10n.string("livetv_sports_tab_leaders", fallback: "Top Players")
            case .lineups: return L10n.string("livetv_sports_tab_lineups", fallback: "Line-ups")
            case .table: return L10n.string("livetv_sports_tab_table", fallback: "Table")
            case .form: return L10n.string("livetv_sports_tab_form", fallback: "Form")
            case .info: return L10n.string("livetv_sports_tab_info", fallback: "Match Info")
            }
        }
    }

    private var event: SportsEvent? { store.event(id: eventID) }

    /// The tabs with something in them; before kick-off or with Hide
    /// Scores only Form, Table and Info (as Android's).
    private func tabs(_ event: SportsEvent, _ extras: SportsGameExtras?) -> [Tab] {
        guard let extras else { return [] }
        let spoilerFree = event.state == .pre || settings.hides(event)
        var list: [Tab] = []
        if !spoilerFree, !extras.plays.isEmpty || extras.hasOdds { list.append(.overview) }
        if spoilerFree, extras.hasOdds, event.state == .pre { list.append(.overview) }
        if !spoilerFree, !extras.stats.isEmpty { list.append(.stats) }
        if !spoilerFree, !extras.performers.isEmpty { list.append(.leaders) }
        if !spoilerFree, !extras.lineups.isEmpty { list.append(.lineups) }
        if !extras.table.isEmpty { list.append(.table) }
        if !extras.form.isEmpty || !extras.meetings.isEmpty { list.append(.form) }
        list.append(.info)
        return list
    }

    var body: some View {
        ZStack {
            if let event, let league = SportsCatalog.league(event.leagueId) {
                backdrop(event)
                page(event, league: league)
            } else {
                Color.black.ignoresSafeArea()
                ProgressView()
            }
        }
        .onExitCommand { dismiss() }
        .task(id: eventID) { await keepFresh() }
    }

    /// The summary now, then every 30 s while the game is on (or about to
    /// start).
    private func keepFresh() async {
        while !Task.isCancelled {
            now = Date()
            if let event {
                if event.state == .live || (event.state == .pre && event.start.timeIntervalSinceNow < 15 * 60) {
                    await store.refreshGame(event)
                }
                if let fresh = self.event, let found = await store.extras(for: fresh) { extras = found }
                if let event = self.event, let extras, !tabs(event, extras).contains(tab), let first = tabs(event, extras).first {
                    tab = first
                }
            }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    private func backdrop(_ event: SportsEvent) -> some View {
        let colors = event.sides.compactMap { $0.team.color }.map { Color(sportsARGB: $0) }
        return ZStack {
            Color.black
            if colors.count == 2 {
                LinearGradient(colors: [colors[0].opacity(0.6), colors[1].opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.92)], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }

    private func page(_ event: SportsEvent, league: League) -> some View {
        let list = tabs(event, extras)
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                SportsLeagueLogo(league: league, logo: store.leagueLogos[league.id], size: 40)
                Text([league.name, Self.round(event)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                if event.state == .live { SportsLiveBadge() }
            }
            if event.sides.count == 2 {
                // A star under either team follows it (its games in My Teams).
                SportsMatchup(event: event, league: league, hideScores: settings.hides(event), width: 1100, logoSize: 150,
                              follow: true)
                    .focusSection()
                    .frame(maxWidth: .infinity)
            } else {
                Text(event.title).font(.system(size: 52, weight: .bold)).lineLimit(2)
            }
            VStack(spacing: 6) {
                if let venue = extras?.venue ?? event.venue {
                    Label([venue, extras?.city ?? event.city].compactMap { $0 }.joined(separator: ", "), systemImage: "mappin.and.ellipse")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                }
                Text(SportsView.whenLine(event, hideScores: settings.hides(event)))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(LiveTVTheme.accent)
                if let countdown = Self.countdown(event, now: now) {
                    Text(countdown).font(.system(size: 22)).foregroundColor(.white.opacity(0.75))
                }
                if let situation = event.situation, !settings.hides(event) {
                    Text(situation).font(.system(size: 22)).foregroundColor(.white.opacity(0.8))
                }
                if !settings.hides(event), event.state != .pre {
                    SportsPeriodTable(event: event, league: league)
                }
            }
            .frame(maxWidth: .infinity)
            if list.isEmpty {
                Text(extras == nil ? L10n.string("livetv_sports_loading_game", fallback: "Getting more about the game…")
                                   : L10n.string("livetv_sports_no_more", fallback: "ESPN has nothing more about this game yet."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 14) {
                    ForEach(list) { item in
                        Button {
                            tab = item
                        } label: {
                            Text(item.title).font(.system(size: 22, weight: tab == item ? .bold : .regular))
                        }
                        // Focus starts on the tabs (the stars are up from
                        // here).
                        .prefersDefaultFocus(item == list.first, in: focusSpace)
                    }
                }
                .focusSection()
                .frame(maxWidth: .infinity)
                if let extras {
                    tabContent(list.contains(tab) ? tab : list[0], event: event, league: league, extras: extras)
                        .frame(maxWidth: 1400)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 50)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusScope(focusSpace)
    }

    /// The round or match day ("14. Spieltag", "Week 12", "Group A"), not
    /// the venue (shown under the score).
    static func round(_ event: SportsEvent) -> String? {
        guard let subtitle = event.subtitle else { return nil }
        let parts = subtitle.components(separatedBy: " · ").filter { $0 != event.venue }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Starts in 2 h 15 min".
    static func countdown(_ event: SportsEvent, now: Date) -> String? {
        guard event.state == .pre, event.hasTime else { return nil }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        guard minutes > 0, minutes < 48 * 60 else { return nil }
        let text = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return L10n.format("livetv_sports_starts_in", fallback: "Starts in %@", text)
    }

    // MARK: Tabs

    @ViewBuilder
    private func tabContent(_ tab: Tab, event: SportsEvent, league: League, extras: SportsGameExtras) -> some View {
        switch tab {
        case .overview: overview(event, league: league, extras: extras)
        case .stats: stats(event, league: league, extras: extras)
        case .leaders: leaders(event, extras: extras)
        case .lineups: lineups(extras)
        case .table: table(extras)
        case .form: form(event, extras: extras)
        case .info: info(event, extras: extras)
        }
    }

    private func teamColor(_ event: SportsEvent, home: Bool) -> Color {
        let side = home ? event.home : event.away
        return Color(sportsARGB: side?.team.color ?? (home ? 0xFF3A6EA5 : 0xFFB5523B))
    }

    /// The scoring so far (newest first) and the chances.
    private func overview(_ event: SportsEvent, league: League, extras: SportsGameExtras) -> some View {
        HStack(alignment: .top, spacing: 50) {
            if !extras.plays.isEmpty, !settings.hides(event), event.state != .pre {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("livetv_sports_scoring", fallback: "Scoring"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                    ForEach(Array(extras.plays.reversed().prefix(8).enumerated()), id: \.offset) { _, play in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(play.clock).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                                .frame(width: 110, alignment: .leading)
                            if let team = play.team {
                                Text(team).font(.system(size: 20, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.7).frame(width: 220, alignment: .leading)
                            }
                            Text(play.text).font(.system(size: 20)).lineLimit(2)
                            Spacer(minLength: 10)
                            if let away = play.awayScore, let home = play.homeScore {
                                Text(league.sport.homeFirst ? "\(home)–\(away)" : "\(away)–\(home)")
                                    .font(.system(size: 20, weight: .bold)).monospacedDigit()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if extras.hasOdds {
                chances(event, league: league, extras: extras)
                    .frame(width: 520)
            }
        }
    }

    /// Who's likely to win: a bar in the teams' colours (and the draw).
    private func chances(_ event: SportsEvent, league: League, extras: SportsGameExtras) -> some View {
        let home = extras.homeWin ?? 0
        let away = extras.awayWin ?? 0
        let draw = extras.draw ?? 0
        let total = max(home + away + draw, 1)
        let first = league.sport.homeFirst
        let left = first ? home : away
        let right = first ? away : home
        return VStack(alignment: .leading, spacing: 12) {
            Text(event.state == .live ? L10n.string("livetv_sports_win_chance_now", fallback: "Win chance now")
                                      : L10n.string("livetv_sports_win_chance", fallback: "Win chance"))
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
            GeometryReader { box in
                HStack(spacing: 3) {
                    Rectangle().fill(teamColor(event, home: first)).frame(width: box.size.width * CGFloat(left / total))
                    if draw > 0 { Rectangle().fill(Color.gray).frame(width: box.size.width * CGFloat(draw / total)) }
                    Rectangle().fill(teamColor(event, home: !first))
                }
            }
            .frame(height: 22)
            .clipShape(Capsule())
            HStack {
                Text(String(format: "%.0f%%", left)).font(.system(size: 24, weight: .heavy))
                Spacer()
                if draw > 0 {
                    Text(L10n.format("livetv_sports_draw_format", fallback: "Draw %@", String(format: "%.0f%%", draw)))
                        .font(.system(size: 20))
                    Spacer()
                }
                Text(String(format: "%.0f%%", right)).font(.system(size: 24, weight: .heavy))
            }
        }
    }

    /// The teams' stats side by side, with bars.
    private func stats(_ event: SportsEvent, league: League, extras: SportsGameExtras) -> some View {
        let first = league.sport.homeFirst
        return VStack(spacing: 18) {
            ForEach(extras.stats, id: \.label) { line in
                let left = first ? line.home : line.away
                let right = first ? line.away : line.home
                let leftValue = (first ? line.homeValue : line.awayValue) ?? 0
                let rightValue = (first ? line.awayValue : line.homeValue) ?? 0
                let sum = max(leftValue + rightValue, 0.0001)
                VStack(spacing: 6) {
                    HStack {
                        Text(left).font(.system(size: 24, weight: .bold)).monospacedDigit()
                        Spacer()
                        Text(line.label).font(.system(size: 18, weight: .semibold)).foregroundColor(.white.opacity(0.65))
                        Spacer()
                        Text(right).font(.system(size: 24, weight: .bold)).monospacedDigit()
                    }
                    GeometryReader { box in
                        HStack(spacing: 4) {
                            Rectangle().fill(teamColor(event, home: first)).frame(width: box.size.width * CGFloat(leftValue / sum))
                            Rectangle().fill(teamColor(event, home: !first))
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: 1000)
    }

    /// The leaders, each team's in turn, with their pictures.
    private func leaders(_ event: SportsEvent, extras: SportsGameExtras) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 30), GridItem(.flexible(), spacing: 30)], alignment: .leading, spacing: 18) {
            ForEach(Array(extras.performers.prefix(10).enumerated()), id: \.offset) { _, person in
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.12))
                        Image(systemName: "person.fill").font(.system(size: 26)).foregroundColor(.white.opacity(0.35))
                        if let url = person.photo.flatMap(URL.init(string:)) {
                            SportsImage(url: url, fill: true) { Color.clear }
                        }
                    }
                    .frame(width: 70, height: 70)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(person.teamId == event.home?.team.id ? teamColor(event, home: true)
                                                   : teamColor(event, home: false), lineWidth: 3))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.category).font(.system(size: 16, weight: .bold)).foregroundColor(.white.opacity(0.55))
                        Text([person.name, person.position].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 21, weight: .bold)).lineLimit(1)
                        Text(person.line).font(.system(size: 19)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                    }
                }
            }
        }
    }

    private func lineups(_ extras: SportsGameExtras) -> some View {
        HStack(alignment: .top, spacing: 80) {
            ForEach(Array(extras.lineups.enumerated()), id: \.offset) { _, lineup in
                VStack(alignment: .leading, spacing: 6) {
                    Text([lineup.team, lineup.formation].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 24, weight: .bold))
                        .padding(.bottom, 6)
                    ForEach(Array(lineup.players.prefix(11).enumerated()), id: \.offset) { _, player in
                        Text(player).font(.system(size: 20))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func table(_ extras: SportsGameExtras) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = extras.tableTitle {
                Text(title).font(.system(size: 22, weight: .bold)).foregroundColor(.white.opacity(0.6))
            }
            HStack {
                Text("#").frame(width: 50, alignment: .leading)
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(extras.tableHead, id: \.self) { Text($0).frame(width: 90) }
            }
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white.opacity(0.55))
            ForEach(Array(extras.table.enumerated()), id: \.offset) { _, row in
                if let group = row.group {
                    Text(group).font(.system(size: 18, weight: .bold)).foregroundColor(.white.opacity(0.55)).padding(.top, 8)
                }
                HStack {
                    Text(row.pos).frame(width: 50, alignment: .leading)
                    Text(row.team).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text(row.a).frame(width: 90)
                    Text(row.b).frame(width: 90)
                    Text(row.c).frame(width: 90)
                }
                .font(.system(size: 21, weight: row.mine ? .heavy : .regular))
                .monospacedDigit()
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(row.mine ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: 1000)
    }

    /// The last results (W, D, L as dots) and earlier meetings.
    private func form(_ event: SportsEvent, extras: SportsGameExtras) -> some View {
        HStack(alignment: .top, spacing: 80) {
            if !extras.form.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.string("livetv_sports_last_five", fallback: "Last five"))
                        .font(.system(size: 22, weight: .bold)).foregroundColor(.white.opacity(0.6))
                    ForEach(Array(extras.form.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            Text(row.team).font(.system(size: 22, weight: .bold)).frame(width: 260, alignment: .leading).lineLimit(1)
                            ForEach(Array(row.results.enumerated()), id: \.offset) { _, result in
                                Text(result)
                                    .font(.system(size: 17, weight: .heavy))
                                    .frame(width: 36, height: 36)
                                    .background(result == "W" ? Color.green : result == "L" ? Color.red : Color.gray, in: Circle())
                            }
                        }
                    }
                }
            }
            if !extras.meetings.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.string("livetv_sports_meetings", fallback: "Last meetings"))
                        .font(.system(size: 22, weight: .bold)).foregroundColor(.white.opacity(0.6))
                    ForEach(Array(extras.meetings.enumerated()), id: \.offset) { _, meeting in
                        HStack(spacing: 16) {
                            if let date = meeting.date {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 19)).foregroundColor(.white.opacity(0.6))
                                    .frame(width: 170, alignment: .leading)
                            }
                            Text(meeting.text).font(.system(size: 21, weight: .semibold))
                        }
                    }
                }
            }
        }
    }

    /// Everything known about the game, line by line on a glass panel:
    /// kick-off, competition and round, venue, weather, referee, crowd, TV,
    /// and where both teams stand.
    private func info(_ event: SportsEvent, extras: SportsGameExtras) -> some View {
        let league = SportsCatalog.league(event.leagueId)
        let table = store.standings[event.leagueId]
        var lines: [(icon: String, label: String, value: String)] = []
        let kickoff = DateFormatter()
        kickoff.setLocalizedDateFormatFromTemplate(event.hasTime ? "EEEE d MMMM yyyy jmm" : "EEEE d MMMM yyyy")
        lines.append(("calendar", L10n.string("livetv_sports_kickoff", fallback: "Kick-off"), kickoff.string(from: event.start)))
        lines.append(("trophy", L10n.string("livetv_sports_competition", fallback: "Competition"),
                      [league?.name, Self.round(event)].compactMap { $0 }.joined(separator: " · ")))
        if let venue = extras.venue ?? event.venue {
            lines.append(("mappin.and.ellipse", L10n.string("livetv_sports_venue", fallback: "Venue"),
                          [venue, extras.city ?? event.city].compactMap { $0 }.joined(separator: ", ")))
        }
        if let temp = extras.tempF {
            let celsius = Int((Double(temp) - 32) * 5 / 9)
            lines.append(("thermometer.medium", L10n.string("livetv_sports_weather", fallback: "Weather"),
                          ["\(celsius) °C", extras.conditions].compactMap { $0 }.joined(separator: " · ")))
        }
        if let referee = extras.referee {
            lines.append(("person.badge.shield.checkmark", L10n.string("livetv_sports_referee_title", fallback: "Referee"), referee))
        }
        if let attendance = extras.attendance {
            lines.append(("person.3", L10n.string("livetv_sports_attendance_title", fallback: "Attendance"), attendance.formatted()))
        }
        if !event.broadcasts.isEmpty {
            lines.append(("tv", L10n.string("livetv_sports_tv", fallback: "TV"), event.broadcasts.joined(separator: ", ")))
        }
        for side in event.ordered(league?.sport ?? .football) {
            let parts = [side.record ?? side.team.record, table?.placeText(side.team.id)].compactMap { $0 }
            if !parts.isEmpty {
                lines.append(("shield", side.team.fullName.isEmpty ? side.team.name : side.team.fullName, parts.joined(separator: " · ")))
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Image(systemName: line.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(LiveTVTheme.accent)
                        .frame(width: 36)
                    Text(line.label)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 260, alignment: .leading)
                    Text(line.value)
                        .font(.system(size: 23, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                if index < lines.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(width: 1100)
        .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .task(id: event.leagueId) { if let league { await store.loadStandings(league) } }
    }
}
