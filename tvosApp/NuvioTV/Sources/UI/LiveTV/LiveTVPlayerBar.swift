import SwiftUI

/// The info bar over the full-screen picture (LIVE_TV_DESIGN.md, step 4),
/// as Android's `LiveTvPlayerPanel`: a floating glass card at the bottom
/// with the channel line and its tags, what's on (times, time left,
/// progress, description) and, on the right, the clock and what's next.
/// Expanded (OK) it adds the channel row: recently watched channels.
struct LiveTVPlayerBar: View {
    @ObservedObject var player: LiveTVPlayer

    var body: some View {
        if let channel = player.channel, player.bar != .hidden {
            // A replay's position moves every second; live, the clock.
            TimelineView(.periodic(from: .now, by: player.replay == nil ? 30 : 1)) { context in
                card(channel, now: context.date)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 50)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func card(_ channel: XtreamLiveChannel, now: Date) -> some View {
        let replay = player.replay
        let live = player.programmes.first(where: { $0.start <= now && now < $0.end })
        let current = replay ?? live
        let next = replay == nil ? player.programmes.first(where: { $0.start >= (live?.end ?? now) }) : nil
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 24) {
                LiveTVLogo(url: channel.logoURL.flatMap(URL.init(string:)))
                    .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 6) {
                    channelLine(channel)
                    Text(current?.title ?? L10n.string("livetv_info_none", fallback: "No information"))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(LiveTVTheme.primaryText)
                        .lineLimit(1)
                    if replay != nil {
                        replayLine()
                    } else if let current {
                        let info = LiveTVProgrammeInfo(
                            start: current.start, end: current.end, title: current.title, description: current.description)
                        Text(LiveTVInfoPanel.clock(info.start, now: now) + " – " + LiveTVInfoPanel.clock(info.end, now: now, withDay: false)
                             + "  ·  " + LiveTVInfoPanel.timeLeft(info.minutesLeft(at: now)))
                            .font(.system(size: LiveTVTheme.Font.small))
                            .foregroundColor(LiveTVTheme.secondaryText)
                        progressBar(info.progress(at: now))
                        if channel.archiveDays > 0 {
                            Text(L10n.string("livetv_restart_hint", fallback: "▶︎❚❚ watch from the beginning"))
                                .font(.system(size: LiveTVTheme.Font.badge))
                                .foregroundColor(LiveTVTheme.tertiaryText)
                        }
                        if let description = current.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !description.isEmpty {
                            Text(description)
                                .font(.system(size: LiveTVTheme.Font.small))
                                .foregroundColor(LiveTVTheme.secondaryText)
                                .lineLimit(player.bar == .expanded ? 2 : 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 110)
                VStack(alignment: .leading, spacing: 6) {
                    Text(LiveTVSettings.shared.time(now))
                        .font(.system(size: 36, weight: .heavy))
                        .foregroundColor(LiveTVTheme.primaryText)
                    if let next {
                        Text(L10n.string("livetv_bar_up_next", fallback: "UP NEXT") + " · "
                             + LiveTVSettings.shared.time(next.start))
                            .font(.system(size: LiveTVTheme.Font.badge, weight: .bold))
                            .foregroundColor(LiveTVTheme.tertiaryText)
                        Text(next.title)
                            .font(.system(size: LiveTVTheme.Font.small, weight: .bold))
                            .foregroundColor(LiveTVTheme.primaryText)
                            .lineLimit(2)
                    }
                }
                .frame(width: 300, alignment: .leading)
            }
            if player.bar == .expanded {
                channelRow(now: now)
            }
        }
        .padding(24)
        .liveTVGlass()
    }

    private func channelLine(_ channel: XtreamLiveChannel) -> some View {
        HStack(spacing: 12) {
            if let number = channel.number {
                Text(String(number))
                    .font(.system(size: LiveTVTheme.Font.small, weight: .bold))
                    .foregroundColor(LiveTVTheme.primaryText)
            }
            Text(channel.name)
                .font(.system(size: LiveTVTheme.Font.small))
                .foregroundColor(LiveTVTheme.secondaryText)
                .lineLimit(1)
            if let replay = player.replay {
                // What's replayed and when it was on.
                tag("↺ " + L10n.string("livetv_info_catchup", fallback: "CATCH-UP"), fill: LiveTVTheme.markColor)
                Text(LiveTVInfoPanel.clock(replay.start, now: Date()) + " – "
                     + LiveTVInfoPanel.clock(replay.end, now: Date(), withDay: false))
                    .font(.system(size: LiveTVTheme.Font.badge))
                    .foregroundColor(LiveTVTheme.secondaryText)
            } else {
                tag("● " + L10n.string("livetv_info_live", fallback: "LIVE"), fill: LiveTVTheme.liveRed)
            }
            if player.replay == nil, channel.archiveDays > 0 {
                tag(L10n.string("livetv_info_catchup", fallback: "CATCH-UP"), fill: Color.white.opacity(0.18))
            }
        }
    }

    private func tag(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: LiveTVTheme.Font.badge, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
    }

    /// A replay: position of length, paused, and the keys for it.
    private func replayLine() -> some View {
        let engine = player.session.activeEngine
        let position = Double(engine.positionMs) / 1000
        let duration = Double(engine.durationMs) / 1000
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if player.isPaused {
                    Image(systemName: "pause.fill")
                        .foregroundColor(LiveTVTheme.primaryText)
                }
                Text(Self.duration(position) + (duration > 0 ? " / " + Self.duration(duration) : ""))
                    .font(.system(size: LiveTVTheme.Font.small).monospacedDigit())
                    .foregroundColor(LiveTVTheme.secondaryText)
                Text(L10n.string("livetv_catchup_keys", fallback: "◀ 10 s  ·  30 s ▶  ·  ▶︎❚❚ pause"))
                    .font(.system(size: LiveTVTheme.Font.badge))
                    .foregroundColor(LiveTVTheme.tertiaryText)
            }
            progressBar(duration > 0 ? min(1, max(0, position / duration)) : 0)
        }
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(LiveTVTheme.markColor).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
    }

