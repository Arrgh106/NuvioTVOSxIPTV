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
    @Published private(set) var channel: XtreamLiveChannel?
    @Published private(set) var status: Status = .idle
    @Published var isFullscreen = false {
        didSet {
            if !isFullscreen { hideBar() }
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
        guard let next = LiveTVZapper.shared.step(by: delta) else { return }
        startChannel(next.channel)
        showBar(.compact)
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

/// Where the preview window sits; the video layer reads it.
struct LiveTVPreviewAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The preview window's place in the info panel (16:9).
struct LiveTVPreviewSlot: View {
    static let size = CGSize(width: 288, height: 162)

    var body: some View {
        RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
            .fill(Color.black)
            .frame(width: Self.size.width, height: Self.size.height)
            .anchorPreference(key: LiveTVPreviewAnchorKey.self, value: .bounds) { $0 }
    }
}

/// The picture, in the preview window or full screen, with its status.
struct LiveTVVideoLayer: View {
    @ObservedObject var player: LiveTVPlayer
    let anchor: Anchor<CGRect>?

    var body: some View {
        GeometryReader { geometry in
            let screen = UIScreen.main.bounds.size
            let rect = anchor.map { geometry[$0] } ?? .zero
            if rect.width > 1 {
                ZStack {
                    // Full screen draws the picture over the app instead
                    // (one engine view can only be in one place).
                    if player.channel != nil, !player.isFullscreen {
                        StablePlayerSurfacePresentation(viewportSize: screen, presentationSize: rect.size) {
                            LiveTVVideoSurface(session: player.session)
                        }
                        // The picture never takes focus or presses.
                        .disabled(true)
                        .allowsHitTesting(false)
                    }
                    LiveTVPlayerStatus(player: player)
                }
                .frame(width: rect.width, height: rect.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
                        .strokeBorder(LiveTVTheme.accent.opacity(player.channel == nil ? 0 : 0.8), lineWidth: 2)
                )
                .position(x: rect.midX, y: rect.midY)
            }
        }
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
            Color.black
            if player.channel != nil {
                LiveTVVideoSurface(session: player.session)
                    .disabled(true)
                    .allowsHitTesting(false)
            }
            LiveTVPlayerStatus(player: player)
            LiveTVFullscreenControls(player: player, onExit: { player.isFullscreen = false })
            LiveTVPlayerBar(player: player)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Full screen: the remote talks to the player (as on Android): Up / Down
/// switch channels, Right shows the info bar, OK the bar with the channel
/// row (Left / Right / OK in it), Left and Menu go back to the guide (Menu
/// first closes the bar).
struct LiveTVFullscreenControls: View {
    @ObservedObject var player: LiveTVPlayer
    let onExit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        // A button for OK; it draws nothing.
        Button(action: select) { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(LiveTVInvisibleButtonStyle())
            .focused($focused)
            .onMoveCommand(perform: move)
            .onExitCommand {
                if player.bar != .hidden { player.hideBar() } else { onExit() }
            }
            .onAppear { focused = true }
    }

    private func select() {
        if player.bar == .expanded { player.playRowSelection() } else { player.showBar(.expanded) }
    }

    private func move(_ direction: MoveCommandDirection) {
        let inRow = player.bar == .expanded
        switch direction {
        case .up:
            if inRow { player.showBar(.compact) } else { player.zap(by: -1) }
        case .down:
            if !inRow { player.zap(by: 1) }
        case .left:
            if inRow { player.moveInRow(by: -1) } else { onExit() }
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
