import SwiftUI
import UIKit

/// Live TV's own player (LIVE_TV_DESIGN.md, step 3), as on Android: one
/// player for the preview window and full screen. OK on a channel plays it
/// small in the info panel; OK on the channel already playing makes the same
/// picture full screen. Same stream, no reconnect: accounts with a single
/// connection can't run a preview and a full-screen player side by side.
///
/// Built on the app's playback session (AetherEngine for HLS / live, MPV as
/// fallback), with its own engines, separate from the film player.
@MainActor
final class LiveTVPlayer: ObservableObject {
    /// One for the app: the preview lives in the Live TV tab, full screen
    /// over the whole app (like the film player), both show this one.
    static let shared = LiveTVPlayer()

    enum Status: Equatable {
        case idle
        case loading
        case playing
        case failed(String)
    }

    let session = PlaybackSessionCoordinator()
    /// The guide over the full-screen picture (step 4b).
    let overlay = LiveTVOverlayModel()
    @Published private(set) var channel: XtreamLiveChannel?
    @Published private(set) var status: Status = .idle
    /// Where the preview window is on screen (nil: not on screen).
    @Published var previewFrame: CGRect?
    @Published var isFullscreen = false {
        didSet {
            if !isFullscreen {
                hideBar()
                overlay.close()
                if oldValue {
                    LiveTVFocusLinks.guideWillReturn?()
                    // Without a preview window nothing would show the
                    // picture: back in the guide, playback ends.
                    if !LiveTVSettings.shared.previewActive {
                        Task { @MainActor [weak self] in
                            guard let self, !self.isFullscreen else { return }
                            self.stop()
                        }
                    }
                }
            }
            if LiveTVFullscreenState.shared.isActive != isFullscreen {
                LiveTVFullscreenState.shared.isActive = isFullscreen
            }
        }
    }

    // MARK: Info bar (step 4)

    enum Bar: Equatable {
        case hidden
        /// Channel and what's on (after switching channels, Right).
        case compact
        /// OK: also the channel row.
        case expanded
    }

    @Published private(set) var bar: Bar = .hidden
    /// The playing channel's programmes (stored guide, else now/next).
    @Published private(set) var programmes: [XtreamProgram] = []
    /// The channel row: recently watched, the playing one first.
    @Published private(set) var rowChannels: [XtreamLiveChannel] = []
    @Published private(set) var rowIndex = 0

    /// Set by Live TV: recently watched channels, and starting a channel
    /// from the row (it knows the store and the zapping list).
    var recentChannels: () -> [XtreamLiveChannel] = { [] }
    var startChannel: (XtreamLiveChannel) -> Void = { _ in }
    private var barTimer: Timer?
    private var programmesTask: Task<Void, Never>?

    private var watch: Timer?
    private var loadStarted = Date.distantPast
    private var triedFallback = false

    /// Starts `channel` (or switches to it). The picture stays where it is:
    /// in the preview window or full screen.
    func play(_ channel: XtreamLiveChannel, item: LiveTVStore.PlaybackItem) {
        self.channel = channel
        status = .loading
        loadStarted = Date()
        loadProgrammes(for: channel)
        triedFallback = false
        session.load(PlaybackLoadRequest(
            videoURL: item.url,
            httpHeaders: item.headers,
            // A preview must not switch the TV's display mode.
            matchContentEnabled: false,
            cacheProfile: .fromSettings(ProfileSettings.current.string(forKey: SettingsKey.networkCache)),
            isLiveStream: true,
            streamName: channel.name,
            filename: channel.name,
            nowPlayingTitle: channel.name
        ))
        PlaybackWakeLock.acquire(ownerID: session.wakeLockOwnerID)
        startWatching()
    }

    /// Ends playback and frees the provider connection.
    func stop() {
        watch?.invalidate()
        watch = nil
        session.stopAll()
        PlaybackWakeLock.release(ownerID: session.wakeLockOwnerID)
        programmesTask?.cancel()
        channel = nil
        programmes = []
        status = .idle
        isFullscreen = false
    }

    /// Up / Down while full screen: the next channel of the group it was
    /// started from (Android and the film player do the same).
    func zap(by delta: Int) {
        // "Reverse channel up/down" (as on Android).
        let step = LiveTVSettings.shared.reverseZap ? -delta : delta
        guard let next = LiveTVZapper.shared.step(by: step) else { return }
        startChannel(next.channel)
        if LiveTVSettings.shared.infoBarOnZap { showBar(.compact) }
    }

    func showBar(_ kind: Bar) {
        if kind == .expanded {
            rowChannels = Array(recentChannels().prefix(20))
            rowIndex = rowChannels.firstIndex { $0.streamID == channel?.streamID } ?? 0
        }
        withAnimation(.easeOut(duration: 0.2)) { bar = kind }
        restartBarTimer()
    }

