import Foundation

/// An XMLTV guide added by hand next to the provider's (step 9), as
/// Android's `EpgSource`. The link itself is kept in the Keychain (it often
/// carries a user name and password), see `LiveTVEPGSources`.
struct LiveTVEPGSource: Codable, Hashable, Identifiable, Sendable {
    /// Short, lowercase, no "|": it is part of the guide channel keys.
    let id: String
    var name: String
    var enabled: Bool = true
    /// Minutes the guide's listings are moved by: later (+) or earlier (−).
    var shiftMinutes: Int = 0

    static func newID() -> String {
        "x" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }
}

/// One guide file to read at the import: the provider's or an added one.
struct LiveTVGuideFeed: Sendable {
    /// "" for the provider's guide, else the source's id.
    let sourceID: String
    let name: String
    let url: URL
    let shiftMinutes: Int
}

/// Rules around guide sources with no UIKit, SQLite or Keychain, so they
/// have Linux tests (Tests/LiveTVLogic).
enum LiveTVEPGSourceRules {
    /// Time shifts offered: −12 h to +12 h in half hours (Android: ±24 h).
    static let shiftChoices = Array(stride(from: -12 * 60, through: 12 * 60, by: 30))

    /// "+1:30 h", "−0:30 h", "None".
    static func shiftLabel(_ minutes: Int, none: String = "None") -> String {
        guard minutes != 0 else { return none }
        let sign = minutes > 0 ? "+" : "−"
        let value = abs(minutes)
        return "\(sign)\(value / 60):" + String(format: "%02d", value % 60) + " h"
    }

    /// The key a guide channel is stored under: the provider's guide keeps
    /// its ids as they are (older choices in Assign EPG stay valid), added
    /// guides put their source in front, so equal ids don't mix.
    static func key(sourceID: String, guideID: String) -> String {
        let id = guideID.lowercased()
        return sourceID.isEmpty ? id : sourceID + "|" + id
    }

    /// The guide id without its source ("x1a2b3c4d|das.erste.de" → "das.erste.de").
    static func guideID(fromKey key: String) -> String {
        guard key.hasPrefix("x"), let bar = key.firstIndex(of: "|") else { return key }
        return String(key[key.index(after: bar)...])
    }

    /// The host shown under a guide in Settings ("epgshare01.online").
    static func host(of url: String) -> String {
        URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.host ?? url
    }

    /// What the stored guide was read from; a different one means read
    /// again. Links go in as a hash only (the database isn't the Keychain).
    static func fingerprint(_ feeds: [LiveTVGuideFeed]) -> String {
        feeds.map { feed in
            "\(feed.sourceID):\(String(fnv1a(feed.url.absoluteString), radix: 36)):\(feed.shiftMinutes)"
        }.joined(separator: ",")
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: gzip

    /// A gzip file starts with 1f 8b.
    static func isGzip(_ head: [UInt8]) -> Bool {
        head.count >= 2 && head[0] == 0x1f && head[1] == 0x8b
    }

    /// Length of a gzip header (RFC 1952), where the deflate data begins.
    /// Nil when it isn't one or it's longer than `head`.
    static func gzipHeaderLength(_ head: [UInt8]) -> Int? {
        guard head.count >= 10, isGzip(head), head[2] == 8 else { return nil }
        let flags = head[3]
        var index = 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard head.count >= index + 2 else { return nil }
            index += 2 + Int(head[index]) + Int(head[index + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT
            while index < head.count, head[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }   // FHCRC
        return index <= head.count ? index : nil
    }
}
