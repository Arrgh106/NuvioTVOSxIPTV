import Combine
import SwiftUI
import UIKit

/// The calendar (step 16), as Android's: on top a big picture of the card
/// in focus; below it the List (Upcoming / Recently aired, a row of wide
/// cards per day), the Week (a column per day) or the Month (a grid of days,
/// the chosen day's cards above it).
struct LiveTVCalendarView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case list
        case week
        case month
        var id: String { rawValue }

        var title: String {
            switch self {
            case .list: return L10n.string("livetv_cal_list", fallback: "List")
            case .week: return L10n.string("livetv_cal_week", fallback: "Week")
            case .month: return L10n.string("livetv_cal_month", fallback: "Month")
            }
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case upcoming
        case recent
        case airing
        case following
        case hidden
        var id: String { rawValue }

        var title: String {
            switch self {
            case .upcoming: return L10n.string("livetv_cal_upcoming", fallback: "Upcoming")
            case .recent: return L10n.string("livetv_cal_recent", fallback: "Recently aired")
            case .airing: return L10n.string("livetv_cal_airing", fallback: "Airing today")
            case .following: return L10n.string("livetv_cal_following", fallback: "Following")
            case .hidden: return L10n.string("livetv_cal_hidden", fallback: "Hidden")
            }
        }
    }

    /// Airing today's filters (as Android's).
    enum AiringFilter: String, CaseIterable, Identifiable {
        case all, prime, streaming, following
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L10n.string("livetv_cal_airing_all", fallback: "All")
            case .prime: return L10n.string("livetv_cal_airing_prime", fallback: "Prime time")
            case .streaming: return L10n.string("livetv_cal_airing_streaming", fallback: "Streaming")
            case .following: return L10n.string("livetv_cal_following", fallback: "Following")
            }
        }
    }

    /// Opens a card's show or film page (on its episode).
    let onOpen: (LiveTVCalendarEntry) -> Void

    @ObservedObject private var store = LiveTVCalendarStore.shared
    @ObservedObject private var about = LiveTVCalendarAbout.shared
    @State private var tab: Tab = .upcoming
    @State private var unwatchedOnly = LiveTVCalendarSettings.unwatchedOnly
    @State private var focusedKey: String?
    @State private var mode = Mode(rawValue: LiveTVCalendarSettings.view) ?? .list
    @State private var airingFilter: AiringFilter = .all
    /// Upcoming: only episodes in your Live TV guide (16d, Android's On my TV).
    @State private var onMyTV = false
    /// OK on an episode in your guide: its Live TV options (16e).
    @State private var liveChoice: LiveTVCalendarEntry?
    /// The calendar's quick menu (the gear, as the guide's).
    @State private var showsQuickMenu = false

    private var shown: [LiveTVCalendarEntry] {
        let now = Date()
        switch tab {
        case .upcoming:
            let list = LiveTVCalendarLogic.upcoming(store.entries, now: now, zone: LiveTVCalendarSettings.timeZone)
            return onMyTV && mode == .list ? list.filter { store.onTV[$0.key] != nil } : list
        case .recent: return LiveTVCalendarLogic.recent(store.entries, now: now, zone: LiveTVCalendarSettings.timeZone, unwatchedOnly: unwatchedOnly)
        case .airing: return airingShown
        case .following: return followingCards
        case .hidden: return []
        }
    }

    /// Upcoming / Recently aired: your own calendar, in List, Week or Month.
    private var ownCalendar: Bool { tab == .upcoming || tab == .recent }

    /// As Android's: in Week and Month, Upcoming and Recently aired are one
    /// tab, My calendar. Hidden only while there are any.
    private var tabs: [Tab] {
        Tab.allCases.filter { item in
            if item == .hidden { return !store.hidden.isEmpty }
            if item == .recent { return mode == .list }
            return true
        }
    }

    private func tabTitle(_ item: Tab) -> String {
        item == .upcoming && mode != .list ? L10n.string("livetv_cal_mine", fallback: "My calendar") : item.title
    }

    /// Airing today through its filter.
    private var airingShown: [LiveTVCalendarEntry] {
        let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = LiveTVCalendarSettings.timeZone
            return calendar
        }()
        return store.airing.filter { entry in
            switch airingFilter {
            case .all: return true
            case .prime: return entry.air.map { (19...22).contains(calendar.component(.hour, from: $0)) } ?? false
            case .streaming: return entry.streaming
            case .following: return entry.followed
            }
        }
    }

    /// Following: each title's next episode, else its last one, else a card
    /// saying nothing is announced yet.
    private var followingCards: [LiveTVCalendarEntry] {
        let today = LiveTVCalendarLogic.day(of: Date(), in: LiveTVCalendarSettings.timeZone)
        var byTitle: [String: [LiveTVCalendarEntry]] = [:]
        for entry in store.entries { byTitle[entry.contentID, default: []].append(entry) }
        return store.followed.map { follow in
            let list = byTitle[follow.id] ?? []
            if let next = list.first(where: { $0.day >= today }) { return next }
            if let last = list.last { return last }
            return LiveTVCalendarEntry(
                key: "follow|" + follow.id, kind: follow.series ? .episode : .movie, contentID: follow.id,
                title: follow.title, poster: follow.poster, background: follow.background, day: today,
                note: follow.series
                    ? L10n.string("livetv_cal_nothing_yet", fallback: "Nothing announced yet")
                    : L10n.string("livetv_cal_waiting", fallback: "Waiting to come out"),
                reasons: [.bell])
        }
    }

    /// The cards by day, in the list's order.
    private var days: [(day: String, entries: [LiveTVCalendarEntry])] {
        var result: [(day: String, entries: [LiveTVCalendarEntry])] = []
        for entry in shown {
            if result.last?.day == entry.day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((entry.day, [entry]))
            }
        }
        return result
    }

    var body: some View {
        let list = days
        let focused = (ownCalendar && mode != .list ? store.entries : shown).first { $0.key == focusedKey }
            ?? (ownCalendar ? list.first?.entries.first : shown.first)
        VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 60)
                    .padding(.top, 30)
                    .focusSection()
                // Without TMDB: no films, wide pictures or logos.
                if !LiveTVCalendarSources.tmdbReady {
                    Label(L10n.string("livetv_cal_tmdb_off", fallback: "Films, pictures and logos need TMDB: turn it on and add your API key in Settings → TMDB"),
                          systemImage: "info.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 60)
                        .padding(.top, 8)
                }
                if !ownCalendar {
                    switch tab {
                    case .airing: airingContent(focused)
                    case .following:
                        twoPane(focused) {
                            grid(followingCards, empty: L10n.string("livetv_cal_following_empty", fallback: "Ring the bell on a show's or film's page (or hold OK on a card) and it shows up here."))
                        }
                    default: hiddenContent
                    }
                } else {
                switch mode {
                case .list:
                    twoPane(focused) { content(list) }
                case .week:
                    LiveTVCalendarWeek(
                        entries: store.entries,
                        details: AnyView(details(focused, compact: true)
                            .padding(.horizontal, 60)
                            .frame(height: 150, alignment: .topLeading)),
                        onFocus: { focusedKey = $0.key }, onOpen: choose)
                        .padding(.top, 16)
                case .month:
                    LiveTVCalendarMonth(entries: store.entries, onFocus: { focusedKey = $0.key }, onOpen: choose)
                        .padding(.top, 16)
                }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(showsQuickMenu)
        // The quick menu, top right over the calendar, which changes as the
        // options change.
        .overlay(alignment: .topTrailing) {
            if showsQuickMenu {
                LiveTVCalendarQuickMenu(
                    unwatchedOnly: Binding(get: { unwatchedOnly }, set: {
                        unwatchedOnly = $0
                        LiveTVCalendarSettings.unwatchedOnly = $0
                    }),
                    onMyTV: Binding(get: { onMyTV }, set: { onMyTV = $0; focusedKey = nil }),
                    onClose: { showsQuickMenu = false })
                    .padding(.top, 20)
                    .padding(.trailing, 40)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsQuickMenu)
        .onReceive(LiveTVSettings.shared.$calendarSkipNewsTalk.dropFirst()) { _ in
            if tab == .airing { DispatchQueue.main.async { store.loadAiring() } }
        }
        // The big picture behind (out to the screen's edges): as a sibling
        // it made the page wider than the screen.
        .background(alignment: .top) { hero(focused) }
        .background(Color.black.ignoresSafeArea())
        // The text, ratings and cast of the card in focus.
        .task(id: focused?.key) { about.want(focused) }
        .onAppear {
            store.opened()
            if tab == .airing { store.loadAiring() }
        }
        .onChange(of: tab) { _, now in if now == .airing { store.loadAiring() } }
        .confirmationDialog(liveChoice?.title ?? "", isPresented: Binding(
            get: { liveChoice != nil }, set: { if !$0 { liveChoice = nil } }
        ), titleVisibility: .visible, presenting: liveChoice) { entry in
            liveOptions(entry)
        } message: { entry in
            if let onTV = store.onTV[entry.key] {
                Text(onTV.channelName + " · " + Self.clock(onTV.start) + "–" + Self.clock(onTV.end))
            }
        }
    }

    /// OK on a card: an episode in your Live TV guide opens its Live TV
    /// options (Settings → Calendar → OK on an Episode in Your Guide), else
    /// the show's or film's page.
    private func choose(_ entry: LiveTVCalendarEntry) {
        if LiveTVSettings.shared.calendarOkAction == "live", let onTV = store.onTV[entry.key], onTV.end > Date(),
           LiveTVStore.shared.channel(id: onTV.channelID) != nil {
            liveChoice = entry
        } else {
            onOpen(entry)
        }
    }

    @ViewBuilder
    private func liveOptions(_ entry: LiveTVCalendarEntry) -> some View {
        if let onTV = store.onTV[entry.key], let channel = LiveTVStore.shared.channel(id: onTV.channelID) {
            let now = Date()
            if now >= onTV.start.addingTimeInterval(-10 * 60) {
                Button(L10n.format("livetv_cal_watch_live_format", fallback: "Watch live on %@", channel.name)) {
                    LiveTVWatch.shared.watch(LiveTVWatchRequest(channelID: channel.streamID))
                }
            }
            if onTV.start > now {
                let set = LiveTVReminders.shared.isSet(channelID: channel.streamID, start: onTV.start)
                Button(set
                       ? L10n.string("livetv_cal_remind_off", fallback: "Don't remind me")
                       : L10n.format("livetv_cal_remind_format", fallback: "Remind me (%@, %@)",
                                     channel.name, Self.clock(onTV.start))) {
                    LiveTVReminders.shared.toggle(
                        channel: channel,
                        programme: XtreamProgram(title: onTV.title, description: nil, start: onTV.start, end: onTV.end))
                }
            }
        }
        Button(L10n.string(entry.kind == .movie ? "livetv_cal_open_film" : "livetv_cal_open_show",
                           fallback: entry.kind == .movie ? "Open the film's page" : "Open the show's page")) {
            onOpen(entry)
        }
        Button(L10n.string("cancel", fallback: "Cancel"), role: .cancel) {}
    }

    // MARK: Airing today, Following, Hidden (16c)

    /// The cards on the left (two in a row), the one in focus described on
    /// the right, where the big picture leaves room.
    private func twoPane<Left: View>(_ focused: LiveTVCalendarEntry?, @ViewBuilder left: () -> Left) -> some View {
        HStack(alignment: .top, spacing: 30) {
            left()
                .frame(width: Self.paneWidth)
            // On a dark glass: the big picture shows through, the text reads.
            // One box of the same size and place for every card, so going
            // through the cards moves nothing; what doesn't fit is cut.
            GeometryReader { box in
                details(focused, compact: false, width: max(box.size.width - 56, 200))
                    .padding(28)
                    .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)
                    .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(.top, 30)
            .padding(.bottom, 40)
            .padding(.trailing, 60)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Two cards of `cardWidth` and the room around them.
    private static let cardWidth: CGFloat = 380
    private static let paneWidth: CGFloat = 60 + 2 * cardWidth + 28 + 30

    private func airingContent(_ focused: LiveTVCalendarEntry?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach(AiringFilter.allCases) { item in
                    Button {
                        airingFilter = item
                        focusedKey = nil
                    } label: {
                        Text(item.title).font(.system(size: 20, weight: airingFilter == item ? .bold : .regular))
                    }
                }
                Spacer()
                if store.airingLoading { ProgressView() }
                Text(LiveTVCalendarSettings.country)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 60)
            .focusSection()
            .padding(.top, 14)
            twoPane(focused) {
                grid(airingShown, empty: store.airingLoading
                     ? L10n.string("livetv_cal_loading", fallback: "Getting the dates of your shows and films…")
                     : L10n.string("livetv_cal_airing_empty", fallback: "No new episodes today."))
            }
        }
    }

    /// Cards in rows (Airing today, Following).
    @ViewBuilder
    private func grid(_ entries: [LiveTVCalendarEntry], empty: String) -> some View {
        if entries.isEmpty {
            Text(empty)
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 30) {
                    ForEach(entries) { entry in
                        LiveTVCalendarCard(entry: entry, width: Self.cardWidth, onTV: store.onTV[entry.key],
                                           onFocus: { focusedKey = entry.key }, onOpen: { choose(entry) })
                    }
                }
                .padding(.leading, 60)
                .padding(.vertical, 24)
            }
        }
    }

    private var hiddenContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("livetv_cal_hidden_detail", fallback: "OK shows a title in the calendar again."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
                ForEach(store.hidden) { item in
                    Button {
                        store.unhide(item.id)
                        if store.hidden.isEmpty { tab = .upcoming }
                    } label: {
                        Label(item.name, systemImage: "eye.slash")
                            .font(.system(size: 24))
                            .frame(maxWidth: 700, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 20)
        }
    }

    // MARK: Header

    /// One row, as Android's: the tabs on the left; for your own calendar
    /// List / Week / Month on the right, then Refresh.
    private var header: some View {
        HStack(spacing: 14) {
            ForEach(tabs) { item in
                Button {
                    tab = item
                    focusedKey = nil
                } label: {
                    Text(tabTitle(item))
                        .font(.system(size: 22, weight: tab == item || (item == .upcoming && tab == .recent && mode != .list) ? .bold : .regular))
                }
            }
            // On my TV and Unwatched only are in the quick menu (the gear).
            Spacer(minLength: 12)
            if let progress = store.progress, progress.total > 0 {
                Text(L10n.format("livetv_cal_progress_format", fallback: "Updating %d of %d", progress.done, progress.total))
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.6))
            } else if store.isLoading {
                ProgressView()
            }
            if ownCalendar {
                // The same buttons as the tabs on the left.
                ForEach(Mode.allCases) { item in
                    Button {
                        guard mode != item else { return }
                        mode = item
                        focusedKey = nil
                        LiveTVCalendarSettings.view = item.rawValue
                        if item != .list, tab == .recent { tab = .upcoming }
                    } label: {
                        Text(item.title)
                            .font(.system(size: 22, weight: mode == item ? .bold : .regular))
                    }
                }
            }
            Button {
                if tab == .airing { store.loadAiring(force: true) } else { store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityLabel(L10n.string("livetv_refresh", fallback: "Refresh"))
            }
            .disabled(store.isLoading)
            Button {
                showsQuickMenu = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityLabel(L10n.string("livetv_cal_quick_menu", fallback: "Calendar options"))
            }
        }
    }

    // MARK: The card in focus

    private func hero(_ entry: LiveTVCalendarEntry?) -> some View {
        ZStack {
            if let url = entry.flatMap(Self.heroImage) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.black
                    }
                }
                .id(url)
                .transition(.opacity)
            }
            // The whole screen: darker under the cards on the left and
            // towards the bottom, so text reads on any picture.
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.55), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0.45), .black.opacity(0.15)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: entry?.key)
    }

    private static func heroImage(_ entry: LiveTVCalendarEntry) -> URL? {
        (entry.background ?? entry.poster).flatMap(URL.init(string:))
    }

    /// The card in focus: its logo (or title), episode, when and where, and
    /// what it's about. `compact`: one short block above the Week.
    private func details(_ entry: LiveTVCalendarEntry?, compact: Bool, width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            if let entry {
                // The show's own logo when TMDB has one, else its title.
                if let logo = entry.titleLogo.flatMap(URL.init(string:)) {
                    LiveTVCalendarLogo(url: logo, style: .title,
                                       box: compact ? CGSize(width: 360, height: 60) : CGSize(width: 560, height: 130),
                                       area: compact ? 9_000 : 30_000, alignment: .bottomLeading) {
                        Text(entry.title).font(.system(size: compact ? 32 : 44, weight: .bold)).lineLimit(2)
                    }
                    .id(logo)
                } else {
                    Text(entry.title)
                        .font(.system(size: compact ? 32 : 44, weight: .bold))
                        .lineLimit(2)
                }
                if let line = Self.subtitle(entry) {
                    Text(line)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    let logo = entry.networkLogo.flatMap(URL.init(string:))
                    Text(Self.when(entry, network: logo == nil))
                        .font(.system(size: 22))
                        .foregroundColor(LiveTVTheme.accent)
                        .lineLimit(1)
                    if let logo, let network = entry.network {
                        Text("·").font(.system(size: 22)).foregroundColor(LiveTVTheme.accent)
                        LiveTVCalendarLogo(url: logo, style: .network, box: CGSize(width: 120, height: 30), area: 1_900,
                                           alignment: .leading) {
                            Text(network).font(.system(size: 22)).foregroundColor(LiveTVTheme.accent)
                        }
                        .id(logo)
                    }
                }
                if let onTV = store.onTV[entry.key], !compact {
                    onTVLine(onTV)
                }
                if compact {
                    if let summary = entry.summary, !entry.spoiler {
                        Text(summary)
                            .font(.system(size: 19))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                            .frame(maxWidth: 1100, alignment: .leading)
                    }
                } else {
                    aboutBlock(entry, width: width ?? 900)
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    /// Below the dates: tags, ratings, year and genres, the episode's text
    /// (the show's when the episode has none), then who's in it.
    @ViewBuilder
    private func aboutBlock(_ entry: LiveTVCalendarEntry, width: CGFloat) -> some View {
        let meta = about.meta(entry)
        if !entry.tags.isEmpty {
            Text(entry.tags.map(Self.tagTitle).joined(separator: "  ·  "))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
        }
        ratingsRow(entry, width: width)
        if let facts = meta.flatMap(Self.facts) {
            Text(facts)
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
        }
        let episodeText = entry.spoiler ? nil : entry.summary
        let showText = meta?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let episodeText {
            Text(episodeText)
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(5)
                .padding(.top, 4)
        }
        if let showText, !showText.isEmpty, showText != episodeText {
            VStack(alignment: .leading, spacing: 4) {
                if episodeText != nil {
                    Text(L10n.string(entry.kind == .movie ? "livetv_cal_about_film" : "livetv_cal_about_show",
                                     fallback: entry.kind == .movie ? "About the film" : "About the show"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
                Text(showText)
                    .font(.system(size: episodeText == nil ? 22 : 20))
                    .foregroundColor(.white.opacity(episodeText == nil ? 0.8 : 0.65))
                    .lineLimit(episodeText == nil ? 7 : 3)
            }
            .padding(.top, 4)
        }
        if let people = about.people[entry.contentID], !people.isEmpty {
            castRow(people, width: width)
        } else if let cast = meta?.cast?.filter({ !$0.isEmpty }), !cast.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("livetv_cal_cast", fallback: "Cast"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Text(cast.prefix(6).joined(separator: ", "))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
            }
            .padding(.top, 4)
        }
        let makers = Array((meta?.director ?? []).filter { !$0.isEmpty }.prefix(3))
        if !makers.isEmpty {
            Text(L10n.string(entry.kind == .movie ? "livetv_cal_director" : "livetv_cal_creators",
                             fallback: entry.kind == .movie ? "Director" : "Created by")
                 + ": " + makers.joined(separator: ", "))
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    /// "On your TV: ProSieben HD · 20:15–21:10 (+2 channels)", and what
    /// holding OK does.
    private func onTVLine(_ onTV: LiveTVCalendarOnTV) -> some View {
        let now = Date()
        let live = now >= onTV.start && now < onTV.end
        var text = L10n.format("livetv_cal_on_tv_format", fallback: "On your TV: %@ · %@–%@", onTV.channelName,
                               Self.clock(onTV.start), Self.clock(onTV.end))
        if onTV.others > 0 {
            text += "  " + L10n.format("livetv_cal_on_tv_others_format", fallback: "(+%d channels)", onTV.others)
        }
        return VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: live ? "dot.radiowaves.left.and.right" : "tv")
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(LiveTVTheme.accent)
                .lineLimit(1)
            Text(onTV.start.addingTimeInterval(-10 * 60) <= now
                 ? L10n.string("livetv_cal_on_tv_hold_live", fallback: "Hold OK on the card to watch it live")
                 : L10n.string("livetv_cal_on_tv_hold_remind", fallback: "Hold OK on the card for a reminder"))
                .font(.system(size: 17))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    /// The ratings on in Settings → Rating Providers & Order, in that
    /// order (as many as fit); one not known (yet) shows "–", so none ever
    /// moves.
    @ViewBuilder
    private func ratingsRow(_ entry: LiveTVCalendarEntry, width: CGFloat) -> some View {
        let fit = max(1, Int((width + 20) / (26 + 7 + 62 + 20)))
        let chosen = Array(LiveTVCalendarSettings.ratingVisuals.prefix(fit))
        if !chosen.isEmpty, about.meta(entry) != nil || entry.contentID.hasPrefix("tt") {
            let values = about.ratingValues(entry)
            HStack(spacing: 20) {
                ForEach(chosen, id: \.source) { visual in
                    HStack(spacing: 7) {
                        TvRatingIcon(visual: visual, height: 26)
                        Text(values[visual.source].map { visual.format($0.value) } ?? "–")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white.opacity(values[visual.source] == nil ? 0.35 : 0.85))
                            .lineLimit(1)
                            .frame(width: 62, alignment: .leading)
                    }
                }
            }
            .frame(height: 30, alignment: .leading)
        }
    }

    /// Who's in it: a picture and a name each.
    private func castRow(_ people: [TmdbPersonMetadata], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("livetv_cal_cast", fallback: "Cast"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            HStack(alignment: .top, spacing: 16) {
                ForEach(people.prefix(max(1, min(7, Int((width + 16) / (96 + 16)))))) { person in
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.12))
                            Image(systemName: "person.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.white.opacity(0.35))
                            if let url = person.profileURL.flatMap(URL.init(string:)) {
                                AsyncImage(url: url) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    }
                                }
                            }
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                        Text(person.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                        if let role = person.role, !role.isEmpty {
                            Text(role)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 96)
                }
            }
        }
        .padding(.top, 4)
    }

    /// "2024 · Drama, Crime · 45 min · Continuing".
    private static func facts(_ meta: NuvioMeta) -> String? {
        var parts: [String] = []
        if let info = meta.releaseInfo?.trimmingCharacters(in: .whitespaces), !info.isEmpty {
            parts.append(info)
        } else if let year = meta.year {
            parts.append(String(year))
        }
        if let genres = meta.genres?.prefix(3), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        if let runtime = meta.runtime?.trimmingCharacters(in: .whitespaces), !runtime.isEmpty { parts.append(runtime) }
        if let certification = meta.certification?.trimmingCharacters(in: .whitespaces), !certification.isEmpty {
            parts.append(certification)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // MARK: Days

    @ViewBuilder
    private func content(_ list: [(day: String, entries: [LiveTVCalendarEntry])]) -> some View {
        if list.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "calendar")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.6))
                Text(emptyText)
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 44) {
                    ForEach(list, id: \.day) { day in
                        VStack(alignment: .leading, spacing: 16) {
                            dayHeader(day.day, count: day.entries.count)
                            // Two in a row, more go on the next row.
                            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 26) {
                                ForEach(day.entries) { entry in
                                    LiveTVCalendarCard(entry: entry, width: Self.cardWidth, onTV: store.onTV[entry.key],
                                                       onFocus: { focusedKey = entry.key },
                                                       onOpen: { choose(entry) })
                                }
                            }
                        }
                        .padding(.leading, 60)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 60)
            }
        }
    }

    /// A day's start: its name (today in the accent colour), the date when
    /// the name is "Tomorrow", how many, and a line across.
    private func dayHeader(_ day: String, count: Int) -> some View {
        let today = LiveTVCalendarLogic.day(of: Date(), in: LiveTVCalendarSettings.timeZone)
        let title = Self.dayTitle(day)
        let date = Self.dayDate(day)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(day == today ? LiveTVTheme.accent : .white)
                if date != title {
                    Text(date)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer(minLength: 10)
                Text(String(count))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            Rectangle()
                .fill(Color.white.opacity(day == today ? 0.5 : 0.25))
                .frame(height: 2)
        }
        .frame(width: 2 * Self.cardWidth + 28)
    }

    private static let columns = [GridItem(.fixed(cardWidth), spacing: 28, alignment: .topLeading),
                                  GridItem(.fixed(cardWidth), alignment: .topLeading)]

    private var emptyText: String {
        if store.isLoading {
            return L10n.string("livetv_cal_loading", fallback: "Getting the dates of your shows and films…")
        }
        if store.isEmptySource {
            return L10n.string("livetv_cal_no_titles", fallback: "Follow shows and films, add them to your Library or watch them, and their new episodes and release dates show up here.")
        }
        return tab == .upcoming
            ? L10n.string("livetv_cal_none_upcoming", fallback: "Nothing coming up in the next four months.")
            : L10n.string("livetv_cal_none_recent", fallback: "Nothing aired in the last 30 days.")
    }

    // MARK: Text

    /// "S02 · E05 · Title" (several: "S02 · E05–E08"); a film's other release.
    static func subtitle(_ entry: LiveTVCalendarEntry) -> String? {
        guard entry.kind == .episode, let season = entry.season, let episode = entry.episode else { return entry.note }
        var parts = ["S" + two(season), entry.lastEpisode.map { "E\(two(episode))–E\(two($0))" } ?? "E" + two(episode)]
        if let title = entry.episodeTitle, !entry.spoiler { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    /// 5 → "05", 12 → "12".
    static func two(_ number: Int) -> String { number < 10 && number >= 0 ? "0\(number)" : String(number) }

    /// "Today · 20:15 · NBC", "Tomorrow · time not announced · Paramount+"
    /// (`network` false: its logo stands after it).
    static func when(_ entry: LiveTVCalendarEntry, network: Bool = true) -> String {
        var parts = [dayTitle(entry.day)]
        if let air = entry.air {
            parts.append(clock(air))
        } else if entry.kind == .episode {
            parts.append(L10n.string("livetv_cal_no_time", fallback: "time not announced"))
        }
        if network, let name = entry.network { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    /// "DE" → "Germany", in the app's language.
    static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// "Fri, Nov 27" (never "Tomorrow").
    static func dayDate(_ day: String) -> String {
        let zone = LiveTVCalendarSettings.timeZone
        guard let date = LiveTVCalendarLogic.start(of: day, in: zone) else { return day }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }

    static func dayTitle(_ day: String) -> String {
        let zone = LiveTVCalendarSettings.timeZone
        let today = LiveTVCalendarLogic.day(of: Date(), in: zone)
        if day == today { return L10n.string("livetv_info_today", fallback: "Today") }
        if day == LiveTVCalendarLogic.day(today, plus: 1) { return L10n.string("livetv_info_tomorrow", fallback: "Tomorrow") }
        if day == LiveTVCalendarLogic.day(today, plus: -1) { return L10n.string("livetv_info_yesterday", fallback: "Yesterday") }
        guard let date = LiveTVCalendarLogic.start(of: day, in: zone) else { return day }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }

    /// An air time in the calendar's time zone, in Live TV's clock style.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = LiveTVCalendarSettings.timeZone
        switch LiveTVSettings.shared.clock {
        case .hours24: formatter.dateFormat = "HH:mm"
        case .hours12: formatter.dateFormat = "h:mm a"
        case .system: formatter.setLocalizedDateFormatFromTemplate("jmm")
        }
        return formatter.string(from: date)
    }

    static func tagTitle(_ tag: LiveTVCalendarTag) -> String {
        switch tag {
        case .new: return L10n.string("livetv_cal_tag_new", fallback: "New")
        case .seriesPremiere: return L10n.string("livetv_cal_tag_series_premiere", fallback: "Series premiere")
        case .seasonPremiere: return L10n.string("livetv_cal_tag_season_premiere", fallback: "Season premiere")
        case .seasonFinale: return L10n.string("livetv_cal_tag_season_finale", fallback: "Season finale")
        case .seriesFinale: return L10n.string("livetv_cal_tag_series_finale", fallback: "Series finale")
        case .inTheaters: return L10n.string("livetv_cal_tag_theaters", fallback: "In theaters")
        case .atHome: return L10n.string("livetv_cal_tag_home", fallback: "At home")
        case .onDisc: return L10n.string("livetv_cal_tag_disc", fallback: "On disc")
        case .onTV: return L10n.string("livetv_cal_tag_tv", fallback: "On TV")
        }
    }
}

/// A wide card: the episode's picture (the show's while it would spoil),
/// its time and tag on top, the title and channel at the bottom, the
/// episode below.
private struct LiveTVCalendarCard: View {
    let entry: LiveTVCalendarEntry
    var width: CGFloat = 400
    /// Where it's on in your Live TV guide (16d).
    var onTV: LiveTVCalendarOnTV? = nil
    let onFocus: () -> Void
    let onOpen: () -> Void

    @FocusState private var focused: Bool

    /// Logos and text follow the card's size (Week and Month cards are smaller).
    private var scale: CGFloat { width / 400 }

    private var picture: URL? {
        let link = entry.spoiler ? (entry.background ?? entry.poster) : (entry.episodeImage ?? entry.background ?? entry.poster)
        return link.flatMap(URL.init(string:))
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    AsyncImage(url: picture) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color.white.opacity(0.08)
                                Image(systemName: entry.kind == .movie ? "film" : "tv")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading) {
                        HStack(alignment: .top) {
                            if let air = entry.air {
                                chip(LiveTVCalendarView.clock(air), fill: .black.opacity(0.7))
                            }
                            Spacer()
                            if entry.watched {
                                chip("✓", fill: .black.opacity(0.7))
                            } else if let tag = entry.tags.first {
                                // A white accent: dark text on it.
                                chip(LiveTVCalendarView.tagTitle(tag), fill: LiveTVTheme.accent.opacity(0.9),
                                     text: LiveTVTheme.isWhiteAccent ? .black : .white)
                            }
                        }
                        Spacer()
                        HStack(alignment: .bottom) {
                            if let logo = entry.titleLogo.flatMap(URL.init(string:)) {
                                LiveTVCalendarLogo(url: logo, style: .title, box: CGSize(width: 220 * scale, height: 64 * scale),
                                                   area: 7_000 * scale * scale, alignment: .bottomLeading) {
                                    Text(entry.title.uppercased()).font(.system(size: 20 * scale, weight: .heavy)).lineLimit(2)
                                }
                            } else {
                                Text(entry.title.uppercased())
                                    .font(.system(size: 20 * scale, weight: .heavy))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            if let logo = entry.networkLogo.flatMap(URL.init(string:)) {
                                LiveTVCalendarLogo(url: logo, style: .network, box: CGSize(width: 96 * scale, height: 30 * scale),
                                                   area: 1_400 * scale * scale, alignment: .bottomTrailing) {
                                    if let network = entry.network { chip(network, fill: .white.opacity(0.2)) }
                                }
                            } else if let network = entry.network {
                                chip(network, fill: .white.opacity(0.2))
                            }
                        }
                    }
                    .foregroundColor(.white)
                    .padding(12)
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 4))
                Text(LiveTVCalendarView.subtitle(entry) ?? " ")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(focused ? 1 : 0.7))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
                if let onTV, width >= 300 {
                    Label(onTV.channelName + " · " + LiveTVCalendarView.clock(onTV.start), systemImage: "tv")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(LiveTVTheme.accent)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
        .onChange(of: focused) { _, now in if now { onFocus() } }
        // Hold OK: the bell, and hiding the show (16c, as Android's).
        .contextMenu {
            if let onTV, let channel = LiveTVStore.shared.channel(id: onTV.channelID) {
                let now = Date()
                if now >= onTV.start.addingTimeInterval(-10 * 60), now < onTV.end {
                    Button {
                        LiveTVWatch.shared.watch(LiveTVWatchRequest(channelID: channel.streamID))
                    } label: {
                        Label(L10n.format("livetv_cal_watch_live_format", fallback: "Watch live on %@", channel.name),
                              systemImage: "play.tv")
                    }
                } else if onTV.start > now {
                    let programme = XtreamProgram(title: onTV.title, description: nil, start: onTV.start, end: onTV.end)
                    let set = LiveTVReminders.shared.isSet(channelID: channel.streamID, start: onTV.start)
                    Button {
                        LiveTVReminders.shared.toggle(channel: channel, programme: programme)
                    } label: {
                        Label(set
                              ? L10n.string("livetv_cal_remind_off", fallback: "Don't remind me")
                              : L10n.format("livetv_cal_remind_format", fallback: "Remind me (%@, %@)",
                                            channel.name, LiveTVCalendarView.clock(onTV.start)),
                              systemImage: set ? "bell.slash" : "alarm")
                    }
                }
            }
            let imdb = entry.contentID.hasPrefix("tt") ? entry.contentID : nil
            if LiveTVCalendarBell.canRing(id: entry.contentID, imdb: imdb, tmdb: nil) {
                let ringing = LiveTVCalendarBell.isRinging(id: entry.contentID, imdb: imdb, tmdb: nil)
                Button {
                    LiveTVCalendarBell.toggle(id: entry.contentID, imdb: imdb, tmdb: nil, series: entry.kind == .episode,
                                              type: entry.kind == .episode ? "series" : "movie", title: entry.title,
                                              poster: entry.poster, year: nil)
                } label: {
                    Label(ringing
                          ? L10n.string("livetv_cal_bell_off", fallback: "Turn off the bell")
                          : L10n.string("livetv_cal_bell_on", fallback: "Ring the bell"),
                          systemImage: ringing ? "bell.slash" : "bell")
                }
            }
            Button(role: .destructive) {
                LiveTVCalendarStore.shared.hide(entry)
            } label: {
                Label(L10n.string("livetv_cal_hide", fallback: "Hide this show from the Calendar"), systemImage: "eye.slash")
            }
        }
    }

    private func chip(_ text: String, fill: Color, text color: Color = .white) -> some View {
        Text(text)
            .font(.system(size: 17 * max(scale, 0.75), weight: .bold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A logo, made to look alike on every card: its empty edges cut off and
/// sized to the same area whether it is wide or tall. Network logos are
/// drawn white, as the Apple TV app does: their shape when they stand free
/// (FOX, CBS), only their lettering when they sit on a box or a dark disc
/// (TF1, ABC), so none turns into a white blot. Title logos keep their
/// colours.
struct LiveTVCalendarLogo<Fallback: View>: View {
    enum Style { case title, network }

    let url: URL
    let style: Style
    /// The most room the logo may take.
    let box: CGSize
    /// The area every logo gets (points²), within `box`.
    let area: CGFloat
    let alignment: Alignment
    @ViewBuilder let fallback: () -> Fallback

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                let size = Self.size(of: image.size, box: box, area: area)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(style == .network ? 0.85 : 0.75), radius: style == .network ? 3 : 4)
            } else if failed {
                fallback()
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(maxWidth: box.width, maxHeight: box.height, alignment: alignment)
        .task(id: url) {
            let white = style == .network
            let key = ((white ? "w|" : "c|") + url.absoluteString) as NSString
            if let known = LiveTVCalendarLogoCache.shared.object(forKey: key) {
                image = known
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data),
                  let made = await Task.detached(priority: .utility, operation: {
                      LiveTVCalendarLogoMaker.make(loaded, white: white)
                  }).value
            else {
                failed = true
                return
            }
            LiveTVCalendarLogoCache.shared.setObject(made, forKey: key)
            image = made
        }
    }

    /// The same area for every logo, as wide or tall as it is, inside the box.
    static func size(of picture: CGSize, box: CGSize, area: CGFloat) -> CGSize {
        guard picture.width > 0, picture.height > 0 else { return .zero }
        let aspect = picture.width / picture.height
        var width = (area * aspect).squareRoot()
        var height = width / aspect
        if width > box.width { width = box.width; height = width / aspect }
        if height > box.height { height = box.height; width = height * aspect }
        return CGSize(width: width, height: height)
    }
}

enum LiveTVCalendarLogoCache {
    @MainActor static let shared = NSCache<NSString, UIImage>()
}

/// Makes logos alike: cut to what's drawn; `white`: drawn in white.
enum LiveTVCalendarLogoMaker {
    static func make(_ image: UIImage, white: Bool) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0, width * height <= 4_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        /// 0…1 of a pixel's colour, without its transparency.
        func luminance(_ i: Int) -> Double {
            let alpha = Double(pixels[i + 3])
            guard alpha > 0 else { return 0 }
            return (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / alpha
        }

        if white {
            // On a box or a dark disc: only the light parts (the lettering);
            // standing free: the whole shape.
            var opaque = 0, light = 0, dark = 0, colour = 0
            for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
                opaque += 1
                let lum = luminance(i)
                if lum > 0.7 { light += 1 } else if lum < 0.3 { dark += 1 }
                // Strongly coloured (a box behind letters: RTL's squares).
                let high = max(pixels[i], pixels[i + 1], pixels[i + 2]), low = min(pixels[i], pixels[i + 1], pixels[i + 2])
                if lum <= 0.7, high > 0, Double(high - low) / Double(high) > 0.45 { colour += 1 }
            }
            let cover = Double(opaque) / Double(width * height)
            let share = { (count: Int) -> Double in opaque > 0 ? Double(count) / Double(opaque) : 0 }
            let lettering = cover > 0.85 || (share(light) > 0.12 && share(dark) > 0.2)
                || (share(light) > 0.05 && share(colour) > 0.45)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                var alpha = Double(pixels[i + 3]) / 255
                if lettering { alpha *= min(1, max(0, (luminance(i) - 0.55) / 0.25)) }
                let value = UInt8(alpha * 255)
                pixels[i] = value
                pixels[i + 1] = value
                pixels[i + 2] = value
                pixels[i + 3] = value
            }
        }

        // Cut to what's drawn.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let whole: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space, bitmapInfo: info)?.makeImage()
        }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cut = whole?.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cut)
    }
}

