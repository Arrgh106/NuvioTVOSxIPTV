import CryptoKit
import Foundation

/// The Xtream logins and Stalker portals (step 13f) VOD reads (step 13c), as Android's catalogue from
/// every playlist with "Include movies & series": their titles in one
/// index, with the app's ids (`LiveTVSourceIDs`: the first login keeps the
/// provider's, the others carry their slot). Calls to a provider go to the
/// login an id belongs to, with its own id.
enum OnDemandSources {
    /// The logins that read VOD, in your order.
    static func all(settings: UserDefaults = ProfileSettings.current) -> [LiveTVSource] {
        LiveTVSourceStore.read(settings: settings).filter {
            $0.enabled && $0.readsVOD && (($0.kind == .xtream && $0.xtream != nil) || $0.kind == .stalker)
        }
    }

    /// Any login VOD reads (the VOD page, Home row, search and stream lists).
    static var hasAny: Bool { !all().isEmpty }

    /// A login's client: Xtream's or the portal's.
    struct Route: Sendable {
        let source: LiveTVSource
        let xtream: XtreamClient?
        let stalker: LiveTVStalkerClient?

        /// The headers a played file is asked with.
        var headers: [String: String] { xtream?.httpHeaders ?? [:] }
    }

    /// A client per login, by slot (made before going off the main thread:
    /// the passwords come from the Keychain).
    static func routes(settings: UserDefaults = ProfileSettings.current) -> [Int: Route] {
        var result: [Int: Route] = [:]
        for source in all(settings: settings) {
            if source.kind == .stalker {
                guard let client = LiveTVStalker.client(sourceID: source.id) else { continue }
                result[source.slot] = Route(source: source, xtream: nil, stalker: client)
            } else if let account = source.xtream {
                result[source.slot] = Route(
                    source: source,
                    xtream: XtreamClient(account: account, password: XtreamAccountStore.password(for: account)),
                    stalker: nil)
            }
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
        if source.kind == .stalker {
            // The MAC is the portal's login: only a hash of it goes into
            // the index's meta.
            let config = LiveTVStalker.config(for: source.id)
            let identity = "\(config?.portal ?? "")|\(config?.mac ?? "")|\(config?.username ?? "")"
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return "\(source.slot)|stalker|\(digest)"
        }
        return "\(source.slot)|\(source.xtream?.server ?? "")|\(source.xtream?.username ?? "")"
    }
}
