import Foundation

/// The Xtream logins VOD reads (step 13c), as Android's catalogue from
/// every playlist with "Include movies & series": their titles in one
/// index, with the app's ids (`LiveTVSourceIDs`: the first login keeps the
/// provider's, the others carry their slot). Calls to a provider go to the
/// login an id belongs to, with its own id.
enum OnDemandSources {
    /// The logins that read VOD, in your order.
    static func all(settings: UserDefaults = ProfileSettings.current) -> [LiveTVSource] {
        LiveTVSourceStore.read(settings: settings).filter {
            $0.enabled && $0.kind == .xtream && $0.readsVOD && $0.xtream != nil
        }
    }

    struct Route: Sendable {
        let client: XtreamClient
        let source: LiveTVSource
    }

    /// A client per login, by slot (made before going off the main thread:
    /// the passwords come from the Keychain).
    static func routes(settings: UserDefaults = ProfileSettings.current) -> [Int: Route] {
        var result: [Int: Route] = [:]
        for source in all(settings: settings) {
            guard let account = source.xtream else { continue }
            result[source.slot] = Route(
                client: XtreamClient(account: account, password: XtreamAccountStore.password(for: account)),
                source: source)
        }
        return result
    }

    /// The login of an item id.
    static func route(_ id: Int, in routes: [Int: Route]) -> Route? {
        routes[LiveTVSourceIDs.slot(ofChannel: id)]
    }

    /// The login's own id of an item id.
    static func raw(_ id: Int) -> Int {
        LiveTVSourceIDs.raw(ofChannel: id)
    }

    /// What the logins were read with: another set (added, removed, other
    /// server or user) is looked at again.
    static func fingerprint(_ sources: [LiveTVSource]) -> String {
        sources.map(key).sorted().joined(separator: ";")
    }

    /// One login as read: another server or user reads it again.
    static func key(_ source: LiveTVSource) -> String {
        "\(source.slot)|\(source.xtream?.server ?? "")|\(source.xtream?.username ?? "")"
    }
}
