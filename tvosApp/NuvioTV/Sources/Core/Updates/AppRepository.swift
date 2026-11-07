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

    /// Client ID of this app's own Trakt API app, so users only tap
    /// "Connect" and approve on their phone, like on Android. A Trakt client
    /// ID is public (it ships in every Android APK too); new Trakt apps need
    /// no secret. Registered redirect URI: `http://localhost:5173/callback`
    /// (development apps only accept localhost; device login never opens
    /// it, but token refreshes must send it). Forks should use their own app.
    /// Empty = users have to enter their own Client ID (upstream behaviour).
    static let traktClientID = "3maPPLzo48UbH6kAPS2bGyxEAoScNgdRdKHmzzouxpc"

    /// Client ID of this app's own Simkl app (PIN login, no secret needed).
    /// Registered redirect URI: `urn:ietf:wg:oauth:2.0:oob`. Empty = users
    /// have to enter their own Client ID (upstream behaviour).
    static let simklClientID = ""
}
