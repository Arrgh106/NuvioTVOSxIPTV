import SwiftUI

/// Progress of the full guide download/import in the Live TV header. Its
/// own view observing `LiveTVGuide`, so progress updates redraw only this
/// label and not the channel lists.
struct LiveTVGuideStatusView: View {
    @ObservedObject private var guide = LiveTVGuide.shared

    var body: some View {
        if let text {
            HStack(spacing: 10) {
                if isWorking { ProgressView().scaleEffect(0.7) }
                Text(text)
                    .lineLimit(1)
            }
            .font(.system(size: 20))
            .foregroundColor(.white.opacity(0.6))
        }
    }

    private var isWorking: Bool {
        switch guide.status {
        case .downloading, .importing: return true
        default: return false
        }
    }

    private var text: String? {
        let label = L10n.string("livetv_guide", fallback: "Guide")
        switch guide.status {
        case .idle:
            return nil
        case .downloading(let fraction):
            if let fraction {
                return "\(label): " + L10n.format("livetv_guide_downloading", fallback: "downloading %d%%", Int(fraction * 100))
            }
            return "\(label): " + L10n.string("livetv_guide_downloading_unknown", fallback: "downloading…")
        case .importing(let count):
            return "\(label): " + L10n.format("livetv_guide_importing", fallback: "reading %@ programmes", count.formatted())
        case .ready(let count, _):
            return "\(label): " + L10n.format("livetv_guide_ready", fallback: "%@ programmes", count.formatted())
        case .failed(let message):
            return "\(label): ⚠︎ \(message)"
        }
    }
}