// MARK: - Week and Month (16b)

/// Days of the calendar in its time zone, the week starting as the Apple
/// TV's region has it.
private enum LiveTVCalendarDays {
    @MainActor static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = LiveTVCalendarSettings.timeZone
        calendar.firstWeekday = Calendar.current.firstWeekday
        calendar.locale = Locale.current
        return calendar
    }

    @MainActor static func key(_ date: Date) -> String {
        LiveTVCalendarLogic.day(of: date, in: LiveTVCalendarSettings.timeZone)
    }

    @MainActor static func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = LiveTVCalendarSettings.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    static func byDay(_ entries: [LiveTVCalendarEntry]) -> [String: [LiveTVCalendarEntry]] {
        Dictionary(grouping: entries, by: \.day)
    }
}

/// A row of pills to move by weeks or months.
private struct LiveTVCalendarPager: View {
    let title: String
    let back: String
    let now: String
    let forward: String
    let canBack: Bool
    let canForward: Bool
    let onMove: (Int) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
            Spacer()
            Button { onMove(-1) } label: { Text("‹ " + back).font(.system(size: 22)) }
                .disabled(!canBack)
            Button { onMove(0) } label: { Text(now).font(.system(size: 22)) }
            Button { onMove(1) } label: { Text(forward + " ›").font(.system(size: 22)) }
                .disabled(!canForward)
        }
        .focusSection()
    }
}

