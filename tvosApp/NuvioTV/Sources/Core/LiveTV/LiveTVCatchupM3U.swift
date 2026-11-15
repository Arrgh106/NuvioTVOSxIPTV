import Foundation

/// What an M3U playlist says about a channel's archive (step 13d), as
/// Android's `CatchupInfo`: `catchup` / `catchup-type`, `catchup-source`,
/// `catchup-days` (or `tvg-rec`, `timeshift`), `catchup-correction`.
struct LiveTVM3UCatchup: Codable, Hashable, Sendable {
    var type: String
    var source: String?
    var days: Int
    /// Hours the playlist moves catch-up times by (TiviMate's).
    var correctionHours: Double = 0

    /// From an entry's attributes over the playlist's: nil without any.
    init?(attributes: [String: String]) {
        let type = attributes["catchup"] ?? attributes["catchup-type"]
        let days = (attributes["catchup-days"] ?? attributes["tvg-rec"] ?? attributes["timeshift"])
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard type?.isEmpty == false || (days ?? 0) > 0 else { return nil }
        self.type = (type?.isEmpty == false ? type! : "default").lowercased()
        self.source = attributes["catchup-source"].flatMap { $0.isEmpty ? nil : $0 }
        // The playlist's word only: kept within sane bounds (a huge or
        // infinite value would trap when turned into seconds).
        self.days = min(365, max(1, days ?? 1))
        let correction = attributes["catchup-correction"]
            .flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } ?? 0
        self.correctionHours = correction.isFinite && abs(correction) <= 48 ? correction : 0
    }

    init(type: String, source: String?, days: Int, correctionHours: Double = 0) {
        self.type = type
        self.source = source
        self.days = days
        self.correctionHours = correctionHours
    }
}

/// Replay links for M3U channels (step 13d), as Android's
/// `CatchupUrlBuilder`: default / append (a template in catchup-source),
/// shift, flussonic and xc. Links that look like an Xtream server's get
/// Xtream's forms, tried in turn (`LiveTVCatchup.xtreamURLs`).
enum LiveTVCatchupM3U {
    static func urls(
        live: String, catchup: LiveTVM3UCatchup, start: Date, end: Date, now: Date,
        fileExtension: String = "ts", serverTimeZone: TimeZone? = nil
    ) -> [URL] {
        let hours = catchup.correctionHours
        let correction = (hours.isFinite && abs(hours) <= 48 ? hours : 0) * 3600
        let startC = start.addingTimeInterval(correction)
        let endC = end.addingTimeInterval(correction)
        let startS = Int64(startC.timeIntervalSince1970)
        let endS = Int64(endC.timeIntervalSince1970)
        let nowS = Int64(now.timeIntervalSince1970)
        let duration = max(60, endS - startS)
        func fillIn(_ template: String) -> String {
            fill(template, start: startS, end: endS, now: nowS, duration: duration, serverZone: serverTimeZone)
        }
        func xtreamGuess() -> [URL]? {
            xtream(live: live, start: startC, end: endC, now: now, fileExtension: fileExtension, zone: serverTimeZone)
        }
        let single: String?
        switch catchup.type {
        case "append":
            single = catchup.source.map { live + fillIn($0) }
        case "default":
            if let source = catchup.source {
                single = source.lowercased().hasPrefix("http") ? fillIn(source) : live + fillIn(source)
            } else {
                return xtreamGuess() ?? [URL(string: shift(live, start: startS, now: nowS))].compactMap { $0 }
            }
        case "shift", "timeshift":
            if catchup.source == nil, let guess = xtreamGuess() { return guess }
            single = shift(live, start: startS, now: nowS)
        case "flussonic", "flussonic-hls", "flussonic-ts", "fs":
            single = flussonic(live, start: startS, duration: duration)
        case "xc", "xtream":
            return xtreamGuess() ?? []
        default:
            single = catchup.source.map(fillIn)
        }
        return [single.flatMap(URL.init(string:))].compactMap { $0 }
    }

    /// `{server}/(live/)?{user}/{pass}/{id}.{ext}`: Xtream's timeshift forms.
    static func xtream(
        live: String, start: Date, end: Date, now: Date, fileExtension: String, zone: TimeZone?
    ) -> [URL]? {
        guard let components = URLComponents(string: live), let scheme = components.scheme, let host = components.host else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        if parts.first == "live" { parts.removeFirst() }
        guard parts.count == 3, let last = parts.last else { return nil }
        let idText = last.split(separator: ".").first.map(String.init) ?? last
        guard let id = Int(idText) else { return nil }
        let ext = last.contains(".") ? String(last.split(separator: ".").last ?? "ts") : fileExtension
        let server = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
        return LiveTVCatchup.xtreamURLs(
            server: server,
            username: parts[0].removingPercentEncoding ?? parts[0],
            password: parts[1].removingPercentEncoding ?? parts[1],
            streamID: id, start: start, end: end, now: now,
            fileExtension: ext == "m3u8" ? "m3u8" : "ts", serverTimeZone: zone)
    }

