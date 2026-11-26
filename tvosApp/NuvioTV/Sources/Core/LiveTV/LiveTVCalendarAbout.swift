import Foundation

/// Fork: what the calendar says about the card in focus beyond its dates
/// (step 16): the show's or film's text, ratings, genres and cast, from the
/// same metadata and ratings its page uses. Asked only for the card in
/// focus, a moment after it's chosen; kept while the app runs.
@MainActor
final class LiveTVCalendarAbout: ObservableObject {
    static let shared = LiveTVCalendarAbout()

    @Published private(set) var metas: [String: NuvioMeta] = [:]
    @Published private(set) var ratings: [String: [NuvioExternalRating]] = [:]

    private var asking: Set<String> = []
    private var failedAt: [String: Date] = [:]
    private var waiting: Task<Void, Never>?

    /// The metadata of a card's title, when it's known.
    func meta(_ entry: LiveTVCalendarEntry) -> NuvioMeta? { metas[entry.contentID] }

    /// The ratings to show (the ones fetched, else the metadata's own).
    func shownRatings(_ entry: LiveTVCalendarEntry) -> [NuvioExternalRating] {
        guard let meta = metas[entry.contentID] else { return [] }
        return AddonRatingsService.heroDisplayRatings(
            for: meta, fetched: ratings[entry.contentID] ?? AddonRatingsService.cachedHeroRatings(for: meta))
    }

    /// The card in focus changed: its title is asked after a short pause,
    /// so scrolling past cards asks nothing.
    func want(_ entry: LiveTVCalendarEntry?) {
        waiting?.cancel()
        guard let entry, Self.canAsk(entry.contentID), metas[entry.contentID] == nil,
              !asking.contains(entry.contentID) else { return }
        if let failed = failedAt[entry.contentID], Date().timeIntervalSince(failed) < 600 { return }
        waiting = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.ask(entry)
        }
    }

    /// IMDb ids only: what the metadata add-on knows titles by.
    private static func canAsk(_ id: String) -> Bool { id.hasPrefix("tt") }

    private func ask(_ entry: LiveTVCalendarEntry) async {
        let id = entry.contentID
        asking.insert(id)
        defer { asking.remove(id) }
        let type = entry.kind == .movie ? "movie" : "series"
        guard let meta = try? await CinemetaCatalogRepository().getMetadata(id: id, type: type) else {
            failedAt[id] = Date()
            return
        }
        metas[id] = meta
        let found = await AddonRatingsService.fetchHeroRatings(for: meta)
        if !found.isEmpty { ratings[id] = found }
    }
}
