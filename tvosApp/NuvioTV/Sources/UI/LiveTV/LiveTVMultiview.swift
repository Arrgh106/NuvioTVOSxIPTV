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
        /// A run of tries since the channel was picked (step 15b): drops
        /// reconnect, the second in a row moves to a backup copy.
        fileprivate var attempts = 0
        fileprivate var tried: Set<Int> = []
        fileprivate var playingSince: Date?
        fileprivate var retryTask: Task<Void, Never>?

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
        // Backup copies are ready by the time a pane needs one.
        LiveTVStore.shared.prepareBackups()
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

    /// `run`: a reconnect or a backup copy, not a channel you picked (the
    /// tries so far count).
    func assign(_ channel: XtreamLiveChannel, to index: Int, run: Bool = false) {
        guard panes.indices.contains(index) else { return }
        let pane = panes[index]
        clear(pane)
        if !run {
            pane.attempts = 0
            pane.tried = []
        }
        pane.channel = channel
        pane.status = .loading
        if pane.engine == nil { pane.engine = try? AetherEngine() }
        guard let engine = pane.engine else {
            pane.status = .failed(L10n.string("livetv_multiview_no_player", fallback: "No player for this pane"))
            return
        }
        pane.watch = engine.$state.combineLatest(engine.$hasFirstFrameReadyForDisplay)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak pane] state, firstFrame in
                MainActor.assumeIsolated {
                    guard let self, let pane, pane.channel != nil else { return }
                    switch state {
                    case .error(let message): self.paneFailed(pane, message)
                    // A live stream never really ends: the provider closed it.
                    case .ended: self.paneFailed(pane, L10n.string("livetv_multiview_lost", fallback: "The stream stopped"))
                    default:
                        // Playing again (not the engine stopped for a reconnect).
                        if firstFrame, state == .playing, pane.status != .playing {
                            pane.status = .playing
                            pane.playingSince = Date()
                        }
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
                self?.paneFailed(pane, error.localizedDescription)
            }
        }
        applySound()
    }

    func remove(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        clear(panes[index])
        if fullPane == index { fullPane = nil }
    }

    /// How often a pane reconnects before it shows its error.
    private static let maxAttempts = 3

    /// A pane's stream failed or dropped (step 15b, as Android's panes): it
    /// reconnects after a short wait; the second failure in a row moves it
    /// to a backup copy of the channel when there is one (Backup Channel
    /// on); out of tries, it shows the error.
    private func paneFailed(_ pane: Pane, _ message: String) {
        guard let channel = pane.channel, pane.retryTask == nil else { return }
        if case .failed = pane.status { return }
        // Playing for a minute since the last drop counts as recovered.
        if let since = pane.playingSince, Date().timeIntervalSince(since) >= 60 {
            pane.attempts = 0
            pane.tried = []
        }
        pane.playingSince = nil
        pane.attempts += 1
        pane.task?.cancel()
        pane.engine?.stop()
        let index = pane.id
        if pane.attempts >= 2, LiveTVSettings.shared.backupChannel {
            pane.tried.insert(channel.streamID)
            if let backup = LiveTVStore.shared.backup(for: channel, tried: pane.tried) {
                print("[Multiview] P\(index + 1): \(channel.name) won't play: switched to \(backup.name)")
                assign(backup, to: index, run: true)
                return
            }
        }
        guard pane.attempts <= Self.maxAttempts else {
            pane.status = .failed(message)
            return
        }
        // The last picture stays; the pane shows it is loading again.
        pane.status = .loading
        let wait = UInt64(min(pane.attempts * 2, 10)) * 1_000_000_000
        pane.retryTask = Task { [weak self, weak pane] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self, let pane, pane.channel?.streamID == channel.streamID else { return }
            pane.retryTask = nil
            self.assign(channel, to: index, run: true)
        }
    }

    private func clear(_ pane: Pane) {
        pane.retryTask?.cancel()
        pane.retryTask = nil
        pane.playingSince = nil
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
    /// The highlight is on the bar (Up from a top pane). Only then can the
    /// bar take focus, and the panes can't: a swipe up bounced straight
    /// back to the panes.
    @State private var onBar = false

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
                        showsLabel: model.overlaysShown || model.fullPane == pane.id,
                        // The bar is over the top panes' names: below it.
                        labelTop: model.overlaysShown
                            && (model.fullPane == pane.id || (model.fullPane == nil && model.layout.isTop(pane.id)))
                            ? 120 : 12)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        // Full screen: the others play on underneath.
                        .zIndex(model.fullPane == pane.id ? 1 : 0)
                        .opacity(model.fullPane == nil || model.fullPane == pane.id ? 1 : 0)
                }
                // The remote's target over the panes: it draws nothing. Gone
                // while a picker is open: only disabled, it kept the focus
                // and the channel list (UIKit) never got it.
                if model.pickerPane == nil && !model.layoutPickerOpen {
                    Button(action: { model.select() }) { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(LiveTVInvisibleButtonStyle())
                        .focused($focus, equals: .panes)
                        .onMoveCommand(perform: move)
                        .onExitCommand { model.back() }
                        .disabled(onBar)
                        .zIndex(2)
                }
                if model.overlaysShown {
                    bar
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 30)
                        // A picker open: the remote stays in it.
                        .disabled(model.pickerPane != nil || model.layoutPickerOpen || !onBar)
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
        .onChange(of: model.pickerPane) { _, open in
            if open == nil { leaveBar() } else { focus = nil }
        }
        // On the bar: it stays up; back on the panes the timer runs again.
        .onChange(of: onBar) { _, value in model.barFocused = value }
        .onChange(of: model.layoutPickerOpen) { _, open in if !open { leaveBar() } }
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

    /// Back to the panes from the bar.
    private func leaveBar() {
        onBar = false
        DispatchQueue.main.async { focus = .panes }
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
                onBar = true
                // Once the bar can take focus.
                DispatchQueue.main.async { focus = .layout }
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
        .onExitCommand { leaveBar() }
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
        // Down from the bar: back to the panes.
        .onMoveCommand { if $0 == .down { leaveBar() } }
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
    /// How far down the name sits (below the bar while it's up).
    var labelTop: CGFloat = 12

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
                label
                    .padding(12)
                    .padding(.top, labelTop - 12)
                    .animation(.easeInOut(duration: 0.2), value: labelTop)
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
        VStack(alignment: .leading, spacing: 4) {
            nameLine
            // What's on now (step 15b).
            if let channel = pane.channel {
                LiveTVMultiviewNow(channel: channel)
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    private var nameLine: some View {
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
    }
}

/// A pane's show on now, with how far it is (step 15b, as Android's pane
/// names). Nothing without guide information.
private struct LiveTVMultiviewNow: View {
    let channel: XtreamLiveChannel
    @State private var programmes: [XtreamProgram] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let show = programmes.first(where: { $0.start <= context.date && context.date < $0.end }) {
                let info = LiveTVProgrammeInfo(start: show.start, end: show.end, title: nil, description: nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title)
                        .font(.system(size: LiveTVTheme.Font.badge))
                        .foregroundColor(LiveTVTheme.accent)
                        .lineLimit(1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule().fill(LiveTVTheme.markColor)
                            .frame(width: 180 * info.progress(at: context.date))
                    }
                    .frame(width: 180, height: 3)
                }
            }
        }
        .task(id: channel.streamID) {
            programmes = LiveTVGuideRows.shared.cached(channel) ?? []
            programmes = await LiveTVGuideRows.shared.programmes(for: channel)
        }
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

/// The channel picker, as Android's: one list down the side away from the
/// pane being filled. Your groups on top, then each source's heading
/// (more than one source; OK folds its groups) with its own All channels
/// and its groups (one source: All channels on top); OK on a group opens its channels under it (number, logo, name,
/// what's on now). The list is a `UICollectionView` with cell reuse, as
/// Live TV's lists: tvOS scrolls it natively, with its fast-scroll thumb on
/// long swipes.
@MainActor
final class LiveTVMultiviewPickerModel: ObservableObject {
    enum Item {
        /// The first row: search the channels (step 15b); with a search
        /// on, its words and how many were found.
        case search(String?, count: Int)
        case heading(LiveTVGroup)
        case group(LiveTVGroup, open: Bool)
        case channel(XtreamLiveChannel)
    }

    private(set) var items: [Item] = []
    /// Bumped when the items change: the list loads them again.
    @Published private(set) var version = 0
    /// The row with the focus (the list keeps it).
    var index = 0
    /// After a change, the row the focus goes to.
    private(set) var focusTarget: Int?

    private var groups: [LiveTVGroup] = []
    private var openGroupID: String?
    private var openChannels: [XtreamLiveChannel] = []
    /// The words searched for (nil: no search); the list shows what was
    /// found instead of the groups.
    private(set) var query: String?
    private var results: [XtreamLiveChannel] = []
    private var store: LiveTVStore { LiveTVStore.shared }

    /// Most channels a search shows (as Android).
    private static let maxResults = 5000

    /// Opens on the pane's channel in its group, else Favorites when there
    /// are some, else the group Live TV shows.
    func open(current: XtreamLiveChannel?) {
        query = nil
        results = []
        groups = pickerGroups()
        let favorites = store.channels(inGroup: LiveTVGroup.favoritesID)
        var group = favorites.isEmpty ? store.selectedGroupID : LiveTVGroup.favoritesID
        if !groups.contains(where: { $0.id == group && !$0.isHeading }) { group = allGroup(for: current) }
        var list = channels(of: group)
        if let current, !list.contains(where: { $0.streamID == current.streamID }) {
            group = allGroup(for: current)
            list = channels(of: group)
        }
        openGroupID = group
        openChannels = list
        rebuild()
        let groupRow = items.firstIndex { if case .group(let g, _) = $0 { return g.id == group } else { return false } } ?? 0
        let at = current.flatMap { channel in list.firstIndex { $0.streamID == channel.streamID } }.map { groupRow + 1 + $0 }
            ?? (list.isEmpty ? groupRow : groupRow + 1)
        index = at
        focusTarget = at
        version &+= 1
    }

    func focusTaken() { focusTarget = nil }

    /// OK on a row: a channel is picked (returned); a group opens or
    /// closes; a heading folds or unfolds its source's groups.
    func select(_ at: Int) -> XtreamLiveChannel? {
        guard items.indices.contains(at) else { return nil }
        switch items[at] {
        case .channel(let channel):
            return channel
        case .group(let group, _):
            toggle(group)
        case .heading(let heading):
            store.toggleFold(headingID: heading.id)
            groups = pickerGroups()
            rebuild()
            land(on: items.firstIndex { if case .heading(let h) = $0 { return h.id == heading.id } else { return false } } ?? 0)
        case .search:
            // The list asks for the words (the keyboard), then `search`.
            break
        }
        return nil
    }

    /// Searches channel names in every shown group; empty words end the
    /// search. The highlight goes to the first channel found.
    func search(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            endSearch()
            return
        }
        query = words
        var found: [XtreamLiveChannel] = []
        for channel in store.channels(inGroup: LiveTVGroup.allID) where channel.name.localizedCaseInsensitiveContains(words) {
            found.append(channel)
            if found.count == Self.maxResults { break }
        }
        results = found
        rebuild()
        land(on: found.isEmpty ? 0 : 1)
    }

    private func endSearch() {
        query = nil
        results = []
        rebuild()
        land(on: openGroupIndex ?? 0)
    }

    /// Left in the channels: up to their group.
    func left() {
        guard items.indices.contains(index), case .channel = items[index], let at = openGroupIndex else { return }
        land(on: at)
    }

    /// Right on a closed group: its channels.
    func right() {
        guard items.indices.contains(index), case .group(let group, let open) = items[index], !open else { return }
        toggle(group)
    }

    /// Back: in an open group, it closes (the focus on it); else false and
    /// the picker closes.
    func back() -> Bool {
        // A search ends first.
        if query != nil {
            endSearch()
            return true
        }
        guard let at = openGroupIndex, case .group(let group, _) = items[at], index >= at else { return false }
        toggle(group)
        return true
    }

    private var openGroupIndex: Int? {
        guard let id = openGroupID else { return nil }
        return items.firstIndex { if case .group(let g, _) = $0 { return g.id == id } else { return false } }
    }

    /// Opens a group (closing the one open) or closes it.
    private func toggle(_ group: LiveTVGroup) {
        if openGroupID == group.id {
            openGroupID = nil
            openChannels = []
        } else {
            openGroupID = group.id
            openChannels = channels(of: group.id)
        }
        rebuild()
        land(on: items.firstIndex { if case .group(let g, _) = $0 { return g.id == group.id } else { return false } } ?? 0)
    }

    /// The groups as rows (each source's All channels under its heading
    /// comes from the store).
    private func pickerGroups() -> [LiveTVGroup] {
        store.groups.filter { !$0.locked && $0.id != LiveTVGroup.searchID }
    }

    private func channels(of groupID: String) -> [XtreamLiveChannel] {
        store.channels(inGroup: groupID)
    }

    private func allGroup(for channel: XtreamLiveChannel?) -> String {
        store.allGroupID(for: channel)
    }

    private func land(on at: Int) {
        index = at
        focusTarget = at
        version &+= 1
    }

    private func rebuild() {
        var list: [Item] = [.search(query, count: results.count)]
        if query != nil {
            list += results.map(Item.channel)
            items = list
            index = min(index, max(0, list.count - 1))
            return
        }
        list.reserveCapacity(groups.count + openChannels.count + 1)
        for group in groups {
            if group.isHeading {
                list.append(.heading(group))
            } else {
                let open = group.id == openGroupID
                list.append(.group(group, open: open))
                if open { list += openChannels.map(Item.channel) }
            }
        }
        items = list
        index = min(index, max(0, list.count - 1))
    }
}

/// The picker's panel: its pane and title on top, the list, a hint below.
private struct LiveTVMultiviewPicker: View {
    @ObservedObject var model: LiveTVMultiview
    let pane: Int
    @ObservedObject private var picker: LiveTVMultiviewPickerModel

    static let width: CGFloat = 680

    init(model: LiveTVMultiview, pane: Int) {
        self.model = model
        self.pane = pane
        _picker = ObservedObject(wrappedValue: model.picker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("livetv_multiview_pane_format", fallback: "Pane %d", pane + 1))
                    .font(.system(size: LiveTVTheme.Font.badge, weight: .semibold))
                    .foregroundColor(LiveTVTheme.secondaryText)
                Text(L10n.string("livetv_multiview_channels", fallback: "Channels"))
                    .font(.system(size: LiveTVTheme.Font.secondary, weight: .bold))
                    .foregroundColor(LiveTVTheme.primaryText)
            }
            .padding(.horizontal, 26)
            LiveTVMultiviewPickerList(
                picker: picker, version: picker.version, pane: pane,
                paneOf: { id in model.panes.first { $0.channel?.streamID == id }?.id },
                onPick: { channel in
                    model.assign(channel, to: pane)
                    model.pickerPane = nil
                },
                onBack: { if !picker.back() { model.pickerPane = nil } })
                .frame(maxHeight: .infinity)
            Text(L10n.format("livetv_multiview_picker_hint", fallback: "OK: play in P%d · Back: close", pane + 1))
                .font(.system(size: LiveTVTheme.Font.badge))
                .foregroundColor(LiveTVTheme.secondaryText)
                .padding(.horizontal, 26)
        }
        .padding(.vertical, 24)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .liveTVGlass(cornerRadius: 24)
        .padding(20)
        .onAppear { picker.open(current: model.panes[pane].channel) }
    }
}

