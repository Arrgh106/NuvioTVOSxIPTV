import Foundation

// Fork: the calendar (step 16), as Android's (`livetv/calendar`): episodes
// from TVmaze and film dates from TMDB for the shows and films you follow,
// watch or keep. The rules here are pure, so the logic tests run them on
// Linux.

/// A tag on a calendar card.
enum LiveTVCalendarTag: String, Codable, CaseIterable, Sendable {
    case new
    case seriesPremiere
    case seasonPremiere
    case seasonFinale
    case seriesFinale
    case inTheaters
    case atHome
    case onDisc
    case onTV
}

/// Why a title is in the calendar.
enum LiveTVCalendarReason: String, Codable, Sendable {
    /// You rang its bell (follow).
    case bell
    case library
    case watching
    case airingToday
}

/// One episode as TVmaze lists it (what the calendar keeps of it).
struct LiveTVCalendarEpisode: Codable, Equatable, Sendable {
    let season: Int
    let number: Int
    var name: String?
    /// The air time; nil when TVmaze only knows the day.
    var airstamp: Date?
    /// "yyyy-MM-dd", the day in the network's time zone.
    var airdate: String
    var runtime: Int?
    var image: String?
    var summary: String?
    /// How many episodes its season will have (TVmaze `episodeOrder`).
    var seasonEpisodes: Int?
}

/// A card in the calendar.
struct LiveTVCalendarEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case episode, movie }

    let key: String
    let kind: Kind
    /// IMDb id ("tt…") when known, else the title's own id.
    let contentID: String
    let title: String
    var poster: String?
    var background: String?
    var season: Int?
    var episode: Int?
    /// Several episodes on one card: the last of them.
    var lastEpisode: Int?
    var episodeTitle: String?
    var episodeImage: String?
    var summary: String?
    /// When it airs; nil when only the day is known.
    var air: Date?
    /// "yyyy-MM-dd" in the Apple TV's time zone.
    var day: String
    var network: String?
    /// The network's logo (TMDB), shown in place of its name.
    var networkLogo: String?
    var streaming = false
    var tags: [LiveTVCalendarTag] = []
    /// Films: the other release ("At home Oct 2").
    var note: String?
    var reasons: Set<LiveTVCalendarReason> = []
    var watched = false
    /// Further than you've watched: its title, picture and text stay hidden.
    var spoiler = false
    var runtime: Int?

    var id: String { key }
    var followed: Bool { reasons.contains(.bell) }
}

enum LiveTVCalendarLogic {
    // MARK: Days

