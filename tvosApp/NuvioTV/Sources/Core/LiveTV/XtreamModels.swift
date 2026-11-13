import Foundation

// MARK: - Account

/// How live channel links are requested from an Xtream server.
enum XtreamStreamFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    /// HLS when the account allows it, otherwise MPEG-TS.
    case auto
    case ts
    case hls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .ts: return "TS"
        case .hls: return "HLS"
        }
    }
}

/// An Xtream Codes login. The password is not part of this value: it lives in
/// the Keychain (`XtreamAccountStore`) so it never ends up in a profile copy,
/// a sync payload or a bug-report export.
struct XtreamAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Normalised base URL, e.g. `http://example.com:8080` (no trailing slash).
    var server: String
    var username: String
    var streamFormat: XtreamStreamFormat

    /// Accepts what people type: `host:port`, `http://host:port/`, or a full
    /// `.../player_api.php?...` / `.../get.php?...` link.
    static func normaliseServer(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://" + value
        }
        if let query = value.firstIndex(of: "?") {
            value = String(value[..<query])
        }
        for suffix in ["/player_api.php", "/get.php", "/xmltv.php"] where value.lowercased().hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

// MARK: - Lossy JSON helpers

/// Xtream panels are inconsistent: the same field can be a string, a number,
/// a bool or null depending on the panel version. These decode any of them.
struct LossyString: Decodable, Hashable, Sendable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = bool ? "1" : "0"
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    func lossyString(_ key: Key) -> String? {
        guard let raw = (try? decodeIfPresent(LossyString.self, forKey: key))??.value else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func lossyInt(_ key: Key) -> Int? {
        guard let raw = lossyString(key) else { return nil }
        if let int = Int(raw) { return int }
        if let double = Double(raw) { return Int(double) }
        return nil
    }
}

// MARK: - API payloads

struct XtreamUserInfo: Decodable, Equatable, Sendable {
    let auth: Int
    let status: String?
    let expiresAt: Date?
    let activeConnections: Int?
    let maxConnections: Int?
    let isTrial: Bool
    let allowedOutputFormats: [String]
    /// The panel's time zone (`server_info.timezone`), set by the login.
    var serverTimeZone: String?

    enum CodingKeys: String, CodingKey {
        case auth, status
        case expDate = "exp_date"
        case activeCons = "active_cons"
        case maxConnections = "max_connections"
        case isTrial = "is_trial"
        case allowedOutputFormats = "allowed_output_formats"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auth = c.lossyInt(.auth) ?? 0
        status = c.lossyString(.status)
        if let exp = c.lossyString(.expDate).flatMap(TimeInterval.init), exp > 0 {
            expiresAt = Date(timeIntervalSince1970: exp)
        } else {
            expiresAt = nil
        }
        activeConnections = c.lossyInt(.activeCons)
        maxConnections = c.lossyInt(.maxConnections)
        isTrial = c.lossyInt(.isTrial) == 1
        allowedOutputFormats = ((try? c.decodeIfPresent([LossyString].self, forKey: .allowedOutputFormats)) ?? nil)?
            .compactMap { $0.value?.lowercased() } ?? []
    }
}

struct XtreamLoginResponse: Decodable, Sendable {
    let userInfo: XtreamUserInfo?
    let serverInfo: ServerInfo?

    struct ServerInfo: Decodable, Sendable {
        let timezone: String?
    }

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

struct XtreamCategory: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The app's id for a source's slot (step 13a).
    func inSource(slot: Int) -> XtreamCategory {
        slot == 0 ? self : XtreamCategory(id: LiveTVSourceIDs.group(slot: slot, category: id), name: name)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyString(.id) ?? ""
        name = c.lossyString(.name) ?? "—"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
    }
}

struct XtreamLiveChannel: Codable, Identifiable, Hashable, Sendable {
    let streamID: Int
    let number: Int?
    /// The name shown: renamed or cleaned (step 10a), else the provider's.
    var name: String
    let logoURL: String?
    let epgChannelID: String?
    let categoryID: String?
    /// Days of catch-up the provider keeps (0 = none).
    let archiveDays: Int

    /// The provider's name when `name` differs (not saved in the cache).
    var providerName: String? = nil

    var id: Int { streamID }
    /// What the provider calls it: guide matching and separator rows go by this.
    var originalName: String { providerName ?? name }

    /// The same channel shown under another name.
    func shown(as display: String) -> XtreamLiveChannel {
        var copy = self
        copy.providerName = originalName
        copy.name = display
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case number = "num"
        case name
        case logoURL = "stream_icon"
        case epgChannelID = "epg_channel_id"
        case categoryID = "category_id"
        case tvArchive = "tv_archive"
        case archiveDays = "tv_archive_duration"
    }

    init(
        streamID: Int, number: Int?, name: String, logoURL: String?, epgChannelID: String?,
        categoryID: String?, archiveDays: Int
    ) {
        self.streamID = streamID
        self.number = number
        self.name = name
        self.logoURL = logoURL
        self.epgChannelID = epgChannelID
        self.categoryID = categoryID
        self.archiveDays = archiveDays
    }

