import Combine
import SwiftUI

/// Fork (Live TV step 17b): the Sports page, as Android's: on top the sports
/// of the day and the days around; below the day's games by league, two in
/// a row, each in its teams' colours, the one in focus described on the
/// right. Scores come from ESPN (no key).
struct SportsView: View {
    @ObservedObject private var store = SportsStore.shared
    @ObservedObject private var settings = SportsSettings.shared
    @State private var sport: Sport?
    /// My Teams, the day's games, or the tables (17d, as Android's chips).
    @State private var page: Page = .events
    @State private var liveOnly = false
    @State private var focusedID: String?
    @State private var showsQuickMenu = false
    @State private var showsLeagues = false
    /// The game page open (17c).
    @State private var openGame: SportsGameID?
    /// Redrawn every 30 s (clocks, time bars, Today).
    @State private var tick = Date()

    enum Page { case myTeams, events, tables }

    private static let cardWidth: CGFloat = 380
    private static let paneWidth: CGFloat = 60 + 2 * cardWidth + 28 + 30
    private static let columns = [GridItem(.fixed(cardWidth), spacing: 28, alignment: .top),
                                  GridItem(.fixed(cardWidth), spacing: 28, alignment: .top)]

    private var allGames: [(league: League, events: [SportsEvent])] { store.games(day: store.dayOffset, now: tick) }

    private var shown: [(league: League, events: [SportsEvent])] {
        allGames.compactMap { item in
            guard sport == nil || item.league.sport == sport else { return nil }
            let events = liveOnly ? item.events.filter { $0.state == .live } : item.events
            return events.isEmpty ? nil : (item.league, events)
        }
    }

    var body: some View {
        let games = shown
        let focused = games.flatMap(\.events).first { $0.id == focusedID } ?? games.first?.events.first
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 60)
                .padding(.top, 30)
                .focusSection()
            switch page {
            case .myTeams:
                SportsMyTeamsView(now: tick, onOpen: { openGame = SportsGameID(id: $0.id) })
                    .focusSection()
            case .tables:
                SportsTablesView()
                    .focusSection()
            case .events:
            dayStrip
                .padding(.top, 14)
                .focusSection()
            HStack(alignment: .top, spacing: 30) {
                // Its own section: down from any day lands on a game, even
                // one not right below it.
                list(games)
                    .frame(width: Self.paneWidth)
                    .focusSection()
                GeometryReader { box in
                    details(focused, width: max(box.size.width - 56, 200))
                        .padding(28)
                        .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)
                        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .padding(.top, 20)
                .padding(.bottom, 40)
                .padding(.trailing, 60)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(showsQuickMenu)
        .background(alignment: .top) { backdrop(page == .events ? focused : nil) }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if showsQuickMenu {
                SportsQuickMenu(onLeagues: { showsQuickMenu = false; showsLeagues = true },
                                onClose: { showsQuickMenu = false })
                    .padding(.top, 20)
                    .padding(.trailing, 40)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsQuickMenu)
        .fullScreenCover(isPresented: $showsLeagues) { SportsLeaguesPicker() }
        .fullScreenCover(item: $openGame) { game in SportsGamePage(eventID: game.id) }
        .onAppear {
            settings.reload()
            store.setVisible(true)
        }
        .onDisappear { store.setVisible(false) }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { tick = $0 }
    }

    // MARK: Header

    /// All, the sports of the day, Live; on the right the quick menu and
    /// Refresh.
    private var header: some View {
        let games = allGames
        let order = SportsCatalog.sportsOrder(region: settings.effectiveRegion)
        let sports = Set(games.map(\.league.sport))
        let liveCount = games.reduce(0) { $0 + $1.events.filter { $0.state == .live }.count }
        return HStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    chip("★ " + L10n.string("livetv_sports_my_teams", fallback: "My Teams"), selected: page == .myTeams) {
                        page = .myTeams
                        store.loadFollowed()
                    }
                    chip(L10n.string("livetv_sports_all", fallback: "All Events"), selected: page == .events && sport == nil && !liveOnly) {
                        page = .events
                        sport = nil
                        liveOnly = false
                    }
                    chip(liveCount > 0 ? L10n.format("livetv_sports_live_count", fallback: "Live (%d)", liveCount)
                                       : L10n.string("livetv_sports_live", fallback: "Live"), selected: page == .events && liveOnly) {
                        page = .events
                        liveOnly.toggle()
                    }
                    chip("🏆 " + L10n.string("livetv_sports_tables", fallback: "Tables"), selected: page == .tables) {
                        page = .tables
                    }
                    ForEach(order.filter { sports.contains($0) }, id: \.self) { item in
                        chip(item.icon + " " + item.label, selected: page == .events && sport == item) {
                            page = .events
                            sport = sport == item ? nil : item
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            Spacer(minLength: 12)
            if store.pending > 0 { ProgressView() }
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityLabel(L10n.string("livetv_refresh", fallback: "Refresh"))
            }
            Button {
                showsQuickMenu = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityLabel(L10n.string("livetv_sports_quick_menu", fallback: "Sports options"))
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 22, weight: selected ? .bold : .regular))
        }
    }

