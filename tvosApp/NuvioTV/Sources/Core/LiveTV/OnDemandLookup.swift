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
        return library.inStreams && library.database != nil && XtreamAccountStore.load() != nil
    }

    static func streams(videoId: String) async -> [NuvioStream] {
        // One of the provider's own titles (opened from the VOD page
        // or Home row without a match): its file, nothing to look up.
        if let own = OnDemandID.parse(videoId) { return await ownStreams(own) }
        guard isAvailable, let database = OnDemandLibrary.shared.database,
              let account = XtreamAccountStore.load(),
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
        let client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))

        return await Task.detached(priority: .userInitiated) { () -> [NuvioStream] in
            let key = OnDemandTitle.key(hint.name)
            let candidates = database.candidates(kind: kind, tmdb: tmdb, key: key)
            guard !candidates.isEmpty else { return [] }
            let categories = database.categoryNames(kind)
            let allowed = candidates.filter { item in
                if hiddenIDs.contains(lockID(kind: kind, category: item.categoryID)) { return false }
                guard lockedNames else { return true }
                if lockedIDs.contains(lockID(kind: kind, category: item.categoryID)) { return false }
                guard lockAdult else { return true }
                return !LiveTVParental.isAdult(item.name) && !LiveTVParental.isAdult(categories[item.categoryID] ?? "")
            }
            let copies = OnDemandMatch.copies(of: allowed, name: hint.name, year: hint.year, tmdb: tmdb)
            var streams: [NuvioStream] = []
            for copy in copies {
                let category = categories[copy.categoryID]
                if let season = episode.season, let number = episode.episode {
                    guard let data = try? await client.seriesInfo(seriesID: copy.id),
                          let found = OnDemandMatch.episode(OnDemandParse.episodes(data), season: season, episode: number),
                          let url = client.episodeURL(episodeID: found.id, ext: found.ext) else { continue }
                    streams.append(stream(url: url, copy: copy, ext: found.ext, category: category, client: client,
                                          title: hint.name, year: nil, season: season, episode: number))
                } else {
                    guard let url = client.movieURL(streamID: copy.id, ext: copy.ext) else { continue }
                    streams.append(stream(url: url, copy: copy, ext: copy.ext ?? "mp4", category: category, client: client,
                                          title: hint.name, year: copy.year ?? hint.year, season: nil, episode: nil))
                }
            }
            return streams
        }.value
    }

    private static func ownStreams(_ own: (kind: OnDemandKind, id: Int, season: Int?, episode: Int?)) async -> [NuvioStream] {
        guard let database = OnDemandLibrary.shared.database,
              let item = database.item(kind: own.kind, id: own.id),
              let account = XtreamAccountStore.load() else { return [] }
        let category = database.categoryNames(own.kind)[item.categoryID]
        // Also when opened from Continue Watching or the history: a locked
        // (or adult) category plays nothing.
        guard !OnDemandBrowse.isHidden(item, categoryName: category ?? "") else { return [] }
        let client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))
        let title = OnDemandTitle.searchName(item.name, tags: database.tags(own.kind))
        // Every version (step 12c): the other copies of this title (other
        // qualities, other categories), this one first, then the best.
        let names = database.categoryNames(own.kind)
        let others = OnDemandMatch.copies(
            of: database.candidates(kind: own.kind, tmdb: item.tmdb, key: item.key)
                .filter { $0.id != item.id && !OnDemandBrowse.isHidden($0, categoryName: names[$0.categoryID] ?? "") },
            name: title, year: item.year, tmdb: item.tmdb, limit: 5)
        let versions = [item] + others
        if own.season == nil, own.kind == .series { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [NuvioStream] in
            var streams: [NuvioStream] = []
            for copy in versions {
                let copyCategory = names[copy.categoryID]
                if let season = own.season, let number = own.episode {
                    guard let data = try? await client.seriesInfo(seriesID: copy.id),
                          let found = OnDemandMatch.episode(OnDemandParse.episodes(data), season: season, episode: number),
                          let url = client.episodeURL(episodeID: found.id, ext: found.ext) else { continue }
                    streams.append(stream(url: url, copy: copy, ext: found.ext, category: copyCategory, client: client,
                                          title: title, year: nil, season: season, episode: number))
                } else {
                    guard let url = client.movieURL(streamID: copy.id, ext: copy.ext) else { continue }
                    streams.append(stream(url: url, copy: copy, ext: copy.ext ?? "mp4", category: copyCategory, client: client,
                                          title: title, year: copy.year ?? item.year, season: nil, episode: nil))
                }
            }
            return streams
        }.value
    }

    /// Parental lock ids for a VOD category (step 12c lets you lock them).
    nonisolated static func lockID(kind: OnDemandKind, category: String) -> String {
        "vod:\(kind.rawValue):\(category)"
    }

    nonisolated private static func stream(
        url: URL, copy: OnDemandItem, ext: String, category: String?, client: XtreamClient,
        title: String, year: Int?, season: Int?, episode: Int?
    ) -> NuvioStream {
        let quality = OnDemandTitle.quality(copy.name)
        let details = [copy.name, category].compactMap { $0 }.joined(separator: " · ")
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
            httpHeaders: client.httpHeaders
        )
    }
}
