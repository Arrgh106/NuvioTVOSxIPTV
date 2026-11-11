import SwiftUI
import Combine

/// "Watch this channel full screen", from outside Live TV (Home row,
/// reminders). The app opens the Live TV tab; Live TV plays it.
struct LiveTVWatchRequest: Equatable {
    let channelID: Int
    /// The channels up / down go through (empty: the group shown).
    var listIDs: [Int] = []
    /// The group Live TV shows (and lands on when going back).
    var groupID: String?
}

@MainActor
final class LiveTVWatch: ObservableObject {
    static let shared = LiveTVWatch()

    @Published var pending: LiveTVWatchRequest?
    /// Set by the app: closes what's on top and selects the Live TV tab.
    var openLiveTV: () -> Void = {}

    func watch(_ request: LiveTVWatchRequest) {
        pending = request
        openLiveTV()
    }
}

// MARK: - Model

/// Home's Live TV row (LIVE_TV_DESIGN.md, step 7b), as Android's
/// `LiveTvHomeRow`: favorite channels (or recently watched) with what's on.
///
/// Two objects so Home stays smooth: Home observes only `metas`, which
/// changes when the channels do; the row's cards observe `LiveTVHomeRowNow`,
/// which ticks with the programmes.
@MainActor
final class LiveTVHomeRowModel: ObservableObject {
    static let shared = LiveTVHomeRowModel()
    static let sectionID = "fork_livetv"
    static let limit = 20

    /// One per card, for Home's rows and focus (ids "livetv:<stream id>").
    @Published private(set) var metas: [NuvioMeta] = []
    private(set) var channels: [XtreamLiveChannel] = []
    /// The source actually shown (favorites fall back to recent when none).
    private(set) var groupID = LiveTVGroup.favoritesID

    private struct Saved: Codable {
        var favorites: [XtreamLiveChannel]
        var recent: [XtreamLiveChannel]
    }

    private static let key = "nuvio.tv.livetv.homeChannels"
    private var saved = Saved(favorites: [], recent: [])
    private var observers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?

    private init() {
        load()
        observers.append(NotificationCenter.default.addObserver(
            forName: ProfileSettings.settingsChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        })
        // On / off and the source, from Settings → Live TV.
        let settings = LiveTVSettings.shared
        settingsSubscription = settings.$homeRow.combineLatest(settings.$homeRowSource)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuild() } }
    }

    /// From Live TV's store whenever favorites or recently watched change.
    func remember(favorites: [XtreamLiveChannel], recent: [XtreamLiveChannel]) {
        let next = Saved(favorites: Array(favorites.prefix(Self.limit)), recent: Array(recent.prefix(Self.limit)))
        guard next.favorites != saved.favorites || next.recent != saved.recent else { return }
        saved = next
        if let data = try? JSONEncoder().encode(next) {
            ProfileSettings.current.set(data, forKey: Self.key)
        }
        rebuild()
    }

    func meta(for channel: XtreamLiveChannel) -> NuvioMeta {
        NuvioMeta(id: "livetv:\(channel.streamID)", name: channel.name, logoUrl: channel.logoURL, type: "livetv")
    }

    func channel(for meta: NuvioMeta) -> XtreamLiveChannel? {
        channels.first { "livetv:\($0.streamID)" == meta.id }
    }

    /// OK on a card: full screen, zapping through the row's channels, and
    /// the row's group in the guide (as Android's `playFromHome`).
    func play(_ meta: NuvioMeta) {
        guard let channel = channel(for: meta) else { return }
        LiveTVWatch.shared.watch(LiveTVWatchRequest(
            channelID: channel.streamID, listIDs: channels.map(\.streamID), groupID: groupID))
    }

    private func load() {
        saved = ProfileSettings.current.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved(favorites: [], recent: [])
        rebuild()
    }

    private func rebuild() {
        let settings = LiveTVSettings.shared
        let list: [XtreamLiveChannel]
        if !settings.homeRow || XtreamAccountStore.load() == nil {
            list = []
        } else if settings.homeRowSource == .favorites, !saved.favorites.isEmpty {
            list = saved.favorites
            groupID = LiveTVGroup.favoritesID
        } else {
            list = saved.recent
            groupID = LiveTVGroup.recentID
        }
        guard list != channels else { return }
        channels = list
        metas = list.map(meta(for:))
        LiveTVHomeRowNow.shared.load(list)
    }
}