    /// A week back to a week ahead.
    private var dayStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(-SportsStore.daysBack...SportsStore.daysAhead, id: \.self) { offset in
                        Button {
                            store.dayOffset = offset
                            focusedID = nil
                        } label: {
                            Text(Self.dayTitle(offset))
                                .font(.system(size: 20, weight: store.dayOffset == offset ? .bold : .regular))
                                .foregroundColor(store.dayOffset == offset ? LiveTVTheme.accent : nil)
                        }
                        .id(offset)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(store.dayOffset, anchor: .center) }
        }
    }

    static func dayTitle(_ offset: Int) -> String {
        switch offset {
        case 0: return L10n.string("livetv_cal_today", fallback: "Today")
        case -1: return L10n.string("livetv_cal_yesterday", fallback: "Yesterday")
        case 1: return L10n.string("livetv_cal_tomorrow", fallback: "Tomorrow")
        default:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE d")
            return formatter.string(from: SportsStore.dayStart(offset))
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        switch LiveTVSettings.shared.clock {
        case .hours24: formatter.dateFormat = "HH:mm"
        case .hours12: formatter.dateFormat = "h:mm a"
        case .system: formatter.setLocalizedDateFormatFromTemplate("jmm")
        }
        return formatter.string(from: date)
    }

    // MARK: Games

    @ViewBuilder
    private func list(_ games: [(league: League, events: [SportsEvent])]) -> some View {
        if games.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: store.pending > 0 ? "hourglass" : "sportscourt")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.6))
                Text(store.pending > 0
                     ? L10n.string("livetv_sports_loading", fallback: "Getting the games…")
                     : (liveOnly ? L10n.string("livetv_sports_none_live", fallback: "Nothing live right now.")
                                 : L10n.string("livetv_sports_none", fallback: "No games this day in your leagues. Add leagues with the gear (Leagues).")))
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 700)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    ForEach(games, id: \.league.id) { item in
                        VStack(alignment: .leading, spacing: 14) {
                            leagueHeader(item.league, count: item.events.count)
                            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 24) {
                                ForEach(item.events) { event in
                                    SportsGameCard(event: event, league: item.league, width: Self.cardWidth,
                                                   hideScores: settings.hides(event), now: tick,
                                                   onFocus: { focusedID = event.id },
                                                   onOpen: { openGame = SportsGameID(id: event.id) })
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 60)
                .padding(.vertical, 20)
            }
        }
    }

    private func leagueHeader(_ league: League, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let logo = store.leagueLogos[league.id].flatMap(URL.init(string:)) {
                    AsyncImage(url: logo) { phase in
                        if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fit) }
                    }
                    .frame(width: 36, height: 36)
                } else {
                    Text(league.short)
                        .font(.system(size: 15, weight: .heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(sportsARGB: league.color), in: Capsule())
                }
                Text(league.name)
                    .font(.system(size: 28, weight: .bold))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 18, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            Rectangle().fill(Color.white.opacity(0.25)).frame(height: 2)
        }
        .frame(width: 2 * Self.cardWidth + 28)
    }

    // MARK: The game in focus

    @ViewBuilder
    private func backdrop(_ event: SportsEvent?) -> some View {
        // The two teams' colours, washed out to the dark.
        let colors = (event?.sides ?? []).compactMap { $0.team.color }.map { Color(sportsARGB: $0) }
        ZStack {
            if colors.count == 2 {
                LinearGradient(colors: [colors[0].opacity(0.55), colors[1].opacity(0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: event?.id)
    }

    @ViewBuilder
    private func details(_ event: SportsEvent?, width: CGFloat) -> some View {
        if let event, let league = SportsCatalog.league(event.leagueId) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    if let logo = store.leagueLogos[league.id].flatMap(URL.init(string:)) {
                        AsyncImage(url: logo) { phase in
                            if case .success(let image) = phase { image.resizable().aspectRatio(contentMode: .fit) }
                        }
                        .frame(width: 30, height: 30)
                    }
                    Text(league.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                    if event.state == .live { SportsLiveBadge() }
                }
                if event.sides.count == 2 {
                    SportsMatchup(event: event, league: league, hideScores: settings.hides(event), width: width)
                } else {
                    Text(event.title)
                        .font(.system(size: 40, weight: .bold))
                        .lineLimit(3)
                }
                Text(Self.whenLine(event, hideScores: settings.hides(event)))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(LiveTVTheme.accent)
                if let situation = event.situation, !settings.hides(event) {
                    Text(situation).font(.system(size: 21)).foregroundColor(.white.opacity(0.8))
                }
                if let note = event.note {
                    Text(note).font(.system(size: 20)).foregroundColor(.white.opacity(0.7))
                }
                if let subtitle = event.subtitle {
                    Label(subtitle, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
                if !event.broadcasts.isEmpty {
                    Label(event.broadcasts.prefix(5).joined(separator: ", "), systemImage: "tv")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
                if !settings.hides(event), event.state != .pre {
                    SportsPeriodTable(event: event, league: league)
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
    }

    /// "Today · 20:30", "2nd Half · 67'", "Final".
    static func whenLine(_ event: SportsEvent, hideScores: Bool) -> String {
        switch event.state {
        case .pre:
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
            let day = Calendar.current.isDateInToday(event.start) ? L10n.string("livetv_cal_today", fallback: "Today")
                : Calendar.current.isDateInTomorrow(event.start) ? L10n.string("livetv_cal_tomorrow", fallback: "Tomorrow")
                : formatter.string(from: event.start)
            return event.hasTime ? day + " · " + clock(event.start) : day
        case .live:
            return hideScores ? L10n.string("livetv_sports_live", fallback: "Live") : (event.status ?? L10n.string("livetv_sports_live", fallback: "Live"))
        case .post:
            return hideScores ? L10n.string("livetv_sports_over", fallback: "Over") : (event.status ?? "Final")
        case .off:
            return event.status ?? "Postponed"
        }
    }
}

/// A game: the league and when on top, then each team on its colour with
/// its logo, name and score; a time bar while it's on.
struct SportsGameCard: View {
    let event: SportsEvent
    let league: League
    let width: CGFloat
    let hideScores: Bool
    let now: Date
    /// The day too (My Teams: games of other days).
    var withDate = false
    let onFocus: () -> Void
    let onOpen: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if event.state == .live { SportsLiveBadge() }
                    Text(when)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let tv = event.broadcasts.first {
                        Text(tv)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                if event.sides.count == 2 {
                    ForEach(Array(event.ordered(league.sport).enumerated()), id: \.offset) { _, side in
                        band(side)
                    }
                } else {
                    Text(event.title)
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(2)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                        .background(Color(sportsARGB: league.color).opacity(0.6))
                    if let note = event.note {
                        Text(note).font(.system(size: 16)).foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 14).frame(height: 28)
                    }
                }
                // How far the game is.
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.12))
                        Rectangle().fill(LiveTVTheme.accent).frame(width: box.size.width * progress)
                    }
                }
                .frame(height: 4)
                .opacity(event.state == .live ? 1 : 0)
            }
            .foregroundColor(.white)
            .frame(width: width)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(focused ? Color.white : Color.white.opacity(0.1), lineWidth: focused ? 4 : 1))
            .scaleEffect(focused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
        .onChange(of: focused) { _, now in if now { onFocus() } }
    }

    /// "Sat 29 Nov · FT" for another day (My Teams), else the state.
    private var when: String {
        let line = SportsView.whenLine(event, hideScores: hideScores)
        guard withDate, event.state != .pre, !Calendar.current.isDateInToday(event.start) else { return line }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: event.start) + " · " + line
    }

    /// The clock's share of the game, else the time since the start
    /// against the league's usual length.
    private var progress: CGFloat {
        if let value = event.progress { return CGFloat(value) }
        let done = now.timeIntervalSince(event.start) / Double(league.minutes * 60)
        return CGFloat(min(max(done, 0.02), 0.98))
    }

    private func band(_ side: SportsSide) -> some View {
        let argb = side.team.color ?? side.team.altColor ?? 0xFF333A45
        let color = Color(sportsARGB: argb)
        let showScore = event.hasScore && !hideScores
        let lost = showScore && event.state == .post && !side.winner && event.sides.contains { $0.winner }
        return HStack(spacing: 12) {
            SportsTeamLogo(team: side.team, size: 40)
            Text(side.team.name)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            if showScore {
                Text(side.score ?? "")
                    .font(.system(size: 28, weight: .heavy))
                    .monospacedDigit()
            }
        }
        .foregroundColor(SportsColors.isLight(argb) ? .black : .white)
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(
            LinearGradient(colors: [color, color.opacity(SportsColors.isLight(argb) ? 0.85 : 0.5)], startPoint: .leading, endPoint: .trailing))
        .opacity(lost ? 0.6 : 1)
    }
}

