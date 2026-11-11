import SwiftUI
import UIKit

/// The guide over the full-screen picture (LIVE_TV_DESIGN.md, step 4b), as
/// Android's `LiveTvOverlayMode` (TiviMate's overlay mode). Left in full
/// screen opens the group's channels, with the highlighted channel's shows
/// beside them and what's on top right; Left again the groups.
///
/// No focus engine: the full-screen controls pass the remote's presses here
/// and only the highlight moves, so nothing can jump to the sidebar, and
/// only the rows on screen are drawn (`LiveTVListWindow`).
@MainActor
final class LiveTVOverlayModel: ObservableObject {
    enum Level {
        case channels
        case groups
    }

    @Published private(set) var isOpen = false
    @Published private(set) var level: Level = .channels
    @Published private(set) var groups: [LiveTVGroup] = []
    @Published private(set) var groupIndex = 0
    /// The group whose channels are listed.
    @Published private(set) var groupID = LiveTVGroup.allID
    @Published private(set) var channels: [XtreamLiveChannel] = []
    @Published private(set) var channelIndex = 0
    /// Digits of the longest channel number: the number column is that wide.
    @Published private(set) var numberDigits = 1
    @Published private(set) var channelWindow = LiveTVListWindow(rows: 10)
    @Published private(set) var groupWindow = LiveTVListWindow(rows: 12)
    /// The highlighted channel once the highlight rests: the schedule and
    /// the details follow it, not every step while scrolling.
    @Published private(set) var settledChannel: XtreamLiveChannel?
    @Published private(set) var settledProgrammes: [XtreamProgram] = []
    /// Bumped when programmes for rows on screen arrive.
    @Published private(set) var rowsRevision = 0

    /// Set by Live TV (it owns the store).
    weak var store: LiveTVStore?
    /// Plays a channel picked here, from `list` (the zapping list) of `groupID`.
    var onPlay: (_ channel: XtreamLiveChannel, _ list: [XtreamLiveChannel], _ groupID: String) -> Void = { _, _, _ in }

    private var settleTask: Task<Void, Never>?
    private var groupTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var rowsTask: Task<Void, Never>?

    var highlighted: XtreamLiveChannel? {
        channels.indices.contains(channelIndex) ? channels[channelIndex] : nil
    }

    var favoriteIDs: Set<Int> { Set(store?.favoriteIDs ?? []) }

    // MARK: Open, close

    /// Opens on the channel playing, in the group it was started from.
    func open(playing: XtreamLiveChannel?) {
        guard let store else { return }
        groups = store.groups
        var group = store.selectedGroupID
        var list = store.channels(inGroup: group)
        if let playing, !list.contains(where: { $0.streamID == playing.streamID }) {
            group = LiveTVGroup.allID
            list = store.channels(inGroup: group)
        }
        show(group: group, channels: list, landOn: playing)
        level = .channels
        withAnimation(.easeOut(duration: 0.2)) { isOpen = true }
        LiveTVOverlayPan.shared.install { [weak self] delta in self?.scroll(by: delta) }
        touched()
    }

    func close() {
        LiveTVOverlayPan.shared.remove()
        settleTask?.cancel()
        groupTask?.cancel()
        closeTask?.cancel()
        rowsTask?.cancel()
        guard isOpen else { return }
        withAnimation(.easeIn(duration: 0.2)) { isOpen = false }
    }

    /// The panels set how many rows fit.
    func setRows(channels channelRows: Int, groups groupRows: Int) {
        if channelWindow.rows != channelRows {
            channelWindow.rows = max(1, channelRows)
            channelWindow.follow(channelIndex, count: channels.count)
        }
        if groupWindow.rows != groupRows {
            groupWindow.rows = max(1, groupRows)
            groupWindow.follow(groupIndex, count: groups.count)
        }
    }

    // MARK: Remote

    func move(_ direction: MoveCommandDirection) {
        touched()
        // Up / Down from a swipe: the swipe itself scrolls (LiveTVOverlayPan).
        if direction == .up || direction == .down, !LiveTVOverlayPan.shared.acceptsMoveCommand() { return }
        switch (level, direction) {
        case (.channels, .up): moveChannel(by: -1)
        case (.channels, .down): moveChannel(by: 1)
        case (.channels, .left):
            groupIndex = groups.firstIndex { $0.id == groupID } ?? 0
            groupWindow.land(on: groupIndex, count: groups.count)
            level = .groups
        case (.groups, .up): moveGroup(by: -1)
        case (.groups, .down): moveGroup(by: 1)
        case (.groups, .right):
            applyPendingGroup()
            level = .channels
        default:
            break
        }
    }

