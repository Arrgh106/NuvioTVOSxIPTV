import Foundation

/// What a Stalker / Ministra portal needs from you (step 13e), as Android's
/// `StalkerConfig`: the portal and the MAC address the provider registered,
/// a login on portals that ask for one, and device ids on the few that
/// check them. Kept in the Keychain as a whole (the MAC is the login).
struct LiveTVStalkerConfig: Codable, Equatable, Sendable {
    var portal: String
    var mac: String
    var username: String = ""
    var password: String = ""
    var serialNumber: String = ""
    var deviceID: String = ""
    var deviceID2: String = ""
    var signature: String = ""
    var timezone: String = "UTC"
    var language: String = "en"

    /// "00:1A:79:…" in upper case with colons, nil when it isn't a MAC.
    static func normalisedMAC(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: ":").uppercased()
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return cleaned
    }
}

/// The portal protocol's rules with no networking (Linux tests), as
/// Android's `StalkerWire`: where the portal answers, request links, the
/// `js` envelope, stream commands and guide times.
enum LiveTVStalkerWire {
    /// Where the portal may answer, likeliest first: the link as given
    /// when it names a file, then `portal.php` and `server/load.php` under
    /// its folder (a `/c/` link is the portal's web page).
    static func endpoints(portal: String) -> [String] {
        guard var components = URLComponents(string: portal.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else { return [] }
        components.fragment = nil
        let path = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        let lower = path.lowercased()
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        let explicit = last.contains(".") && !lower.hasSuffix("/c")
        let base: String
        if lower.hasSuffix("/c/index.html") || lower.hasSuffix("/c/index.php"),
           let range = lower.range(of: "/c/", options: .backwards) {
            base = String(path[..<range.lowerBound])
        } else if lower.hasSuffix("/server/load.php") {
            base = String(path.dropLast("/server/load.php".count))
        } else if lower.hasSuffix("/portal.php") {
            base = String(path.dropLast("/portal.php".count))
        } else if lower.hasSuffix("/c") {
            base = String(path.dropLast(2))
        } else if explicit {
            base = path.split(separator: "/").dropLast().map { "/" + $0 }.joined()
        } else {
            base = path
        }
        func at(_ value: String) -> String? {
            var copy = components
            copy.percentEncodedPath = value
            copy.query = nil
            return copy.string
        }
        var result: [String] = []
        if explicit, let given = components.string { result.append(given) }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        for candidate in [at(trimmed + "/portal.php"), at(trimmed + "/server/load.php"),
                          trimmed.isEmpty ? at("/stalker_portal/server/load.php") : nil] {
            if let candidate, !result.contains(candidate) { result.append(candidate) }
        }
        return result
    }

    /// The installation's folder ("…/stalker_portal/"): referer and the
    /// base of relative media paths.
    static func installationBase(_ endpoint: String) -> String {
        guard var components = URLComponents(string: endpoint) else { return endpoint }
        let path = components.percentEncodedPath
        if path.lowercased().hasSuffix("/server/load.php") {
            components.percentEncodedPath = String(path.dropLast("server/load.php".count))
        } else if let slash = path.lastIndex(of: "/") {
            components.percentEncodedPath = String(path[...slash])
        } else {
            components.percentEncodedPath = "/"
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? endpoint
    }

    /// "http://host:port".
    static func origin(_ endpoint: String) -> String {
        guard var components = URLComponents(string: endpoint) else { return endpoint }
        components.percentEncodedPath = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? endpoint
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }

    /// The portal link with the request's parameters (and the portal's
    /// own `JsHttpRequest`).
    static func requestURL(endpoint: String, parameters: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        let replaced = Set(parameters.map(\.0) + ["JsHttpRequest"])
        var items = (components.queryItems ?? []).filter { !replaced.contains($0.name) }
        items += parameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        items.append(URLQueryItem(name: "JsHttpRequest", value: "1-xml"))
        components.queryItems = items
        // "+" in a value (a password, a time zone) would read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.fragment = nil
        return components.url
    }

    /// The headers of a MAG box, as portals expect them.
    static func headers(config: LiveTVStalkerConfig, endpoint: String, token: String?) -> [String: String] {
        let mac = (LiveTVStalkerConfig.normalisedMAC(config.mac) ?? config.mac)
        func escaped(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? text
        }
        var headers = [
            "Accept": "application/json",
            "User-Agent": userAgent,
            "X-User-Agent": "Model: MAG250; Link: Ethernet",
            "Referer": installationBase(endpoint) + "c/",
            "Cookie": "mac=\(escaped(mac)); stb_lang=\(escaped(config.language)); timezone=\(escaped(config.timezone))",
        ]
        if !config.serialNumber.isEmpty { headers["SN"] = config.serialNumber }
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer " + token }
        return headers
    }

    static let userAgent = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG250 stbapp ver: 2 rev: 250 Safari/533.3"

    // MARK: Answers

    enum Answer {
        case value(Any)
        /// The portal wants a new session (token gone, not authorised).
        case unauthorised
        case invalid
    }

    /// `{"js": …}`: what's inside, or why there's nothing usable.
    static func unwrap(_ data: Data) -> Answer {
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if isAuthMessage(body) { return .unauthorised }
        guard let root = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any],
              let js = root["js"] else { return .invalid }
        if let message = js as? String, isAuthMessage(message) { return .unauthorised }
        if let envelope = js as? [String: Any], let error = Self.text(envelope, "error", "message"), isAuthMessage(error) {
            return .unauthorised
        }
        return .value(js)
    }

    static func isAuthMessage(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmed = cleaned.hasSuffix(".") ? String(cleaned.dropLast()) : cleaned
        return ["authorization failed", "authentication failed", "not authorized", "unauthorized",
                "invalid token", "token expired", "access denied"].contains(trimmed)
    }

    /// The rows of a list answer: an array, `data` (array or keyed), or
    /// an object of objects.
    static func rows(_ value: Any) -> [[String: Any]]? {
        if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        guard let object = value as? [String: Any] else { return nil }
        if let data = object["data"] {
            if let array = data as? [Any] { return array.compactMap { $0 as? [String: Any] } }
            if let keyed = data as? [String: Any] { return keyed.values.compactMap { $0 as? [String: Any] } }
            return nil
        }
        let values = Array(object.values)
        return values.allSatisfy({ $0 is [String: Any] }) ? values.compactMap { $0 as? [String: Any] } : nil
    }

    /// A field as text (numbers too), the first of `keys` that's set.
    static func text(_ row: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            switch row[key] {
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return trimmed }
            case let int as Int:
                return String(int)
            case let double as Double:
                return double == double.rounded() && abs(double) < 1e15 ? String(Int64(double)) : String(double)
            default:
                continue
            }
        }
        return nil
    }

    static func flag(_ row: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            switch row[key] {
            case let bool as Bool: return bool
            case let int as Int: return int != 0
            case let string as String:
                switch string.lowercased() {
                case "1", "true": return true
                case "0", "false": return false
                default: continue
                }
            default: continue
            }
        }
        return nil
    }

    // MARK: Streams

    /// "ffmpeg http://…" → "http://…" (the box's player prefixes).
    static func stripWrapper(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return trimmed }
        let prefix = trimmed[..<space].lowercased()
        return ["ffmpeg", "ffrt", "ffrt2", "ffrt3", "ffrt4", "auto"].contains(prefix)
            ? trimmed[space...].trimmingCharacters(in: .whitespaces) : trimmed
    }

    /// The command as a link that plays as it is, if it is one (not a
    /// placeholder host the portal fills in with `create_link`).
    static func direct(_ command: String) -> URL? {
        let raw = stripWrapper(command)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty,
              !isPlaceholder(host) else { return nil }
        return url
    }

    /// What `create_link` gave, as a full link: absolute, protocol-relative,
    /// or a path under the installation.
    static func resolved(_ command: String, endpoint: String) -> URL? {
        let raw = stripWrapper(command)
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }) else { return nil }
        let absolute: String
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            absolute = raw
        } else if raw.hasPrefix("//") {
            absolute = (URL(string: endpoint)?.scheme ?? "http") + ":" + raw
        } else if raw.hasPrefix("/") {
            let basePath = URL(string: installationBase(endpoint))?.path ?? ""
            let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            let path = raw.split(separator: "?").first.map(String.init) ?? raw
            let prefixed = trimmedBase.isEmpty || path == trimmedBase || path.hasPrefix(trimmedBase + "/")
            absolute = origin(endpoint) + (prefixed ? raw : trimmedBase + raw)
        } else if !(raw.split(separator: "/").first ?? "").contains(":") {
            absolute = installationBase(endpoint) + raw
        } else {
            return nil
        }
        guard let url = URL(string: absolute), let host = url.host, !isPlaceholder(host) else { return nil }
        return url
    }

    /// A picture link: absolute, or under the portal.
    static func image(_ value: String?, endpoint: String) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return raw }
        if raw.hasPrefix("//") { return (URL(string: endpoint)?.scheme ?? "http") + ":" + raw }
        if raw.hasPrefix("/") { return origin(endpoint) + raw }
        return installationBase(endpoint) + raw
    }

    private static func isPlaceholder(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h == "0.0.0.0" || h.hasPrefix("127.")
    }

    // MARK: Guide

    /// A guide time: Unix seconds (or ms), or "2026-11-15 20:15:00" in the
    /// portal's time zone.
    static func timestamp(_ value: String, zone: TimeZone) -> Date? {
        if let number = Int64(value) {
            guard number > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(number >= 100_000_000_000 ? number / 1000 : number))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// One programme of `get_epg_info`, if it has a channel, times and a title.
    struct Programme: Equatable {
        var channel: String
        var start: Date
        var stop: Date
        var title: String
        var description: String?
    }

    /// The programmes of a `get_epg_info` answer: `data` keyed by channel
    /// (lists), or one list with `ch_id` in every row.
    static func programmes(_ value: Any, zone: TimeZone) -> [Programme] {
        var result: [Programme] = []
        func add(_ row: [String: Any], channel: String?) {
            guard let id = text(row, "ch_id", "channel_id") ?? channel,
                  let startText = text(row, "start_timestamp") ?? text(row, "start", "time"),
                  let stopText = text(row, "stop_timestamp", "end_timestamp") ?? text(row, "stop", "time_to"),
                  let start = timestamp(startText, zone: zone), let stop = timestamp(stopText, zone: zone),
                  stop > start, let title = text(row, "name", "title") else { return }
            result.append(Programme(channel: id, start: start, stop: stop, title: title,
                                    description: text(row, "descr", "description", "plot")))
        }
        let data = (value as? [String: Any]).flatMap { $0["data"] } ?? value
        if let list = data as? [Any] {
            for case let row as [String: Any] in list { add(row, channel: nil) }
        } else if let keyed = data as? [String: Any] {
            for (channel, rows) in keyed {
                let list = (rows as? [Any])
                    ?? ((rows as? [String: Any]).flatMap { ($0["data"] ?? $0["epg"] ?? $0["items"]) as? [Any] }) ?? []
                for case let row as [String: Any] in list { add(row, channel: channel) }
            }
        }
        return result
    }

    /// XMLTV time: "20261115201500 +0000".
    static func xmltvTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d +0000",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func xmlEscaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // Characters XML 1.0 doesn't allow (control codes) go.
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20,
                   scalar != "\n", scalar != "\t", scalar != "\r" { continue }
                out.append(character)
            }
        }
        return out
    }
}
