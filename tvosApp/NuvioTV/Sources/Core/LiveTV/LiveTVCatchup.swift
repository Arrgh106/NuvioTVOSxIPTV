import Foundation

/// Catch-up (LIVE_TV_DESIGN.md, step 6): watching a show again on a channel
/// whose provider keeps an archive, as Android's `CatchupUrlBuilder` does it
/// for Xtream. Foundation only, so it is tested on Linux in CI.
enum LiveTVCatchup {
    /// How far back the stored guide goes (`LiveTVGuide.pastWindow`).
    static let guidePast: TimeInterval = 24 * 3600

    /// A show that started before now, within the channel's archive.
    static func isAvailable(start: Date, archiveDays: Int, now: Date) -> Bool {
        guard archiveDays > 0, start < now else { return false }
        return now.timeIntervalSince(start) <= Double(archiveDays) * 86_400
    }

    /// How far Left goes back in the guide for a channel (nil: no archive).
    static func earliest(archiveDays: Int, now: Date) -> Date? {
        guard archiveDays > 0 else { return nil }
        return now.addingTimeInterval(-min(Double(archiveDays) * 86_400, guidePast))
    }

    /// Xtream replay links for a show, the likeliest first; the others are
    /// tried in turn when one fails, because panels differ:
    /// 1. `{server}/timeshift/{user}/{pass}/{minutes}/{yyyy-MM-dd:HH-mm}/{id}.{ext}`
    ///    with the start in the server's time zone (TiviMate's form),
    /// 2. the same with the other extension (some panels replay only HLS or TS),
    /// 3. a show still on air: only the minutes aired so far,
    /// 4. `timeshift.php` (older panels),
    /// 5. without the server's time zone: the start in UTC instead.
    static func xtreamURLs(
        server: String,
        username: String,
        password: String,
        streamID: Int,
        start: Date,
        end: Date,
        now: Date,
        fileExtension: String,
        serverTimeZone: TimeZone?
    ) -> [URL] {
        let user = pathEncode(username)
        let pass = pathEncode(password)
        let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded(.up)))
        let zone = serverTimeZone ?? .current
        let stamp = Self.stamp(start, in: zone)
        let other = fileExtension == "m3u8" ? "ts" : "m3u8"
        func timeshift(_ minutes: Int, _ stamp: String, _ ext: String) -> String {
            "\(server)/timeshift/\(user)/\(pass)/\(minutes)/\(stamp)/\(streamID).\(ext)"
        }
        var links = [
            timeshift(minutes, stamp, fileExtension),
            timeshift(minutes, stamp, other),
        ]
        if end > now {
            let aired = max(1, Int((now.timeIntervalSince(start) / 60).rounded(.down)))
            if aired < minutes {
                links.append(timeshift(aired, stamp, fileExtension))
                links.append(timeshift(aired, stamp, other))
            }
        }
        var php = URLComponents(string: "\(server)/streaming/timeshift.php")
        php?.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "stream", value: String(streamID)),
            URLQueryItem(name: "start", value: stamp),
            URLQueryItem(name: "duration", value: String(minutes)),
        ]
        if var components = php {
            // URLComponents leaves "+" unescaped, which servers read as a space.
            let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            components.percentEncodedQuery = query
            if let link = components.string { links.append(link) }
        }
        if serverTimeZone == nil, let utc = TimeZone(identifier: "UTC") {
            let utcStamp = Self.stamp(start, in: utc)
            if utcStamp != stamp { links.append(timeshift(minutes, utcStamp, fileExtension)) }
        }
        var seen = Set<String>()
        return links.filter { seen.insert($0).inserted }.compactMap(URL.init(string:))
    }

    /// "2026-11-11:20-15" in `zone`.
    static func stamp(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d:%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func pathEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
