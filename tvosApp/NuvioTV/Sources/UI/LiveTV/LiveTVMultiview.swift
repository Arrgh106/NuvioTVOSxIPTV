import AetherEngine
import Combine
import SwiftUI
import UIKit

// MARK: - Model

/// Multiview (Live TV step 15), as Android's: up to four channels at once,
/// each pane its own AetherEngine (the engine is built for side-by-side
/// tiles: one `.primary`, the others `.secondary`; switching the sound is a
/// volume change, nothing loads again). Sound follows the pane in focus.
/// While Multiview is open the single player is stopped (a provider allows
/// only so many connections).
@MainActor
final class LiveTVMultiview: ObservableObject {
    static let shared = LiveTVMultiview()

    enum PaneStatus: Equatable {
        case empty
        case loading
        case playing
        case failed(String)
    }

    /// One pane: its engine (made when first used), channel and state.
    @MainActor
    final class Pane: ObservableObject, Identifiable {
        let id: Int
        @Published fileprivate(set) var channel: XtreamLiveChannel?
        @Published fileprivate(set) var status: PaneStatus = .empty
        fileprivate var engine: AetherEngine?
        fileprivate var task: Task<Void, Never>?
        fileprivate var watch: AnyCancellable?

        init(id: Int) { self.id = id }
    }

    @Published private(set) var isOpen = false
    @Published private(set) var layout: LiveTVMultiviewLayout = .two
    @Published private(set) var focused = 0
    /// One pane grown to the whole screen (the others play on, silent).
    @Published private(set) var fullPane: Int?
    /// The bar, pane names and edges; they fade after 5 s.
    @Published private(set) var overlaysShown = true
    /// The pane the channel picker fills (nil: closed).
    @Published var pickerPane: Int?
    @Published var layoutPickerOpen = false
    /// The highlight is on the bar: it stays up.
    var barFocused = false {
        didSet { if barFocused { showOverlays() } }
    }

    let panes: [Pane] = (0..<LiveTVMultiviewLayout.maxPanes).map(Pane.init)
    /// The channel picker's highlight and lists.
    let picker = LiveTVMultiviewPickerModel()
    private var overlayTimer: Timer?

    var visiblePanes: [Pane] { Array(panes.prefix(layout.paneCount)) }
    var audiblePane: Int { fullPane ?? focused }

    // MARK: Open, close

