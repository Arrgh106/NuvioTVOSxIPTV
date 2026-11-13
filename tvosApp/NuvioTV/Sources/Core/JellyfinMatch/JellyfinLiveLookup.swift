import Foundation

/// Fork: asks the user's Jellyfin servers live whether they have the title
/// being opened, and returns its file as a playable stream. Titles, posters
/// and details keep coming from Cinemeta/TMDB; Jellyfin only supplies the
/// file. No library has to be read in beforehand, and new files show up as
/// soon as Jellyfin knows them.
///
/// Matching: search Jellyfin by the title's name, then accept only an item
/// whose IMDb or TMDB id matches (name + year only when the title has no id).
@MainActor
enum JellyfinLiveLookup {
    struct Hint {
        let name: String
        let year: Int?
        let imdbID: String?
        let tmdbID: Int?
    }

    /// Name/year/ids of titles opened in Details, by content id; the stream
    /// search only has the video id.
    private static var hints: [String: Hint] = [:]

    static func remember(_ meta: NuvioMeta, alias: String? = nil) {
        let hint = Hint(
            name: meta.name,
            year: meta.year,
            imdbID: meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id : nil),
            tmdbID: meta.tmdbId
        )
        if hints.count > 200 { hints.removeAll() }
        hints[meta.id] = hint
        if let alias { hints[alias] = hint }
        if let imdb = hint.imdbID { hints[imdb] = hint }
        if let tmdb = hint.tmdbID { hints["tmdb:\(tmdb)"] = hint }
    }

    /// Streams for a `videoId` (`tt…`, `tmdb:…`, optionally `:season:episode`)
    /// from every configured server, queried in parallel. Never throws: an
    /// unreachable server just contributes nothing.
    /// Name, year and ids of the title a video id belongs to (also used by
    /// On Demand, step 12a).
    static func hint(forVideoId videoId: String) async -> Hint? {
        let ids = JellyfinCatalogMatch.catalogIDs(fromVideoId: videoId)
        let parts = videoId.split(separator: ":")
        let baseKey = ids.tmdbID != nil ? "tmdb:\(ids.tmdbID!)" : String(parts.first ?? "")
        let episode = StreamsRepository.seasonEpisode(fromVideoId: videoId)
        // Streams can be searched before Details has loaded the title (e.g.
        // from Continue Watching): then look the name up ourselves.
        var found = hints[baseKey]
        if found == nil, let imdb = ids.imdbID {
            found = await cinemetaHint(imdbID: imdb, isSeries: episode.season != nil)
            if let found { hints[baseKey] = found }
        }
        return found
    }

    static func streams(videoId: String) async -> [NuvioStream] {
        let ids = JellyfinCatalogMatch.catalogIDs(fromVideoId: videoId)
        let episode = StreamsRepository.seasonEpisode(fromVideoId: videoId)
        guard let hint = await hint(forVideoId: videoId) else { return [] }
        let imdb = ids.imdbID ?? hint.imdbID
        let tmdb = ids.tmdbID ?? hint.tmdbID

        let targets: [(server: JellyfinServerConfig, baseURL: URL, token: String)] =
            JellyfinServerStore.shared.servers.compactMap { server in
                guard let baseURL = server.baseURL, !server.userId.isEmpty else { return nil }
                let token = JellyfinCredentialStore.token(forServerID: server.id)
                return token.isEmpty ? nil : (server, baseURL, token)
            }
        guard !targets.isEmpty else { return [] }

        return await withTaskGroup(of: [NuvioStream].self) { group in
            for target in targets {
                group.addTask {
                    await lookup(
                        client: JellyfinClient(baseURL: target.baseURL, accessToken: target.token),
                        userId: target.server.userId,
                        serverName: target.server.displayName,
                        baseURL: target.baseURL,
                        token: target.token,
                        hint: hint,
                        imdb: imdb,
                        tmdb: tmdb,
                        season: episode.season,
                        episode: episode.episode
                    )
                }
            }
            var all: [NuvioStream] = []
            for await streams in group { all += streams }
            return all
        }
    }

    /// Name and year from Cinemeta's public meta endpoint.
    nonisolated private static func cinemetaHint(imdbID: String, isSeries: Bool) async -> Hint? {
        let type = isSeries ? "series" : "movie"
        guard let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(type)/\(imdbID).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = root["meta"] as? [String: Any],
              let name = meta["name"] as? String, !name.isEmpty else { return nil }
        let yearText = (meta["year"] as? String) ?? (meta["releaseInfo"] as? String) ?? ""
        let year = Int(yearText.prefix(4)) ?? (meta["year"] as? Int)
        let tmdb = (meta["moviedb_id"] as? Int) ?? (meta["tmdb_id"] as? Int)
        return Hint(name: name, year: year, imdbID: imdbID, tmdbID: tmdb)
    }

    nonisolated private static func lookup(
        client: JellyfinClient,
        userId: String,
        serverName: String,
        baseURL: URL,
        token: String,
        hint: Hint,
        imdb: String?,
        tmdb: Int?,
        season: Int?,
        episode: Int?
    ) async -> [NuvioStream] {
        let isEpisode = season != nil && episode != nil
        guard let candidates = try? await client.search(
            userId: userId, term: hint.name, types: isEpisode ? "Series" : "Movie") else { return [] }

        let matches = candidates.filter { item in
            if let imdb, let itemIMDb = item.imdbId {
                return itemIMDb.caseInsensitiveCompare(imdb) == .orderedSame
            }
            if let tmdb, let itemTMDb = item.tmdbId {
                return itemTMDb == tmdb
            }
            // No comparable id on either side: exact name and year.
            return imdb == nil && tmdb == nil
                && item.name.caseInsensitiveCompare(hint.name) == .orderedSame
                && (hint.year == nil || item.productionYear == hint.year)
        }

        var files: [JellyfinMediaItem] = []
        if let season, let episode {
            for series in matches {
                guard let list = try? await client.episodes(userId: userId, seriesId: series.id, season: season) else { continue }
                files += list.filter { $0.indexNumber == episode && ($0.parentIndexNumber ?? season) == season }
            }
        } else {
            files = matches
        }

        return files.compactMap { item in
            let file = JellyfinIndexedItem(itemId: item.id, container: item.container, size: item.sizeBytes)
            guard let url = file.streamURL(baseURL: baseURL, accessToken: token) else { return nil }
            return NuvioStream(
                url: url.absoluteString,
                name: serverName,
                description: item.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                addonName: "Jellyfin",
                videoSize: item.sizeBytes
            )
        }
    }
}
