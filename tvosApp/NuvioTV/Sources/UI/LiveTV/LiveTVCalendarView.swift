import SwiftUI

/// The calendar (step 16), as Android's: tabs on top, then a big picture of
/// the card in focus and a row of wide cards per day. 16a: the List view
/// with Upcoming and Recently aired.
struct LiveTVCalendarView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case upcoming
        case recent
        var id: String { rawValue }

        var title: String {
            switch self {
            case .upcoming: return L10n.string("livetv_cal_upcoming", fallback: "Upcoming")
            case .recent: return L10n.string("livetv_cal_recent", fallback: "Recently aired")
            }
        }
    }

    /// Opens a card's show or film page (on its episode).
    let onOpen: (LiveTVCalendarEntry) -> Void

    @ObservedObject private var store = LiveTVCalendarStore.shared
    @State private var tab: Tab = .upcoming
    @State private var unwatchedOnly = LiveTVCalendarSettings.unwatchedOnly
    @State private var focusedKey: String?

    private var shown: [LiveTVCalendarEntry] {
        let now = Date()
        switch tab {
        case .upcoming: return LiveTVCalendarLogic.upcoming(store.entries, now: now, zone: LiveTVCalendarSettings.timeZone)
        case .recent: return LiveTVCalendarLogic.recent(store.entries, now: now, zone: LiveTVCalendarSettings.timeZone, unwatchedOnly: unwatchedOnly)
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
        let focused = shown.first { $0.key == focusedKey } ?? list.first?.entries.first
        ZStack(alignment: .topLeading) {
            hero(focused)
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 60)
                    .padding(.top, 30)
                    .focusSection()
                details(focused)
                    .padding(.horizontal, 60)
                    .frame(height: 230, alignment: .bottomLeading)
                content(list)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { store.opened() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 18) {
            Text(L10n.string("livetv_cal_title", fallback: "Calendar"))
                .font(.system(size: 40, weight: .bold))
                .padding(.trailing, 20)
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                    focusedKey = nil
                } label: {
                    Text(item.title)
                        .font(.system(size: 24, weight: tab == item ? .bold : .regular))
                }
            }
            if tab == .recent {
                Button {
                    unwatchedOnly.toggle()
                    LiveTVCalendarSettings.unwatchedOnly = unwatchedOnly
                } label: {
                    Label(L10n.string("livetv_cal_unwatched", fallback: "Unwatched only"),
                          systemImage: unwatchedOnly ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                }
            }
            Spacer()
            if let progress = store.progress, progress.total > 0 {
                Text(L10n.format("livetv_cal_progress_format", fallback: "Updating %d of %d", progress.done, progress.total))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.6))
            } else if store.isLoading {
                ProgressView()
            }
            Button {
                store.refresh()
            } label: {
                Label(L10n.string("livetv_refresh", fallback: "Refresh"), systemImage: "arrow.clockwise")
                    .font(.system(size: 22))
            }
            .disabled(store.isLoading)
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
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85), .black],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 620)
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: entry?.key)
    }

    private static func heroImage(_ entry: LiveTVCalendarEntry) -> URL? {
        (entry.background ?? entry.poster).flatMap(URL.init(string:))
    }

    private func details(_ entry: LiveTVCalendarEntry?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entry {
                Text(entry.title)
                    .font(.system(size: 44, weight: .bold))
                    .lineLimit(1)
                if let line = Self.subtitle(entry) {
                    Text(line)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Text(Self.when(entry))
                    .font(.system(size: 22))
                    .foregroundColor(LiveTVTheme.accent)
                if let summary = entry.summary, !entry.spoiler {
                    Text(summary)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
        .padding(.bottom, 20)
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
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(list, id: \.day) { day in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(Self.dayTitle(day.day) + "  ·  " + String(day.entries.count))
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.horizontal, 60)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 28) {
                                    ForEach(day.entries) { entry in
                                        LiveTVCalendarCard(entry: entry,
                                                           onFocus: { focusedKey = entry.key },
                                                           onOpen: { onOpen(entry) })
                                    }
                                }
                                .padding(.horizontal, 60)
                                .padding(.vertical, 20)
                            }
                            .focusSection()
                        }
                    }
                }
                .padding(.bottom, 60)
            }
        }
    }

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

    /// "S2 · E5 · Title" (several: "S2 · E5–E8"); a film's other release.
    static func subtitle(_ entry: LiveTVCalendarEntry) -> String? {
        guard entry.kind == .episode, let season = entry.season, let episode = entry.episode else { return entry.note }
        var parts = ["S\(season)", entry.lastEpisode.map { "E\(episode)–E\($0)" } ?? "E\(episode)"]
        if let title = entry.episodeTitle, !entry.spoiler { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    /// "Today 20:15 · NBC", "Fri, Nov 27 · Netflix".
    static func when(_ entry: LiveTVCalendarEntry) -> String {
        var parts = [dayTitle(entry.day)]
        if let air = entry.air { parts[0] += " " + clock(air) }
        if let network = entry.network { parts.append(network) }
        return parts.joined(separator: " · ")
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
    let onFocus: () -> Void
    let onOpen: () -> Void

    @FocusState private var focused: Bool

    static let width: CGFloat = 400

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
                                chip(LiveTVCalendarView.tagTitle(tag), fill: LiveTVTheme.accent.opacity(0.9))
                            }
                        }
                        Spacer()
                        HStack(alignment: .bottom) {
                            Text(entry.title.uppercased())
                                .font(.system(size: 20, weight: .heavy))
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            if let logo = entry.networkLogo.flatMap(URL.init(string:)) {
                                // The network's logo on a light chip (most are dark).
                                AsyncImage(url: logo) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    } else if let network = entry.network {
                                        Text(network).font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                                    }
                                }
                                .frame(maxWidth: 110, maxHeight: 26)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                            } else if let network = entry.network {
                                chip(network, fill: .white.opacity(0.2))
                            }
                        }
                    }
                    .foregroundColor(.white)
                    .padding(12)
                }
                .frame(width: Self.width, height: Self.width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 4))
                Text(LiveTVCalendarView.subtitle(entry) ?? " ")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(focused ? 1 : 0.7))
                    .lineLimit(1)
                    .frame(width: Self.width, alignment: .leading)
            }
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
        .onChange(of: focused) { _, now in if now { onFocus() } }
    }

    private func chip(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
    }
}