    /// Opens Multiview with these channels (the one playing first), in the
    /// layout that fits them (two panes at least).
    func open(with channels: [XtreamLiveChannel]) {
        var unique: [XtreamLiveChannel] = []
        for channel in channels where !unique.contains(where: { $0.streamID == channel.streamID }) { unique.append(channel) }
        let list = Array(unique.prefix(LiveTVMultiviewLayout.maxPanes))
        // The single player's connection goes first.
        LiveTVPlayer.shared.stop()
        layout = .fitting(max(2, list.count))
        focused = 0
        fullPane = nil
        pickerPane = nil
        layoutPickerOpen = false
        isOpen = true
        LiveTVFullscreenState.shared.multiviewActive = true
        for (index, channel) in list.enumerated() { assign(channel, to: index) }
        showOverlays()
        // An empty first pane: straight to the channels, once the screen is
        // up and holds the remote (opened with it, the picker never got the
        // focus: no arrow, no Menu).
        if list.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.isOpen, self.pickerPane == nil, !self.layoutPickerOpen else { return }
                self.pickerPane = 0
            }
        }
    }

    /// "Add to Multiview" (a channel's menu): into the first empty pane, or
    /// Multiview opens with the channel playing and this one.
    func add(_ channel: XtreamLiveChannel) {
        guard isOpen else {
            open(with: [LiveTVPlayer.shared.channel, channel].compactMap { $0 })
            return
        }
        if panes.contains(where: { $0.channel?.streamID == channel.streamID }) { return }
        if let empty = visiblePanes.first(where: { $0.channel == nil }) {
            assign(channel, to: empty.id)
        } else if layout.paneCount < LiveTVMultiviewLayout.maxPanes {
            setLayout(.fitting(layout.paneCount + 1))
            assign(channel, to: layout.paneCount - 1)
        } else {
            assign(channel, to: focused)
        }
    }

    /// Back out of Multiview: every engine stops; the pane in focus goes on
    /// full screen in the single player.
    func close() {
        let channel = panes[audiblePane].channel
        for pane in panes { clear(pane) }
        overlayTimer?.invalidate()
        isOpen = false
        pickerPane = nil
        layoutPickerOpen = false
        LiveTVFullscreenState.shared.multiviewActive = false
        if let channel {
            let player = LiveTVPlayer.shared
            player.startChannel(channel)
            player.isFullscreen = true
        }
    }

    // MARK: Panes

    func setLayout(_ value: LiveTVMultiviewLayout) {
        guard value != layout else { return }
        // Panes the new layout has no room for stop.
        for pane in panes where pane.id >= value.paneCount { clear(pane) }
        layout = value
        focused = min(focused, value.paneCount - 1)
        if let full = fullPane, full >= value.paneCount { fullPane = nil }
        applySound()
        showOverlays()
    }

    func assign(_ channel: XtreamLiveChannel, to index: Int) {
        guard panes.indices.contains(index) else { return }
        let pane = panes[index]
        clear(pane)
        pane.channel = channel
        pane.status = .loading
        if pane.engine == nil { pane.engine = try? AetherEngine() }
        guard let engine = pane.engine else {
            pane.status = .failed(L10n.string("livetv_multiview_no_player", fallback: "No player for this pane"))
            return
        }
        pane.watch = engine.$state.combineLatest(engine.$hasFirstFrameReadyForDisplay)
            .receive(on: RunLoop.main)
            .sink { [weak pane] state, firstFrame in
                MainActor.assumeIsolated {
                    guard let pane, pane.channel != nil else { return }
                    switch state {
                    case .error(let message): pane.status = .failed(message)
                    default: if firstFrame, pane.status != .playing { pane.status = .playing }
                    }
                }
            }
        pane.task = Task { [weak self] in
            guard let item = LiveTVStore.shared.playbackItem(for: channel) else {
                pane.status = .failed(L10n.string("livetv_multiview_no_link", fallback: "No link for this channel"))
                return
            }
            var url = item.url
            var headers = item.headers
            do {
                // Stalker: the portal gives the link to play now.
                if url.scheme == LiveTVStalker.scheme,
                   let source = LiveTVSourceStore.shared.source(slot: LiveTVSourceIDs.slot(ofChannel: channel.streamID)) {
                    (url, headers) = try await LiveTVStalker.resolve(url, sourceID: source.id)
                }
                guard !Task.isCancelled else { return }
                var options = LoadOptions()
                options.httpHeaders = headers
                // Tiles never switch the TV's picture mode; the first is the
                // primary output, the others secondary.
                options.matchContentEnabled = false
                options.isLive = true
                options.liveJoinProfile = .fastZap
                options.sharedOutputRole = index == 0 ? .primary : .secondary
                engine.logTag = "multiview.\(index + 1)"
                engine.volume = 0
                try await engine.load(url: url, options: options)
                guard !Task.isCancelled else { return }
                self?.applySound()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                pane.status = .failed(error.localizedDescription)
            }
        }
        applySound()
    }

    func remove(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        clear(panes[index])
        if fullPane == index { fullPane = nil }
    }

    private func clear(_ pane: Pane) {
        pane.task?.cancel()
        pane.task = nil
        pane.watch = nil
        // Every engine stops before it's let go (the engine's contract).
        pane.engine?.stop()
        pane.channel = nil
        pane.status = .empty
    }

    /// Only the pane in focus (or full screen) is heard.
    private func applySound() {
        for pane in panes {
            pane.engine?.volume = pane.id == audiblePane && pane.channel != nil ? 1 : 0
        }
    }

    // MARK: Remote

    func move(_ direction: LiveTVMultiviewLayout.Direction) {
        if let full = fullPane {
            // Full screen: Left / Right go round the panes with a channel.
            guard direction == .left || direction == .right else { return }
            let filled = visiblePanes.filter { $0.channel != nil }.map(\.id)
            fullPane = LiveTVMultiviewLayout.nextFull(filled, from: full, forward: direction == .right)
            focused = fullPane ?? focused
            applySound()
            return
        }
        let next = layout.next(from: focused, direction)
        if next != focused {
            focused = next
            applySound()
        }
        showOverlays()
    }

    /// OK on a pane: an empty or failed one gets a channel; else the picker
    /// for it too (to change it).
    func select() {
        pickerPane = focused
        showOverlays()
    }

    func toggleFullScreen() {
        if fullPane != nil {
            fullPane = nil
        } else if panes[focused].channel != nil {
            fullPane = focused
        }
        applySound()
        showOverlays()
    }

    func back() {
        switch LiveTVMultiviewLayout.back(
            pickerOpen: pickerPane != nil || layoutPickerOpen, fullScreen: fullPane != nil, overlaysShown: overlaysShown) {
        case .closePicker:
            pickerPane = nil
            layoutPickerOpen = false
        case .allPanes:
            fullPane = nil
            applySound()
        case .hideOverlays:
            overlayTimer?.invalidate()
            overlaysShown = false
        case .leave:
            close()
        }
    }

    /// The bar and the names come back; they go again after 5 s (not while
    /// a picker is open).
    func showOverlays() {
        if !overlaysShown { overlaysShown = true }
        overlayTimer?.invalidate()
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pickerPane == nil, !self.layoutPickerOpen, !self.barFocused else { return }
                self.overlaysShown = false
            }
        }
    }

    fileprivate func engine(of pane: Pane) -> AetherEngine? { pane.engine }
}

