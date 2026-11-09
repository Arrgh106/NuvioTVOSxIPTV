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
    @Published var isFullscreen = false

    private var watch: Timer?
    private var loadStarted = Date.distantPast
    private var triedFallback = false

    /// Starts `channel` (or switches to it). The picture stays where it is:
    /// in the preview window or full screen.
    func play(_ channel: XtreamLiveChannel, item: LiveTVStore.PlaybackItem) {
        self.channel = channel
        status = .loading
        loadStarted = Date()
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
        channel = nil
        status = .idle
        isFullscreen = false
    }

    /// Up / Down while full screen: the next channel of the group it was
    /// started from (Android and the film player do the same).
    func zap(by delta: Int) {
        guard let next = LiveTVZapper.shared.step(by: delta) else { return }
        play(next.channel, item: next.item)
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

/// Full screen: takes focus so the remote talks to the player. Up / Down
/// switch channels, Menu goes back to the guide.
struct LiveTVFullscreenControls: View {
    @ObservedObject var player: LiveTVPlayer
    let onExit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .focusable()
            .focused($focused)
            .onMoveCommand { direction in
                switch direction {
                case .up: player.zap(by: -1)
                case .down: player.zap(by: 1)
                default: break
                }
            }
            .onExitCommand(perform: onExit)
            .onAppear { focused = true }
    }
}
