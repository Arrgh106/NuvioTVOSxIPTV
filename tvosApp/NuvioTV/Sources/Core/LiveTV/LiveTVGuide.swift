import Compression
import Foundation
import SQLite3

/// The programme guide, stored on the device in SQLite: the provider's own
/// (`xmltv.php`) and any added XMLTV guides (step 9). Tens of thousands of
/// channels make an XMLTV file hundreds of MB, so each is downloaded to a
/// file, read as a stream, and only programmes of guide channels the
/// provider's channels use within a time window are kept.
///
/// Refreshes in the background when older than `maxAge` or when the guides
/// change; progress is published for the activity pill.
@MainActor
final class LiveTVGuide: ObservableObject {
    static let shared = LiveTVGuide()

    enum Status: Equatable {
        case idle
        /// `part`: which guide, when there are several ("2 / 3").
        case downloading(fraction: Double?, part: String?)
        case importing(programmes: Int)
        case ready(programmes: Int, updated: Date)
        case failed(String)
    }

    /// How one guide did at the last import, for Settings → Live TV.
    struct FeedResult: Codable, Equatable, Sendable {
        var programmes = 0
        /// Guide channels in use (matched or chosen).
        var channels = 0
        var error: String?
    }

    @Published private(set) var status: Status = .idle {
        didSet { reportActivity() }
    }
    /// Source id ("" = the provider's guide) → result of the last import.
    @Published private(set) var results: [String: FeedResult] = [:]
    @Published private(set) var updated: Date?

    private func reportActivity() {
        let id = "livetv.guide"
        let center = ActivityCenter.shared
        switch status {
        case .idle, .ready:
            center.finish(id)
        case .downloading(let fraction, let part):
            let label = L10n.string("livetv_guide_downloading_label", fallback: "Downloading guide")
            center.update(id, label: part.map { label + " · " + $0 } ?? label, fraction: fraction)
        case .importing(let count):
            center.update(id, label: L10n.format("livetv_guide_importing_label", fallback: "Reading guide · %@ programmes", count.formatted()))
        case .failed(let message):
            center.fail(id, message: L10n.string("livetv_guide", fallback: "Guide") + ": " + message)
        }
    }

    /// Kept: 24 h back (as on Android; catch-up needs the past) to 3 days
    /// ahead. Refreshed every 12 h, also as on Android.
    nonisolated static let pastWindow: TimeInterval = 24 * 3600
    nonisolated static let futureWindow: TimeInterval = 3 * 24 * 3600
    static let maxAge: TimeInterval = 12 * 3600

    private var database: GuideDatabase?
    private var scope: String?
    private var refreshTask: Task<Void, Never>?
    /// Stream → guide channel key, worked out at import (steps 8a, 9).
    /// Empty for a guide stored before matching: then the provider's guide
    /// id counts.
    private var links: [Int: String] = [:]
    /// Bumped when the stored guide changes how it reads (re-import once).
    private static let formatVersion = "3"

    // MARK: Reading

    /// The stored guide, for queries off the main thread (the handle is
    /// thread-safe). Nil until a guide has been imported.
    func reader() -> GuideDatabase? {
        // Another profile since it was opened: its own guide (or none).
        let active = ProfileSettings.activeProfileScope
        if let scope, scope != active, refreshTask == nil {
            closeDatabase()
            self.scope = active
        }
        return openDatabase()
    }

    /// The guide channel a stream reads its programmes from: the match from
    /// the import (manual, id or name), else the provider's guide id.
    func guideID(streamID: Int, fallback: String?) -> String? {
        _ = reader()
        if let link = links[streamID] { return link }
        let id = fallback?.trimmingCharacters(in: .whitespaces)
        return id?.isEmpty == false ? id : nil
    }

    func guideID(for channel: XtreamLiveChannel) -> String? {
        guideID(streamID: channel.streamID, fallback: channel.epgChannelID)
    }

    // MARK: Refresh