/// A team's logo on a light disc (ESPN's logos are made for light
/// backgrounds), else its short name.
struct SportsTeamLogo: View {
    let team: TeamInfo
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.92))
            if let url = SportsTeamLogo.url(team.logo, size: size) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fit).padding(size * 0.14)
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
    }

    private var initials: some View {
        Text(team.abbr.isEmpty ? String(team.name.prefix(3)).uppercased() : team.abbr)
            .font(.system(size: size * 0.28, weight: .heavy))
            .foregroundColor(.black.opacity(0.75))
            .minimumScaleFactor(0.5)
    }

    /// ESPN's logos at the size shown (its own resizer).
    static func url(_ link: String?, size: CGFloat) -> URL? {
        guard let link, let url = URL(string: link) else { return nil }
        guard url.host?.hasSuffix("espncdn.com") == true else { return url }
        let pixels = Int(size * 2)
        return URL(string: "https://a.espncdn.com/combiner/i?img=\(url.path)&w=\(pixels)&h=\(pixels)") ?? url
    }
}

struct SportsLiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: 14, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.red, in: Capsule())
    }
}

/// The Sports page's quick menu (the gear, as the guide's and the
/// calendar's).
private struct SportsQuickMenu: View {
    let onLeagues: () -> Void
    let onClose: () -> Void
    @ObservedObject private var settings = SportsSettings.shared
    @FocusState private var focused: Int?
    @State private var choosingRegion = false
    @State private var choosingScores = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("livetv_sports_quick_menu", fallback: "Sports options"))
                .font(.system(size: LiveTVTheme.Font.secondary, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            LiveTVQuickRow(title: L10n.string("livetv_sports_scores", fallback: "Scores"),
                           value: settings.scoreMode.title, isFocused: focused == 0) { choosingScores = true }
                .focused($focused, equals: 0)
                .confirmationDialog(L10n.string("livetv_sports_scores", fallback: "Scores"), isPresented: $choosingScores,
                                    titleVisibility: .visible) {
                    ForEach(SportsSettings.ScoreMode.allCases, id: \.self) { mode in
                        Button(mode.title) { settings.scoreMode = mode }
                    }
                    Button(L10n.string("cancel", fallback: "Cancel"), role: .cancel) {}
                } message: {
                    Text(L10n.string("livetv_sports_scores_detail", fallback: "Hide Live Scores: results of games that are over show, running games don't."))
                }
            LiveTVQuickRow(title: L10n.string("livetv_sports_region", fallback: "Your Region"),
                           value: settings.region.isEmpty
                               ? L10n.format("livetv_settings_calendar_zone_device", fallback: "Apple TV: %@",
                                             SportsCatalog.regionName(settings.effectiveRegion))
                               : SportsCatalog.regionName(settings.region),
                           isFocused: focused == 1) {
                choosingRegion = true
            }
            .focused($focused, equals: 1)
            .confirmationDialog(L10n.string("livetv_sports_region", fallback: "Your Region"), isPresented: $choosingRegion,
                                titleVisibility: .visible) {
                Button(L10n.format("livetv_settings_calendar_zone_device", fallback: "Apple TV: %@",
                                   SportsCatalog.regionName(SportsCatalog.region(ofCountry: SportsSettings.country)))) {
                    settings.region = ""
                }
                ForEach(SportsCatalog.regions, id: \.code) { region in
                    Button(region.name) { settings.region = region.code }
                }
                Button(L10n.string("cancel", fallback: "Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("livetv_sports_region_detail", fallback: "Which leagues are on at first (your own country's football is always on)."))
            }
            LiveTVQuickRow(title: L10n.string("livetv_sports_leagues", fallback: "Leagues…"),
                           value: "\(settings.shownLeagues.count)", isFocused: focused == 2, action: onLeagues)
                .focused($focused, equals: 2)
        }
        .padding(18)
        .frame(width: 720)
        .liveTVGlass(cornerRadius: 24)
        .focusSection()
        .onAppear { focused = 0 }
        .onExitCommand(perform: onClose)
    }
}

/// Which leagues All Events shows, by sport (as Android's Leagues dialog).
private struct SportsLeaguesPicker: View {
    @ObservedObject private var settings = SportsSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let order = SportsCatalog.sportsOrder(region: settings.effectiveRegion)
        let leagues = SportsCatalog.all.filter(\.hasFeed)
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("livetv_sports_leagues_title", fallback: "Leagues in All Events"))
                        .font(.system(size: 38, weight: .bold))
                    Text(L10n.string("livetv_sports_leagues_detail", fallback: "Your region's leagues are on; turn any on or off."))
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.bottom, 10)
                    ForEach(order, id: \.self) { sport in
                        let list = leagues.filter { $0.sport == sport }
                        if !list.isEmpty {
                            Text(sport.icon + " " + sport.label)
                                .font(.system(size: 26, weight: .bold))
                                .padding(.top, 16)
                            ForEach(list) { league in
                                SportsLeagueRow(league: league)
                            }
                        }
                    }
                }
                .padding(60)
            }
        }
        .onExitCommand { dismiss() }
    }
}

