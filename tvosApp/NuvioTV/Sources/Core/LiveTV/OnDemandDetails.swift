import Foundation

/// Opening one of the provider's titles (step 12b), as Android's On Demand:
/// when it can be matched (the provider's TMDB id, otherwise a Cinemeta
/// search by name and year) Nuvio's own Details open, and the provider's
/// copy is the "On Demand" stream there. Otherwise Details show what the
/// provider says about it (plot, picture, seasons and episodes).
@MainActor
enum OnDemandDetails {
    /// Content id → the catalog id it opens as ("" = none found).
    private static var resolved: [String: String] = [:]
    /// Provider details by content id (`get_vod_info` / `get_series_info`).
    private static var infoCache: [String: [String: Any]] = [:]

    /// Where an On Demand card leads: a catalog id (`tt…`) or its own id.
    static func target(for contentID: String, type: String) async -> (id: String, type: String) {
        guard let parsed = OnDemandID.parse(contentID) else { return (contentID, type) }
        let kindType = parsed.kind == .series ? "series" : "movie"
        if let known = resolved[contentID] {
            return known.isEmpty ? (contentID, kindType) : (known, kindType)
        }
        ActivityCenter.shared.update("ondemand.open", label: L10n.string("livetv_ondemand_opening", fallback: "Opening…"))
        defer { ActivityCenter.shared.finish("ondemand.open") }
        let found = await catalogID(kind: parsed.kind, id: parsed.id) ?? ""
        if resolved.count > 500 { resolved.removeAll() }
        resolved[contentID] = found
        return found.isEmpty ? (contentID, kindType) : (found, kindType)
    }

    /// TMDB id → IMDb id (with a TMDB key), else Cinemeta's search; at most
    /// a few seconds. Adult titles (with the automatic lock) never match.
    private static func catalogID(kind: OnDemandKind, id: Int) async -> String? {
        guard let database = OnDemandLibrary.shared.database,
              let item = database.item(kind: kind, id: id) else { return nil }
        let parental = LiveTVParentalControls.shared
        if parental.isEnabled, parental.lockAdult, LiveTVParental.isAdult(item.name) { return nil }
        let type = kind == .series ? "series" : "movie"
        if let tmdb = item.tmdb,
           let imdb = await withTimeout(4, { await CinemetaCatalogRepository.imdbID(forTmdbID: tmdb, type: type) }) ?? nil {
            return imdb
        }
        let name = OnDemandTitle.searchName(item.name, tags: database.tags(kind))
        guard !name.isEmpty else { return nil }
        return await withTimeout(4, { await cinemetaSearch(name: name, type: type, key: item.key, year: item.year) }) ?? nil
    }

    nonisolated private static func cinemetaSearch(name: String, type: String, key: String, year: Int?) async -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?&=#")
        guard let query = name.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://v3-cinemeta.strem.io/catalog/\(type)/top/search=\(query).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metas = root["metas"] as? [[String: Any]] else { return nil }
        let results: [(id: String, name: String, year: Int?)] = metas.compactMap { meta in
            guard let id = (meta["imdb_id"] as? String) ?? (meta["id"] as? String), id.hasPrefix("tt"),
                  let name = meta["name"] as? String else { return nil }
            let yearText = (meta["releaseInfo"] as? String) ?? (meta["year"] as? String)
            return (id, name, OnDemandTitle.year(field: yearText))
        }
        return OnDemandMatch.pick(results, key: key, year: year)
    }

    nonisolated private static func withTimeout<T: Sendable>(
        _ seconds: Double, _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: The provider's own Details

    /// Details from the provider for a title that matched nothing.
    static func meta(forContentId contentID: String) async -> NuvioMeta? {
        guard let parsed = OnDemandID.parse(contentID), parsed.season == nil,
              let database = OnDemandLibrary.shared.database,
              let item = database.item(kind: parsed.kind, id: parsed.id),
              let account = XtreamAccountStore.load() else { return nil }
        let client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))
        let info = await self.info(contentID: contentID, kind: parsed.kind, id: parsed.id, client: client)
        let details = info?["info"] as? [String: Any] ?? [:]
        func text(_ keys: String...) -> String? {
            for key in keys {
                if let value = details[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
            }
            return nil
        }
        let backdrop = (details["backdrop_path"] as? [String])?.first ?? (details["backdrop_path"] as? String)
        var videos: [NuvioVideo]?
        if parsed.kind == .series, let info, let data = try? JSONSerialization.data(withJSONObject: info) {
            let episodes = OnDemandParse.episodes(data)
            let list = info["episodes"] as? [String: Any]
            videos = episodes.map { episode in
                let entry = ((list?[String(episode.season)] as? [[String: Any]]) ?? [])
                    .first { OnDemandParse.int($0["id"]) == episode.id }
                let extra = entry?["info"] as? [String: Any]
                return NuvioVideo(
                    id: OnDemandID.episode(seriesID: parsed.id, season: episode.season, episode: episode.episode),
                    title: episode.title,
                    season: episode.season,
                    episode: episode.episode,
                    thumbnail: extra?["movie_image"] as? String,
                    overview: extra?["plot"] as? String,
                    released: extra?["releasedate"] as? String,
                    rating: nil
                )
            }
        }
        let genres = text("genre").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return NuvioMeta(
            id: contentID,
            name: OnDemandTitle.searchName(item.name, tags: database.tags(parsed.kind)).nilIfEmpty ?? item.name,
            description: text("plot", "description"),
            posterUrl: text("movie_image", "cover") ?? item.icon,
            backgroundUrl: backdrop,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: item.tmdb,
            type: parsed.kind == .series ? "series" : "movie",
            year: item.year,
            genres: genres,
            rating: item.rating.flatMap(Double.init),
            releaseInfo: item.year.map(String.init),
            runtime: text("duration"),
            cast: text("cast").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } },
            director: text("director").map { [$0] },
            writer: nil,
            certification: nil,
            country: nil,
            released: text("releasedate", "releaseDate"),
            status: nil,
            videos: videos,
            trailerYtIds: nil,
            externalRatings: nil
        )
    }

    private static func info(contentID: String, kind: OnDemandKind, id: Int, client: XtreamClient) async -> [String: Any]? {
        if let cached = infoCache[contentID] { return cached }
        let data: Data?
        switch kind {
        case .movie: data = try? await client.vodInfo(vodID: id)
        case .series: data = try? await client.seriesInfo(seriesID: id)
        }
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if infoCache.count > 100 { infoCache.removeAll() }
        infoCache[contentID] = root
        return root
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
