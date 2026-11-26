import Foundation

/// The calendar's bell (step 16c, as Android's): follow a show or film so
/// it is in the calendar and its Following list. It rings in Nuvio's own
/// calendar follows, so both calendars share them.
@MainActor
enum LiveTVCalendarBell {
    private static var cache: [String: CalendarItem]?
    private static var observer: NSObjectProtocol?

    private static var follows: [String: CalendarItem] {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: CalendarManualFollowStore.changedNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { LiveTVCalendarBell.cache = nil }
            }
        }
        if let cache { return cache }
        let items = CalendarManualFollowStore.items()
        cache = items
        return items
    }

    /// A title can be followed when TMDB or IMDb knows it.
    static func canRing(id: String, imdb: String?, tmdb: Int?) -> Bool {
        tmdb != nil || NuvioMeta.canonicalImdbID(from: imdb ?? id) != nil
    }

    static func isRinging(id: String, imdb: String?, tmdb: Int?) -> Bool {
        !keys(id: id, imdb: imdb, tmdb: tmdb).isEmpty
    }

    private static func keys(id: String, imdb: String?, tmdb: Int?) -> Set<String> {
        let canonical = NuvioMeta.canonicalImdbID(from: imdb ?? id)
        return Set(follows.filter { _, item in
            item.id == id
                || (canonical != nil && (item.imdbId == canonical || item.id == canonical))
                || (tmdb != nil && item.tmdbId == tmdb)
        }.keys)
    }

    /// Rings or silences the bell; true when it rings now.
    @discardableResult
    static func toggle(id: String, imdb: String?, tmdb: Int?, series: Bool, type: String?,
                       title: String, poster: String?, year: Int?) -> Bool {
        let profileID = CalendarManualFollowStore.captureProfileContext().profileID
        let ringing = keys(id: id, imdb: imdb, tmdb: tmdb)
        defer { cache = nil }
        if !ringing.isEmpty {
            CalendarManualFollowStore.remove(ringing, profileID: profileID)
            return false
        }
        let canonical = NuvioMeta.canonicalImdbID(from: imdb ?? id)
        let kind: CalendarMediaKind = series ? .series : .movie
        let key = tmdb.map { CalendarSuggestions.key(kind: kind, tmdbId: $0) } ?? "\(kind.rawValue):\(canonical ?? id)"
        let added = CalendarManualFollowStore.add([CalendarSuggestionItem(
            key: key, kind: kind, type: type, tmdbId: tmdb, imdbId: canonical, title: title,
            posterURL: poster.flatMap(URL.init(string:)), year: year)], profileID: profileID)
        return !added.isEmpty
    }

    static func toggle(_ meta: NuvioMeta) -> Bool {
        toggle(id: meta.id, imdb: meta.imdbId, tmdb: meta.tmdbId, series: meta.isSeries, type: meta.type,
               title: meta.name, poster: meta.posterUrl, year: meta.year)
    }
}