    /// A step of a swipe on the remote's touch surface (fast swipes take
    /// bigger steps).
    func scroll(by delta: Int) {
        guard isOpen else { return }
        touched()
        switch level {
        case .channels: moveChannel(by: delta, wraps: false)
        case .groups: moveGroup(by: delta)
        }
    }

    /// OK: plays the highlighted channel (OK on the one playing closes);
    /// in the groups, shows that group's channels.
    func select(playing: XtreamLiveChannel?) {
        touched()
        switch level {
        case .channels:
            guard let channel = highlighted else { return }
            if channel.streamID != playing?.streamID { onPlay(channel, channels, groupID) }
            close()
        case .groups:
            applyPendingGroup()
            level = .channels
        }
    }

    /// Menu: from the groups back to the channels, from the channels out.
    func back() {
        touched()
        switch level {
        case .channels: close()
        case .groups:
            applyPendingGroup()
            level = .channels
        }
    }

    // MARK: Private

    private func show(group: String, channels list: [XtreamLiveChannel], landOn channel: XtreamLiveChannel?) {
        groupID = group
        channels = list
        numberDigits = list.lazy.compactMap(\.number).map { String($0).count }.max() ?? 1
        channelIndex = channel.flatMap { playing in list.firstIndex { $0.streamID == playing.streamID } } ?? 0
        channelWindow.land(on: channelIndex, count: list.count)
        settledChannel = nil
        settle(after: 0)
    }

    private func moveChannel(by delta: Int, wraps: Bool = true) {
        guard !channels.isEmpty else { return }
        if wraps {
            // Presses wrap round at the ends, as on Android.
            channelIndex = ((channelIndex + delta) % channels.count + channels.count) % channels.count
        } else {
            // A swipe stops at the ends.
            channelIndex = min(max(0, channelIndex + delta), channels.count - 1)
        }
        channelWindow.follow(channelIndex, count: channels.count)
        settle(after: 0.2)
    }

    private func moveGroup(by delta: Int) {
        guard !groups.isEmpty else { return }
        groupIndex = min(max(0, groupIndex + delta), groups.count - 1)
        groupWindow.follow(groupIndex, count: groups.count)
        // The channels switch once the highlight rests: switching on every
        // step made scrolling through the groups lag on Android.
        groupTask?.cancel()
        groupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.applyPendingGroup()
        }
    }

    private func applyPendingGroup() {
        groupTask?.cancel()
        guard let store, groups.indices.contains(groupIndex), groups[groupIndex].id != groupID else { return }
        let id = groups[groupIndex].id
        show(group: id, channels: store.channels(inGroup: id), landOn: LiveTVPlayer.shared.channel)
    }

    /// The highlight rested: schedule, details and the rows' shows.
    private func settle(after seconds: Double) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            let channel = self.highlighted
            self.settledChannel = channel
            self.settledProgrammes = channel.flatMap { LiveTVGuideRows.shared.cached($0) } ?? []
            self.loadRows()
            guard let channel else { return }
            let list = await LiveTVGuideRows.shared.programmes(for: channel)
            guard !Task.isCancelled, self.settledChannel?.streamID == channel.streamID else { return }
            self.settledProgrammes = list
        }
    }

    /// What's on for the rows on screen that aren't loaded yet.
    private func loadRows() {
        rowsTask?.cancel()
        let missing = channelWindow.range(count: channels.count)
            .map { channels[$0] }
            .filter { LiveTVGuideRows.shared.cached($0) == nil }
        guard !missing.isEmpty else { return }
        rowsTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for channel in missing {
                    group.addTask { @MainActor in _ = await LiveTVGuideRows.shared.programmes(for: channel) }
                }
            }
            guard !Task.isCancelled else { return }
            self?.rowsRevision &+= 1
        }
    }

    /// Closes itself after a while without a press (as on Android).
    private func touched() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }
}

// MARK: - Swipe scrolling

/// Swipes on the remote's touch surface scroll the overlay's lists by how
/// far and how fast the finger moves (a swipe gives the focus engine only
/// one Up / Down, too slow for long lists). Watches the window's touches
/// while the overlay is open; never takes them from anyone.
@MainActor
final class LiveTVOverlayPan: NSObject, UIGestureRecognizerDelegate {
    static let shared = LiveTVOverlayPan()

