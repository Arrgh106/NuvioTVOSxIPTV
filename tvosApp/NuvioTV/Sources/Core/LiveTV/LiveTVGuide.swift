import Foundation
import SQLite3

/// The provider's full programme guide (`xmltv.php`), stored on the device
/// in SQLite. Tens of thousands of channels make the XMLTV file hundreds of
/// MB, so it is downloaded to a file, read as a stream, and only programmes
/// of channels in visible groups within a time window are kept.
///
/// Refreshes in the background when older than `maxAge`; progress is
/// published for the Live TV header.
@MainActor
final class LiveTVGuide: ObservableObject {
    static let shared = LiveTVGuide()

    enum Status: Equatable {
        case idle
        case downloading(fraction: Double?)
        case importing(programmes: Int)
        case ready(programmes: Int, updated: Date)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle {
        didSet { reportActivity() }
    }

    private func reportActivity() {
        let id = "livetv.guide"
        let center = ActivityCenter.shared
        switch status {
        case .idle, .ready:
            center.finish(id)
        case .downloading(let fraction):
            center.update(id, label: L10n.string("livetv_guide_downloading_label", fallback: "Downloading guide"), fraction: fraction)
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

    // MARK: Reading

    /// The stored guide, for queries off the main thread (the handle is
    /// thread-safe). Nil until a guide has been imported.
    func reader() -> GuideDatabase? {
        openDatabase()
    }

    // MARK: Refresh

    /// Starts a background refresh when the stored guide is missing or older
    /// than `maxAge` (or always with `force`). `epgIDs`: the channels to
    /// keep programmes for.
    func refreshIfNeeded(account: XtreamAccount, password: String, epgIDs: Set<String>, force: Bool = false) {
        let scope = ProfileSettings.activeProfileScope
        if scope != self.scope { closeDatabase(); self.scope = scope }
        if refreshTask != nil { return }
        let db = openDatabase()
        if !force, let db, let updated = db.updatedAt(), Date().timeIntervalSince(updated) < Self.maxAge {
            status = .ready(programmes: db.storedCount(), updated: updated)
            return
        }
        guard !epgIDs.isEmpty, let url = Self.xmltvURL(account: account, password: password),
              let target = Self.databaseURL(scope: scope) else { return }

        status = .downloading(fraction: nil)
        refreshTask = Task { [weak self] in
            defer { Task { @MainActor in self?.refreshTask = nil } }
            do {
                let file = try await GuideDownloader.download(url) { fraction in
                    Task { @MainActor in self?.status = .downloading(fraction: fraction) }
                }
                defer { try? FileManager.default.removeItem(at: file) }
                await MainActor.run { self?.status = .importing(programmes: 0) }
                let count = try await Task.detached(priority: .utility) {
                    try GuideImporter.importXMLTV(file: file, into: target, keep: epgIDs) { imported in
                        Task { @MainActor in self?.status = .importing(programmes: imported) }
                    }
                }.value
                await MainActor.run {
                    guard let self else { return }
                    self.closeDatabase()
                    self.status = .ready(programmes: count, updated: Date())
                    NotificationCenter.default.post(name: Self.updatedNotification, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run { self?.status = .idle }
            } catch {
                await MainActor.run { self?.status = .failed(error.localizedDescription) }
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
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        database = GuideDatabase(url: url, readOnly: true)
        return database
    }

    private func closeDatabase() {
        database = nil
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

/// Guide refresh failures, worded for the Live TV header.
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
            return L10n.string("livetv_guide_error_not_xmltv", fallback: "The provider didn't send an XMLTV guide.")
        case .empty:
            return L10n.string("livetv_guide_error_empty", fallback: "The provider's guide is empty.")
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
            """)
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
    func storedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM meta WHERE k = 'count'", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return 0 }
        return Int(String(cString: text)) ?? 0
    }

    func programmes(channel: String, from: Date, to: Date) -> [XtreamProgram] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let sql = "SELECT start, stop, title, descr FROM programmes WHERE ch = ? AND stop > ? AND start < ? ORDER BY start LIMIT 200"
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

// MARK: - Import

/// Streams the XMLTV file into a fresh database next to the live one, then
/// swaps it in.
private enum GuideImporter {
    static func importXMLTV(
        file: URL,
        into target: URL,
        keep: Set<String>,
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
        guard let stream = InputStream(url: file) else {
            throw GuideError.unreadable
        }
        database.execute("BEGIN")

        let now = Date().timeIntervalSince1970
        let delegate = XMLTVParserDelegate(
            keep: keep,
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
        database.execute("COMMIT")
        if Task.isCancelled { throw CancellationError() }
        guard ok || delegate.count > 0 else {
            // Typically an HTML error page or an empty answer instead of XMLTV.
            throw GuideError.notXMLTV
        }
        guard delegate.count > 0 else {
            throw delegate.sawProgrammes ? GuideError.noMatchingChannels : GuideError.empty
        }
        database.createIndex()
        let count = delegate.count
        database.setMeta("updated", String(Date().timeIntervalSince1970))
        database.setMeta("count", String(count))

        // Swap: the reader opens the file again after the refresh.
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)
        return count
    }
}

/// SAX handler for `<programme start stop channel><title/><desc/></programme>`.
private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    struct Programme {
        let channel: String
        let start: Int64
        let stop: Int64
        let title: String
        let descr: String?
    }

    private let keep: Set<String>
    private let from: Int64
    private let to: Int64
    private let onProgramme: (Programme) -> Void
    private let onCount: (Int) -> Void
    private(set) var count = 0
    /// Any <programme> at all, matched or not (tells "no guide" from "no
    /// matching channels").
    private(set) var sawProgrammes = false

    private var current: (channel: String, start: Int64, stop: Int64)?
    private var title = ""
    private var descr = ""
    private var element: String?

    init(keep: Set<String>, from: Int64, to: Int64,
         onProgramme: @escaping (Programme) -> Void, onCount: @escaping (Int) -> Void) {
        self.keep = keep
        self.from = from
        self.to = to
        self.onProgramme = onProgramme
        self.onCount = onCount
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if Task.isCancelled { parser.abortParsing(); return }
        switch elementName {
        case "programme":
            sawProgrammes = true
            // Guide ids are matched without regard to case (as on Android).
            guard let channel = attributes["channel"]?.lowercased(), keep.contains(channel),
                  let start = attributes["start"].flatMap(Self.parseTime),
                  let stop = attributes["stop"].flatMap(Self.parseTime),
                  stop > from, start < to, stop > start else {
                current = nil
                return
            }
            current = (channel, start, stop)
            title = ""
            descr = ""
        case "title", "desc":
            element = current == nil ? nil : elementName
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch element {
        case "title": if title.count < 300 { title += string }
        case "desc": if descr.count < 2000 { descr += string }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "title", "desc":
            element = nil
        case "programme":
            if let current {
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTitle.isEmpty {
                    let cleanDescr = descr.trimmingCharacters(in: .whitespacesAndNewlines)
                    onProgramme(Programme(channel: current.channel, start: current.start, stop: current.stop,
                                          title: cleanTitle, descr: cleanDescr.isEmpty ? nil : cleanDescr))
                    count += 1
                    onCount(count)
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
