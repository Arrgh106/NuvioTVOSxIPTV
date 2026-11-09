import SwiftUI

/// The corner pill for `ActivityCenter`. Never takes focus. Its own view
/// observing the center, so progress updates redraw only the pill.
struct ActivityPill: View {
    @ObservedObject private var center = ActivityCenter.shared

    var body: some View {
        if let activity = center.current {
            HStack(spacing: 12) {
                if activity.failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 22, height: 22)
                }
                Text(text(for: activity))
                    .lineLimit(1)
                if center.activities.count > 1 {
                    Text("+\(center.activities.count - 1)")
                        .foregroundColor(LiveTVTheme.tertiaryText)
                }
                if !activity.failed {
                    // Elapsed time, redrawn once a second.
                    TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
                        Text(Self.elapsed(since: activity.startedAt, now: context.date))
                            .monospacedDigit()
                            .foregroundColor(LiveTVTheme.secondaryText)
                    }
                }
            }
            .font(.system(size: LiveTVTheme.Font.small, weight: .medium))
            .foregroundColor(LiveTVTheme.primaryText)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .liveTVGlass(cornerRadius: 30)
            .frame(maxWidth: 760, alignment: .trailing)
            .padding(.trailing, 50)
            .padding(.bottom, 36)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeOut(duration: 0.2), value: activity.id)
            .allowsHitTesting(false)
            .focusable(false)
            .accessibilityElement(children: .combine)
        }
    }

    private func text(for activity: ActivityCenter.Activity) -> String {
        guard let fraction = activity.fraction else { return activity.label }
        return "\(activity.label)… \(Int((fraction * 100).rounded())) %"
    }

    private static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
