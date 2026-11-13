import Foundation

/// Minimal Xtream Codes API client (`player_api.php`), the same calls TiviMate
/// and NuvioPlusIPTV use for live TV.
struct XtreamClient: Sendable {
    let server: String
    let username: String
    let password: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Movie and series lists can be tens of MB on big panels (step 12).
    private static let longSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 40 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Many panels reject unknown clients; a common player User-Agent is the
    /// most compatible default.
    static let userAgent = "VLC/3.0.20 LibVLC/3.0.20"

    init(account: XtreamAccount, password: String) {
        self.server = account.server
        self.username = account.username
        self.password = password
    }

    init(server: String, username: String, password: String) {
        self.server = XtreamAccount.normaliseServer(server)
        self.username = username
        self.password = password
    }

    // MARK: API

    func login() async throws -> XtreamUserInfo {
        let data = try await get(action: nil)
        guard let response = try? JSONDecoder().decode(XtreamLoginResponse.self, from: data),
              var info = response.userInfo else {
            throw XtreamError.authenticationFailed
        }
        info.serverTimeZone = response.serverInfo?.timezone?.trimmingCharacters(in: .whitespaces)
        guard info.auth == 1 else { throw XtreamError.authenticationFailed }
        if let status = info.status, status.lowercased() != "active" {
            throw XtreamError.accountInactive(status)
        }
        return info
    }

    func liveCategories() async throws -> [XtreamCategory] {
        let data = try await get(action: "get_live_categories")
        guard let categories = try? JSONDecoder().decode([XtreamCategory].self, from: data) else {
            // Some panels answer `{}` or `null` when there are no categories.
            return []
        }
        return categories.filter { !$0.id.isEmpty }
    }

    func liveChannels() async throws -> [XtreamLiveChannel] {
        let data = try await get(action: "get_live_streams")
        guard let channels = try? JSONDecoder().decode([XtreamLiveChannel].self, from: data) else {
            throw XtreamError.invalidResponse
        }
        return channels.filter { $0.streamID >= 0 }
    }

    /// What's on now and next on one channel (`get_short_epg`). Titles and
    /// descriptions come base64-encoded from most panels.
    func shortEPG(streamID: Int, limit: Int = 2) async throws -> [XtreamProgram] {
        let data = try await get(action: "get_short_epg", extra: [
            URLQueryItem(name: "stream_id", value: String(streamID)),
            URLQueryItem(name: "limit", value: String(limit)),
        ], timeout: 8)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listings = root["epg_listings"] as? [[String: Any]] else { return [] }
        return listings.compactMap(XtreamProgram.init(listing:))
            .sorted { $0.start < $1.start }
    }

    // MARK: VOD (step 12)

    func vodCategories() async throws -> [XtreamCategory] {
        let data = try await get(action: "get_vod_categories", long: true)
        return ((try? JSONDecoder().decode([XtreamCategory].self, from: data)) ?? []).filter { !$0.id.isEmpty }
    }

    func seriesCategories() async throws -> [XtreamCategory] {
        let data = try await get(action: "get_series_categories", long: true)
        return ((try? JSONDecoder().decode([XtreamCategory].self, from: data)) ?? []).filter { !$0.id.isEmpty }
    }

    /// The whole list as it came (`get_vod_streams` / `get_series`).
    /// `progress`: bytes in and, when the server says it, the size.
    func onDemandList(
        _ kind: OnDemandKind, progress: (@Sendable (_ received: Int64, _ expected: Int64?) -> Void)? = nil
    ) async throws -> Data {
        try await get(action: kind == .movie ? "get_vod_streams" : "get_series", long: true, progress: progress)
    }

    /// `get_vod_info`: plot, pictures and details of one movie.
    func vodInfo(vodID: Int) async throws -> Data {
        try await get(action: "get_vod_info", extra: [URLQueryItem(name: "vod_id", value: String(vodID))], timeout: 15)
    }

