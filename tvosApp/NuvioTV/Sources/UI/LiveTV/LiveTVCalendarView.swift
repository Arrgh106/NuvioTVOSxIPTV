import SwiftUI
import UIKit

/// The calendar (step 16), as Android's: tabs on top, then a big picture of
/// the card in focus and a row of wide cards per day. 16a: the List view
/// with Upcoming and Recently aired.
struct LiveTVCalendarView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case upcoming
        case recent
        var id: String { rawValue }

        var title: String {
            switch self {
            case .upcoming: return L10n.string("livetv_cal_upcoming", fallback: "Upcoming")
            case .recent: return L10n.string("livetv_cal_recent", fallback: "Recently aired")
            }
        }
    }

    /// Opens a card's show or film page (on its episode).
    let onOpen: (LiveTVCalendarEntry) -> Void

    @ObservedObject private var store = LiveTVCalendarStore.shared
    @State private var tab: Tab = .upcoming
    @State private var unwatchedOnly = LiveTVCalendarSettings.unwatchedOnly
    @State private var focusedKey: String?

    private var shown: [LiveTVCalendarEntry] {
        let now = Date()
        switch tab {
        case .upcoming: return LiveTVCalendarLogic.upcoming(store.entries, now: now, zone: LiveTVCalendarSettings.timeZone)
        case .recent: return LiveTVCalendarLogic.recent(store.entries, now: now, zone: LiveTVCalendarSettings.timeZone, unwatchedOnly: unwatchedOnly)
        }
    }

    /// The cards by day, in the list's order.
    private var days: [(day: String, entries: [LiveTVCalendarEntry])] {
        var result: [(day: String, entries: [LiveTVCalendarEntry])] = []
        for entry in shown {
            if result.last?.day == entry.day {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((entry.day, [entry]))
            }
        }
        return result
    }

    var body: some View {
        let list = days
        let focused = shown.first { $0.key == focusedKey } ?? list.first?.entries.first
        ZStack(alignment: .topLeading) {
            hero(focused)
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 60)
                    .padding(.top, 30)
                    .focusSection()
                // Without TMDB: no films, wide pictures or logos.
                if !LiveTVCalendarSources.tmdbReady {
                    Label(L10n.string("livetv_cal_tmdb_off", fallback: "Films, pictures and logos need TMDB: turn it on and add your API key in Settings → TMDB"),
                          systemImage: "info.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 60)
                        .padding(.top, 8)
                }
                details(focused)
                    .padding(.horizontal, 60)
                    .frame(height: 230, alignment: .bottomLeading)
                content(list)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { store.opened() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 18) {
            Text(L10n.string("livetv_cal_title", fallback: "Calendar"))
                .font(.system(size: 40, weight: .bold))
                .padding(.trailing, 20)
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                    focusedKey = nil
                } label: {
                    Text(item.title)
                        .font(.system(size: 24, weight: tab == item ? .bold : .regular))
                }
            }
            if tab == .recent {
                Button {
                    unwatchedOnly.toggle()
                    LiveTVCalendarSettings.unwatchedOnly = unwatchedOnly
                } label: {
                    Label(L10n.string("livetv_cal_unwatched", fallback: "Unwatched only"),
                          systemImage: unwatchedOnly ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                }
            }
            Spacer()
            if let progress = store.progress, progress.total > 0 {
                Text(L10n.format("livetv_cal_progress_format", fallback: "Updating %d of %d", progress.done, progress.total))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.6))
            } else if store.isLoading {
                ProgressView()
            }
            Button {
                store.refresh()
            } label: {
                Label(L10n.string("livetv_refresh", fallback: "Refresh"), systemImage: "arrow.clockwise")
                    .font(.system(size: 22))
            }
            .disabled(store.isLoading)
        }
    }

    // MARK: The card in focus

    private func hero(_ entry: LiveTVCalendarEntry?) -> some View {
        ZStack {
            if let url = entry.flatMap(Self.heroImage) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.black
                    }
                }
                .id(url)
                .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.85), .black],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 620)
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: entry?.key)
    }

    private static func heroImage(_ entry: LiveTVCalendarEntry) -> URL? {
        (entry.background ?? entry.poster).flatMap(URL.init(string:))
    }

    private func details(_ entry: LiveTVCalendarEntry?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entry {
                // The show's own logo when TMDB has one, else its title.
                if let logo = entry.titleLogo.flatMap(URL.init(string:)) {
                    LiveTVLogo(url: logo, style: .title, box: CGSize(width: 520, height: 110), area: 24_000,
                               alignment: .bottomLeading) {
                        Text(entry.title).font(.system(size: 44, weight: .bold)).lineLimit(1)
                    }
                    .id(logo)
                } else {
                    Text(entry.title)
                        .font(.system(size: 44, weight: .bold))
                        .lineLimit(1)
                }
                if let line = Self.subtitle(entry) {
                    Text(line)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Text(Self.when(entry))
                    .font(.system(size: 22))
                    .foregroundColor(LiveTVTheme.accent)
                if let summary = entry.summary, !entry.spoiler {
                    Text(summary)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: Days

    @ViewBuilder
    private func content(_ list: [(day: String, entries: [LiveTVCalendarEntry])]) -> some View {
        if list.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "calendar")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.6))
                Text(emptyText)
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 34) {
                    ForEach(list, id: \.day) { day in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(Self.dayTitle(day.day) + "  ·  " + String(day.entries.count))
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.horizontal, 60)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 28) {
                                    ForEach(day.entries) { entry in
                                        LiveTVCalendarCard(entry: entry,
                                                           onFocus: { focusedKey = entry.key },
                                                           onOpen: { onOpen(entry) })
                                    }
                                }
                                .padding(.horizontal, 60)
                                .padding(.vertical, 20)
                            }
                            .focusSection()
                        }
                    }
                }
                .padding(.bottom, 60)
            }
        }
    }

    private var emptyText: String {
        if store.isLoading {
            return L10n.string("livetv_cal_loading", fallback: "Getting the dates of your shows and films…")
        }
        if store.isEmptySource {
            return L10n.string("livetv_cal_no_titles", fallback: "Follow shows and films, add them to your Library or watch them, and their new episodes and release dates show up here.")
        }
        return tab == .upcoming
            ? L10n.string("livetv_cal_none_upcoming", fallback: "Nothing coming up in the next four months.")
            : L10n.string("livetv_cal_none_recent", fallback: "Nothing aired in the last 30 days.")
    }

    // MARK: Text

    /// "S2 · E5 · Title" (several: "S2 · E5–E8"); a film's other release.
    static func subtitle(_ entry: LiveTVCalendarEntry) -> String? {
        guard entry.kind == .episode, let season = entry.season, let episode = entry.episode else { return entry.note }
        var parts = ["S\(season)", entry.lastEpisode.map { "E\(episode)–E\($0)" } ?? "E\(episode)"]
        if let title = entry.episodeTitle, !entry.spoiler { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    /// "Today 20:15 · NBC", "Fri, Nov 27 · Netflix".
    static func when(_ entry: LiveTVCalendarEntry) -> String {
        var parts = [dayTitle(entry.day)]
        if let air = entry.air { parts[0] += " " + clock(air) }
        if let network = entry.network { parts.append(network) }
        return parts.joined(separator: " · ")
    }

    static func dayTitle(_ day: String) -> String {
        let zone = LiveTVCalendarSettings.timeZone
        let today = LiveTVCalendarLogic.day(of: Date(), in: zone)
        if day == today { return L10n.string("livetv_info_today", fallback: "Today") }
        if day == LiveTVCalendarLogic.day(today, plus: 1) { return L10n.string("livetv_info_tomorrow", fallback: "Tomorrow") }
        if day == LiveTVCalendarLogic.day(today, plus: -1) { return L10n.string("livetv_info_yesterday", fallback: "Yesterday") }
        guard let date = LiveTVCalendarLogic.start(of: day, in: zone) else { return day }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: date)
    }

    /// An air time in the calendar's time zone, in Live TV's clock style.
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = LiveTVCalendarSettings.timeZone
        switch LiveTVSettings.shared.clock {
        case .hours24: formatter.dateFormat = "HH:mm"
        case .hours12: formatter.dateFormat = "h:mm a"
        case .system: formatter.setLocalizedDateFormatFromTemplate("jmm")
        }
        return formatter.string(from: date)
    }

    static func tagTitle(_ tag: LiveTVCalendarTag) -> String {
        switch tag {
        case .new: return L10n.string("livetv_cal_tag_new", fallback: "New")
        case .seriesPremiere: return L10n.string("livetv_cal_tag_series_premiere", fallback: "Series premiere")
        case .seasonPremiere: return L10n.string("livetv_cal_tag_season_premiere", fallback: "Season premiere")
        case .seasonFinale: return L10n.string("livetv_cal_tag_season_finale", fallback: "Season finale")
        case .seriesFinale: return L10n.string("livetv_cal_tag_series_finale", fallback: "Series finale")
        case .inTheaters: return L10n.string("livetv_cal_tag_theaters", fallback: "In theaters")
        case .atHome: return L10n.string("livetv_cal_tag_home", fallback: "At home")
        case .onDisc: return L10n.string("livetv_cal_tag_disc", fallback: "On disc")
        case .onTV: return L10n.string("livetv_cal_tag_tv", fallback: "On TV")
        }
    }
}

