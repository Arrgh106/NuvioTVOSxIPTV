import Foundation

/// Fork: finds the Jellyfin titles behind a catalog title (Cinemeta/TMDB), so
/// a movie picked on Home also lists the copy on the user's Jellyfin server as
/// a stream, like on Android. Upstream only offers Jellyfin streams on
/// Jellyfin's own catalog entries (`jellyfin-<server>-<item>` ids).
///
/// Matching uses the IMDb/TMDB ids Jellyfin's metadata agent stored for each
/// title. A title Jellyfin couldn't identify can't be matched.
enum JellyfinCatalogMatch {
    /// The catalog ids a stream `videoId` refers to: `tt…` (IMDb) or
    /// `tmdb:<id>`, each optionally followed by `:<season>:<episode>`.
    static func catalogIDs(fromVideoId videoId: String) -> (imdbID: String?, tmdbID: Int?) {
        let parts = videoId.split(separator: ":").map(String.init)
        guard let first = parts.first else { return (nil, nil) }
        if first.lowercased() == "tmdb", parts.count >= 2 {
            return (nil, Int(parts[1]))
        }
        if first.hasPrefix("tt") {
            return (first, nil)
        }
        return (nil, nil)
    }

    @MainActor
    static func titles(forVideoId videoId: String) -> [JellyfinIndexedTitle] {
        let ids = catalogIDs(fromVideoId: videoId)
        guard ids.imdbID != nil || ids.tmdbID != nil else { return [] }
        return JellyfinLibraryIndex.shared.titles().filter { title in
            if let imdb = ids.imdbID, let titleIMDb = title.imdbId,
               titleIMDb.caseInsensitiveCompare(imdb) == .orderedSame {
                return true
            }
            if let tmdb = ids.tmdbID, title.tmdbId == tmdb {
                return true
            }
            return false
        }
    }
}
