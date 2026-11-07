import Foundation

/// The GitHub repository this build is published from. Update checks and the
/// announcements feed read from here, so a fork never points its users at
/// the upstream app (which lacks the fork's features).
enum AppRepository {
    static let owner = "Arrgh106"
    static let name = "NuvioTVOSxIPTV"
    static var slug: String { "\(owner)/\(name)" }

    /// This app's own URL scheme (Top Shelf links, external player callbacks).
    /// Upstream's `nuvio-tv` would be ambiguous with NuvioTVOS installed too.
    static let urlScheme = "nuvio-iptv"
}