/// A wide card: the episode's picture (the show's while it would spoil),
/// its time and tag on top, the title and channel at the bottom, the
/// episode below.
private struct LiveTVCalendarCard: View {
    let entry: LiveTVCalendarEntry
    let onFocus: () -> Void
    let onOpen: () -> Void

    @FocusState private var focused: Bool

    static let width: CGFloat = 400

    private var picture: URL? {
        let link = entry.spoiler ? (entry.background ?? entry.poster) : (entry.episodeImage ?? entry.background ?? entry.poster)
        return link.flatMap(URL.init(string:))
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    AsyncImage(url: picture) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color.white.opacity(0.08)
                                Image(systemName: entry.kind == .movie ? "film" : "tv")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading) {
                        HStack(alignment: .top) {
                            if let air = entry.air {
                                chip(LiveTVCalendarView.clock(air), fill: .black.opacity(0.7))
                            }
                            Spacer()
                            if entry.watched {
                                chip("✓", fill: .black.opacity(0.7))
                            } else if let tag = entry.tags.first {
                                // A white accent: dark text on it.
                                chip(LiveTVCalendarView.tagTitle(tag), fill: LiveTVTheme.accent.opacity(0.9),
                                     text: LiveTVTheme.isWhiteAccent ? .black : .white)
                            }
                        }
                        Spacer()
                        HStack(alignment: .bottom) {
                            if let logo = entry.titleLogo.flatMap(URL.init(string:)) {
                                LiveTVLogo(url: logo, style: .title, box: CGSize(width: 220, height: 64), area: 7_000,
                                           alignment: .bottomLeading) {
                                    Text(entry.title.uppercased()).font(.system(size: 20, weight: .heavy)).lineLimit(2)
                                }
                            } else {
                                Text(entry.title.uppercased())
                                    .font(.system(size: 20, weight: .heavy))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            if let logo = entry.networkLogo.flatMap(URL.init(string:)) {
                                LiveTVLogo(url: logo, style: .network, box: CGSize(width: 96, height: 30), area: 1_500,
                                           alignment: .bottomTrailing) {
                                    if let network = entry.network { chip(network, fill: .white.opacity(0.2)) }
                                }
                            } else if let network = entry.network {
                                chip(network, fill: .white.opacity(0.2))
                            }
                        }
                    }
                    .foregroundColor(.white)
                    .padding(12)
                }
                .frame(width: Self.width, height: Self.width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(focused ? Color.white : Color.clear, lineWidth: 4))
                Text(LiveTVCalendarView.subtitle(entry) ?? " ")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(focused ? 1 : 0.7))
                    .lineLimit(1)
                    .frame(width: Self.width, alignment: .leading)
            }
            .scaleEffect(focused ? 1.06 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
        .onChange(of: focused) { _, now in if now { onFocus() } }
    }

    private func chip(_ text: String, fill: Color, text color: Color = .white) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .bold))
            .foregroundColor(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A logo, made to look alike on every card: its empty edges cut off and
/// sized to the same area whether it is wide or tall. Network logos are
/// drawn in white: their shape when they stand free (FOX, CBS), their light
/// parts when they sit on a box or a dark disc (TF1, ABC), so none turns
/// into a white blot. Title logos keep their colours.
struct LiveTVLogo<Fallback: View>: View {
    enum Style { case title, network }

    let url: URL
    let style: Style
    /// The most room it may take.
    let box: CGSize
    /// The area every logo gets (points²), within `box`.
    let area: CGFloat
    let alignment: Alignment
    @ViewBuilder let fallback: () -> Fallback

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                let size = Self.size(of: image.size, box: box, area: area)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(0.75), radius: style == .network ? 3 : 4)
            } else if failed {
                fallback()
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(maxWidth: box.width, maxHeight: box.height, alignment: alignment)
        .task(id: url) {
            let key = "\(style == .network ? "n" : "t")|\(url.absoluteString)" as NSString
            if let known = LiveTVLogoCache.shared.object(forKey: key) {
                image = known
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data),
                  let made = await Task.detached(priority: .utility, operation: {
                      LiveTVLogoMaker.make(loaded, white: style == .network)
                  }).value else {
                failed = true
                return
            }
            LiveTVLogoCache.shared.setObject(made, forKey: key)
            image = made
        }
    }

    /// The same area for every logo, as wide or tall as it is, inside the box.
    static func size(of picture: CGSize, box: CGSize, area: CGFloat) -> CGSize {
        guard picture.width > 0, picture.height > 0 else { return .zero }
        let aspect = picture.width / picture.height
        var width = (area * aspect).squareRoot()
        var height = width / aspect
        if width > box.width { width = box.width; height = width / aspect }
        if height > box.height { height = box.height; width = height * aspect }
        return CGSize(width: width, height: height)
    }
}