    static func shift(_ url: String, start: Int64, now: Int64) -> String {
        url + (url.contains("?") ? "&" : "?") + "utc=\(start)&lutc=\(now)"
    }

    static func flussonic(_ url: String, start: Int64, duration: Int64) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else { return nil }
        let server = "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
        var parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let file = parts.removeLast()
        let stream = parts.joined(separator: "/")
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        if file.hasSuffix(".m3u8") || file.isEmpty {
            let base = file.isEmpty ? "index" : String(file.dropLast(5))
            return "\(server)\(stream)/\(base)-\(start)-\(duration).m3u8\(query)"
        }
        return "\(server)\(stream)/timeshift_abs-\(start).ts\(query)"
    }

    /// A catch-up template: `{utc}`, `{start}`, `{end}`, `{utcend}`,
    /// `{lutc}`, `{now}`, `{timestamp}`, `{duration}`, `{offset}` (also with
    /// `$`), `{utc:Y-m-d H:M:S}` style dates (UTC; Xtream timeshift links in
    /// the server's time), `{duration:60}` / `{offset:60}` divided, and bare
    /// `{Y}{m}{d}{H}{M}{S}` of the start in the server's or this device's
    /// time.
    static func fill(
        _ template: String, start: Int64, end: Int64, now: Int64, duration: Int64, serverZone: TimeZone? = nil
    ) -> String {
        var out = template
        let lower = template.lowercased()
        let xtreamLink = lower.contains("/timeshift/") || lower.contains("timeshift.php")
        let formatZone = serverZone != nil && xtreamLink ? serverZone! : TimeZone(identifier: "UTC")!
        out = replace(in: out, pattern: #"\$?\{(utc|start|utcend|end|lutc|now|timestamp):([^}]+)\}"#) { groups in
            let epoch: Int64
            switch groups[1] {
            case "utcend", "end": epoch = end
            case "lutc", "now", "timestamp": epoch = now
            default: epoch = start
            }
            return format(groups[2], epoch: epoch, zone: formatZone)
        }
        out = replace(in: out, pattern: #"\$?\{duration:(\d+)\}"#) { groups in
            String(duration / max(1, Int64(groups[1]) ?? 1))
        }
        out = replace(in: out, pattern: #"\$?\{offset:(\d+)\}"#) { groups in
            String((now - start) / max(1, Int64(groups[1]) ?? 1))
        }
        let simple: [(String, Int64)] = [
            ("utcend", end), ("utc", start), ("start", start), ("timestamp", now), ("end", end),
            ("lutc", now), ("now", now), ("duration", duration), ("offset", now - start),
        ]
        for (key, value) in simple {
            out = out.replacingOccurrences(of: "${\(key)}", with: String(value))
                .replacingOccurrences(of: "{\(key)}", with: String(value))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = serverZone ?? .current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(start)))
        let bare: [(String, String)] = [
            ("{Y}", String(format: "%04d", parts.year ?? 0)), ("{m}", String(format: "%02d", parts.month ?? 0)),
            ("{d}", String(format: "%02d", parts.day ?? 0)), ("{H}", String(format: "%02d", parts.hour ?? 0)),
            ("{M}", String(format: "%02d", parts.minute ?? 0)), ("{S}", String(format: "%02d", parts.second ?? 0)),
        ]
        for (key, value) in bare { out = out.replacingOccurrences(of: key, with: value) }
        return out
    }

    /// `Y-m-d:H-M` style: Y m d H M S are the date's parts, the rest as is.
    static func format(_ pattern: String, epoch: Int64, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        var out = ""
        for character in pattern {
            switch character {
            case "Y": out += String(format: "%04d", parts.year ?? 0)
            case "m": out += String(format: "%02d", parts.month ?? 0)
            case "d": out += String(format: "%02d", parts.day ?? 0)
            case "H": out += String(format: "%02d", parts.hour ?? 0)
            case "M": out += String(format: "%02d", parts.minute ?? 0)
            case "S": out += String(format: "%02d", parts.second ?? 0)
            default: out.append(character)
            }
        }
        return out
    }

    private static func replace(in text: String, pattern: String, with build: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            var groups: [String] = []
            for index in 0..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? "" : (text as NSString).substring(with: range))
            }
            guard let whole = Range(match.range, in: result) else { continue }
            result.replaceSubrange(whole, with: build(groups))
        }
        return result
    }
}
