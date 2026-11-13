import Foundation

/// VOD in Nuvio's search (step 12c), as Android's On Demand search row:
/// the provider's titles matching what was typed. Search shows one list
/// of cards in every style, so the titles the add-ons didn't find are
/// added at its end (the others already open with the provider's copy in
/// their stream list). Hidden, locked and adult (automatic lock)
/// categories are left out. Settings → Live TV / VOD → VOD → VOD in Search.
@MainActor
enum OnDemandSearch {
    static let limit = 40

    static func adding(to outcome: CatalogSearchOutcome, query: String) async -> CatalogSearchOutcome {
        let vod = await results(for: query, known: outcome.results)
        guard !vod.isEmpty else { return outcome }
        return CatalogSearchOutcome(results: outcome.results + vod, isComplete: outcome.isComplete)
    }

    private static func results(for query: String, known: [NuvioMeta]) async -> [NuvioMeta] {
        let words = OnDemandTitle.searchWords(query)
        guard OnDemandPreferences.shared.inSearch, !words.isEmpty, words.joined().count >= 2,
              XtreamAccountStore.load() != nil, let database = OnDemandLibrary.shared.database else { return [] }
        let found = await Task.detached(priority: .userInitiated) {
            (movies: database.search(kind: .movie, words: words, limit: 150),
             series: database.search(kind: .series, words: words, limit: 150),
             names: [OnDemandKind.movie: database.categoryNames(.movie), .series: database.categoryNames(.series)],
             tags: [OnDemandKind.movie: database.tags(.movie), .series: database.tags(.series)])
        }.value
        guard !Task.isCancelled else { return [] }
        let merge = OnDemandPreferences.shared.mergeDuplicates
        let knownTitles = known.map { (name: $0.name, year: $0.year, tmdb: $0.tmdbId) }
        func shown(_ items: [OnDemandItem]) -> [OnDemandItem] {
            var dedupe = OnDemandDedupe()
            let visible = items.filter {
                !OnDemandBrowse.isHidden($0, categoryName: found.names[$0.kind]?[$0.categoryID] ?? "")
                    && (!merge || dedupe.isNew($0))
            }
            return OnDemandSearchMatch.providerOnly(visible, known: knownTitles)
        }
        return OnDemandSearchMatch.mix(movies: shown(found.movies), series: shown(found.series), limit: limit)
            .map { OnDemandBrowse.meta($0, tags: found.tags[$0.kind] ?? []) }
    }
}