enum LiveTVLogoCache {
    @MainActor static let shared = NSCache<NSString, UIImage>()
}

/// Makes a logo alike: cut to what's drawn; for networks, white.
enum LiveTVLogoMaker {
    static func make(_ image: UIImage, white: Bool) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0, width * height <= 4_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        func luminance(_ i: Int) -> Double {
            let alpha = Double(pixels[i + 3])
            guard alpha > 0 else { return 0 }
            return (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / alpha
        }

        if white {
            // On a box or a dark disc: only its light parts (the lettering).
            var opaque = 0, light = 0, dark = 0
            for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 128 {
                opaque += 1
                let lum = luminance(i)
                if lum > 0.7 { light += 1 } else if lum < 0.3 { dark += 1 }
            }
            let cover = Double(opaque) / Double(width * height)
            let share = { (count: Int) in opaque > 0 ? Double(count) / Double(opaque) : 0 }
            let lettering = cover > 0.85 || (share(light) > 0.12 && share(dark) > 0.2)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                var alpha = Double(pixels[i + 3]) / 255
                if lettering {
                    let lum = luminance(i)
                    alpha *= min(1, max(0, (lum - 0.55) / 0.25))
                }
                let value = UInt8(alpha * 255)
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = value
            }
        }

        // Cut to what's drawn.
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 24 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let made: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space, bitmapInfo: info)?.makeImage()
        }
        let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cut = made?.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cut)
    }
}