// MARK: - Screen

/// Multiview over the whole app, as Live TV's full screen.
struct LiveTVMultiviewHost: View {
    @ObservedObject var model = LiveTVMultiview.shared
    @FocusState private var focus: Focus?

    enum Focus: Hashable {
        case panes
        case layout
        case channels
        case full
        case exit
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(model.visiblePanes) { pane in
                    let frame = paneFrame(pane.id, in: geo.size)
                    LiveTVMultiviewPaneView(
                        pane: pane, model: model,
                        focused: model.focused == pane.id && model.fullPane == nil,
                        audible: model.audiblePane == pane.id,
                        showsLabel: model.overlaysShown || model.fullPane == pane.id)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        // Full screen: the others play on underneath.
                        .zIndex(model.fullPane == pane.id ? 1 : 0)
                        .opacity(model.fullPane == nil || model.fullPane == pane.id ? 1 : 0)
                }
                // The remote's target over the panes: it draws nothing.
                Button(action: { model.select() }) { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(LiveTVInvisibleButtonStyle())
                    .focused($focus, equals: .panes)
                    .onMoveCommand(perform: move)
                    .onExitCommand { model.back() }
                    .disabled(model.pickerPane != nil || model.layoutPickerOpen)
                    .zIndex(2)
                if model.overlaysShown {
                    bar
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 30)
                        // A picker open: the remote stays in it.
                        .disabled(model.pickerPane != nil || model.layoutPickerOpen)
                        .zIndex(3)
                        .transition(.opacity)
                }
                if let pane = model.pickerPane {
                    LiveTVMultiviewPicker(model: model, pane: pane)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: paneFrame(pane, in: geo.size).midX <= geo.size.width / 2 ? .trailing : .leading)
                        .zIndex(4)
                }
                if model.layoutPickerOpen {
                    LiveTVMultiviewLayoutPicker(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .zIndex(4)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: model.overlaysShown)
        .onAppear {
            focus = .panes
            // The screen fades in over the app: focus again once it's there.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if model.pickerPane == nil, !model.layoutPickerOpen { focus = .panes }
            }
            LiveTVPlayPausePress.shared.install { LiveTVMultiview.shared.toggleFullScreen() }
        }
        .onDisappear { LiveTVPlayPausePress.shared.remove() }
        .onChange(of: model.pickerPane) { _, open in if open == nil { focus = .panes } }
        // On the bar: it stays up; back on the panes the timer runs again.
        .onChange(of: focus) { _, value in model.barFocused = value != nil && value != .panes }
        .onChange(of: model.layoutPickerOpen) { _, open in if !open { focus = .panes } }
    }

    private func paneFrame(_ index: Int, in size: CGSize) -> CGRect {
        if model.fullPane == index { return CGRect(origin: .zero, size: size) }
        let frames = model.layout.frames
        guard frames.indices.contains(index) else { return .zero }
        let f = frames[index]
        let x: CGFloat = CGFloat(f.x) * size.width
        let y: CGFloat = CGFloat(f.y) * size.height
        let width: CGFloat = CGFloat(f.width) * size.width
        let height: CGFloat = CGFloat(f.height) * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func move(_ direction: MoveCommandDirection) {
        // Hidden overlays: the first arrow only brings them back.
        if !model.overlaysShown, model.fullPane == nil {
            model.showOverlays()
            return
        }
        switch direction {
        case .up:
            if model.fullPane == nil, model.layout.isTop(model.focused) {
                model.showOverlays()
                focus = .layout
            } else {
                model.move(.up)
            }
        case .down: model.move(.down)
        case .left: model.move(.left)
        case .right: model.move(.right)
        @unknown default: break
        }
    }

    /// Layout, channels for the pane in focus, full screen, exit, and which
    /// pane is heard.
    private var bar: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("livetv_title", fallback: "Live TV").uppercased())
                    .font(.system(size: LiveTVTheme.Font.badge, weight: .bold))
                    .foregroundColor(LiveTVTheme.tertiaryText)
                Text(L10n.string("livetv_multiview", fallback: "Multiview"))
                    .font(.system(size: LiveTVTheme.Font.small, weight: .heavy))
                    .foregroundColor(LiveTVTheme.primaryText)
            }
            barButton(.layout, title: L10n.string("livetv_multiview_layout", fallback: "Layout"),
                      systemImage: "rectangle.split.2x2") { model.layoutPickerOpen = true }
            barButton(.channels, title: L10n.string("livetv_multiview_channels", fallback: "Channels"),
                      systemImage: "list.bullet") { model.pickerPane = model.focused }
            barButton(.full, title: model.fullPane == nil
                        ? L10n.string("livetv_multiview_full", fallback: "Full Screen")
                        : L10n.string("livetv_multiview_all", fallback: "All Panes"),
                      systemImage: model.fullPane == nil ? "arrow.up.left.and.arrow.down.right" : "rectangle.grid.2x2") {
                model.toggleFullScreen()
            }
            barButton(.exit, title: L10n.string("livetv_multiview_exit", fallback: "Exit"),
                      systemImage: "xmark") { model.close() }
            Text(L10n.format("livetv_multiview_sound_format", fallback: "Sound: P%d", model.audiblePane + 1))
                .font(.system(size: LiveTVTheme.Font.badge, weight: .semibold))
                .foregroundColor(LiveTVTheme.secondaryText)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .liveTVGlass()
        .focusSection()
        .onExitCommand { focus = .panes }
    }

    private func barButton(_ id: Focus, title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
            model.showOverlays()
        }) {
            Label(title, systemImage: systemImage)
                .font(.system(size: LiveTVTheme.Font.small, weight: .semibold))
        }
        .focused($focus, equals: id)
    }
}

