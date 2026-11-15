import Foundation

/// One channel of an M3U playlist (step 13b).
struct LiveTVM3UEntry: Equatable, Sendable {
    var name: String
    var url: String
    var tvgID: String?
    var tvgName: String?
    var logo: String?
    var group: String?
    var number: Int?
    /// HTTP headers for the stream (User-Agent, Referer, Origin, …).
    var headers: [String: String] = [:]
    /// Its archive (step 13d), from its attributes over the playlist's.
    var catchup: LiveTVM3UCatchup? = nil
}

struct LiveTVM3UPlaylist: Equatable, Sendable {
    var entries: [LiveTVM3UEntry] = []
    /// Guides linked in the `#EXTM3U` line (`url-tvg`, `x-tvg-url`,
    /// `tvg-url`), as Android reads them.
    var guideURLs: [String] = []
}

/// Reads M3U playlists as Android's `M3uParser`: `#EXTINF` with tvg-id,
/// tvg-name, tvg-logo / logo, group-title (or `#EXTGRP`), tvg-chno /
/// channel-number / tvg-num, user-agent; headers from `#EXTVLCOPT`,
/// `#EXTHTTP` and `link|User-Agent=…`. Movies and series in the list are
/// left out (they belong to VOD), as on Android.
enum LiveTVM3U {
    static func parse(_ text: String) -> LiveTVM3UPlaylist {
        var playlist = LiveTVM3UPlaylist()
        var pending: LiveTVM3UEntry?
        var pendingGroup: String?
        var pendingHeaders: [String: String] = [:]
        /// Catch-up attributes of the `#EXTM3U` line: for every entry.
        var playlistCatchup: [String: String] = [:]
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTM3U") {
                let attributes = attributes(of: Substring(line.dropFirst(7)))
                for key in catchupKeys {
                    if let value = attributes[key], !value.isEmpty { playlistCatchup[key] = value }
                }
                for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                    for link in (attributes[key] ?? "").split(separator: ",") {
                        let trimmed = link.trimmingCharacters(in: .whitespaces)
                        if trimmed.lowercased().hasPrefix("http"), !playlist.guideURLs.contains(trimmed) {
                            playlist.guideURLs.append(trimmed)
                        }
                    }
                }
            } else if line.hasPrefix("#EXTINF:") {
                pending = entry(fromInfo: Substring(line.dropFirst(8)), playlistCatchup: playlistCatchup)
                pendingGroup = nil
                pendingHeaders = [:]
            } else if line.hasPrefix("#EXTGRP:") {
                let group = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
                if !group.isEmpty { pendingGroup = group }
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst(11)
                guard let equals = option.firstIndex(of: "=") else { continue }
                let key = option[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = option[option.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if let header = vlcHeaders[key], !value.isEmpty { pendingHeaders[header] = value }
            } else if line.hasPrefix("#EXTHTTP:") {
                if let data = line.dropFirst(9).data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for (key, value) in object {
                        if let text = value as? String { pendingHeaders[canonical(key)] = text }
                    }
                }
            } else if line.hasPrefix("#") {
                continue
            } else {
                // The link: closes the entry above it.
                guard var entry = pending else { continue }
                pending = nil
                let (url, linkHeaders) = splitLink(line)
                guard !url.isEmpty else { continue }
                entry.url = url
                if entry.group == nil { entry.group = pendingGroup }
                entry.headers.merge(pendingHeaders) { _, new in new }
                entry.headers.merge(linkHeaders) { _, new in new }
                if !isVOD(url: url) { playlist.entries.append(entry) }
            }
        }
        return playlist
    }

    static let catchupKeys = ["catchup", "catchup-type", "catchup-source", "catchup-days", "catchup-correction", "tvg-rec", "timeshift"]

    private static let vlcHeaders = [
        "http-user-agent": "User-Agent", "http-referrer": "Referer", "http-referer": "Referer",
        "http-origin": "Origin",
    ]

    /// `-1 tvg-id="…" group-title="…",Name`: the name is what follows the
    /// first comma outside quotes.
    static func entry(fromInfo info: Substring, playlistCatchup: [String: String] = [:]) -> LiveTVM3UEntry {
        var inQuotes = false
        var nameStart: Substring.Index?
        for index in info.indices {
            let character = info[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ",", !inQuotes {
                nameStart = info.index(after: index)
                break
            }
        }
        let head = nameStart.map { info[..<info.index(before: $0)] } ?? info
        let attributes = attributes(of: head)
        let title = nameStart.map { info[$0...].trimmingCharacters(in: .whitespaces) } ?? ""
        var entry = LiveTVM3UEntry(name: "", url: "")
        entry.tvgID = attributes["tvg-id"].flatMap(nonEmpty)
        entry.tvgName = attributes["tvg-name"].flatMap(nonEmpty)
        entry.logo = (attributes["tvg-logo"] ?? attributes["logo"]).flatMap(nonEmpty)
        entry.group = attributes["group-title"]
            .map { $0.split(separator: ";").first.map(String.init) ?? $0 }
            .flatMap { nonEmpty($0.trimmingCharacters(in: .whitespaces)) }
        entry.number = (attributes["tvg-chno"] ?? attributes["channel-number"] ?? attributes["tvg-num"])
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let agent = (attributes["user-agent"] ?? attributes["http-user-agent"]).flatMap(nonEmpty) {
            entry.headers["User-Agent"] = agent
        }
        if let referrer = attributes["http-referrer"].flatMap(nonEmpty) { entry.headers["Referer"] = referrer }
        entry.name = nonEmpty(title) ?? entry.tvgName ?? entry.tvgID ?? "—"
        entry.catchup = LiveTVM3UCatchup(attributes: playlistCatchup.merging(attributes) { _, own in own })
        return entry
    }

    /// `key="value"` pairs (keys in lower case); values without quotes run
    /// to the next space.
    static func attributes(of text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        while index < text.endIndex {
            guard let equals = text[index...].firstIndex(of: "=") else { break }
            let key = text[index..<equals].split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map { $0.lowercased() } ?? ""
            var valueStart = text.index(after: equals)
            let value: Substring
            if valueStart < text.endIndex, text[valueStart] == "\"" {
                valueStart = text.index(after: valueStart)
                let close = text[valueStart...].firstIndex(of: "\"") ?? text.endIndex
                value = text[valueStart..<close]
                index = close < text.endIndex ? text.index(after: close) : close
            } else {
                let end = text[valueStart...].firstIndex(where: { $0 == " " || $0 == "\t" }) ?? text.endIndex
                value = text[valueStart..<end]
                index = end
            }
            if !key.isEmpty { result[key] = String(value) }
        }
        return result
    }

    /// Kodi's `link|User-Agent=…&Referer=…`.
    static func splitLink(_ line: String) -> (url: String, headers: [String: String]) {
        guard let bar = line.firstIndex(of: "|") else { return (line, [:]) }
        var headers: [String: String] = [:]
        for pair in line[line.index(after: bar)...].split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = canonical(String(pair[..<equals]))
            let raw = String(pair[pair.index(after: equals)...])
            headers[key] = raw.removingPercentEncoding ?? raw
        }
        return (String(line[..<bar]).trimmingCharacters(in: .whitespaces), headers)
    }

    /// Movies and series in a playlist: by the path or the file type.
    static func isVOD(url: String) -> Bool {
        let path = (URLComponents(string: url)?.path ?? url).lowercased()
        if path.contains("/movie/") || path.contains("/movies/") || path.contains("/series/") || path.contains("/vod/") {
            return true
        }
        return ["mp4", "mkv", "avi", "mov", "wmv", "m4v", "webm", "flv"].contains((path as NSString).pathExtension)
    }

    /// Ids for the entries, the same at every read while names and tvg-ids
    /// stay (links with tokens may change): favorites and names hold.
    /// Below 2^31; a clash takes the next free number.
    static func ids(for entries: [LiveTVM3UEntry]) -> [Int] {
        var used = Set<Int>()
        return entries.map { entry in
            let key = (entry.tvgID ?? "") + "|" + entry.name
            var id = Int(fnv1a(key) & 0x7FFF_FFFF)
            if id == 0 { id = 1 }
            while !used.insert(id).inserted { id = id == 0x7FFF_FFFF ? 1 : id + 1 }
            return id
        }
    }

    /// The groups in the order they first come, for the group column.
    static func groups(of entries: [LiveTVM3UEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            if let group = entry.group, seen.insert(group).inserted { result.append(group) }
        }
        return result
    }

    private static func canonical(_ key: String) -> String {
        switch key.trimmingCharacters(in: .whitespaces).lowercased() {
        case "user-agent", "http-user-agent": return "User-Agent"
        case "referer", "referrer", "http-referrer", "http-referer": return "Referer"
        case "origin", "http-origin": return "Origin"
        case "cookie": return "Cookie"
        default: return key.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
