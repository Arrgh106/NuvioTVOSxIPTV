import Foundation

/// The provider's copies of the title being opened (step 12a), as Android's
/// "VOD in Streams": matched by TMDB id, otherwise by name and year,
/// and offered as the "VOD" group in the stream list. Categories the
/// parental controls lock (or adult ones, with the automatic lock) never
/// show up.
@MainActor
enum OnDemandLookup {
    nonisolated static let groupID = "livetv.ondemand"
    nonisolated static let groupName = "VOD"
    nonisolated static let bingeGroup = "nuvio-iptv-on-demand"

    /// Whether to look at all: on, logged in, the index read once.
    static var isAvailable: Bool {
        let library = OnDemandLibrary.shared
        library.refreshIfNeeded()
        return library.inStreams && library.database != nil && OnDemandSources.hasAny
    }

    static func streams(videoId: String) async -> [NuvioStream] {
        // One of the provider's own titles (opened from the VOD page
        // or Home row without a match): its file, nothing to look up.
        if let own = OnDemandID.parse(videoId) { return await ownStreams(own) }
        let routes = OnDemandSources.routes()
        guard isAvailable, let database = OnDemandLibrary.shared.database, !routes.isEmpty,
              let hint = await JellyfinLiveLookup.hint(forVideoId: videoId) else { return [] }
        let ids = JellyfinCatalogMatch.catalogIDs(fromVideoId: videoId)
        let tmdb = ids.tmdbID ?? hint.tmdbID
        let episode = StreamsRepository.seasonEpisode(fromVideoId: videoId)
        let kind: OnDemandKind = episode.season != nil ? .series : .movie
        let parental = LiveTVParentalControls.shared
        let lockedNames = parental.isEnabled
        let lockedIDs = parental.lockedGroups
        let lockAdult = parental.isEnabled && parental.lockAdult
        let hiddenIDs = OnDemandPreferences.shared.hidden
        let languages = OnDemandPreferences.shared.languageFilter

        return await Task.detached(priority: .userInitiated) { () -> [NuvioStream] in
            let key = OnDemandTitle.key(hint.name)
            let candidates = database.candidates(kind: kind, tmdb: tmdb, key: key)
            guard !candidates.isEmpty else { return [] }
            let categories = database.categoryNames(kind)
            let unlocked = candidates.filter { item in
                if hiddenIDs.contains(lockID(kind: kind, category: item.categoryID)) { return false }
                guard lockedNames else { return true }
                if lockedIDs.contains(lockID(kind: kind, category: item.categoryID)) { return false }
                guard lockAdult else { return true }
                return !LiveTVParental.isAdult(item.name) && !LiveTVParental.isAdult(categories[item.categoryID] ?? "")
            }
            let allowed = languages.versions(unlocked) { $0.language }
            let copies = OnDemandMatch.copies(of: allowed, name: hint.name, year: hint.year, tmdb: tmdb)
            var streams: [NuvioStream] = []
            for copy in copies {
                guard let route = OnDemandSources.route(copy.id, in: routes),
                      let found = await file(copy, route: route, season: episode.season, episode: episode.episode)
                else { continue }
                let source = routes.count > 1 ? route.source.displayName : nil
                streams.append(stream(
                    url: found.url, copy: copy, ext: found.ext, category: categories[copy.categoryID], headers: found.headers,
                    title: hint.name, year: episode.season == nil ? copy.year ?? hint.year : nil,
                    season: episode.season, episode: episode.episode, source: source))
            }
            return streams
        }.value
    }