/// One pane: the picture, its name (P1 and the channel), a sound mark, and
/// what it's doing when it isn't playing.
private struct LiveTVMultiviewPaneView: View {
    @ObservedObject var pane: LiveTVMultiview.Pane
    let model: LiveTVMultiview
    let focused: Bool
    let audible: Bool
    let showsLabel: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let engine = model.engine(of: pane), pane.channel != nil {
                LiveTVMultiviewSurface(engine: engine)
            }
            switch pane.status {
            case .empty:
                Label(L10n.string("livetv_multiview_pick", fallback: "OK: choose a channel"), systemImage: "plus")
                    .font(.system(size: LiveTVTheme.Font.small, weight: .semibold))
                    .foregroundColor(LiveTVTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text(message)
                    .font(.system(size: LiveTVTheme.Font.badge))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .playing:
                EmptyView()
            }
            // A pane that isn't playing keeps its name.
            if showsLabel || pane.status != .playing {
                label.padding(12)
            }
        }
        .clipped()
        .overlay(
            Rectangle().strokeBorder(
                focused && showsLabel ? AppFocusOutline.color : Color.white.opacity(showsLabel ? 0.15 : 0),
                lineWidth: focused ? AppFocusOutline.emphasizedWidth : 1)
        )
    }

    private var label: some View {
        HStack(spacing: 8) {
            Text("P\(pane.id + 1)")
                .font(.system(size: LiveTVTheme.Font.badge, weight: .heavy))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            if let channel = pane.channel {
                Text(channel.name)
                    .font(.system(size: LiveTVTheme.Font.badge, weight: .semibold))
                    .lineLimit(1)
            }
            if audible, pane.channel != nil {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: LiveTVTheme.Font.badge))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// An engine's picture (the engine's own view, bound to it).
private struct LiveTVMultiviewSurface: UIViewRepresentable {
    let engine: AetherEngine

    func makeUIView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        engine.bind(view: view)
        return view
    }

    func updateUIView(_ view: AetherPlayerView, context: Context) {}

    static func dismantleUIView(_ view: AetherPlayerView, coordinator: ()) {}
}