/// The picker's rows in a `UICollectionView`.
private struct LiveTVMultiviewPickerList: UIViewRepresentable {
    let picker: LiveTVMultiviewPickerModel
    let version: Int
    let pane: Int
    let paneOf: (Int) -> Int?
    let onPick: (XtreamLiveChannel) -> Void
    let onBack: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(picker: picker) }

    func makeUIView(context: Context) -> LiveTVMenuTakingView {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVMultiviewPickerCell.height)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVMultiviewPickerCell.height)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 4
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.remembersLastFocusedIndexPath = false
        view.register(LiveTVMultiviewPickerCell.self, forCellWithReuseIdentifier: LiveTVMultiviewPickerCell.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        // Left / Right presses: to the group, into a group.
        for (type, action) in [(UIPress.PressType.leftArrow, #selector(Coordinator.pressLeft)),
                               (UIPress.PressType.rightArrow, #selector(Coordinator.pressRight))] {
            let press = UITapGestureRecognizer(target: context.coordinator, action: action)
            press.allowedPressTypes = [NSNumber(value: type.rawValue)]
            view.addGestureRecognizer(press)
        }
        // Menu: back in the picker (closes a group, then the picker). A
        // recognizer of its own that the app's other Menu handlers wait on:
        // the root's safety net (an overlay is up) took the press first.
        let menu = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressMenu))
        menu.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menu.delegate = context.coordinator
        view.addGestureRecognizer(menu)
        let container = LiveTVMenuTakingView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Search: an editor kept off screen (as Settings' fields), so OK
        // opens the tvOS keyboard straight away, also typing on the iPhone.
        let field = UITextField(frame: CGRect(x: -4_000, y: 0, width: 1, height: 1))
        field.backgroundColor = .clear
        field.textColor = .clear
        field.tintColor = .clear
        field.keyboardAppearance = .dark
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.placeholder = L10n.string("livetv_search_channels", fallback: "Search channels")
        field.delegate = context.coordinator
        container.addSubview(field)
        context.coordinator.searchField = field
        context.coordinator.collection = view
        update(context.coordinator)
        return container
    }

    func updateUIView(_ container: LiveTVMenuTakingView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.pane = pane
        coordinator.paneOf = paneOf
        coordinator.onPick = onPick
        coordinator.onBack = onBack
        coordinator.apply(version: version)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate,
                             UITextFieldDelegate {
        let picker: LiveTVMultiviewPickerModel
        weak var collection: UICollectionView?
        weak var searchField: UITextField?
        var pane = 0
        var paneOf: (Int) -> Int? = { _ in nil }
        var onPick: (XtreamLiveChannel) -> Void = { _ in }
        var onBack: () -> Void = {}
        private var shownVersion = -1
        private var rowsTask: Task<Void, Never>?

        init(picker: LiveTVMultiviewPickerModel) { self.picker = picker }

        func apply(version: Int) {
            guard version != shownVersion, let collection else { return }
            shownVersion = version
            collection.reloadData()
            guard let target = picker.focusTarget, picker.items.indices.contains(target) else { return }
            collection.layoutIfNeeded()
            collection.scrollToItem(at: IndexPath(item: target, section: 0), at: .centeredVertically, animated: false)
            // The focus goes to the row (preferred below). Asked of the
            // window's focus system: the panes' button had the focus and
            // went disabled, so nothing in the list could ask for it.
            pullFocus(attempts: 4)
            loadRows(after: 0.3)
        }

        /// Moves the focus into the list, trying again while the panel is
        /// still appearing.
        func pullFocus(attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let collection = self.collection else { return }
                if let window = collection.window, let system = UIFocusSystem.focusSystem(for: window) {
                    // In the list already, on the row asked for (a search
                    // moves it off the search row).
                    if let item = system.focusedItem as? UIView, item.isDescendant(of: collection) {
                        guard let target = self.picker.focusTarget, let cell = item as? UICollectionViewCell,
                              collection.indexPath(for: cell)?.item != target else { return }
                    }
                    system.requestFocusUpdate(to: collection)
                    system.updateFocusIfNeeded()
                }
                guard attempts > 1 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.pullFocus(attempts: attempts - 1) }
            }
        }

        @objc func pressLeft() { picker.left() }
        @objc func pressRight() { picker.right() }
        @objc func pressMenu() { onBack() }

        /// Every other Menu recognizer waits until the picker's has failed.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.menu.rawValue))
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            picker.items.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LiveTVMultiviewPickerCell.reuseID, for: indexPath)
            configure(cell as? LiveTVMultiviewPickerCell, at: indexPath.item)
            return cell
        }

        private func configure(_ cell: LiveTVMultiviewPickerCell?, at index: Int) {
            guard let cell, picker.items.indices.contains(index) else { return }
            switch picker.items[index] {
            case .search(let query, let count): cell.configureSearch(query, count: count)
            case .heading(let group): cell.configureHeading(group, folded: LiveTVStore.shared.isFolded(headingID: group.id))
            case .group(let group, let open): cell.configureGroup(group, open: open)
            case .channel(let channel):
                let inPane = paneOf(channel.streamID)
                cell.configureChannel(channel, inThisPane: inPane == pane, otherPane: inPane == pane ? nil : inPane)
            }
        }

        func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
            let at = picker.focusTarget ?? picker.index
            return picker.items.indices.contains(at) ? IndexPath(item: at, section: 0) : nil
        }

        func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                            with coordinator: UIFocusAnimationCoordinator) {
            guard let path = context.nextFocusedIndexPath else { return }
            picker.index = path.item
            if picker.focusTarget == path.item { picker.focusTaken() }
            loadRows(after: 0.3)
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            picker.index = indexPath.item
            if picker.items.indices.contains(indexPath.item), case .search = picker.items[indexPath.item] {
                askForSearch()
                return
            }
            if let channel = picker.select(indexPath.item) { onPick(channel) }
        }

        /// The tvOS keyboard straight away (the off-screen editor), with
        /// the words searched so far.
        private func askForSearch() {
            guard let field = searchField else { return }
            field.text = picker.query
            field.becomeFirstResponder()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        /// The keyboard closed (Search, or Menu): the words are searched;
        /// unchanged words leave the list as it is.
        func textFieldDidEndEditing(_ textField: UITextField) {
            let words = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard words != (picker.query ?? "") else { return }
            picker.search(words)
        }

        /// What's on for the channels on screen, once the focus rests.
        private func loadRows(after seconds: Double) {
            rowsTask?.cancel()
            rowsTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self, let collection = self.collection else { return }
                let paths = collection.indexPathsForVisibleItems
                let missing = paths.compactMap { path -> XtreamLiveChannel? in
                    guard self.picker.items.indices.contains(path.item),
                          case .channel(let channel) = self.picker.items[path.item],
                          LiveTVGuideRows.shared.cached(channel) == nil else { return nil }
                    return channel
                }
                guard !missing.isEmpty else { return }
                await withTaskGroup(of: Void.self) { group in
                    for channel in missing {
                        group.addTask { @MainActor in _ = await LiveTVGuideRows.shared.programmes(for: channel) }
                    }
                }
                guard !Task.isCancelled else { return }
                for path in collection.indexPathsForVisibleItems {
                    self.configure(collection.cellForItem(at: path) as? LiveTVMultiviewPickerCell, at: path.item)
                }
            }
        }
    }
}