/// What's on for the row's cards; refreshed every 30 s while Home shows it.
@MainActor
final class LiveTVHomeRowNow: ObservableObject {
    static let shared = LiveTVHomeRowNow()

    @Published private(set) var programmes: [Int: [XtreamProgram]] = [:]
    @Published private(set) var now = Date()
    private var channels: [XtreamLiveChannel] = []
    private var loadTask: Task<Void, Never>?
    private var timer: Timer?

    func load(_ list: [XtreamLiveChannel]) {
        channels = list
        programmes = programmes.filter { id, _ in list.contains { $0.streamID == id } }
        reload()
    }

    /// The row came on screen / went away.
    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func current(_ channel: XtreamLiveChannel) -> (now: XtreamProgram?, next: XtreamProgram?) {
        let list = programmes[channel.streamID] ?? []
        let index = list.firstIndex { $0.start <= now && now < $0.end }
        let current = index.map { list[$0] }
        let next = list.first { $0.start >= (current?.end ?? now) }
        return (current, next)
    }

    private func tick() {
        now = Date()
        // A show ended and nothing is known after it: ask again.
        if channels.contains(where: { current($0).now == nil }) { reload() }
    }

    private func reload() {
        loadTask?.cancel()
        let list = channels
        loadTask = Task { @MainActor [weak self] in
            for channel in list {
                let shows = await LiveTVGuideRows.shared.programmes(for: channel)
                guard !Task.isCancelled, let self else { return }
                if self.programmes[channel.streamID]?.count != shows.count
                    || self.programmes[channel.streamID]?.first?.start != shows.first?.start {
                    self.programmes[channel.streamID] = shows
                }
            }
        }
    }
}

// MARK: - Row

/// The row in Home, built like Home's own rows (same focus binding, scroll
/// and outline), so Home's focus memory and Up / Down work on it.
struct LiveTVHomeRow: View {
    let id: String
    let title: String
    let horizontalEdgeInset: CGFloat
    let items: [NuvioMeta]
    var externalFocus: FocusState<String?>.Binding? = nil
    let initialFocusCardKey: String?
    let initialScrollIndex: Int
    let onScrollIndexChange: (Int) -> Void
    let onFocus: (NuvioMeta) -> Void
    let onBlur: (NuvioMeta) -> Void

    @State private var scrollIndex: Int?
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false

    static let cardWidth: CGFloat = 420
    static let cardHeight: CGFloat = 124
    static let spacing: CGFloat = 28
    /// Title, cards and the strip's padding: Home lays rows out by this.
    static let rowHeight: CGFloat = 50 + cardHeight + TVHomeLayout.stripVerticalPadding * 2

    private var effectiveScrollIndex: Int {
        min(max(0, scrollIndex ?? initialScrollIndex), max(0, items.count - 1))
    }

    private var defaultFocusKey: String? {
        if let initialFocusCardKey { return initialFocusCardKey.hasPrefix("\(id)\u{1}") ? initialFocusCardKey : nil }
        guard !items.isEmpty else { return nil }
        return TVHomeCardIdentity.key(rowID: id, item: items[effectiveScrollIndex])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.appFont(size: 30, weight: .bold))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .offset(y: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(2)
            strip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable(externalFocus, defaultFocusKey)
        .onAppear { LiveTVHomeRowNow.shared.setVisible(true) }
        .onDisappear { LiveTVHomeRowNow.shared.setVisible(false) }
    }