    static func dayFormatter(_ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func day(of date: Date, in zone: TimeZone) -> String {
        dayFormatter(zone).string(from: date)
    }

    /// The day `days` after `day` ("yyyy-MM-dd").
    static func day(_ day: String, plus days: Int) -> String {
        let utc = TimeZone(identifier: "UTC")!
        let formatter = dayFormatter(utc)
        guard let date = formatter.date(from: day) else { return day }
        return formatter.string(from: date.addingTimeInterval(TimeInterval(days) * 86_400))
    }

    /// Midnight of a day in a zone.
    static func start(of day: String, in zone: TimeZone) -> Date? {
        dayFormatter(zone).date(from: day)
    }

    // MARK: Episodes

    /// Episodes shown on one card: in a row in the same season, on the same
    /// day at the same time (or a streaming drop).
    static func grouped(_ episodes: [LiveTVCalendarEpisode], streaming: Bool) -> [[LiveTVCalendarEpisode]] {
        var groups: [[LiveTVCalendarEpisode]] = []
        for episode in episodes {
            if let last = groups.last?.last, last.season == episode.season, last.number + 1 == episode.number,
               last.airdate == episode.airdate, streaming || last.airstamp == episode.airstamp {
                groups[groups.count - 1].append(episode)
            } else {
                groups.append([episode])
            }
        }
        return groups
    }

    /// Premiere and finale tags of a card (`first` … `last`).
    static func tags(first: LiveTVCalendarEpisode, last: LiveTVCalendarEpisode,
                     showEnded: Bool, highestSeason: Int) -> [LiveTVCalendarTag] {
        var tags: [LiveTVCalendarTag] = []
        if first.season == 1 && first.number == 1 {
            tags.append(.seriesPremiere)
        } else if first.number == 1 {
            tags.append(.seasonPremiere)
        }
        if let total = last.seasonEpisodes, last.number >= total,
           !(first.number == 1 && last.number == 1 && total > 1) {
            tags.append(showEnded && last.season >= highestSeason ? .seriesFinale : .seasonFinale)
        }
        return tags
    }

    /// "New": aired, not watched, since yesterday.
    static func isNew(aired: Bool, watched: Bool, day: String, today: String) -> Bool {
        aired && !watched && day >= Self.day(today, plus: -1)
    }

    /// TVmaze's placeholder names ("Episode 5") say nothing.
    static func episodeName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.range(of: #"^(?i)episode \d+$"#, options: .regularExpression) != nil { return nil }
        return name
    }

    /// TVmaze's summary as plain text.
    static func plainText(_ html: String?) -> String? {
        guard var text = html else { return nil }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Spoilers

    /// Further than one step past what you've watched: next episode and the
    /// next season's first are fine.
    static func isAhead(season: Int, episode: Int, furthest: (season: Int, episode: Int)) -> Bool {
        if season < furthest.season || (season == furthest.season && episode <= furthest.episode + 1) { return false }
        if season == furthest.season + 1 && episode == 1 { return false }
        return true
    }

    /// Watched: marked, or before the furthest one you've seen.
    static func isWatched(season: Int, episode: Int, marked: Set<String>, furthest: (season: Int, episode: Int)?) -> Bool {
        if marked.contains("\(season):\(episode)") { return true }
        guard let furthest else { return false }
        return season < furthest.season || (season == furthest.season && episode <= furthest.episode)
    }

    // MARK: West Coast feeds

    /// Hours an East Coast show airs earlier by the clock here: 0 on the
    /// West Coast (the Pacific feed at the same clock time), 1 in Mountain
    /// time; nil where the real time is right (Central, Eastern, abroad).
    static func westShiftHours(_ zone: TimeZone, at date: Date) -> Int? {
        let id = zone.identifier
        let american = id.hasPrefix("America/") || id.hasPrefix("US/") || id.hasPrefix("GMT") || id == "UTC"
        guard american else { return nil }
        let standard = (zone.secondsFromGMT(for: date) - Int(zone.daylightSavingTimeOffset(for: date))) / 3600
        switch standard {
        case -11 ... -8: return 0
        case -7: return 1
        default: return nil
        }
    }

    /// When an episode airs here: the listed time, or on the West Coast and
    /// in Mountain time the local feed of an East Coast show.
    static func localAir(listed: Date?, networkZone: String?, scheduleTime: String?,
                         streaming: Bool, local: TimeZone) -> Date? {
        guard let listed, !streaming, let shift = westShiftHours(local, at: listed),
              let eastern = TimeZone(identifier: "America/New_York") else { return listed }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: listed)
        let eastCoast: Bool
        if let networkZone, let zone = TimeZone(identifier: networkZone) {
            eastCoast = networkZone.hasPrefix("America/") && zone.secondsFromGMT(for: listed) == eastern.secondsFromGMT(for: listed)
        } else if let scheduleTime, let hour = parts.hour, let minute = parts.minute {
            eastCoast = scheduleTime == String(format: "%02d:%02d", hour, minute)
        } else {
            eastCoast = false
        }
        guard eastCoast else { return listed }
        var here = calendar
        here.timeZone = local
        var wall = parts
        wall.hour = (parts.hour ?? 0) - shift
        return here.date(from: wall) ?? listed
    }

    // MARK: Lists

    /// Coming up: today's (until they've ended) and later days, in order.
    static func upcoming(_ entries: [LiveTVCalendarEntry], now: Date, zone: TimeZone) -> [LiveTVCalendarEntry] {
        let today = day(of: now, in: zone)
        return entries.filter { entry in
            guard entry.day >= today else { return false }
            if entry.day > today { return true }
            guard let when = entry.air else { return true }
            return when.addingTimeInterval(TimeInterval((entry.runtime ?? 30) * 60)) > now
        }
    }

    /// Aired: newest first (`unwatchedOnly`: not watched yet).
    static func recent(_ entries: [LiveTVCalendarEntry], now: Date, zone: TimeZone, unwatchedOnly: Bool) -> [LiveTVCalendarEntry] {
        let today = day(of: now, in: zone)
        return entries.filter { entry in
            guard entry.day <= today else { return false }
            let when = entry.air ?? start(of: entry.day, in: zone) ?? now
            return when <= now && (!unwatchedOnly || !entry.watched)
        }
        .sorted { a, b in
            if a.day != b.day { return a.day > b.day }
            return (a.air ?? .distantPast) > (b.air ?? .distantPast)
        }
    }

    /// The order of the whole calendar: by day, then time (no time last),
    /// then title.
    static func sorted(_ entries: [LiveTVCalendarEntry]) -> [LiveTVCalendarEntry] {
        entries.sorted { a, b in
            if a.day != b.day { return a.day < b.day }
            switch (a.air, b.air) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    // MARK: Films

    /// A film's dates as TMDB gives them ("yyyy-MM-dd").
    struct MovieDates: Codable, Equatable, Sendable {
        var theatrical: String?
        var digital: String?
        var disc: String?
    }

    /// A film's cards inside the window: In theaters, At home, and On disc
    /// when there's no home release. `label` writes a note's date.
    static func movieCards(_ dates: MovieDates, from: String, to: String,
                           label: (LiveTVCalendarTag, String) -> String) -> [(tag: LiveTVCalendarTag, day: String, note: String?)] {
        func inside(_ day: String?) -> String? {
            guard let day, day >= from, day <= to else { return nil }
            return day
        }
        var cards: [(tag: LiveTVCalendarTag, day: String, note: String?)] = []
        if let day = inside(dates.theatrical) {
            cards.append((.inTheaters, day, dates.digital.map { label(.atHome, $0) } ?? label(.atHome, "")))
        }
        if let day = inside(dates.digital) {
            cards.append((.atHome, day, dates.theatrical.map { label(.inTheaters, $0) }))
        }
        if dates.digital == nil, let day = inside(dates.disc) {
            cards.append((.onDisc, day, nil))
        }
        return cards
    }
}
