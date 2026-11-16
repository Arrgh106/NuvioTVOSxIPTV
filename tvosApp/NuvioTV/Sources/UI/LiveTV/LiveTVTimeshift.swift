import AetherEngine
import Foundation

/// Time-shift (Live TV step 14), as Android's "Pause and Rewind Live TV":
/// AetherEngine keeps the live channel it plays (its DVR window, from the
/// same connection, `PlaybackLoadRequest.liveDVRWindowSeconds`); Live TV
/// pauses, rewinds and goes back to live in it. Nothing is loaded again.
extension AetherPlaybackController {
    /// How far back the channel can go, on the session's time axis (what the
    /// window allows and the engine really holds). nil: live only.
    var liveRewindRange: ClosedRange<Double>? {
        guard let range = engine.seekableLiveRange, range.upperBound > range.lowerBound else { return nil }
        return range
    }

    /// Where the picture is, on the same axis.
    var liveTime: Double { engine.currentTime }

    func seekLive(to seconds: Double) {
        let engine = engine
        Task { @MainActor in await engine.seek(to: seconds) }
    }

    /// Back to the live edge.
    func goLive() {
        let engine = engine
        Task { @MainActor [weak self] in
            await engine.seekToLiveEdge()
            // Through the controller, so its playing state follows.
            self?.playPlayback()
        }
    }
}
