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
        // An empty first pane: straight to the channels.
        if list.isEmpty { pickerPane = 0 }
        showOverlays()
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
        return CGRect(x: f.x * size.width, y: f.y * size.height, width: f.width * size.width, height: f.height * size.height)
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

/// The channels for a pane, as Live TV's groups: a group, then its
/// channels. Locked groups stay out (as everywhere).
private struct LiveTVMultiviewPicker: View {
    @ObservedObject var model: LiveTVMultiview
    let pane: Int
    @ObservedObject private var store = LiveTVStore.shared
    @State private var group: String?
    @FocusState private var focus: String?

    private var groups: [LiveTVGroup] {
        store.groups.filter { !$0.locked && $0.id != LiveTVGroup.searchID && !$0.isHeading }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { item in
                        row(item.name, detail: String(item.count), selected: item.id == currentGroup, id: "g:" + item.id) {
                            group = item.id
                            focus = store.channels(inGroup: item.id).first.map { "c:\($0.streamID)" }
                        }
                    }
                }
                .padding(16)
            }
            .frame(width: 360)
            .focusSection()
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.channels(inGroup: currentGroup), id: \.streamID) { channel in
                        let taken = model.panes.contains { $0.channel?.streamID == channel.streamID }
                        row(channel.name, detail: channel.number.map(String.init) ?? "", selected: taken,
                            id: "c:\(channel.streamID)") {
                            model.assign(channel, to: pane)
                            model.pickerPane = nil
                        }
                    }
                }
                .padding(16)
            }
            .frame(width: 520)
            .focusSection()
        }
        .frame(maxHeight: .infinity)
        .padding(.vertical, 40)
        .liveTVGlass(cornerRadius: 24)
        .padding(30)
        .onExitCommand { model.pickerPane = nil }
        .onAppear {
            // Favorites when there are some, else the group Live TV shows.
            let favorites = store.channels(inGroup: LiveTVGroup.favoritesID)
            group = favorites.isEmpty ? store.selectedGroupID : LiveTVGroup.favoritesID
            focus = store.channels(inGroup: currentGroup).first.map { "c:\($0.streamID)" } ?? "g:" + currentGroup
        }
    }

    private var currentGroup: String { group ?? LiveTVGroup.allID }

    private func row(_ title: String, detail: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        let isFocused = focus == id
        return Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: LiveTVTheme.Font.small, weight: selected || isFocused ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: LiveTVTheme.Font.badge))
                    .opacity(0.6)
            }
            .foregroundColor(isFocused ? .black : (selected ? LiveTVTheme.accent : LiveTVTheme.primaryText))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isFocused ? Color.white : Color.white.opacity(selected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focus, equals: id)
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
        .onAppear { focus = model.layout }
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
            ForEach(Array(layout.frames.enumerated()), id: \.offset) { _, f in
                RoundedRectangle(cornerRadius: 3)
                    .fill(dark ? Color.black.opacity(0.75) : Color.white.opacity(0.8))
                    .frame(width: max(1, f.width * geo.size.width - 3), height: max(1, f.height * geo.size.height - 3))
                    .offset(x: f.x * geo.size.width, y: f.y * geo.size.height)
            }
        }
    }
}