    /// Starts a background refresh when the stored guide is missing, older
    /// than `maxAge` or read from other guides (or always with `force`).
    /// `channels`: the channels to find guide channels for (by id or name,
    /// as on Android); `overrides`: the user's choices (stream → guide
    /// channel key, "" for none); `extra`: the added guides, in order;
    /// `providerGuide`: whether the provider's own guide is read too.
    func refreshIfNeeded(
        account: XtreamAccount, password: String, channels: [LiveTVEPGChannelRef],
        overrides: [Int: String] = [:], extra: [LiveTVGuideFeed] = [], providerGuide: Bool = true,
        force: Bool = false
    ) {
        let scope = ProfileSettings.activeProfileScope
        if scope != self.scope { closeDatabase(); self.scope = scope }
        if refreshTask != nil { return }
        // Added guides first: they win a tie (as on Android).
        var feeds = extra
        if providerGuide, let url = Self.xmltvURL(account: account, password: password) {
            feeds.append(LiveTVGuideFeed(
                sourceID: "", name: L10n.string("livetv_epg_provider", fallback: "Provider's guide"),
                url: url, shiftMinutes: 0))
        }
        let fingerprint = LiveTVEPGSourceRules.fingerprint(feeds)
        let db = openDatabase()
        if !force, let db, db.meta("version") == Self.formatVersion, db.meta("sources") == fingerprint,
           let updated = db.updatedAt(), Date().timeIntervalSince(updated) < Self.maxAge {
            status = .ready(programmes: db.storedCount(), updated: updated)
            return
        }
        guard !channels.isEmpty, !feeds.isEmpty, let target = Self.databaseURL(scope: scope) else { return }
        let version = Self.formatVersion

        status = .downloading(fraction: nil, part: nil)
        refreshTask = Task { [weak self] in
            defer { Task { @MainActor in self?.refreshTask = nil } }
            var files: [(feed: LiveTVGuideFeed, file: URL)] = []
            defer { for item in files { try? FileManager.default.removeItem(at: item.file) } }
            var failures: [String: String] = [:]
            do {
                for (index, feed) in feeds.enumerated() {
                    let part = feeds.count > 1 ? "\(index + 1) / \(feeds.count)" : nil
                    await MainActor.run { self?.status = .downloading(fraction: nil, part: part) }
                    do {
                        let file = try await GuideDownloader.download(feed.url) { fraction in
                            Task { @MainActor in self?.status = .downloading(fraction: fraction, part: part) }
                        }
                        let unpacked = try await Task.detached(priority: .utility) {
                            try GuideFiles.unpacked(file)
                        }.value
                        files.append((feed, unpacked))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // One guide that fails doesn't stop the others.
                        failures[feed.sourceID] = error.localizedDescription
                    }
                }
                guard !files.isEmpty else {
                    throw GuideImporter.Failed.feeds(failures)
                }
                await MainActor.run { self?.status = .importing(programmes: 0) }
                let inputs = files
                let known = failures
                let count = try await Task.detached(priority: .utility) {
                    try GuideImporter.importXMLTV(
                        files: inputs, into: target, channels: channels, overrides: overrides,
                        failures: known, fingerprint: fingerprint, version: version
                    ) { imported in
                        Task { @MainActor in self?.status = .importing(programmes: imported) }
                    }
                }.value
                await MainActor.run {
                    guard let self else { return }
                    self.closeDatabase()
                    _ = self.openDatabase()
                    self.status = .ready(programmes: count, updated: Date())
                    NotificationCenter.default.post(name: Self.updatedNotification, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run { self?.status = .idle }
            } catch {
                var reasons = failures
                var message = error.localizedDescription
                if let failed = error as? GuideImporter.Failed, case .feeds(let all) = failed {
                    reasons.merge(all) { _, new in new }
                    message = failed.message
                }
                let known = reasons
                let text = message
                await MainActor.run {
                    guard let self else { return }
                    self.results = known.mapValues { FeedResult(error: $0) }
                    self.status = .failed(text)
                }
            }
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    static let updatedNotification = Notification.Name("nuvio.tv.livetv.guide.updated")

    // MARK: Files

    private func openDatabase() -> GuideDatabase? {
        if let database { return database }
        let scope = self.scope ?? ProfileSettings.activeProfileScope
        guard let url = Self.databaseURL(scope: scope),
              FileManager.default.fileExists(atPath: url.path) else {
            // Only when it changes: this runs on every read while there's no guide.
            if !results.isEmpty { results = [:] }
            if updated != nil { updated = nil }
            return nil
        }
        database = GuideDatabase(url: url, readOnly: true)
        links = database?.links() ?? [:]
        results = database?.meta("results")
            .flatMap { try? JSONDecoder().decode([String: FeedResult].self, from: Data($0.utf8)) } ?? [:]
        updated = database?.updatedAt()
        return database
    }

    private func closeDatabase() {
        database = nil
        links = [:]
    }

    nonisolated static func databaseURL(scope: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LiveTV", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("guide-\(scope).sqlite")
    }

    nonisolated static func xmltvURL(account: XtreamAccount, password: String) -> URL? {
        guard var components = URLComponents(string: "\(account.server)/xmltv.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "username", value: account.username),
            URLQueryItem(name: "password", value: password),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

/// Guide refresh failures, worded for the Live TV header and Settings.
enum GuideError: LocalizedError {
    case storage
    case unreadable
    case notXMLTV
    case empty
    case noMatchingChannels

    var errorDescription: String? {
        switch self {
        case .storage:
            return L10n.string("livetv_guide_error_storage", fallback: "Couldn't create the guide database on the Apple TV.")
        case .unreadable:
            return L10n.string("livetv_guide_error_unreadable", fallback: "The downloaded guide file couldn't be opened.")
        case .notXMLTV:
            return L10n.string("livetv_guide_error_not_xmltv", fallback: "This isn't an XMLTV guide.")
        case .empty:
            return L10n.string("livetv_guide_error_empty", fallback: "The guide is empty.")
        case .noMatchingChannels:
            return L10n.string("livetv_guide_error_no_match", fallback: "The guide has no programmes for your visible channels.")
        }
    }
}

// MARK: - SQLite

/// Thin SQLite wrapper: one table of programmes indexed by channel and start.
final class GuideDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    init?(url: URL, readOnly: Bool) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func createSchema() {
        execute("""
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE IF NOT EXISTS programmes (ch TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL, title TEXT NOT NULL, descr TEXT);
            CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
            CREATE TABLE IF NOT EXISTS links (stream INTEGER PRIMARY KEY, ch TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS channels (id TEXT PRIMARY KEY, name TEXT NOT NULL, source TEXT NOT NULL DEFAULT '');
            """)
    }

    func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM meta WHERE k = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    /// Stream → guide channel (empty in a guide stored before matching).
    func links() -> [Int: String] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT stream, ch FROM links", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var result: [Int: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1) {
                result[Int(sqlite3_column_int64(statement, 0))] = String(cString: text)
            }
        }
        return result
    }

    /// The guides' channels (key, first name, guide name), for choosing one by hand.
    func guideChannels() -> [(id: String, name: String, source: String)] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name, source FROM channels ORDER BY name COLLATE NOCASE", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [(id: String, name: String, source: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
            let source = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            result.append((String(cString: id), String(cString: name), source))
        }
        return result
    }

    func writeLinks(_ links: [Int: String]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO links (stream, ch) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (stream, ch) in links {
            sqlite3_bind_int64(statement, 1, Int64(stream))
            sqlite3_bind_text(statement, 2, ch, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
    }

    func writeChannels(_ channels: [(id: String, name: String, source: String)]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO channels (id, name, source) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for channel in channels {
            sqlite3_bind_text(statement, 1, channel.id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(statement, 2, channel.name, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(statement, 3, channel.source, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
    }

    func createIndex() {
        execute("CREATE INDEX IF NOT EXISTS programmes_ch_start ON programmes (ch, start);")
    }

    func setMeta(_ key: String, _ value: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_step(statement)
    }

    func updatedAt() -> Date? {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM meta WHERE k = 'updated'", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              let seconds = Double(String(cString: text)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Programme count written at import (a COUNT(*) over hundreds of
    /// thousands of rows would stall the main thread).
    /// After the import (fresh database, not on the main thread).
    func programmeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM programmes", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    func storedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM meta WHERE k = 'count'", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return 0 }
        return Int(String(cString: text)) ?? 0
    }

    func programmes(channel: String, from: Date, to: Date, limit: Int = 200) -> [XtreamProgram] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let sql = "SELECT start, stop, title, descr FROM programmes WHERE ch = ? AND stop > ? AND start < ? ORDER BY start LIMIT \(max(1, limit))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, channel.lowercased(), -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(statement, 2, Int64(from.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 3, Int64(to.timeIntervalSince1970))
        var result: [XtreamProgram] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let title = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let descr = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            result.append(XtreamProgram(
                title: title,
                description: descr,
                start: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                end: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
            ))
        }
        return result
    }

    /// Prepared insert, reused for the whole import.
    final class Inserter {
        private var statement: OpaquePointer?
        private let db: OpaquePointer?

        init?(database: GuideDatabase) {
            db = database.db
            guard sqlite3_prepare_v2(db, "INSERT INTO programmes (ch, start, stop, title, descr) VALUES (?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return nil }
        }

        deinit { sqlite3_finalize(statement) }

        func insert(channel: String, start: Int64, stop: Int64, title: String, descr: String?) {
            sqlite3_bind_text(statement, 1, channel, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(statement, 2, start)
            sqlite3_bind_int64(statement, 3, stop)
            sqlite3_bind_text(statement, 4, title, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            if let descr { sqlite3_bind_text(statement, 5, descr, -1, SQLITE_TRANSIENT_DESTRUCTOR) } else { sqlite3_bind_null(statement, 5) }
            sqlite3_step(statement)
            sqlite3_reset(statement)
        }
    }
}

/// `SQLITE_TRANSIENT` isn't imported into Swift.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Download

/// Downloads to a temporary file with progress, so a huge XMLTV file never
/// sits in memory.
private final class GuideDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let onProgress: @Sendable (Double?) -> Void
    private var lastReported = -1.0

    private init(onProgress: @escaping @Sendable (Double?) -> Void) {
        self.onProgress = onProgress
    }

    static func download(_ url: URL, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let delegate = GuideDownloader(onProgress: onProgress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(XtreamClient.userAgent, forHTTPHeaderField: "User-Agent")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction: Double? = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        let step = fraction ?? Double(totalBytesWritten / 5_000_000)
        guard step - lastReported >= 0.01 || fraction == nil && step != lastReported else { return }
        lastReported = step
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: XtreamError.badStatus(http.statusCode))
            continuation = nil
            return
        }
        // The file is deleted when this returns: move it somewhere we own.
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-\(UUID().uuidString).xml")
        do {
            try FileManager.default.moveItem(at: location, to: target)
            continuation?.resume(returning: target)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        continuation = nil
    }
}

// MARK: - Unpacking

/// Guides often come as `.xml.gz`: unpacked to a file next to the download
/// in steps of 1 MB, so the whole guide never sits in memory.
enum GuideFiles {
    static func unpacked(_ file: URL) throws -> URL {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let head = [UInt8](input.readData(ofLength: 64 * 1024))
        guard LiveTVEPGSourceRules.isGzip(head) else { return file }
        guard let start = LiveTVEPGSourceRules.gzipHeaderLength(head) else { throw GuideError.unreadable }
        try input.seek(toOffset: UInt64(start))

        let target = file.deletingPathExtension().appendingPathExtension("unpacked.xml")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        var keep = false
        defer {
            try? output.close()
            if !keep { try? FileManager.default.removeItem(at: target) }
        }
        // Far above any real guide: a broken or hostile file can't fill the disk.
        let limit: UInt64 = 2 << 30
        var total: UInt64 = 0

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GuideError.unreadable
        }
        defer { compression_stream_destroy(stream) }
        let size = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }

        var finished = false
        var wrote = false
        var tooBig = false
        while !finished {
            if Task.isCancelled { throw CancellationError() }
            let chunk = input.readData(ofLength: size)
            let last = chunk.isEmpty
            var failed = false
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
                stream.pointee.src_size = raw.count
                while true {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = size
                    let flags = last ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let status = compression_stream_process(stream, flags)
                    let produced = size - stream.pointee.dst_size
                    if produced > 0 {
                        total += UInt64(produced)
                        if total > limit { failed = true; tooBig = true; return }
                        output.write(Data(bytes: buffer, count: produced))
                        wrote = true
                    }
                    if status == COMPRESSION_STATUS_END { finished = true; return }
                    if status != COMPRESSION_STATUS_OK { failed = true; return }
                    // All taken in and room left: on to the next chunk.
                    if stream.pointee.src_size == 0 && stream.pointee.dst_size > 0 { return }
                }
            }
            // A cut-off file: what came so far is read (the parser stops at the cut).
            if failed || last { break }
        }
        guard wrote, !tooBig else { throw GuideError.unreadable }
        keep = true
        try? FileManager.default.removeItem(at: file)
        return target
    }
}

// MARK: - Import

/// Streams the XMLTV files into a fresh database next to the live one, then
/// swaps it in.
private enum GuideImporter {
    /// No guide brought anything (each one's reason by source id).
    enum Failed: Error {
        case feeds([String: String])

        var message: String {
            switch self {
            case .feeds(let all):
                return all[""] ?? all.values.first
                    ?? GuideError.noMatchingChannels.localizedDescription
            }
        }
    }

    static func importXMLTV(
        files: [(feed: LiveTVGuideFeed, file: URL)],
        into target: URL,
        channels: [LiveTVEPGChannelRef],
        overrides: [Int: String],
        failures: [String: String],
        fingerprint: String,
        version: String,
        onProgress: @escaping @Sendable (Int) -> Void
    ) throws -> Int {
        let staging = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".new")
        try? FileManager.default.removeItem(at: staging)
        guard let database = GuideDatabase(url: staging, readOnly: false) else {
            throw GuideError.storage
        }
        // The table must exist before the insert statement can be prepared.
        database.createSchema()
        guard let inserter = GuideDatabase.Inserter(database: database) else {
            throw GuideError.storage
        }

        let now = Date().timeIntervalSince1970
        let state = GuideImportState(picker: LiveTVEPGMatch.Picker(channels: channels, overrides: overrides))
        var errors = failures
        database.execute("BEGIN")
        for (index, item) in files.enumerated() {
            guard let stream = InputStream(url: item.file) else {
                errors[item.feed.sourceID] = GuideError.unreadable.localizedDescription
                continue
            }
            let before = state.count
            let delegate = XMLTVParserDelegate(
                state: state, feed: item.feed, guide: index,
                from: Int64(now - LiveTVGuide.pastWindow),
                to: Int64(now + LiveTVGuide.futureWindow)
            ) { programme in
                inserter.insert(channel: programme.channel, start: programme.start, stop: programme.stop,
                                title: programme.title, descr: programme.descr)
            } onCount: { count in
                if count % 5000 == 0 {
                    database.execute("COMMIT; BEGIN")
                    onProgress(count)
                }
            }
            let parser = XMLParser(stream: stream)
            parser.delegate = delegate
            parser.shouldResolveExternalEntities = false
            let ok = parser.parse()
            if Task.isCancelled {
                database.execute("COMMIT")
                throw CancellationError()
            }
            if state.count == before {
                // Typically an HTML error page or an empty answer instead of XMLTV.
                let error: GuideError = delegate.sawProgrammes ? .noMatchingChannels : (ok ? .empty : .notXMLTV)
                errors[item.feed.sourceID] = error.localizedDescription
            }
        }
        database.execute("COMMIT")
        guard state.count > 0 else { throw Failed.feeds(errors) }

        // Which guide channel each stream reads; programmes of guide channels
        // kept as candidates but not picked go again.
        let links = state.picker.links(stats: state.stats, now: Int64(now))
        database.execute("BEGIN")
        database.writeLinks(links)
        database.writeChannels(state.guideChannels)
        database.execute("DELETE FROM programmes WHERE ch NOT IN (SELECT ch FROM links)")
        database.execute("COMMIT")
        database.createIndex()
        let count = database.programmeCount()
        guard count > 0 else { throw Failed.feeds(errors) }

        // How each guide did, for Settings → Live TV.
        var results: [String: LiveTVGuide.FeedResult] = [:]
        for item in files { results[item.feed.sourceID] = LiveTVGuide.FeedResult() }
        for key in Set(links.values) {
            let source = state.sourceOf[key] ?? ""
            results[source, default: LiveTVGuide.FeedResult()].channels += 1
            results[source, default: LiveTVGuide.FeedResult()].programmes += state.stats[key]?.count ?? 0
        }
        for (source, message) in errors where (results[source]?.channels ?? 0) == 0 {
            results[source] = LiveTVGuide.FeedResult(error: message)
        }
        if let data = try? JSONEncoder().encode(results), let text = String(data: data, encoding: .utf8) {
            database.setMeta("results", text)
        }
        database.setMeta("updated", String(Date().timeIntervalSince1970))
        database.setMeta("count", String(count))
        database.setMeta("sources", fingerprint)
        database.setMeta("version", version)

        // Swap: the reader opens the file again after the refresh.
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        return count
    }
}

/// What the import gathers over all guide files.
private final class GuideImportState {
    var picker: LiveTVEPGMatch.Picker
    /// Guide channel key → its listings kept.
    var stats: [String: LiveTVEPGMatch.ChannelStat] = [:]
    /// Guide channel key → source id ("" = the provider's).
    var sourceOf: [String: String] = [:]
    /// Every guide channel (key, first name, guide name), for choosing by hand.
    var guideChannels: [(id: String, name: String, source: String)] = []
    var count = 0

    init(picker: LiveTVEPGMatch.Picker) {
        self.picker = picker
    }
}

/// SAX handler for `<programme start stop channel><title/><desc/></programme>`,
/// one per guide file.
private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    struct Programme {
        let channel: String
        let start: Int64
        let stop: Int64
        let title: String
        let descr: String?
    }

    private let state: GuideImportState
    private let feed: LiveTVGuideFeed
    private let guide: Int
    private let shift: Int64
    private let from: Int64
    private let to: Int64
    private let onProgramme: (Programme) -> Void
    private let onCount: (Int) -> Void
    /// Any <programme> at all, matched or not (tells "no guide" from "no
    /// matching channels").
    private(set) var sawProgrammes = false
    /// The names of each `<channel>` (they come before the programmes).
    private var displayNames: [String: [String]] = [:]
    /// Per guide channel id: worth keeping? Decided at its first programme.
    private var decided: [String: Bool] = [:]
    private var channelID: String?
    private var channelNames: [String] = []
    private var displayName: String?

    private var current: (channel: String, start: Int64, stop: Int64)?
    private var title = ""
    private var descr = ""
    private var element: String?

    init(state: GuideImportState, feed: LiveTVGuideFeed, guide: Int, from: Int64, to: Int64,
         onProgramme: @escaping (Programme) -> Void, onCount: @escaping (Int) -> Void) {
        self.state = state
        self.feed = feed
        self.guide = guide
        self.shift = Int64(feed.shiftMinutes) * 60
        self.from = from
        self.to = to
        self.onProgramme = onProgramme
        self.onCount = onCount
    }

    private func key(_ id: String) -> String {
        LiveTVEPGSourceRules.key(sourceID: feed.sourceID, guideID: id)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if Task.isCancelled { parser.abortParsing(); return }
        switch elementName {
        case "channel":
            channelID = attributes["id"]?.trimmingCharacters(in: .whitespaces).lowercased()
            channelNames = []
        case "display-name":
            displayName = channelID == nil ? nil : ""
        case "programme":
            sawProgrammes = true
            // Guide ids are matched without regard to case (as on Android);
            // the guide's time shift moves its listings.
            guard let id = attributes["channel"]?.trimmingCharacters(in: .whitespaces).lowercased(),
                  wanted(id),
                  let start = attributes["start"].flatMap(Self.parseTime).map({ $0 + shift }),
                  let stop = attributes["stop"].flatMap(Self.parseTime).map({ $0 + shift }),
                  stop > from, start < to, stop > start else {
                current = nil
                return
            }
            current = (key(id), start, stop)
            title = ""
            descr = ""
        case "title", "desc":
            element = current == nil ? nil : elementName
        default:
            break
        }
    }

    /// Asked once per guide channel, at its first programme.
    private func wanted(_ id: String) -> Bool {
        if let known = decided[id] { return known }
        let names = displayNames[id] ?? []
        if displayNames[id] == nil {
            // A guide without a <channel> list: only the id to go by.
            addChannel(id, name: id)
        }
        let keep = state.picker.saw(key: key(id), id: id, names: names, guide: guide)
        decided[id] = keep
        return keep
    }

    private func addChannel(_ id: String, name: String) {
        let key = key(id)
        state.guideChannels.append((key, name, feed.name))
        state.sourceOf[key] = feed.sourceID
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if displayName != nil, displayName!.count < 200 { displayName! += string; return }
        switch element {
        case "title": if title.count < 300 { title += string }
        case "desc": if descr.count < 2000 { descr += string }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "display-name":
            if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                channelNames.append(name)
            }
            displayName = nil
        case "channel":
            if let channelID, displayNames[channelID] == nil {
                displayNames[channelID] = channelNames
                addChannel(channelID, name: channelNames.first ?? channelID)
            }
            channelID = nil
        case "title", "desc":
            element = nil
        case "programme":
            if let current {
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTitle.isEmpty {
                    state.stats[current.channel, default: LiveTVEPGMatch.ChannelStat()]
                        .add(stop: current.stop, placeholder: LiveTVEPGMatch.isPlaceholder(cleanTitle))
                    let cleanDescr = descr.trimmingCharacters(in: .whitespacesAndNewlines)
                    onProgramme(Programme(channel: current.channel, start: current.start, stop: current.stop,
                                          title: cleanTitle, descr: cleanDescr.isEmpty ? nil : cleanDescr))
                    state.count += 1
                    onCount(state.count)
                }
            }
            current = nil
        default:
            break
        }
    }

    /// XMLTV time: "20261109201500 +0100" (offset optional).
    static func parseTime(_ value: String) -> Int64? {
        let parts = value.split(separator: " ")
        guard let stamp = parts.first, stamp.count >= 14 else { return nil }
        let digits = Array(stamp.prefix(14))
        func number(_ range: Range<Int>) -> Int? { Int(String(digits[range])) }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(8..<10), let minute = number(10..<12), let second = number(12..<14) else { return nil }
        var offset = 0
        if parts.count > 1 {
            let zone = parts[1]
            if zone.count == 5, let sign = zone.first, sign == "+" || sign == "-",
               let hh = Int(zone.dropFirst().prefix(2)), let mm = Int(zone.suffix(2)) {
                offset = (hh * 3600 + mm * 60) * (sign == "-" ? -1 : 1)
            }
        }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        components.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return nil }
        return Int64(date.timeIntervalSince1970) - Int64(offset)
    }
}
