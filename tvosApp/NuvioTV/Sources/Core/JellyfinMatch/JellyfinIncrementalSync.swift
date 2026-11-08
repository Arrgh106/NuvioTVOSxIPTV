import Foundation

/// Fork: updates one Jellyfin library in the local index without reading
/// the whole library again.
///
/// 1. Lists the library's item ids only (a few bytes per item).
/// 2. Ids missing on the server → removed locally.
/// 3. Items the server saved since the last sync (`MinDateLastSaved`) and
///    ids not indexed yet → their full details are fetched.
/// 4. Those are merged into the existing titles.
///
/// A full read still happens the first time, for a library without indexed
/// titles, when the user starts a sync by hand, and once a week as a safety
/// net (e.g. a changed series poster without any changed episode).
enum JellyfinIncrementalSync {
    struct Outcome {
        var titles: [JellyfinIndexedTitle]
        var unmatched: [String]
        var added = 0
        var updated = 0
        var removed = 0
        var incremental = false
    }

    /// `progress(text, count)`: a status line and a running item count.
    typealias Progress = (_ text: String, _ count: Int) async -> Void

    static let fullSyncInterval: TimeInterval = 7 * 24 * 3600

    static func syncLibrary(
        client: JellyfinClient,
        userId: String,
        serverID: String,
        library: JellyfinLibrary,
        existing: [JellyfinIndexedTitle],
        lastSync: Date?,
        forceFull: Bool,
        progress: Progress
    ) async throws -> Outcome {
        guard !forceFull, let lastSync, !existing.isEmpty else {
            return try await fullSync(client: client, userId: userId, serverID: serverID, library: library, progress: progress)
        }

        // 1. What is on the server now.
        let stubs = try await client.itemStubs(userId: userId, libraryId: library.id) { loaded, total in
            await progress(status(library.name, "checking", loaded, total), loaded)
        }
        let current = Set(stubs.map(\.id))
        var known = Set<String>()
        for title in existing {
            known.insert(title.itemId)
            title.items.forEach { known.insert($0.itemId) }
        }
        // An empty answer for a library we hold titles for is more likely a
        // server hiccup than a wiped library: confirm with a full read.
        if current.isEmpty {
            return try await fullSync(client: client, userId: userId, serverID: serverID, library: library, progress: progress)
        }

        // 2./3. Changed since the last sync (a little overlap for clock skew),
        // plus anything not indexed yet.
        let changed = try await client.items(
            userId: userId,
            libraryId: library.id,
            changedSince: lastSync.addingTimeInterval(-10 * 60)
        ) { loaded, total in
            await progress(status(library.name, "changes", loaded, total), loaded)
        }
        let changedIDs = Set(changed.map(\.id))
        let newIDs = current.subtracting(known).subtracting(changedIDs)
        var details = changed
        if !newIDs.isEmpty {
            await progress(status(library.name, "new", newIDs.count, nil), newIDs.count)
            details += try await client.items(userId: userId, ids: Array(newIDs))
        }

        // Episodes need their series item to be grouped; fetch the ones
        // that aren't part of this batch already.
        let seriesInBatch = Set(details.filter { $0.type == "Series" }.map(\.id))
        let missingSeries = Set(details.compactMap { $0.type == "Episode" ? $0.seriesId : nil })
            .subtracting(seriesInBatch)
        if !missingSeries.isEmpty {
            details += try await client.items(userId: userId, ids: Array(missingSeries))
        }

        let removedIDs = known.subtracting(current)
        let resolution = JellyfinLibraryResolver.resolve(
            details,
            serverID: serverID,
            libraryID: library.id,
            libraryName: library.name
        )

        // 4. Merge.
        var byContentID: [String: JellyfinIndexedTitle] = [:]
        for var title in existing where !removedIDs.contains(title.itemId) {
            title.items.removeAll { removedIDs.contains($0.itemId) }
            if title.type == "movie" || !title.items.isEmpty {
                byContentID[title.contentId] = title
            }
        }
        for var title in resolution.titles {
            if title.type == "series", let old = byContentID[title.contentId] {
                let fresh = Set(title.items.map(\.itemId))
                title.items = old.items.filter { !fresh.contains($0.itemId) } + title.items
            }
            byContentID[title.contentId] = title
        }

        return Outcome(
            titles: Array(byContentID.values),
            unmatched: resolution.unmatched,
            added: current.subtracting(known).count,
            updated: changedIDs.intersection(known).count,
            removed: removedIDs.count,
            incremental: true
        )
    }

    private static func fullSync(
        client: JellyfinClient,
        userId: String,
        serverID: String,
        library: JellyfinLibrary,
        progress: Progress
    ) async throws -> Outcome {
        let items = try await client.items(userId: userId, libraryId: library.id) { loaded, total in
            await progress(status(library.name, "full", loaded, total), loaded)
        }
        let resolution = JellyfinLibraryResolver.resolve(
            items,
            serverID: serverID,
            libraryID: library.id,
            libraryName: library.name
        )
        return Outcome(titles: resolution.titles, unmatched: resolution.unmatched, added: items.count)
    }

    /// "Movies · checking 2,000 / 23,412"
    static func status(_ library: String, _ phase: String, _ loaded: Int, _ total: Int?) -> String {
        let label: String
        switch phase {
        case "checking": label = L10n.string("jellyfin_sync_phase_checking", fallback: "Checking for changes")
        case "changes": label = L10n.string("jellyfin_sync_phase_changes", fallback: "Loading changed items")
        case "new": label = L10n.string("jellyfin_sync_phase_new", fallback: "Loading new items")
        default: label = L10n.string("jellyfin_sync_phase_full", fallback: "Reading library")
        }
        let count = total.map { "\(loaded.formatted()) / \($0.formatted())" } ?? loaded.formatted()
        return "\(library) · \(label) \(count)"
    }

    // MARK: - Full-sync schedule

    private static func lastFullSyncKey(_ serverID: String) -> String {
        "nuvio.tv.jellyfin.lastFullSync.\(serverID)"
    }

    static func needsFullSync(serverID: String) -> Bool {
        let last = ProfileSettings.current.double(forKey: lastFullSyncKey(serverID))
        return last == 0 || Date().timeIntervalSince1970 - last > fullSyncInterval
    }

    static func recordFullSync(serverID: String) {
        ProfileSettings.current.set(Date().timeIntervalSince1970, forKey: lastFullSyncKey(serverID))
    }
}