    // MARK: Channel row

    private func channelRow(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("livetv_recent", fallback: "Recently watched"))
                .font(.system(size: LiveTVTheme.Font.badge, weight: .bold))
                .foregroundColor(LiveTVTheme.tertiaryText)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(player.rowChannels.enumerated()), id: \.element.streamID) { index, channel in
                            tile(channel, focused: index == player.rowIndex, now: now)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: player.rowIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(player.rowIndex, anchor: .center) }
            }
        }
    }

    private func tile(_ channel: XtreamLiveChannel, focused: Bool, now: Date) -> some View {
        let playing = channel.streamID == player.channel?.streamID
        let nowTitle = LiveTVGuideRows.shared.cached(channel)?.first { $0.start <= now && now < $0.end }?.title
        return HStack(spacing: 12) {
            LiveTVLogo(url: channel.logoURL.flatMap(URL.init(string:)))
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.system(size: LiveTVTheme.Font.small, weight: .semibold))
                    .lineLimit(1)
                Text(playing ? L10n.string("livetv_bar_watching", fallback: "Watching") : (nowTitle ?? " "))
                    .font(.system(size: LiveTVTheme.Font.badge))
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .foregroundColor(focused ? .black : .white)
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
                .fill(focused ? Color.white : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LiveTVTheme.Metric.cornerRadius, style: .continuous)
                .strokeBorder(playing && !focused ? LiveTVTheme.markColor : .clear, lineWidth: 2)
        )
        .scaleEffect(focused ? LiveTVTheme.Motion.focusScale : 1)
        .animation(LiveTVTheme.Motion.focus, value: focused)
    }
}
