import SwiftUI

/// What the guide has in focus, for the info panel. The guide reports every
/// move; the panel follows once focus rests a moment, so flicking through
/// rows doesn't redraw it each step. Only the panel observes this: the rest
/// of Live TV (and the guide itself) never re-renders because of it.
@MainActor
final class LiveTVInfoModel: ObservableObject {
    struct Focus: Equatable {
        let channel: XtreamLiveChannel
        /// nil while the row's programmes are still loading.
        let info: LiveTVProgrammeInfo?
    }

    @Published private(set) var focus: Focus?
    private var pending: Task<Void, Never>?

    static let settle: Duration = .milliseconds(150)

    func show(_ next: Focus) {
        pending?.cancel()
        guard next != focus else { return }
        // The first one straight away (nothing to replace yet).
        guard focus != nil else {
            focus = next
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            self?.focus = next
        }
    }
}

/// The glass panel above the guide (LIVE_TV_DESIGN.md, step 2), as on
/// Android: channel line with LIVE / CATCH-UP tags, the programme title,
/// times with time left, progress and the description.
struct LiveTVInfoPanel: View {
    @ObservedObject var model: LiveTVInfoModel

    static let height: CGFloat = 210

    var body: some View {
        // The clock moves time left and progress along.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .background(glow)
        .liveTVGlass()
    }

    /// A soft glow in the theme color, top left (Android's "theme glow").
    private var glow: some View {
        RadialGradient(
            colors: [LiveTVTheme.accent.opacity(0.22), .clear],
            center: .topLeading, startRadius: 0, endRadius: 700
        )
        .clipShape(RoundedRectangle(cornerRadius: LiveTVTheme.Metric.panelCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let focus = model.focus {
            HStack(alignment: .center, spacing: 28) {
                LiveTVLogo(url: focus.channel.logoURL.flatMap(URL.init(string:)))
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 8) {
                    channelLine(focus, now: now)
                    Text(title(focus))
                        .font(.system(size: LiveTVTheme.Font.programmeTitle, weight: .bold))
                        .foregroundColor(LiveTVTheme.primaryText)
                        .lineLimit(1)
                    if let info = focus.info {
                        timeLine(info, now: now)
                        if info.isOn(at: now) {
                            progressBar(info.progress(at: now))
                        }
                        if let description = info.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !description.isEmpty {
                            Text(description)
                                .font(.system(size: LiveTVTheme.Font.small))
                                .foregroundColor(LiveTVTheme.secondaryText)
                                .lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
        } else {
            Text(L10n.string("livetv_info_hint", fallback: "Move through the guide to see what's on."))
                .font(.system(size: LiveTVTheme.Font.secondary))
                .foregroundColor(LiveTVTheme.secondaryText)
                .padding(30)
        }
    }

    private func title(_ focus: Focus) -> String {
        guard let info = focus.info else {
            return L10n.string("livetv_info_loading", fallback: "Loading…")
        }
        return info.title ?? L10n.string("livetv_info_none", fallback: "No information")
    }

    private typealias Focus = LiveTVInfoModel.Focus

    private func channelLine(_ focus: Focus, now: Date) -> some View {
        HStack(spacing: 12) {
            Text([focus.channel.number.map(String.init), focus.channel.name].compactMap { $0 }.joined(separator: "  ·  "))
                .font(.system(size: LiveTVTheme.Font.secondary, weight: .medium))
                .foregroundColor(LiveTVTheme.secondaryText)
                .lineLimit(1)
            if let info = focus.info, info.isOn(at: now) {
                tag(L10n.string("livetv_info_live", fallback: "LIVE"), fill: LiveTVTheme.liveRed, text: .white)
            }
            if focus.channel.archiveDays > 0 {
                tag(L10n.string("livetv_info_catchup", fallback: "CATCH-UP"), fill: .clear, text: LiveTVTheme.secondaryText)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
            }
        }
    }

    private func tag(_ text: String, fill: Color, text color: Color) -> some View {
        Text(text)
            .font(.system(size: LiveTVTheme.Font.badge, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
    }

    private func timeLine(_ info: LiveTVProgrammeInfo, now: Date) -> some View {
        var parts = [Self.clock(info.start, now: now) + " – " + Self.clock(info.end, now: now, withDay: false)]
        if info.isOn(at: now) {
            parts.append(Self.timeLeft(info.minutesLeft(at: now)))
        }
        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: LiveTVTheme.Font.secondary))
            .foregroundColor(LiveTVTheme.secondaryText)
            .lineLimit(1)
    }

    private func progressBar(_ fraction: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.18))
            Capsule().fill(LiveTVTheme.markColor)
                .frame(width: 360 * fraction)
        }
        .frame(width: 360, height: 6)
    }

    /// "21:14", "Tomorrow 06:00", "Wed 20:15" (the end time only gets a day
    /// when it's on a different day than the start, which the caller skips).
    static func clock(_ date: Date, now: Date, withDay: Bool = true) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard withDay else { return time }
        switch LiveTVProgrammeInfo.dayOffset(of: date, from: now) {
        case 0: return time
        case 1: return L10n.string("livetv_info_tomorrow", fallback: "Tomorrow") + " " + time
        default: return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
    }

    static func timeLeft(_ minutes: Int) -> String {
        if minutes >= 60 {
            return String(format: L10n.string("livetv_info_left_hours", fallback: "%d h %d min left"), minutes / 60, minutes % 60)
        }
        return String(format: L10n.string("livetv_info_left_minutes", fallback: "%d min left"), minutes)
    }
}
