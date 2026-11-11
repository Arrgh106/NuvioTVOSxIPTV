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
    /// Something of Live TV's lies over the preview window (the quick menu):
    /// the picture, drawn over the whole app, would cover it.
    @Published var previewCovered = false
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
    /// Set by Live TV: plays a show of a channel again (it knows the links).
    var startReplay: (XtreamLiveChannel, XtreamProgram) -> Void = { _, _ in }
    private var barTimer: Timer?
    private var programmesTask: Task<Void, Never>?

    private var watch: Timer?
    private var loadStarted = Date.distantPast
    private var triedFallback = false

    /// A show played again (catch-up, step 6); nil: live.
    @Published private(set) var replay: XtreamProgram?
    /// The replay links not tried yet (panels differ, see LiveTVCatchup).
    private var replayLinks: [URL] = []
    private var replayHeaders: [String: String] = [:]
    /// The replay link playing (1-based) of how many, shown while it loads.
    @Published private(set) var replayAttempt: (index: Int, of: Int) = (0, 0)
    /// A replay's first picture: make sure it plays (a Play/Pause press
    /// during the switch could leave it paused).
    private var playOnFirstFrame = false
    /// A replay paused, Play/Pause again: continue it, or back to live?
    @Published private(set) var resumeChoice = false

    /// Starts `channel` (or switches to it). The picture stays where it is:
    /// in the preview window or full screen.
    func play(_ channel: XtreamLiveChannel, item: LiveTVStore.PlaybackItem) {
        resumeChoice = false
        replay = nil
        replayLinks = []
        start(channel, url: item.url, headers: item.headers, live: true)
    }

    /// Plays a past show of `channel` from its start, trying the links in turn.
    func playCatchup(_ channel: XtreamLiveChannel, programme: XtreamProgram, urls: [URL], headers: [String: String]) {
        guard let first = urls.first else { return }
        resumeChoice = false
        replay = programme
        replayLinks = Array(urls.dropFirst())
        replayHeaders = headers
        replayAttempt = (1, urls.count)
        playOnFirstFrame = true
        start(channel, url: first, headers: headers, live: false)
    }

    private func start(_ channel: XtreamLiveChannel, url: URL, headers: [String: String], live: Bool) {
        self.channel = channel
        status = .loading
        loadStarted = Date()
        loadProgrammes(for: channel)
        triedFallback = !live
        session.load(PlaybackLoadRequest(
            videoURL: url,
            httpHeaders: headers,
            // A preview must not switch the TV's display mode.
            matchContentEnabled: false,
            cacheProfile: .fromSettings(ProfileSettings.current.string(forKey: SettingsKey.networkCache)),
            isLiveStream: live,
            streamName: channel.name,
            filename: channel.name,
            nowPlayingTitle: replay?.title ?? channel.name,
            nowPlayingSubtitle: replay == nil ? nil : channel.name
        ))
        PlaybackWakeLock.acquire(ownerID: session.wakeLockOwnerID)
        startWatching()
    }

    /// The next replay link, when the one playing failed.
    private func tryNextReplayLink() -> Bool {
        guard let channel, replay != nil, !replayLinks.isEmpty else { return false }
        let next = replayLinks.removeFirst()
        replayAttempt = (replayAttempt.index + 1, replayAttempt.of)
        start(channel, url: next, headers: replayHeaders, live: false)
        return true
    }

    // MARK: Replay controls

    var isPaused: Bool { !session.activeEngine.isPlayerPlaying }

    /// Play/Pause pauses and plays on. Live that's all; a replay paused
    /// asks: continue it, or back to the live feed?
    func togglePause() {
        // The choice open: Play/Pause continues.
        if resumeChoice {
            resumeReplay()
            return
        }
        let engine = session.activeEngine
        if engine.isPlayerPlaying {
            engine.pausePlayback()
        } else if replay != nil {
            resumeChoice = true
            return
        } else {
            engine.playPlayback()
        }
        showBar(.compact)
    }

    /// The choice: the replay goes on where it paused.
    func resumeReplay() {
        resumeChoice = false
        session.activeEngine.playPlayback()
        showBar(.compact)
    }

    /// The choice: the channel's live feed.
    func backToLive() {
        resumeChoice = false
        guard let channel else { return }
        startChannel(channel)
        showBar(.compact)
    }

    /// The choice closed with Menu: stays paused.
    func dismissResumeChoice() {
        resumeChoice = false
    }

    /// Left / Right in a replay: back 10 s, on 30 s.
    func skip(by seconds: Double) {
        guard replay != nil else { return }
        let engine = session.activeEngine
        let duration = engine.durationMs
        var target = engine.positionMs + Int64(seconds * 1000)
        target = max(0, duration > 0 ? min(target, duration - 1000) : target)
        engine.seekToMs(target)
        showBar(.compact)
    }

    /// Ends playback and frees the provider connection.
    func stop() {
        watch?.invalidate()
        watch = nil
        session.stopAll()
        PlaybackWakeLock.release(ownerID: session.wakeLockOwnerID)
        programmesTask?.cancel()
        channel = nil
        replay = nil
        replayLinks = []
        resumeChoice = false
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
        // The channel replaying a show: live again.
        if target.streamID != channel?.streamID || replay != nil { startChannel(target) }
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
            if playOnFirstFrame {
                playOnFirstFrame = false
                if replay != nil, !engine.isPlayerPlaying { engine.playPlayback() }
            }
            return
        }
        if !error.isEmpty {
            // A replay link the panel refused: the next form.
            if replay != nil, tryNextReplayLink() { return }
            // Live streams that don't start natively get one try with MPV.
            if !triedFallback, session.requestLiveStartupFallback(generation: session.loadGeneration) {
                triedFallback = true
                return
            }
            status = .failed(error)
            return
        }
        // A replay without a picture after 12 s: the next link.
        if replay != nil, Date().timeIntervalSince(loadStarted) > 12 {
            if !tryNextReplayLink() { status = .failed(L10n.string("livetv_catchup_failed", fallback: "This show can't be played again.")) }
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
        let visible = player.status == .playing
            && (player.isFullscreen || (rect.width > 1 && !covered && !player.previewCovered))
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
            if let replay = player.replay {
                // What's being tried, so a failing replay isn't a mystery.
                VStack(spacing: 12) {
                    ProgressView()
                    Text("↺ " + replay.title)
                        .font(.system(size: LiveTVTheme.Font.small, weight: .semibold))
                    Text(String(
                        format: L10n.string("livetv_catchup_trying", fallback: "Replay link %d of %d"),
                        player.replayAttempt.index, player.replayAttempt.of))
                        .font(.system(size: LiveTVTheme.Font.badge))
                        .foregroundColor(LiveTVTheme.secondaryText)
                }
                .foregroundColor(.white)
            } else {
                ProgressView()
            }
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
            LiveTVResumeChoice(player: player)
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
            .onAppear {
                focused = true
                LiveTVPlayPausePress.shared.install { LiveTVPlayer.shared.togglePause() }
            }
            .onDisappear { LiveTVPlayPausePress.shared.remove() }
            // A replay started or the overlay closed: the controls take the
            // remote again (without focus tvOS sent OK and Play/Pause to the
            // player itself, which only paused).
            .onChange(of: player.replay) { _, _ in focused = true }
            .onChange(of: player.status) { _, _ in focused = true }
            .onChange(of: overlay.isOpen) { _, _ in focused = true }
            .onChange(of: player.resumeChoice) { _, open in if !open { focused = true } }
            // A question (reminder) closed: the controls take the remote again.
            .onReceive(NotificationCenter.default.publisher(for: LiveTVAlert.closedNotification)) { _ in
                focused = true
            }
            // The choice takes the remote while it's open.
            .disabled(player.resumeChoice)
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
        // A replay: Left / Right skip back and on (Up / Down: live channels).
        if player.replay != nil, player.bar != .expanded {
            switch direction {
            case .left: player.skip(by: -10); return
            case .right: player.skip(by: 30); return
            default: break
            }
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

/// A replay paused, Play/Pause again: continue it or back to live.
struct LiveTVResumeChoice: View {
    @ObservedObject var player: LiveTVPlayer
    @FocusState private var focus: Choice?

    private enum Choice {
        case resume
        case live
    }

    var body: some View {
        if player.resumeChoice {
            VStack(spacing: 28) {
                if let show = player.replay {
                    Text(show.title)
                        .font(.system(size: LiveTVTheme.Font.secondary, weight: .bold))
                        .foregroundColor(LiveTVTheme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(LiveTVInfoPanel.clock(show.start, now: Date()) + " – "
                         + LiveTVInfoPanel.clock(show.end, now: Date(), withDay: false))
                        .font(.system(size: LiveTVTheme.Font.small))
                        .foregroundColor(LiveTVTheme.secondaryText)
                }
                HStack(spacing: 30) {
                    Button(action: { player.resumeReplay() }) {
                        Label(L10n.string("livetv_resume", fallback: "Continue watching"), systemImage: "play.fill")
                    }
                    .focused($focus, equals: .resume)
                    Button(action: { player.backToLive() }) {
                        Label(L10n.string("livetv_back_to_live", fallback: "Back to live"),
                              systemImage: "dot.radiowaves.left.and.right")
                    }
                    .focused($focus, equals: .live)
                }
            }
            .padding(44)
            .frame(maxWidth: 1000)
            .liveTVGlass()
            .onAppear { focus = .resume }
            .onExitCommand { player.dismissResumeChoice() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }
}

/// Play/Pause in full screen, caught on the window: as a focused view's
/// command it often never reached Live TV (tvOS gave it to the player as a
/// system play/pause, so it only paused and the choice never came).
@MainActor
final class LiveTVPlayPausePress: NSObject {
    static let shared = LiveTVPlayPausePress()

    private var recognizer: UITapGestureRecognizer?
    private var action: () -> Void = {}

    func install(action: @escaping () -> Void) {
        self.action = action
        guard recognizer == nil, let window = Self.keyWindow else { return }
        let press = UITapGestureRecognizer(target: self, action: #selector(pressed))
        press.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        window.addGestureRecognizer(press)
        recognizer = press
    }

    func remove() {
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
    }

    @objc private func pressed() {
        // A question is up (reminder): it takes the press.
        guard !LiveTVAlert.isShowing else { return }
        action()
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

struct LiveTVInvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