// MARK: - Pickers

/// The channel picker's state, as the full-screen guide's (LiveTVOverlay):
/// the highlight is an index, only the rows on screen are drawn, so even
/// 100,000 channels scroll at once. Groups as in Live TV: a source's
/// heading (more than one source) folds its groups; locked groups stay out.
@MainActor
final class LiveTVMultiviewPickerModel: ObservableObject {
    enum Level { case groups, channels }

    @Published private(set) var level: Level = .channels
    @Published private(set) var groups: [LiveTVGroup] = []
    @Published private(set) var groupIndex = 0
    /// The group whose channels are listed.
    @Published private(set) var groupID = LiveTVGroup.allID
    @Published private(set) var channels: [XtreamLiveChannel] = []
    @Published private(set) var channelIndex = 0
    @Published private(set) var channelWindow = LiveTVListWindow(rows: 12)
    @Published private(set) var groupWindow = LiveTVListWindow(rows: 12)

    private var groupTask: Task<Void, Never>?
    private var store: LiveTVStore { LiveTVStore.shared }

    var highlighted: XtreamLiveChannel? {
        channels.indices.contains(channelIndex) ? channels[channelIndex] : nil
    }

    /// Opens on the pane's channel, else Favorites when there are some,
    /// else the group Live TV shows.
    func open(current: XtreamLiveChannel?) {
        rebuildGroups()
        let favorites = store.channels(inGroup: LiveTVGroup.favoritesID)
        var group = favorites.isEmpty ? store.selectedGroupID : LiveTVGroup.favoritesID
        if !groups.contains(where: { $0.id == group && !$0.isHeading }) { group = LiveTVGroup.allID }
        var list = store.channels(inGroup: group)
        if let current, !list.contains(where: { $0.streamID == current.streamID }) {
            group = LiveTVGroup.allID
            list = store.channels(inGroup: group)
        }
        show(group: group, channels: list, landOn: current)
        level = .channels
        LiveTVOverlayPan.shared.install { [weak self] delta in self?.scroll(by: delta) }
    }

    func close() {
        groupTask?.cancel()
        LiveTVOverlayPan.shared.remove()
    }