/// One row: a source's heading, a group (with its fold arrow) or a
/// channel (number, logo, name, what's on now and its progress).
private final class LiveTVMultiviewPickerCell: UICollectionViewCell {
    static let reuseID = "LiveTVMultiviewPickerCell"
    static let height: CGFloat = 76

    private enum Kind { case heading, group, channel }

    private let background = UIView()
    private let chevron = UIImageView()
    private let numberLabel = UILabel()
    private let logoView = UIImageView()
    private let titleLabel = UILabel()
    private let nowLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let detailLabel = UILabel()
    private let badge = UILabel()
    private let playMark = UIImageView(image: UIImage(systemName: "play.fill"))
    private var progressWidth: NSLayoutConstraint?
    private var leading: NSLayoutConstraint?
    private var kind = Kind.group
    private var hasShow = false
    private var logoURL: URL?
    private var logoTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = 12
        background.layer.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(background)

        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        numberLabel.textAlignment = .right
        logoView.contentMode = .scaleAspectFit
        titleLabel.lineBreakMode = .byTruncatingTail
        nowLabel.font = .systemFont(ofSize: 20)
        nowLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        badge.font = .systemFont(ofSize: 20, weight: .heavy)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 5
        badge.layer.masksToBounds = true
        playMark.contentMode = .scaleAspectFit
        playMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        progressTrack.layer.cornerRadius = 1.5
        progressFill.layer.cornerRadius = 1.5
        for view in [chevron, numberLabel, logoView, titleLabel, nowLabel, progressTrack, detailLabel, badge, playMark] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        for label in [titleLabel, nowLabel] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        for view in [detailLabel, badge, playMark] as [UIView] {
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let leading = chevron.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        self.leading = leading
        let progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        self.progressWidth = progressWidth
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            background.topAnchor.constraint(equalTo: contentView.topAnchor),
            background.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            leading,
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 24),
            numberLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            numberLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 64),
            logoView.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 12),
            logoView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 48),
            logoView.heightAnchor.constraint(equalToConstant: 48),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: playMark.leadingAnchor, constant: -12),
            nowLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            nowLabel.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),
            nowLabel.trailingAnchor.constraint(lessThanOrEqualTo: playMark.leadingAnchor, constant: -12),
            nowLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            progressTrack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressTrack.widthAnchor.constraint(equalToConstant: 220),
            progressTrack.heightAnchor.constraint(equalToConstant: 3),
            progressTrack.topAnchor.constraint(equalTo: nowLabel.bottomAnchor, constant: 5),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressWidth,
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            detailLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            badge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            playMark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            playMark.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        titleConstraints = (
            groupLeading: titleLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 12),
            channelLeading: titleLabel.leadingAnchor.constraint(equalTo: logoView.trailingAnchor, constant: 14),
            centered: titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            top: titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8))
        applyStyle()
    }

    private var titleConstraints: (groupLeading: NSLayoutConstraint, channelLeading: NSLayoutConstraint,
                                   centered: NSLayoutConstraint, top: NSLayoutConstraint)?

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoTask?.cancel()
        logoTask = nil
        logoURL = nil
        logoView.image = nil
    }

    /// The search row: a magnifier, the words searched and how many found.
    func configureSearch(_ query: String?, count: Int) {
        setKind(.group)
        chevron.image = UIImage(systemName: "magnifyingglass")
        titleLabel.text = query.map { L10n.format("livetv_search_for_format", fallback: "Search: %@", $0) }
            ?? L10n.string("livetv_search_channels", fallback: "Search channels")
        titleLabel.font = .systemFont(ofSize: 26, weight: query == nil ? .regular : .bold)
        detailLabel.text = query == nil ? "" : count.formatted()
        applyStyle()
    }

    /// A source's heading: the same arrow as a group's.
    func configureHeading(_ group: LiveTVGroup, folded: Bool) {
        setKind(.heading)
        chevron.image = UIImage(systemName: folded ? "chevron.right" : "chevron.down")
        titleLabel.text = group.name.uppercased()
        detailLabel.text = group.count.formatted()
        applyStyle()
    }

    func configureGroup(_ group: LiveTVGroup, open: Bool) {
        setKind(.group)
        chevron.image = UIImage(systemName: open ? "chevron.down" : "chevron.right")
        titleLabel.text = group.name
        titleLabel.font = .systemFont(ofSize: 26, weight: open ? .bold : .regular)
        detailLabel.text = group.count.formatted()
        applyStyle()
    }

    func configureChannel(_ channel: XtreamLiveChannel, inThisPane: Bool, otherPane: Int?) {
        setKind(.channel)
        numberLabel.text = channel.number.map { String($0) } ?? ""
        titleLabel.text = channel.name
        let now = Date()
        let show = LiveTVGuideRows.shared.cached(channel)?.first { $0.start <= now && now < $0.end }
        hasShow = show != nil
        nowLabel.text = show?.title ?? L10n.string("livetv_info_none", fallback: "No information")
        progressTrack.isHidden = show == nil
        if let show {
            let info = LiveTVProgrammeInfo(start: show.start, end: show.end, title: nil, description: nil)
            progressWidth?.constant = 220 * CGFloat(info.progress(at: now))
        }
        playMark.isHidden = !inThisPane
        badge.isHidden = otherPane == nil
        badge.text = otherPane.map { "P\($0 + 1)" }
        loadLogo(channel.logoURL.flatMap(URL.init(string:)))
        applyStyle()
    }

    private func setKind(_ value: Kind) {
        kind = value
        let isChannel = value == .channel
        chevron.isHidden = isChannel
        numberLabel.isHidden = !isChannel
        logoView.isHidden = !isChannel
        nowLabel.isHidden = !isChannel
        progressTrack.isHidden = !isChannel
        detailLabel.isHidden = isChannel
        if !isChannel {
            badge.isHidden = true
            playMark.isHidden = true
        }
        guard let c = titleConstraints else { return }
        c.groupLeading.isActive = false
        c.channelLeading.isActive = false
        c.centered.isActive = false
        c.top.isActive = false
        if isChannel {
            c.channelLeading.isActive = true
            c.top.isActive = true
        } else {
            c.groupLeading.constant = 12
            c.groupLeading.isActive = true
            c.centered.isActive = true
        }
        if value == .heading { titleLabel.font = .systemFont(ofSize: 20, weight: .heavy) }
        if isChannel { titleLabel.font = .systemFont(ofSize: 24, weight: .semibold) }
    }

    private func loadLogo(_ url: URL?) {
        guard url != logoURL else { return }
        logoTask?.cancel()
        logoURL = url
        logoView.image = UIImage(systemName: "tv")
        guard let url else { return }
        if let cached = LiveTVLogoCache.shared.image(for: url) {
            logoView.image = cached
            return
        }
        logoTask = Task { [weak self] in
            guard let image = await LiveTVLogoCache.shared.load(url) else { return }
            guard let self, self.logoURL == url else { return }
            self.logoView.image = image
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({ [weak self] in self?.applyStyle() })
    }

    private func applyStyle() {
        let focused = isFocused
        let primary: UIColor = focused ? .black : .white
        let secondary: UIColor = focused ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.6)
        background.backgroundColor = focused ? .white : .clear
        titleLabel.textColor = kind == .heading ? secondary : primary
        chevron.tintColor = primary
        numberLabel.textColor = secondary
        detailLabel.textColor = secondary
        nowLabel.textColor = hasShow ? (focused ? .black : LiveTVTheme.accentUIColor) : secondary
        progressTrack.backgroundColor = focused ? UIColor.black.withAlphaComponent(0.2) : UIColor.white.withAlphaComponent(0.18)
        progressFill.backgroundColor = focused ? .black : LiveTVTheme.markUIColor
        badge.textColor = primary
        badge.backgroundColor = focused ? UIColor.black.withAlphaComponent(0.12) : UIColor.white.withAlphaComponent(0.18)
        playMark.tintColor = focused ? .black : LiveTVTheme.markUIColor
        logoView.tintColor = secondary
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
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