    func hideBar() {
        barTimer?.invalidate()
        barTimer = nil
        guard bar != .hidden else { return }
        withAnimation(.easeIn(duration: 0.2)) { bar = .hidden }
    }

    /// Left / Right in the channel row.
    func moveInRow(by delta: Int) {
        guard !rowChannels.isEmpty else { return }
        rowIndex = min(max(0, rowIndex + delta), rowChannels.count - 1)
        restartBarTimer()
    }

    /// OK in the channel row: that channel.
    func playRowSelection() {
        guard rowChannels.indices.contains(rowIndex) else { return }
        let target = rowChannels[rowIndex]
        if target.streamID != channel?.streamID { startChannel(target) }
        showBar(.compact)
    }

    /// The bar goes after a while (longer with the channel row open).
    private func restartBarTimer() {
        barTimer?.invalidate()
        barTimer = Timer.scheduledTimer(withTimeInterval: bar == .expanded ? 10 : 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideBar() }
        }
    }

    private func loadProgrammes(for channel: XtreamLiveChannel) {
        programmesTask?.cancel()
        programmes = LiveTVGuideRows.shared.cached(channel) ?? []
        programmesTask = Task { [weak self] in
            let list = await LiveTVGuideRows.shared.programmes(for: channel)
            guard !Task.isCancelled, let self, self.channel?.streamID == channel.streamID else { return }
            self.programmes = list
        }
    }

    /// Loading, first picture, errors. A few cheap property reads twice a
    /// second, only while something plays.
    private func startWatching() {
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard channel != nil else { return }
        let engine = session.activeEngine
        let error = session.lastLoadError ?? engine.currentErrorMessage
        if engine.hasFirstFrameReadyForDisplay {
            if status != .playing { status = .playing }
            return
        }
        if !error.isEmpty {
            // Live streams that don't start natively get one try with MPV.
            if !triedFallback, session.requestLiveStartupFallback(generation: session.loadGeneration) {
                triedFallback = true
                return
            }
            status = .failed(error)
            return
        }
        // No picture after 10 s: the same fallback, once.
        if !triedFallback, Date().timeIntervalSince(loadStarted) > 10 {
            triedFallback = true
            if session.requestLiveStartupFallback(generation: session.loadGeneration) {
                loadStarted = Date()
            }
        }
    }
}

/// Whether Live TV plays full screen, for views outside Live TV (the
/// activity pill hides then).
@MainActor
final class LiveTVFullscreenState: ObservableObject {
    static let shared = LiveTVFullscreenState()
    @Published var isActive = false
}

// MARK: - Video

/// The engine's picture. Rendered at full-screen size and scaled down for
/// the preview (as the app's post-play mini window), so going full screen
/// only changes the scale: the decoder and its surface never resize.
struct LiveTVVideoSurface: View {
    @ObservedObject var session: PlaybackSessionCoordinator

    var body: some View {
        switch session.activeBackend {
        case .aether:
            if let controller = session.aetherController {
                AetherPlayerSurface(controller: controller)
            } else {
                Color.black
            }
        case .mpv:
            MPVVideoSurface(controller: session.mpvController)
        }
    }
}

/// The preview window's place in the info panel (16:9). It reports where
/// it is on screen; the picture itself is drawn over the app there by
/// `LiveTVVideoHost`, with the status and the outline on top.
struct LiveTVPreviewSlot: View {
    static let size = CGSize(width: 288, height: 162)
    @ObservedObject var player = LiveTVPlayer.shared

    var body: some View {
        RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
            .fill(Color.black)
            .frame(width: Self.size.width, height: Self.size.height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                player.previewFrame = frame
            }
            .onDisappear { player.previewFrame = nil }
            // Over the picture (the picture layer sits below Live TV's
            // overlays but above the panel; see LiveTVVideoHost).
            .overlay { LiveTVPlayerStatus(player: player) }
            .overlay(
                RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
                    .strokeBorder(LiveTVTheme.accent.opacity(player.channel == nil ? 0 : 0.8), lineWidth: 2)
            )
    }
}

/// The picture, over the whole app, in one place for the whole session:
/// moving the engine's view between the preview and full screen blacked it
/// out (SwiftUI took it out of its new place). Rendered at full-screen size
/// and scaled to the preview window, so going full screen only changes the
/// scale and position.
struct LiveTVVideoHost: View {
    @ObservedObject var player = LiveTVPlayer.shared
    /// Another full-screen screen or a notice covers Live TV.
    var covered = false
    /// Where this layer's (zero-size) anchor sits on screen.
    @State private var anchor: CGPoint = .zero