    /// The panel sets how many rows fit.
    func setRows(_ rows: Int) {
        guard channelWindow.rows != rows else { return }
        channelWindow.rows = max(1, rows)
        groupWindow.rows = max(1, rows)
        channelWindow.follow(channelIndex, count: channels.count)
        groupWindow.follow(groupIndex, count: groups.count)
    }

    func move(_ direction: MoveCommandDirection) {
        // Up / Down from a swipe: the swipe itself scrolls.
        if direction == .up || direction == .down, !LiveTVOverlayPan.shared.acceptsMoveCommand() { return }
        switch (level, direction) {
        case (.channels, .up): moveChannel(by: -1, wraps: true)
        case (.channels, .down): moveChannel(by: 1, wraps: true)
        case (.channels, .left):
            groupIndex = groups.firstIndex { $0.id == groupID } ?? 0
            groupWindow.land(on: groupIndex, count: groups.count)
            level = .groups
        case (.groups, .up): moveGroup(by: -1)
        case (.groups, .down): moveGroup(by: 1)
        case (.groups, .right):
            applyPendingGroup()
            level = .channels
        default: break
        }
    }

    func scroll(by delta: Int) {
        switch level {
        case .channels: moveChannel(by: delta, wraps: false)
        case .groups: moveGroup(by: delta)
        }
    }

    /// OK: a channel is picked (returned); a group lists its channels; a
    /// source's heading folds or unfolds its groups.
    func select() -> XtreamLiveChannel? {
        switch level {
        case .channels:
            return highlighted
        case .groups:
            guard groups.indices.contains(groupIndex) else { return nil }
            let group = groups[groupIndex]
            if group.isHeading {
                store.toggleFold(headingID: group.id)
                rebuildGroups()
                groupIndex = groups.firstIndex { $0.id == group.id } ?? 0
                groupWindow.follow(groupIndex, count: groups.count)
                return nil
            }
            applyPendingGroup()
            level = .channels
            return nil
        }
    }

    func isTaken(_ channel: XtreamLiveChannel, in model: LiveTVMultiview) -> Bool {
        model.panes.contains { $0.channel?.streamID == channel.streamID }
    }

    private func rebuildGroups() {
        groups = store.groups.filter { !$0.locked && $0.id != LiveTVGroup.searchID }
    }

    private func show(group: String, channels list: [XtreamLiveChannel], landOn channel: XtreamLiveChannel?) {
        groupID = group
        channels = list
        channelIndex = channel.flatMap { current in list.firstIndex { $0.streamID == current.streamID } } ?? 0
        channelWindow.land(on: channelIndex, count: list.count)
        groupIndex = groups.firstIndex { $0.id == group } ?? 0
        groupWindow.land(on: groupIndex, count: groups.count)
    }

    private func moveChannel(by delta: Int, wraps: Bool) {
        guard !channels.isEmpty else { return }
        if wraps {
            channelIndex = ((channelIndex + delta) % channels.count + channels.count) % channels.count
        } else {
            channelIndex = min(max(0, channelIndex + delta), channels.count - 1)
        }
        channelWindow.follow(channelIndex, count: channels.count)
    }

    private func moveGroup(by delta: Int) {
        guard !groups.isEmpty else { return }
        groupIndex = min(max(0, groupIndex + delta), groups.count - 1)
        groupWindow.follow(groupIndex, count: groups.count)
        // The channels switch once the highlight rests (as the guide).
        groupTask?.cancel()
        groupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.applyPendingGroup()
        }
    }

    private func applyPendingGroup() {
        groupTask?.cancel()
        guard groups.indices.contains(groupIndex) else { return }
        let group = groups[groupIndex]
        guard !group.isHeading, group.id != groupID else { return }
        let index = groupIndex
        show(group: group.id, channels: store.channels(inGroup: group.id), landOn: nil)
        groupIndex = index
    }
}