    /// `get_series_info`: seasons and episodes of one series.
    func seriesInfo(seriesID: Int) async throws -> Data {
        try await get(action: "get_series_info", extra: [URLQueryItem(name: "series_id", value: String(seriesID))], timeout: 15)
    }

    /// `{server}/movie/{user}/{pass}/{id}.{ext}`
    func movieURL(streamID: Int, ext: String?) -> URL? {
        URL(string: "\(server)/movie/\(Self.pathEncode(username))/\(Self.pathEncode(password))/\(streamID).\(ext ?? "mp4")")
    }

    /// `{server}/series/{user}/{pass}/{id}.{ext}`
    func episodeURL(episodeID: Int, ext: String) -> URL? {
        URL(string: "\(server)/series/\(Self.pathEncode(username))/\(Self.pathEncode(password))/\(episodeID).\(ext)")
    }

    // MARK: Links

    /// `{server}/live/{user}/{pass}/{id}.{ext}`
    func liveURL(streamID: Int, format: XtreamStreamFormat, allowedFormats: [String]) -> URL? {
        let ext = Self.fileExtension(for: format, allowedFormats: allowedFormats)
        return URL(string: "\(server)/live/\(Self.pathEncode(username))/\(Self.pathEncode(password))/\(streamID).\(ext)")
    }

    static func fileExtension(for format: XtreamStreamFormat, allowedFormats: [String]) -> String {
        switch format {
        case .ts: return "ts"
        case .hls: return "m3u8"
        case .auto:
            // Some providers only allow HLS; asking for .ts then fails on every
            // channel. Prefer HLS when allowed, fall back to TS otherwise.
            if allowedFormats.isEmpty || allowedFormats.contains("m3u8") { return "m3u8" }
            return allowedFormats.contains("ts") ? "ts" : "m3u8"
        }
    }

    var httpHeaders: [String: String] { ["User-Agent": Self.userAgent] }

    // MARK: Transport

    private func get(
        action: String?, extra: [URLQueryItem] = [], timeout: TimeInterval? = nil, long: Bool = false,
        progress: (@Sendable (Int64, Int64?) -> Void)? = nil
    ) async throws -> Data {
        guard var components = URLComponents(string: "\(server)/player_api.php"),
              components.host?.isEmpty == false else {
            throw XtreamError.invalidServer
        }
        var items = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        items += extra
        components.queryItems = items
        // URLComponents leaves "+" unescaped, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw XtreamError.invalidServer }

        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        if let progress {
            (data, response) = try await XtreamProgressFetch.data(for: request, configuration: Self.longSession.configuration, onProgress: progress)
        } else {
            (data, response) = try await (long ? Self.longSession : Self.session).data(for: request)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw XtreamError.authenticationFailed }
            throw XtreamError.badStatus(http.statusCode)
        }
        return data
    }

    private static func pathEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// A request read with progress (the VOD lists, tens of MB): reported
/// about every MB. The size counts only when the server sends it
/// unpacked; packed, only what's in shows.
private final class XtreamProgressFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private var data = Data()
    private var response: URLResponse?
    private var expected: Int64?
    private var lastReported: Int64 = 0

    private init(onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.onProgress = onProgress
    }

    static func data(
        for request: URLRequest, configuration: URLSessionConfiguration,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (Data, URLResponse) {
        let delegate = XtreamProgressFetch(onProgress: onProgress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    delegate.continuation = continuation
                    session.dataTask(with: request).resume()
                }
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        let packed = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Encoding").map { !$0.isEmpty } ?? false
        if !packed, response.expectedContentLength > 0 {
            expected = response.expectedContentLength
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        onProgress(0, expected)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        data.append(chunk)
        let received = Int64(data.count)
        guard received - lastReported >= 1_000_000 else { return }
        lastReported = received
        onProgress(received, expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if let response {
            onProgress(Int64(data.count), expected)
            continuation?.resume(returning: (data, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
        continuation = nil
    }
}