    private static func ownStreams(_ own: (kind: OnDemandKind, id: Int, season: Int?, episode: Int?)) async -> [NuvioStream] {
        guard let database = OnDemandLibrary.shared.database,
              let item = database.item(kind: own.kind, id: own.id) else { return [] }
        let routes = OnDemandSources.routes()
        guard !routes.isEmpty else { return [] }
        let category = database.categoryNames(own.kind)[item.categoryID]
        // Also when opened from Continue Watching or the history: a locked
        // (or adult) category plays nothing.
        guard !OnDemandBrowse.isHidden(item, categoryName: category ?? "") else { return [] }
        let title = OnDemandTitle.searchName(item.name, tags: database.tags(own.kind))
        // Every version (step 12c): the other copies of this title (other
        // qualities, other categories), this one first, then the best.
        let names = database.categoryNames(own.kind)
        let others = OnDemandMatch.copies(
            of: database.candidates(kind: own.kind, tmdb: item.tmdb, key: item.key)
                .filter { $0.id != item.id && !OnDemandBrowse.isHidden($0, categoryName: names[$0.categoryID] ?? "") },
            name: title, year: item.year, tmdb: item.tmdb, limit: 7)
        let versions = [item] + others
        if own.season == nil, own.kind == .series { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [NuvioStream] in
            var streams: [NuvioStream] = []
            for copy in versions {
                guard let route = OnDemandSources.route(copy.id, in: routes),
                      let found = await file(copy, route: route, season: own.season, episode: own.episode)
                else { continue }
                let source = routes.count > 1 ? route.source.displayName : nil
                streams.append(stream(
                    url: found.url, copy: copy, ext: found.ext, category: names[copy.categoryID], headers: found.headers,
                    title: title, year: own.season == nil ? copy.year ?? item.year : nil,
                    season: own.season, episode: own.episode, source: source))
            }
            return streams
        }.value
    }

    /// Parental lock ids for a VOD category (step 12c lets you lock them).
    nonisolated static func lockID(kind: OnDemandKind, category: String) -> String {
        "vod:\(kind.rawValue):\(category)"
    }

    /// A copy's file (a movie, or the episode `season` / `episode`): from
    /// the Xtream login, or (step 13f) asked of the Stalker portal, whose
    /// link holds for a while.
    nonisolated private static func file(
        _ copy: OnDemandItem, route: OnDemandSources.Route, season: Int?, episode: Int?
    ) async -> (url: URL, ext: String, headers: [String: String])? {
        if let stalker = route.stalker {
            guard let ref = LiveTVStalkerWire.VODRef.decode(copy.play) else { return nil }
            var target = ref
            if let season, let episode {
                guard let list = try? await stalker.episodes(of: ref, title: copy.name),
                      let found = list.first(where: { $0.season == season && $0.episode == episode }) else { return nil }
                target = found.item.ref
            }
            guard let played = try? await stalker.vodPlayback(target) else { return nil }
            let ext = played.0.pathExtension.isEmpty ? "mp4" : played.0.pathExtension.lowercased()
            return (played.0, ext, played.1)
        }
        guard let client = route.xtream else { return nil }
        let raw = OnDemandSources.raw(copy.id)
        if let season, let episode {
            guard let data = try? await client.seriesInfo(seriesID: raw),
                  let found = OnDemandMatch.episode(OnDemandParse.episodes(data), season: season, episode: episode),
                  let url = client.episodeURL(episodeID: found.id, ext: found.ext) else { return nil }
            return (url, found.ext, client.httpHeaders)
        }
        guard let url = client.movieURL(streamID: raw, ext: copy.ext) else { return nil }
        return (url, copy.ext ?? "mp4", client.httpHeaders)
    }

    nonisolated private static func stream(
        url: URL, copy: OnDemandItem, ext: String, category: String?, headers: [String: String],
        title: String, year: Int?, season: Int?, episode: Int?, source: String? = nil
    ) -> NuvioStream {
        let quality = OnDemandTitle.quality(copy.name)
        // With several logins: which one (step 13c), as Android's versions.
        let details = [copy.name, category, source].compactMap { $0 }.joined(separator: " · ")
        // A release-style file name, so the stream badges (4K, 1080p, …) work.
        var file = title.replacingOccurrences(of: " ", with: ".")
        if let year { file += ".\(year)" }
        if let season, let episode { file += String(format: ".S%02dE%02d", season, episode) }
        if let quality { file += ".\(quality == "4K" ? "2160p" : quality)" }
        file += ".\(ext)"
        return NuvioStream(
            url: url.absoluteString,
            name: groupName + (quality.map { "\n" + $0 } ?? ""),
            description: details + " · " + ext.uppercased(),
            addonName: groupName,
            filename: file,
            bingeGroup: bingeGroup,
            httpHeaders: headers
        )
    }
}