/// The channels for a pane: groups on the left, their channels on the
/// right. One invisible button takes the remote; rows are drawn from the
/// model's highlight.
private struct LiveTVMultiviewPicker: View {
    @ObservedObject var model: LiveTVMultiview
    let pane: Int
    @ObservedObject private var picker: LiveTVMultiviewPickerModel
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 54
    private static let rowSpacing: CGFloat = 6

    init(model: LiveTVMultiview, pane: Int) {
        self.model = model
        self.pane = pane
        _picker = ObservedObject(wrappedValue: model.picker)
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 0) {
                groupColumn.frame(width: 380)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
                channelColumn.frame(width: 520)
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { setRows(geo.size.height) }
                    .onChange(of: geo.size.height) { _, height in setRows(height) }
            })
            // The remote's target: it draws nothing.
            Button(action: select) { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(LiveTVInvisibleButtonStyle())
                .focused($focused)
                .onMoveCommand { picker.move($0) }
                .onExitCommand(perform: back)
        }
        .liveTVGlass(cornerRadius: 24)
        .padding(30)
        .onAppear {
            picker.open(current: model.panes[pane].channel)
            focused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true }
        }
        .onDisappear { picker.close() }
    }

    private func setRows(_ height: CGFloat) {
        let usable = height - 48
        picker.setRows(max(1, Int((usable + Self.rowSpacing) / (Self.rowHeight + Self.rowSpacing))))
    }

    private func select() {
        guard let channel = picker.select() else { return }
        model.assign(channel, to: pane)
        model.pickerPane = nil
    }

    /// Back: from the channels to the groups first, then closed.
    private func back() {
        if picker.level == .groups {
            picker.move(.right)
        } else {
            model.pickerPane = nil
        }
    }

    private var groupColumn: some View {
        let range = picker.groupWindow.range(count: picker.groups.count)
        return VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(range), id: \.self) { index in
                let group = picker.groups[index]
                row(group.isHeading ? group.name.uppercased() : group.name,
                    detail: group.count.formatted(),
                    heading: group.isHeading,
                    highlighted: picker.level == .groups && index == picker.groupIndex,
                    marked: group.id == picker.groupID,
                    dimmed: picker.level != .groups)
            }
        }
        .padding(.horizontal, 12)
    }

    private var channelColumn: some View {
        let range = picker.channelWindow.range(count: picker.channels.count)
        return VStack(alignment: .leading, spacing: Self.rowSpacing) {
            if picker.channels.isEmpty {
                Text(L10n.string("livetv_multiview_no_channels", fallback: "No channels in this group"))
                    .font(.system(size: LiveTVTheme.Font.small))
                    .foregroundColor(LiveTVTheme.secondaryText)
                    .padding(14)
            }
            ForEach(Array(range), id: \.self) { index in
                let channel = picker.channels[index]
                row(channel.name,
                    detail: channel.number.map(String.init) ?? "",
                    heading: false,
                    highlighted: picker.level == .channels && index == picker.channelIndex,
                    marked: picker.isTaken(channel, in: model),
                    dimmed: false)
            }
        }
        .padding(.horizontal, 12)
    }

    private func row(_ title: String, detail: String, heading: Bool, highlighted: Bool, marked: Bool, dimmed: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: heading ? LiveTVTheme.Font.badge : LiveTVTheme.Font.small,
                              weight: heading ? .heavy : (marked || highlighted ? .semibold : .regular)))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: LiveTVTheme.Font.badge))
                .opacity(0.6)
        }
        .foregroundColor(highlighted ? .black : (heading ? LiveTVTheme.secondaryText : (marked ? LiveTVTheme.accent : LiveTVTheme.primaryText)))
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .background(
            highlighted ? Color.white : Color.white.opacity(marked && !heading ? (dimmed ? 0.16 : 0.12) : 0),
            in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The eight layouts, each with a small picture of its panes.
private struct LiveTVMultiviewLayoutPicker: View {
    @ObservedObject var model: LiveTVMultiview
    @FocusState private var focus: LiveTVMultiviewLayout?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("livetv_multiview_layout", fallback: "Layout"))
                .font(.system(size: LiveTVTheme.Font.secondary, weight: .bold))
                .foregroundColor(LiveTVTheme.primaryText)
                .padding(.bottom, 8)
            ForEach(LiveTVMultiviewLayout.allCases, id: \.self) { layout in
                let isFocused = focus == layout
                Button {
                    model.setLayout(layout)
                    model.layoutPickerOpen = false
                } label: {
                    HStack(spacing: 18) {
                        LiveTVMultiviewLayoutIcon(layout: layout, dark: isFocused)
                            .frame(width: 64, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(layout))
                                .font(.system(size: LiveTVTheme.Font.small, weight: .semibold))
                            Text(Self.detail(layout))
                                .font(.system(size: LiveTVTheme.Font.badge))
                                .opacity(0.7)
                        }
                        Spacer()
                        if layout == model.layout {
                            Text(L10n.string("livetv_multiview_current", fallback: "CURRENT"))
                                .font(.system(size: LiveTVTheme.Font.badge, weight: .bold))
                        }
                    }
                    .foregroundColor(isFocused ? .black : LiveTVTheme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isFocused ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(LiveTVInvisibleButtonStyle())
                .focused($focus, equals: layout)
            }
        }
        .padding(28)
        .frame(width: 520)
        .liveTVGlass(cornerRadius: 24)
        .padding(30)
        .onAppear {
            focus = model.layout
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focus = nil
                DispatchQueue.main.async { focus = model.layout }
            }
        }
        .onExitCommand { model.layoutPickerOpen = false }
    }

    static func title(_ layout: LiveTVMultiviewLayout) -> String {
        layout.paneCount == 1
            ? L10n.string("livetv_multiview_one", fallback: "1 screen")
            : L10n.format("livetv_multiview_screens_format", fallback: "%d screens", layout.paneCount)
    }

    static func detail(_ layout: LiveTVMultiviewLayout) -> String {
        switch layout {
        case .one: return L10n.string("livetv_multiview_layout_one", fallback: "Full screen")
        case .two: return L10n.string("livetv_multiview_layout_two", fallback: "Side by side")
        case .twoStacked: return L10n.string("livetv_multiview_layout_two_stacked", fallback: "Stacked")
        case .three: return L10n.string("livetv_multiview_layout_three", fallback: "2 on top, 1 wide below")
        case .threeWideTop: return L10n.string("livetv_multiview_layout_three_wide", fallback: "1 wide on top, 2 below")
        case .threeBigLeft: return L10n.string("livetv_multiview_layout_three_left", fallback: "1 big on the left, 2 right")
        case .four: return L10n.string("livetv_multiview_layout_four", fallback: "2 × 2")
        case .fourWideTop: return L10n.string("livetv_multiview_layout_four_wide", fallback: "1 wide on top, 3 below")
        }
    }
}

/// A layout's panes as small boxes.
private struct LiveTVMultiviewLayoutIcon: View {
    let layout: LiveTVMultiviewLayout
    let dark: Bool

    var body: some View {
        GeometryReader { geo in
            ForEach(0..<layout.frames.count, id: \.self) { (index: Int) in
                box(layout.frames[index], in: geo.size)
            }
        }
    }

    // In steps: the type checker gave up on it in one expression.
    private func box(_ frame: LiveTVMultiviewLayout.Frame, in size: CGSize) -> some View {
        let width: CGFloat = max(1, CGFloat(frame.width) * size.width - 3)
        let height: CGFloat = max(1, CGFloat(frame.height) * size.height - 3)
        let x: CGFloat = CGFloat(frame.x) * size.width
        let y: CGFloat = CGFloat(frame.y) * size.height
        let color: Color = dark ? Color.black.opacity(0.75) : Color.white.opacity(0.8)
        return RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: width, height: height)
            .offset(x: x, y: y)
    }
}