    /// The same channel with the app's ids for a source's slot (step 13a,
    /// `LiveTVSourceIDs`); slot 0 keeps the provider's.
    func inSource(slot: Int) -> XtreamLiveChannel {
        guard slot != 0 else { return self }
        var copy = XtreamLiveChannel(
            streamID: LiveTVSourceIDs.channel(slot: slot, raw: streamID), number: number, name: name,
            logoURL: logoURL, epgChannelID: epgChannelID,
            categoryID: LiveTVSourceIDs.group(slot: slot, category: categoryID ?? ""), archiveDays: archiveDays)
        copy.providerName = providerName
        return copy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streamID = c.lossyInt(.streamID) ?? -1
        number = c.lossyInt(.number)
        name = c.lossyString(.name) ?? "—"
        logoURL = c.lossyString(.logoURL)
        epgChannelID = c.lossyString(.epgChannelID)
        categoryID = c.lossyString(.categoryID)
        let hasArchive = (c.lossyInt(.tvArchive) ?? 0) == 1
        archiveDays = hasArchive ? (c.lossyInt(.archiveDays) ?? 0) : 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(streamID, forKey: .streamID)
        try c.encodeIfPresent(number, forKey: .number)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(logoURL, forKey: .logoURL)
        try c.encodeIfPresent(epgChannelID, forKey: .epgChannelID)
        try c.encodeIfPresent(categoryID, forKey: .categoryID)
        try c.encode(archiveDays > 0 ? 1 : 0, forKey: .tvArchive)
        try c.encode(archiveDays, forKey: .archiveDays)
    }
}

// MARK: - Errors

enum XtreamError: LocalizedError, Equatable {
    case invalidServer
    case authenticationFailed
    case accountInactive(String)
    case badStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return L10n.string("livetv_error_invalid_server", fallback: "The server address is not valid.")
        case .authenticationFailed:
            return L10n.string("livetv_error_auth", fallback: "Login failed. Check username and password.")
        case .accountInactive(let status):
            return L10n.string("livetv_error_inactive", fallback: "The account is not active") + " (\(status))."
        case .badStatus(let code):
            // Plain-English reasons for the codes people actually hit (as on Android).
            let reason: String?
            switch code {
            case 404:
                reason = L10n.string("livetv_error_http_404", fallback: "nothing at that address, or the server is busy. Check server and port, then try Refresh.")
            case 429:
                reason = L10n.string("livetv_error_http_429", fallback: "too many requests, try again in a few minutes.")
            case 456, 458, 461:
                reason = L10n.string("livetv_error_http_limit", fallback: "the provider refused this login for now (too many connections, expired or blocked).")
            case 502, 503, 504, 520...524:
                reason = L10n.string("livetv_error_http_down", fallback: "the provider's server didn't respond, try again later.")
            case 884:
                reason = L10n.string("livetv_error_http_blocked", fallback: "the provider blocked this app.")
            default:
                reason = nil
            }
            let prefix = L10n.string("livetv_error_http", fallback: "The server answered with HTTP") + " \(code)"
            return reason.map { "\(prefix): \($0)" } ?? prefix + "."
        case .invalidResponse:
            return L10n.string("livetv_error_response", fallback: "The server sent an unexpected response.")
        }
    }
}

/// One programme from the provider's short EPG.
struct XtreamProgram: Hashable, Sendable {
    let title: String
    let description: String?
    let start: Date
    let end: Date

    init(title: String, description: String?, start: Date, end: Date) {
        self.title = title
        self.description = description
        self.start = start
        self.end = end
    }

    init?(listing: [String: Any]) {
        func number(_ key: String) -> Double? {
            if let value = listing[key] as? Double { return value }
            if let value = listing[key] as? Int { return Double(value) }
            return (listing[key] as? String).flatMap(Double.init)
        }
        guard let start = number("start_timestamp"), let end = number("stop_timestamp") ?? number("end_timestamp"),
              start.isFinite, end.isFinite, end > start,
              // Unix seconds between 2000 and 2100; anything else is garbage.
              (946_684_800...4_102_444_800).contains(start),
              (946_684_800...4_102_444_800).contains(end),
              let rawTitle = listing["title"] as? String else { return nil }
        let title = Self.decode(rawTitle)
        guard !title.isEmpty else { return nil }
        self.title = title
        self.description = (listing["description"] as? String).map(Self.decode).flatMap { $0.isEmpty ? nil : $0 }
        self.start = Date(timeIntervalSince1970: start)
        self.end = Date(timeIntervalSince1970: end)
    }

    /// Panels send base64; a few send plain text.
    private static func decode(_ value: String) -> String {
        if let data = Data(base64Encoded: value), let text = String(data: data, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isOn(at date: Date = Date()) -> Bool { start <= date && date < end }

    /// "20:15–21:00"
    var timeRange: String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(start.formatted(style))–\(end.formatted(style))"
    }
}
