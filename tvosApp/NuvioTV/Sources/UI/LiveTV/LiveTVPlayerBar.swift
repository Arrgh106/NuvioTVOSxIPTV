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
            TimelineView(.periodic(from: .now, by: 30)) { context in
                card(channel, now: context.date)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 50)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func card(_ channel: XtreamLiveChannel, now: Date) -> some View {
        let current = player.programmes.first { $0.start <= now && now < $0.end }
        let next = player.programmes.first { $0.start >= (current?.end ?? now) }
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
                    if let current {
                        let info = LiveTVProgrammeInfo(
                            start: current.start, end: current.end, title: current.title, description: current.description)
                        Text(LiveTVInfoPanel.clock(info.start, now: now) + " – " + LiveTVInfoPanel.clock(info.end, now: now, withDay: false)
                             + "  ·  " + LiveTVInfoPanel.timeLeft(info.minutesLeft(at: now)))
                            .font(.system(size: LiveTVTheme.Font.small))
                            .foregroundColor(LiveTVTheme.secondaryText)
                        progressBar(info.progress(at: now))
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
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 36, weight: .heavy))
                        .foregroundColor(LiveTVTheme.primaryText)
                    if let next {
                        Text(L10n.string("livetv_bar_up_next", fallback: "UP NEXT") + " · "
                             + next.start.formatted(date: .omitted, time: .shortened))
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
            tag("● " + L10n.string("livetv_info_live", fallback: "LIVE"), fill: LiveTVTheme.liveRed)
            if channel.archiveDays > 0 {
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