    /// Finger travel per row; faster swipes count more.
    private static let step: CGFloat = 55

    private var recognizer: UIPanGestureRecognizer?
    private var onStep: (Int) -> Void = { _ in }
    private var travel: CGFloat = 0
    private var touching = false
    private var stepsThisTouch = 0
    /// Up / Down that came in during this touch before the swipe took over.
    private var commandsThisTouch = 0
    private var endedAt = Date.distantPast

    func install(onStep: @escaping (Int) -> Void) {
        self.onStep = onStep
        guard recognizer == nil, let window = Self.keyWindow else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        window.addGestureRecognizer(pan)
        recognizer = pan
    }

    func remove() {
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        touching = false
    }

    /// Whether an Up / Down move command should count: not while (or just
    /// after) a swipe scrolls.
    func acceptsMoveCommand() -> Bool {
        if touching {
            if stepsThisTouch > 0 { return false }
            commandsThisTouch += 1
            return true
        }
        return !(stepsThisTouch > 0 && Date().timeIntervalSince(endedAt) < 0.35)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            touching = true
            travel = 0
            stepsThisTouch = 0
            commandsThisTouch = 0
        case .changed:
            let view = recognizer.view
            let moved = recognizer.translation(in: view).y
            recognizer.setTranslation(.zero, in: view)
            let speed = abs(recognizer.velocity(in: view).y)
            let gain: CGFloat = speed > 3000 ? 5 : speed > 1500 ? 2.5 : 1
            travel += moved * gain
            while abs(travel) >= Self.step {
                let direction = travel > 0 ? 1 : -1
                travel -= CGFloat(direction) * Self.step
                if commandsThisTouch > 0 {
                    // That row was already taken by the move command.
                    commandsThisTouch -= 1
                    stepsThisTouch += 1
                    continue
                }
                stepsThisTouch += 1
                onStep(direction)
            }
        case .ended, .cancelled, .failed:
            touching = false
            endedAt = Date()
        default:
            break
        }
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

// MARK: - View

struct LiveTVOverlayView: View {
    @ObservedObject var overlay: LiveTVOverlayModel
    @ObservedObject var player: LiveTVPlayer

    static let channelRowHeight: CGFloat = 86
    static let groupRowHeight: CGFloat = 62
    private static let headerHeight: CGFloat = 76
    private static let panelPadding: CGFloat = 50
    /// Where the backdrop fades out into the picture.
    private static let fade: CGFloat = 220