    private var strip: some View {
        let stripWidth = max(1920, UIScreen.main.bounds.width + horizontalEdgeInset * 2)
        let scrollX = CGFloat(effectiveScrollIndex) * (Self.cardWidth + Self.spacing)
        return HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, meta in
                let key = TVHomeCardIdentity.key(rowID: id, item: meta)
                LiveTVHomeCard(
                    meta: meta,
                    externalFocus: externalFocus,
                    focusKey: key,
                    onFocus: {
                        if scrollIndex != index {
                            scrollIndex = index
                            onScrollIndexChange(index)
                        }
                        onFocus(meta)
                    },
                    onBlur: { onBlur(meta) },
                    onSelect: { LiveTVHomeRowModel.shared.play(meta) }
                )
            }
        }
        .padding(.vertical, TVHomeLayout.stripVerticalPadding)
        .offset(x: horizontalEdgeInset + TVLayout.rowLeading - scrollX)
        .frame(width: stripWidth, height: Self.cardHeight + TVHomeLayout.stripVerticalPadding * 2, alignment: .topLeading)
        .clipped()
        .offset(x: -horizontalEdgeInset)
        .animation(smoothFocus && !fastNavigation ? TVHomeLayout.scrollAnimation : nil, value: effectiveScrollIndex)
    }
}

/// A channel card, as Android's `HomeCard`: logo, what's on (or the channel
/// name), progress, and "number  name · time left".
private struct LiveTVHomeCard: View {
    let meta: NuvioMeta
    let externalFocus: FocusState<String?>.Binding?
    let focusKey: String
    let onFocus: () -> Void
    let onBlur: () -> Void
    let onSelect: () -> Void

    @ObservedObject private var live = LiveTVHomeRowNow.shared
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) { content }
            .buttonStyle(PosterCardButtonStyle(onNativeFocusChange: { focused in
                if focused { onFocus() } else { onBlur() }
            }))
            .focused($isFocused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: focusKey))
            .focusEffectDisabledIfAvailable()
            .frame(width: LiveTVHomeRow.cardWidth, height: LiveTVHomeRow.cardHeight)
            .zIndex(isFocused ? 1 : 0)
    }

    private var content: some View {
        let channel = LiveTVHomeRowModel.shared.channel(for: meta)
        let shows = channel.map { live.current($0) }
        let current = shows?.now
        let now = live.now
        let playing = channel.map { LiveTVPlayer.shared.channel?.streamID == $0.streamID } ?? false
        return HStack(spacing: 18) {
            LiveTVLogo(url: meta.logoUrl.flatMap(URL.init(string:)))
                .frame(width: 104, height: 78)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if playing {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                    }
                    Text(current?.title ?? meta.name)
                        .font(.system(size: 23, weight: .semibold))
                        .lineLimit(1)
                }
                if let current {
                    let info = LiveTVProgrammeInfo(
                        start: current.start, end: current.end, title: current.title, description: nil)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.18))
                            Capsule().fill(LiveTVTheme.markColor)
                                .frame(width: proxy.size.width * CGFloat(info.progress(at: now)))
                        }
                    }
                    .frame(height: 4)
                    Text(subline(channel: channel, left: info.minutesLeft(at: now)))
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                } else {
                    Text(subline(channel: channel, left: nil))
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .frame(width: LiveTVHomeRow.cardWidth, height: LiveTVHomeRow.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(isFocused ? 0.2 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isFocused ? AppFocusOutline.color : Color.white.opacity(0.16),
                        lineWidth: isFocused ? AppFocusOutline.width : 1)
        )
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    private func subline(channel: XtreamLiveChannel?, left: Int?) -> String {
        var parts: [String] = []
        let number = channel?.number.map(String.init)
        parts.append([number, meta.name].compactMap { $0 }.joined(separator: "  "))
        if let left { parts.append(LiveTVInfoPanel.timeLeft(left)) }
        return parts.joined(separator: "  ·  ")
    }
}