    var body: some View {
        // Takes no room at all: a full-screen layer, even an empty one, over
        // the tab view hid the tab bar's "Live TV" pill and kept Menu from
        // reaching it. The picture hangs off a zero-size anchor instead.
        Color.clear
            .frame(width: 0, height: 0)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { anchor = $0 }
            .overlay(alignment: .topLeading) {
                if player.channel != nil { picture }
            }
            .allowsHitTesting(false)
    }

    private var picture: some View {
        let screen = UIScreen.main.bounds.size
        let rect = player.isFullscreen ? CGRect(origin: .zero, size: screen) : (player.previewFrame ?? .zero)
        // Only a running picture: the status and the hint in the preview
        // window are below this layer.
        let visible = player.status == .playing && (player.isFullscreen || (rect.width > 1 && !covered))
        return StablePlayerSurfacePresentation(
            viewportSize: screen,
            presentationSize: CGSize(width: max(rect.width, 1), height: max(rect.height, 1))
        ) {
            LiveTVVideoSurface(session: player.session)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: player.isFullscreen ? 0 : LiveTVTheme.Metric.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
                .strokeBorder(LiveTVTheme.accent.opacity(player.isFullscreen ? 0 : 0.8), lineWidth: 2)
        )
        .offset(x: rect.minX - anchor.x, y: rect.minY - anchor.y)
        .opacity(visible ? 1 : 0)
        // The picture never takes focus or presses.
        .disabled(true)
    }
}

/// Loading, errors, and the hint before anything plays.
struct LiveTVPlayerStatus: View {
    @ObservedObject var player: LiveTVPlayer

    var body: some View {
        switch player.status {
        case .idle:
            Text(L10n.string("livetv_preview_hint", fallback: "Press OK on a channel to preview"))
                .font(.system(size: LiveTVTheme.Font.badge))
                .foregroundColor(LiveTVTheme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(12)
        case .loading:
            ProgressView()
        case .playing:
            EmptyView()
        case .failed(let message):
            Text(message)
                .font(.system(size: player.isFullscreen ? LiveTVTheme.Font.secondary : LiveTVTheme.Font.badge))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(12)
        }
    }
}

/// Live TV full screen, over the whole app (as the film player): the tab
/// bar and its sidebar are out of reach, so no swipe or Menu press can
/// open them. The app shows this while `LiveTVFullscreenState` is active.
struct LiveTVFullscreenHost: View {
    @ObservedObject var player = LiveTVPlayer.shared

    var body: some View {
        ZStack {
            // The picture is below, in LiveTVVideoHost.
            LiveTVPlayerStatus(player: player)
            LiveTVFullscreenControls(player: player, overlay: player.overlay, onExit: { player.isFullscreen = false })
            LiveTVPlayerBar(player: player)
                .allowsHitTesting(false)
            LiveTVOverlayView(overlay: player.overlay, player: player)
        }
        .ignoresSafeArea()
    }
}

/// Full screen: the remote talks to the player (as on Android): Up / Down
/// switch channels, Right shows the info bar, OK the bar with the channel
/// row (Left / Right / OK in it), Left the guide over the picture, Menu goes
/// back to the guide (first closing the bar or the overlay).
struct LiveTVFullscreenControls: View {
    @ObservedObject var player: LiveTVPlayer
    @ObservedObject var overlay: LiveTVOverlayModel
    let onExit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        // A button for OK; it draws nothing.
        Button(action: select) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(LiveTVInvisibleButtonStyle())
            .focused($focused)
            .onMoveCommand(perform: move)
            .onExitCommand {
                if overlay.isOpen {
                    overlay.back()
                } else if player.bar != .hidden {
                    player.hideBar()
                } else {
                    onExit()
                }
            }
            .onAppear { focused = true }
    }

    private func select() {
        if overlay.isOpen {
            overlay.select(playing: player.channel)
        } else if player.bar == .expanded {
            player.playRowSelection()
        } else {
            player.showBar(.expanded)
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        if overlay.isOpen {
            overlay.move(direction)
            return
        }
        let inRow = player.bar == .expanded
        switch direction {
        case .up:
            if inRow { player.showBar(.compact) } else { player.zap(by: -1) }
        case .down:
            if !inRow { player.zap(by: 1) }
        case .left:
            if inRow {
                player.moveInRow(by: -1)
            } else {
                player.hideBar()
                overlay.open(playing: player.channel)
            }
        case .right:
            if inRow { player.moveInRow(by: 1) } else { player.showBar(.compact) }
        @unknown default:
            break
        }
    }
}

struct LiveTVInvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