    var body: some View {
        if overlay.isOpen {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private func content(now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 0) {
                if overlay.level == .groups {
                    groupsPanel
                }
                channelsPanel(now: now)
                if overlay.level == .channels, let channel = overlay.settledChannel {
                    schedulePanel(channel, now: now)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // One dark backdrop behind the panels that fades into the
            // picture (a hard edge cut the picture in two).
            .background(alignment: .leading) {
                HStack(spacing: 0) {
                    Color.black.opacity(0.78)
                    LinearGradient(
                        colors: [Color.black.opacity(0.78), Color.black.opacity(0.3), .clear],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.fade)
                }
                .padding(.trailing, -Self.fade)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                let body = height - Self.headerHeight - 2 * Self.panelPadding
                overlay.setRows(
                    channels: Int(body / Self.channelRowHeight),
                    groups: Int((height - 2 * Self.panelPadding) / Self.groupRowHeight))
            }
            if overlay.level == .channels, let channel = overlay.settledChannel {
                detailsCard(channel, now: now)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.top, Self.panelPadding)
                    .padding(.trailing, 60)
            }
        }
        // Always the whole screen, panels on the left: without the details
        // card (groups, a channel without information) it was only as wide
        // as the panels and the full-screen view centred it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Groups

    private var groupsPanel: some View {
        let range = overlay.groupWindow.range(count: overlay.groups.count)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(range), id: \.self) { index in
                let group = overlay.groups[index]
                let focused = index == overlay.groupIndex
                HStack {
                    Text(group.name)
                        .font(.system(size: LiveTVTheme.Font.secondary, weight: focused ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if LiveTVSettings.shared.showGroupCounts {
                        Text(String(group.count))
                            .font(.system(size: LiveTVTheme.Font.badge))
                            .opacity(0.6)
                    }
                }
                .foregroundColor(focused ? .black : LiveTVTheme.primaryText)
                .padding(.horizontal, 18)
                .frame(height: Self.groupRowHeight - 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(focused ? Color.white : Color.clear)
                )
                .frame(height: Self.groupRowHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.panelPadding)
        .frame(width: 400, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        // A shade darker than the channels beside it.
        .background(Color.black.opacity(0.35))
    }

    // MARK: Channels

    private func channelsPanel(now: Date) -> some View {
        let range = overlay.channelWindow.range(count: overlay.channels.count)
        let active = overlay.level == .channels
        let favorites = overlay.favoriteIDs
        let title = overlay.groups.first { $0.id == overlay.groupID }?.name
            ?? L10n.string("livetv_all_channels", fallback: "All channels")
        let digits = overlay.numberDigits
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: LiveTVTheme.Font.secondary, weight: .semibold))
                .foregroundColor(LiveTVTheme.primaryText)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .frame(height: Self.headerHeight, alignment: .leading)
            if overlay.channels.isEmpty {
                Text(L10n.string("livetv_no_channels", fallback: "No channels in this group."))
                    .font(.system(size: LiveTVTheme.Font.small))
                    .foregroundColor(LiveTVTheme.secondaryText)
                    .padding(20)
            }
            ForEach(Array(range), id: \.self) { index in
                let channel = overlay.channels[index]
                channelRow(
                    channel,
                    highlighted: index == overlay.channelIndex,
                    active: active,
                    favorite: favorites.contains(channel.streamID),
                    digits: digits,
                    now: now)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Self.panelPadding)
        .frame(width: 560, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Redraw rows once their shows arrive.
        .id(overlay.rowsRevision)
    }

    private func channelRow(
        _ channel: XtreamLiveChannel, highlighted: Bool, active: Bool, favorite: Bool, digits: Int, now: Date
    ) -> some View {
        let solid = highlighted && active
        let current = LiveTVGuideRows.shared.cached(channel)?.first { $0.start <= now && now < $0.end }
        let playing = channel.streamID == player.channel?.streamID
        let text: Color = solid ? .black : LiveTVTheme.primaryText
        let accent: Color = solid ? .black : LiveTVTheme.accent
        return HStack(spacing: 14) {
            Text(channel.number.map { String($0) } ?? "")
                .font(.system(size: LiveTVTheme.Font.badge, weight: .semibold).monospacedDigit())
                .foregroundColor(solid ? .black.opacity(0.7) : LiveTVTheme.secondaryText)
                .frame(width: CGFloat(digits) * 11 + 4, alignment: .trailing)
            LiveTVCachedLogo(url: channel.logoURL.flatMap(URL.init(string:)))
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(channel.name)
                        .font(.system(size: LiveTVTheme.Font.small, weight: .semibold))
                        .foregroundColor(text)
                        .lineLimit(1)
                    if channel.archiveDays > 0 {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: LiveTVTheme.Font.badge))
                            .foregroundColor(solid ? .black.opacity(0.7) : LiveTVTheme.secondaryText)
                    }
                    if favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: LiveTVTheme.Font.badge - 2))
                            .foregroundColor(solid ? .black : .yellow)
                    }
                }
                Text(current?.title ?? L10n.string("livetv_info_none", fallback: "No information"))
                    .font(.system(size: LiveTVTheme.Font.badge))
                    .foregroundColor(current == nil ? (solid ? .black.opacity(0.6) : LiveTVTheme.tertiaryText) : accent)
                    .lineLimit(1)
                if let current {
                    let info = LiveTVProgrammeInfo(start: current.start, end: current.end, title: nil, description: nil)
                    progress(info.progress(at: now), solid: solid)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if playing {
                Image(systemName: "play.fill")
                    .font(.system(size: LiveTVTheme.Font.small))
                    .foregroundColor(solid ? .black : LiveTVTheme.markColor)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.channelRowHeight - 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(solid ? Color.white : (highlighted ? Color.white.opacity(0.12) : Color.clear))
        )
        .frame(height: Self.channelRowHeight)
    }

    private func progress(_ fraction: Double, solid: Bool) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(solid ? Color.black.opacity(0.2) : Color.white.opacity(0.18))
                Capsule().fill(solid ? Color.black : LiveTVTheme.markColor)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
    }

    // MARK: Schedule preview

