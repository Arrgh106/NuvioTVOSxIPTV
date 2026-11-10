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
        didSet { if !isFullscreen { hideBar() } }
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
            let global = geometry.frame(in: .global)
            let full = CGRect(x: -global.minX, y: -global.minY, width: screen.width, height: screen.height)
            let rect = player.isFullscreen ? full : (anchor.map { geometry[$0] } ?? .zero)
            if rect.width > 1 {
                ZStack {
                    if player.channel != nil {
                        StablePlayerSurfacePresentation(viewportSize: screen, presentationSize: rect.size) {
                            LiveTVVideoSurface(session: player.session)
                        }
                        // The picture never takes focus or presses.
                        .disabled(true)
                        .allowsHitTesting(false)
                    }
                    statusText
                }
                .frame(width: rect.width, height: rect.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(
                    cornerRadius: player.isFullscreen ? 0 : LiveTVTheme.Metric.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
                        .strokeBorder(LiveTVTheme.accent.opacity(player.isFullscreen || player.channel == nil ? 0 : 0.8), lineWidth: 2)
                )
                .position(x: rect.midX, y: rect.midY)
                .animation(.easeInOut(duration: 0.25), value: player.isFullscreen)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
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

/// Full screen: the remote talks to the player (as on Android): Up / Down
/// switch channels, Right shows the info bar, OK the bar with the channel
/// row (Left / Right / OK in it), Left and Menu go back to the guide (Menu
/// first closes the bar).
struct LiveTVFullscreenControls: View {
    @ObservedObject var player: LiveTVPlayer
    let onExit: () -> Void

    var body: some View {
        LiveTVRemoteCatcher(onPress: handle)
    }

    private func handle(_ press: LiveTVRemoteCatcher.Press) {
        let inRow = player.bar == .expanded
        switch press {
        case .select:
            if inRow { player.playRowSelection() } else { player.showBar(.expanded) }
        case .menu:
            if player.bar != .hidden { player.hideBar() } else { onExit() }
        case .up:
            if inRow { player.showBar(.compact) } else { player.zap(by: -1) }
        case .down:
            if !inRow { player.zap(by: 1) }
        case .left:
            if inRow { player.moveInRow(by: -1) } else { onExit() }
        case .right:
            if inRow { player.moveInRow(by: 1) } else { player.showBar(.compact) }
        }
    }
}

/// Takes the remote in full screen: presses and swipes come here, never to
/// the focus engine. A tiny focused point in the middle with focus guides
/// all around it that lead back to it, so a swipe can't find anything to
/// move to (tvOS opens the app's sidebar when focus can't move left).
struct LiveTVRemoteCatcher: UIViewRepresentable {
    enum Press { case up, down, left, right, select, menu }

    let onPress: (Press) -> Void

    func makeUIView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onPress = onPress
        return view
    }

    func updateUIView(_ view: CatcherView, context: Context) {
        view.onPress = onPress
    }

    final class CatcherView: UIView {
        var onPress: (Press) -> Void = { _ in }
        private let target = FocusPoint()
        private var guides: [UIFocusGuide] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            target.translatesAutoresizingMaskIntoConstraints = false
            addSubview(target)
            NSLayoutConstraint.activate([
                target.centerXAnchor.constraint(equalTo: centerXAnchor),
                target.centerYAnchor.constraint(equalTo: centerYAnchor),
                target.widthAnchor.constraint(equalToConstant: 2),
                target.heightAnchor.constraint(equalToConstant: 2),
            ])
            // Left, right, above, below the point.
            for _ in 0..<4 {
                let guide = UIFocusGuide()
                addLayoutGuide(guide)
                guide.preferredFocusEnvironments = [target]
                guides.append(guide)
            }
            NSLayoutConstraint.activate([
                guides[0].leadingAnchor.constraint(equalTo: leadingAnchor),
                guides[0].trailingAnchor.constraint(equalTo: target.leadingAnchor, constant: -4),
                guides[0].topAnchor.constraint(equalTo: topAnchor),
                guides[0].bottomAnchor.constraint(equalTo: bottomAnchor),
                guides[1].leadingAnchor.constraint(equalTo: target.trailingAnchor, constant: 4),
                guides[1].trailingAnchor.constraint(equalTo: trailingAnchor),
                guides[1].topAnchor.constraint(equalTo: topAnchor),
                guides[1].bottomAnchor.constraint(equalTo: bottomAnchor),
                guides[2].leadingAnchor.constraint(equalTo: target.leadingAnchor),
                guides[2].trailingAnchor.constraint(equalTo: target.trailingAnchor),
                guides[2].topAnchor.constraint(equalTo: topAnchor),
                guides[2].bottomAnchor.constraint(equalTo: target.topAnchor, constant: -4),
                guides[3].leadingAnchor.constraint(equalTo: target.leadingAnchor),
                guides[3].trailingAnchor.constraint(equalTo: target.trailingAnchor),
                guides[3].topAnchor.constraint(equalTo: target.bottomAnchor, constant: 4),
                guides[3].bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            let presses: [(UIPress.PressType, Press)] = [
                (.upArrow, .up), (.downArrow, .down), (.leftArrow, .left), (.rightArrow, .right),
                (.select, .select), (.menu, .menu),
            ]
            for (type, press) in presses {
                let recognizer = PressRecognizer(target: self, action: #selector(pressed(_:)))
                recognizer.press = press
                recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
                addGestureRecognizer(recognizer)
            }
            let swipes: [(UISwipeGestureRecognizer.Direction, Press)] = [
                (.up, .up), (.down, .down), (.left, .left), (.right, .right),
            ]
            for (direction, press) in swipes {
                let recognizer = SwipeRecognizer(target: self, action: #selector(swiped(_:)))
                recognizer.press = press
                recognizer.direction = direction
                addGestureRecognizer(recognizer)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var preferredFocusEnvironments: [UIFocusEnvironment] { [target] }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Everything else is disabled while full screen; this asks
            // tvOS to land on the point now rather than on its next move.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                UIFocusSystem.focusSystem(for: self)?.requestFocusUpdate(to: self.target)
                UIFocusSystem.focusSystem(for: self)?.updateFocusIfNeeded()
            }
        }

        @objc private func pressed(_ recognizer: PressRecognizer) {
            onPress(recognizer.press)
        }

        @objc private func swiped(_ recognizer: SwipeRecognizer) {
            onPress(recognizer.press)
        }
    }

    final class FocusPoint: UIView {
        override var canBecomeFocused: Bool { true }
    }

    final class PressRecognizer: UITapGestureRecognizer {
        var press: Press = .select
    }

    final class SwipeRecognizer: UISwipeGestureRecognizer {
        var press: Press = .up
    }
}
