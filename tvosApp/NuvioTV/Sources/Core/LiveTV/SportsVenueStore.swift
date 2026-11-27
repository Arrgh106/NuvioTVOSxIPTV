import Foundation

/// Fork (Live TV step 17d): the stadium pictures behind a game's page and
/// the players' photos ESPN has none for (see `SportsVenues`). Each venue is looked up once and kept on the
/// Apple TV (one with none found is tried again after a week); lookups go
/// one at a time, the one asked for last first, and stop for a while when
/// Wikimedia asks to slow down.
@MainActor
final class SportsVenueStore: ObservableObject {
    static let shared = SportsVenueStore()

    /// Picture links by venue key.
    @Published private(set) var images: [String: String]
    private var misses: [String: Date]
    private var queue: [SportsVenueQuery] = []
    private var worker: Task<Void, Never>?
    private var pausedUntil = Date.distantPast

    private static let imagesKey = "livetv.sports.venueImages"
    private static let missesKey = "livetv.sports.venueMisses"
    private static let retryAfter: TimeInterval = 7 * 24 * 3600

    private init() {
        images = UserDefaults.standard.dictionary(forKey: Self.imagesKey) as? [String: String] ?? [:]
        let saved = UserDefaults.standard.dictionary(forKey: Self.missesKey) as? [String: Double] ?? [:]
        misses = saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// The picture for a game or team, when found.
    func image(_ query: SportsVenueQuery?) -> URL? {
        guard let key = query?.key, let link = images[key] else { return nil }
        return URL(string: link)
    }

    /// Look it up (unless known).
    func want(_ query: SportsVenueQuery?) {
        guard let query, let key = query.key, images[key] == nil else { return }
        if let missed = misses[key], Date().timeIntervalSince(missed) < Self.retryAfter { return }
        queue.removeAll { $0.key == key }
        queue.insert(query, at: 0)
        if queue.count > 20 { queue.removeLast(queue.count - 20) }
        guard worker == nil else { return }
        worker = Task { await work() }
    }

    private func work() async {
        defer { worker = nil }
        while let query = queue.first, let key = query.key {
            guard Date() >= pausedUntil else { return }
            queue.removeFirst()
            switch await Self.lookup(query) {
            case .found(let link):
                images[key] = link
                UserDefaults.standard.set(images, forKey: Self.imagesKey)
            case .none:
                misses[key] = Date()
                UserDefaults.standard.set(misses.mapValues(\.timeIntervalSince1970), forKey: Self.missesKey)
            case .busy:
                // Asked to slow down: this one again later.
                pausedUntil = Date().addingTimeInterval(600)
                queue.insert(query, at: 0)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private enum Outcome { case found(String), none, busy }

    private struct Busy: Error {}

    nonisolated private static func lookup(_ query: SportsVenueQuery) async -> Outcome {
        do {
            if let player = query.player?.nilIfBlank {
                guard let team = query.team?.nilIfBlank, let link = try await playerPhoto(player, team: team) else { return .none }
                return .found(link)
            }
            if let venue = query.venue?.nilIfBlank, let link = try await venueImage(venue, city: query.city) {
                return .found(link)
            }
            if let team = query.team?.nilIfBlank, let link = try await teamGround(team) {
                return .found(link)
            }
            return .none
        } catch {
            return error is Busy ? .busy : .none
        }
    }

    /// The venue's own article, when it checks out.
    nonisolated private static func venueImage(_ name: String, city: String?) async throws -> String? {
        guard let url = SportsVenues.pageURL(name), let data = try await fetch(url),
              let page = SportsVenues.parsePage(data), let item = page.item,
              let itemURL = SportsVenues.itemURL(item), let itemData = try await fetch(itemURL),
              SportsVenues.isVenue(page, item: itemData, city: city) else { return nil }
        return page.image ?? SportsVenues.groundImage(itemData, item: item)
    }

    /// The team's current home ground's picture.
    nonisolated private static func teamGround(_ team: String) async throws -> String? {
        guard let url = SportsVenues.pageURL(team), let data = try await fetch(url),
              let page = SportsVenues.parsePage(data), !page.disambiguation, let item = page.item,
              let itemURL = SportsVenues.itemURL(item), let itemData = try await fetch(itemURL),
              let ground = SportsVenues.homeGround(team: itemData, item: item),
              let groundURL = SportsVenues.itemURL(ground), let groundData = try await fetch(groundURL) else { return nil }
        return SportsVenues.groundImage(groundData, item: ground)
    }

    /// A player's photo: his team's item (its article), the items named
    /// like him, the one playing for that team now.
    nonisolated private static func playerPhoto(_ name: String, team: String) async throws -> String? {
        guard let url = SportsVenues.pageURL(team), let data = try await fetch(url),
              let page = SportsVenues.parsePage(data), !page.disambiguation, let teamItem = page.item,
              let searchURL = SportsVenues.searchURL(name), let found = try await fetch(searchURL) else { return nil }
        let ids = SportsVenues.searchIDs(found)
        guard !ids.isEmpty, let itemsURL = SportsVenues.itemsURL(ids), let items = try await fetch(itemsURL) else { return nil }
        return SportsVenues.playerImage(items, ids: ids, team: teamItem)
    }

    /// Wikimedia asks for a name in the User-Agent (no personal details).
    nonisolated private static func fetch(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("NuvioTV/1.0 (Apple TV app; stadium pictures)", forHTTPHeaderField: "User-Agent")
        guard let answer = try? await URLSession.shared.data(for: request),
              let http = answer.1 as? HTTPURLResponse else { return nil }
        if http.statusCode == 429 || http.statusCode == 503 { throw Busy() }
        return http.statusCode == 200 ? answer.0 : nil
    }
}