/// One league, on or off.
private struct SportsLeagueRow: View {
    let league: League
    @ObservedObject private var settings = SportsSettings.shared
    @FocusState private var focused: Bool

    var body: some View {
        LiveTVQuickRow(title: league.name, isOn: settings.isShown(league), isFocused: focused) {
            settings.toggle(league)
        }
        .focused($focused)
        .frame(width: 900)
    }
}

extension Color {
    /// A colour from 0xAARRGGBB.
    init(sportsARGB argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

/// A game page to open (by the game's id).
struct SportsGameID: Identifiable, Hashable {
    let id: String
}

enum SportsColors {
    /// Light enough for dark text on it (white, yellow, light blue).
    static func isLight(_ argb: UInt32) -> Bool {
        let r = Double((argb >> 16) & 0xFF), g = Double((argb >> 8) & 0xFF), b = Double(argb & 0xFF)
        return 0.299 * r + 0.587 * g + 0.114 * b > 170
    }
}

/// The two teams big: logo, name, record, and the score (or kick-off)
/// between them.
struct SportsMatchup: View {
    let event: SportsEvent
    let league: League
    let hideScores: Bool
    let width: CGFloat
    var logoSize: CGFloat = 110

    var body: some View {
        let sides = event.ordered(league.sport)
        let showScore = event.hasScore && !hideScores
        HStack(alignment: .center, spacing: 20) {
            column(sides[0], dim: showScore && event.state == .post && !sides[0].winner && sides[1].winner)
            Group {
                if showScore {
                    Text("\(sides[0].score ?? "") – \(sides[1].score ?? "")")
                        .font(.system(size: logoSize * 0.5, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                } else {
                    Text(event.state == .pre && event.hasTime ? SportsView.clock(event.start) : "VS")
                        .font(.system(size: logoSize * 0.4, weight: .heavy))
                }
            }
            .frame(width: 160 * logoSize / 110)
            column(sides[1], dim: showScore && event.state == .post && !sides[1].winner && sides[0].winner)
        }
        .frame(width: width)
    }

    private func column(_ side: SportsSide, dim: Bool) -> some View {
        VStack(spacing: 10) {
            SportsTeamLogo(team: side.team, size: logoSize)
            Text(side.team.fullName.isEmpty ? side.team.name : side.team.fullName)
                .font(.system(size: 24 * max(1, logoSize / 110 * 0.9), weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let record = side.record ?? side.team.record {
                Text(record).font(.system(size: 18)).foregroundColor(.white.opacity(0.6))
            }
        }
        .frame(width: max((width - 200 * logoSize / 110) / 2, 100))
        .opacity(dim ? 0.55 : 1)
    }
}

/// Score per period, when the feed has it.
struct SportsPeriodTable: View {
    let event: SportsEvent
    let league: League

    var body: some View {
        let sides = event.ordered(league.sport)
        let count = sides.map(\.periods.count).max() ?? 0
        if sides.count == 2, count > 1, count <= 12 {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(sides.enumerated()), id: \.offset) { _, side in
                    HStack(spacing: 0) {
                        Text(side.team.abbr.isEmpty ? side.team.name : side.team.abbr)
                            .font(.system(size: 20, weight: .bold))
                            .frame(width: 90, alignment: .leading)
                        ForEach(0..<count, id: \.self) { index in
                            Text(index < side.periods.count ? side.periods[index] : "")
                                .font(.system(size: 20))
                                .monospacedDigit()
                                .frame(width: 44)
                        }
                        Text(side.score ?? "")
                            .font(.system(size: 20, weight: .heavy))
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}