    private func schedulePanel(_ channel: XtreamLiveChannel, now: Date) -> some View {
        let list = overlay.settledProgrammes
        let live = list.firstIndex { $0.start <= now && now < $0.end }
        let anchor = live ?? list.firstIndex { $0.start >= now } ?? 0
        let shown = Array(list.dropFirst(max(0, anchor - 1)).prefix(14))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                LiveTVCachedLogo(url: channel.logoURL.flatMap(URL.init(string:)))
                    .frame(width: 44, height: 44)
                Text(channel.name)
                    .font(.system(size: LiveTVTheme.Font.small, weight: .semibold))
                    .foregroundColor(LiveTVTheme.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .frame(height: Self.headerHeight, alignment: .leading)
            if shown.isEmpty {
                Text(L10n.string("livetv_info_none", fallback: "No information"))
                    .font(.system(size: LiveTVTheme.Font.small))
                    .foregroundColor(LiveTVTheme.secondaryText)
                    .padding(20)
            }
            ForEach(Self.scheduleRows(shown, now: now)) { row in
                switch row {
                case .day(let label):
                    // "Tomorrow" once, not before every time.
                    Text(label)
                        .font(.system(size: LiveTVTheme.Font.badge, weight: .bold))
                        .foregroundColor(LiveTVTheme.markColor)
                        .padding(.horizontal, 20)
                        .frame(height: 40, alignment: .bottomLeading)
                case .show(let programme):
                    let isLive = programme.start <= now && now < programme.end
                    let color: Color = isLive ? LiveTVTheme.accent
                        : (programme.end <= now ? LiveTVTheme.secondaryText : LiveTVTheme.primaryText)
                    HStack(spacing: 14) {
                        Text(LiveTVInfoPanel.clock(programme.start, now: now, withDay: false))
                            .font(.system(size: LiveTVTheme.Font.badge, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 62, alignment: .leading)
                        Text(programme.title)
                            .font(.system(size: LiveTVTheme.Font.badge, weight: isLive ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundColor(color)
                    .padding(.horizontal, 20)
                    .frame(height: 44)
                }
            }
        }
        .padding(.vertical, Self.panelPadding)
        .frame(width: 440, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private enum ScheduleRow: Identifiable {
        case day(String)
        case show(XtreamProgram)

        var id: String {
            switch self {
            case .day(let label): return "day|" + label
            case .show(let programme): return "\(programme.start.timeIntervalSince1970)|\(programme.title)"
            }
        }
    }

    /// The shows with a heading where a new day starts (none for today).
    private static func scheduleRows(_ list: [XtreamProgram], now: Date) -> [ScheduleRow] {
        var rows: [ScheduleRow] = []
        var lastDay = 0
        for programme in list {
            let day = LiveTVProgrammeInfo.dayOffset(of: programme.start, from: now)
            if day != lastDay {
                rows.append(.day(day == 1
                    ? L10n.string("livetv_info_tomorrow", fallback: "Tomorrow")
                    : programme.start.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))))
                lastDay = day
            }
            rows.append(.show(programme))
        }
        return rows
    }

    // MARK: Details

    @ViewBuilder
    private func detailsCard(_ channel: XtreamLiveChannel, now: Date) -> some View {
        if let current = overlay.settledProgrammes.first(where: { $0.start <= now && now < $0.end }) {
            let info = LiveTVProgrammeInfo(
                start: current.start, end: current.end, title: current.title, description: current.description)
            VStack(alignment: .leading, spacing: 10) {
                Text(current.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(LiveTVTheme.primaryText)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    Text(LiveTVInfoPanel.clock(info.start, now: now) + " – "
                         + LiveTVInfoPanel.clock(info.end, now: now, withDay: false))
                    progress(info.progress(at: now), solid: false)
                        .frame(width: 90)
                    Text(LiveTVInfoPanel.timeLeft(info.minutesLeft(at: now)))
                }
                .font(.system(size: LiveTVTheme.Font.badge))
                .foregroundColor(LiveTVTheme.secondaryText)
                if let description = current.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    Text(description)
                        .font(.system(size: LiveTVTheme.Font.badge))
                        .foregroundColor(LiveTVTheme.secondaryText)
                        .lineLimit(5)
                }
            }
            .padding(22)
            .frame(width: 520, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.6))
            )
        }
    }
}

/// A channel logo from the shared logo cache: shown at once when it was
/// loaded before (the guide loaded most of them), so fast scrolling doesn't
/// flash empty boxes.
struct LiveTVCachedLogo: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image ?? url.flatMap({ LiveTVLogoCache.shared.image(for: $0) }) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = LiveTVLogoCache.shared.image(for: url) { image = cached; return }
            image = nil
            // A row that scrolls straight past doesn't load.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            image = await LiveTVLogoCache.shared.load(url)
        }
    }
}
