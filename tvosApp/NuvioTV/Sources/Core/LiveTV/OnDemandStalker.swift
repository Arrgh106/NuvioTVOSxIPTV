import Foundation

/// A Stalker portal's movies and series in the VOD index (step 13f), as
/// Android's `importStalkerKind`. Foundation only, so it is tested on
/// Linux in CI.
enum OnDemandStalker {
    /// What a list was, for `OnDemandLibrary.digest` (the same again needs
    /// no saving).
    static func digestData(_ entries: [LiveTVStalkerWire.VODEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(entries)) ?? Data()
    }

    /// The index's items: an app id for every title (the portal's id when
    /// it is a small number; series from the movie list get their own, the
    /// ids overlap with the series list's), the match key and year, and
    /// what plays it.
    static func items(_ entries: [LiveTVStalkerWire.VODEntry], kind: OnDemandKind) -> (items: [OnDemandItem], tags: Set<String>) {
        let tags = OnDemandTitle.learnTags(entries.map(\.title))
        var used = Set<Int>()
        var items: [OnDemandItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries where !entry.title.isEmpty {
            var id = LiveTVStalkerWire.number(for: entry.ref.id, salt: entry.ref.variant == "v" ? "v" : "")
            while !used.insert(id).inserted { id = id >= 0x7FFF_FFFE ? 1 : id + 1 }
            var item = OnDemandItem(
                kind: kind, id: id, name: entry.title,
                key: OnDemandTitle.key(entry.title, tags: tags),
                categoryID: entry.categoryID, ext: nil, tmdb: entry.tmdb,
                year: OnDemandTitle.year(field: entry.year) ?? OnDemandTitle.yearInName(entry.title))
            item.icon = entry.poster
            item.added = entry.added
            item.rating = entry.rating
            item.play = entry.ref.encoded()
            items.append(item)
        }
        return (items, tags)
    }
}