/// The Week: a column per day (today tinted), small cards in each.
private struct LiveTVCalendarWeek: View {
    let entries: [LiveTVCalendarEntry]
    /// The card in focus, between the pager and the days.
    let details: AnyView
    let onFocus: (LiveTVCalendarEntry) -> Void
    let onOpen: (LiveTVCalendarEntry) -> Void

    @State private var offset = 0
    /// The loaded window: 30 days back, 120 ahead.
    private static let range = -5...17

    private var days: [Date] {
        let calendar = LiveTVCalendarDays.calendar
        let today = Date()
        guard let week = calendar.dateInterval(of: .weekOfYear, for: today),
              let start = calendar.date(byAdding: .weekOfYear, value: offset, to: week.start) else { return [] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        let byDay = LiveTVCalendarDays.byDay(entries)
        let shown = days
        let today = LiveTVCalendarDays.key(Date())
        VStack(alignment: .leading, spacing: 14) {
            LiveTVCalendarPager(
                title: shown.first.map { LiveTVCalendarDays.format($0, "MMMd") + " – " } .map { $0 + (shown.last.map { LiveTVCalendarDays.format($0, "MMMd") } ?? "") } ?? "",
                back: L10n.string("livetv_cal_week", fallback: "Week"),
                now: L10n.string("livetv_cal_this_week", fallback: "This week"),
                forward: L10n.string("livetv_cal_week", fallback: "Week"),
                canBack: offset > Self.range.lowerBound, canForward: offset < Self.range.upperBound,
                onMove: { step in offset = step == 0 ? 0 : min(max(offset + step, Self.range.lowerBound), Self.range.upperBound) })
                .padding(.horizontal, 60)
            details
            GeometryReader { room in
            let column = max(120, (room.size.width - 2 * 48 - 6 * 12) / 7)
            HStack(alignment: .top, spacing: 12) {
                ForEach(shown, id: \.self) { date in
                    let key = LiveTVCalendarDays.key(date)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(LiveTVCalendarDays.format(date, "EEEd"))
                            .font(.system(size: 22, weight: key == today ? .bold : .semibold))
                            .foregroundColor(key == today ? .black : .white.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(key == today ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                ForEach(byDay[key] ?? []) { entry in
                                    LiveTVCalendarCard(entry: entry, width: column - 16,
                                                       onFocus: { onFocus(entry) }, onOpen: { onOpen(entry) })
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                        }
                    }
                    .frame(width: column, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(key == today ? Color.white.opacity(0.06) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 14))
                    .focusSection()
                }
            }
            .padding(.horizontal, 48)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The Month: the chosen day's cards on top, a grid of days below (each
/// with its first card's picture, the day and what's on); OK on a day goes
/// up to its cards.
private struct LiveTVCalendarMonth: View {
    let entries: [LiveTVCalendarEntry]
    let onFocus: (LiveTVCalendarEntry) -> Void
    let onOpen: (LiveTVCalendarEntry) -> Void

    @State private var offset = 0
    @State private var chosen: String?
    @State private var toCards = false
    @Namespace private var space
    @Environment(\.resetFocus) private var resetFocus
    private static let range = -1...4

    private var month: Date {
        let calendar = LiveTVCalendarDays.calendar
        let start = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        return calendar.date(byAdding: .month, value: offset, to: start) ?? start
    }

    /// Six weeks from the week the month starts in.
    private var grid: [Date] {
        let calendar = LiveTVCalendarDays.calendar
        guard let first = calendar.dateInterval(of: .weekOfYear, for: month)?.start else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    var body: some View {
        let byDay = LiveTVCalendarDays.byDay(entries)
        let calendar = LiveTVCalendarDays.calendar
        let today = LiveTVCalendarDays.key(Date())
        let day = chosen ?? today
        let cards = byDay[day] ?? []
        VStack(alignment: .leading, spacing: 12) {
            LiveTVCalendarPager(
                title: LiveTVCalendarDays.format(month, "yMMMM"),
                back: L10n.string("livetv_cal_month", fallback: "Month"),
                now: L10n.string("livetv_cal_this_month", fallback: "This month"),
                forward: L10n.string("livetv_cal_month", fallback: "Month"),
                canBack: offset > Self.range.lowerBound, canForward: offset < Self.range.upperBound,
                onMove: { step in
                    offset = step == 0 ? 0 : min(max(offset + step, Self.range.lowerBound), Self.range.upperBound)
                    chosen = nil
                })
                .padding(.horizontal, 60)
            // The chosen day's cards.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 22) {
                    if cards.isEmpty {
                        Text(L10n.string("livetv_cal_day_empty", fallback: "Nothing on this day"))
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(height: 170)
                    }
                    ForEach(Array(cards.enumerated()), id: \.element.key) { index, entry in
                        LiveTVCalendarCard(entry: entry, width: 300,
                                           onFocus: {
                                               toCards = false
                                               onFocus(entry)
                                           },
                                           onOpen: { onOpen(entry) })
                            .prefersDefaultFocus(toCards && index == 0, in: space)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 14)
            }
            .frame(height: 230)
            .focusSection()
            // The days.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 7)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(grid.prefix(7)), id: \.self) { date in
                    Text(LiveTVCalendarDays.format(date, "EEE"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
                ForEach(grid, id: \.self) { date in
                    let key = LiveTVCalendarDays.key(date)
                    LiveTVCalendarDayCell(
                        date: date, entries: byDay[key] ?? [],
                        isToday: key == today, isChosen: key == day,
                        inMonth: calendar.isDate(date, equalTo: month, toGranularity: .month),
                        onFocus: {
                            chosen = key
                            if let first = byDay[key]?.first { onFocus(first) }
                        },
                        onSelect: {
                            guard !(byDay[key] ?? []).isEmpty else { return }
                            chosen = key
                            toCards = true
                            resetFocus(in: space)
                        })
                }
            }
            .padding(.horizontal, 60)
            .focusSection()
        }
        .focusScope(space)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A day in the Month: its first card's picture darkened, the day, and the
/// first title with how many more.
private struct LiveTVCalendarDayCell: View {
    let date: Date
    let entries: [LiveTVCalendarEntry]
    let isToday: Bool
    let isChosen: Bool
    let inMonth: Bool
    let onFocus: () -> Void
    let onSelect: () -> Void

    @FocusState private var focused: Bool

    private var picture: URL? {
        guard let first = entries.first else { return nil }
        let link = first.spoiler ? (first.background ?? first.poster) : (first.episodeImage ?? first.background ?? first.poster)
        return link.flatMap(URL.init(string:))
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .topLeading) {
                Color.clear
                VStack(alignment: .leading, spacing: 2) {
                    Text(LiveTVCalendarDays.format(date, date.isFirstOfMonth ? "MMMd" : "d"))
                        .font(.system(size: 22, weight: isToday ? .heavy : .semibold))
                    Spacer(minLength: 0)
                    if let first = entries.first {
                        HStack {
                            if first.titleLogo == nil {
                                Text(first.title)
                                    .font(.system(size: 16, weight: .semibold))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if entries.count > 1 {
                                Text("+\(entries.count - 1)")
                                    .font(.system(size: 15, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .background(Color.white.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                }
                .foregroundColor(.white)
                .padding(8)
            }
            .frame(height: 74)
            .frame(maxWidth: .infinity)
            // The day's first show by its logo on a calm tile (pictures
            // made the month restless).
            .background {
                ZStack {
                    Color.white.opacity(entries.isEmpty ? (inMonth ? 0.05 : 0.02) : (focused ? 0.2 : 0.1))
                    if let first = entries.first, let logo = first.titleLogo.flatMap(URL.init(string:)) {
                        LiveTVCalendarLogo(url: logo, style: .title, box: CGSize(width: 150, height: 34), area: 3_000,
                                           alignment: .center) { EmptyView() }
                            .padding(.top, 10)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? Color.white : (isToday ? LiveTVTheme.accent : (isChosen ? Color.white.opacity(0.4) : Color.clear)),
                                  lineWidth: focused || isToday ? 3 : 2))
            .opacity(inMonth ? 1 : 0.45)
            .scaleEffect(focused ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
        .onChange(of: focused) { _, now in if now { onFocus() } }
    }
}

private extension Date {
    @MainActor var isFirstOfMonth: Bool {
        LiveTVCalendarDays.calendar.component(.day, from: self) == 1
    }
}
