import Foundation
import SQLite3

/// The provider's movies and series on the device (step 12a), as Android's
/// On Demand index: read once a day from the Xtream login, kept in SQLite
/// per profile, and looked up when a title in Nuvio searches its streams
/// (`OnDemandLookup`). Nothing is shown on its own; the provider's copy
/// shows up as "On Demand" in the stream list.
@MainActor
final class OnDemandLibrary: ObservableObject {
    static let shared = OnDemandLibrary()

    enum Status: Equatable {
        case idle
        case importing(String)
        case ready(movies: Int, series: Int, updated: Date)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle {
        didSet { reportActivity() }
    }
    /// The provider's copies in Nuvio's stream lists (Android's "On Demand
    /// in Streams", on by default).
    @Published private(set) var inStreams = true

    static let refreshAge: TimeInterval = 24 * 3600
    private static let inStreamsKey = "nuvio.tv.livetv.onDemandInStreams"
    private var importTask: Task<Void, Never>?
    private var profileObserver: NSObjectProtocol?
    private var scope = ""
    /// Read off the main thread by lookups.
    nonisolated(unsafe) private(set) var database: OnDemandDatabase?

    private init() {
        load()
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileSettings.activeProfileChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    /// The active profile's index (and option).
    private func load() {
        importTask?.cancel()
        importTask = nil
        inStreams = ProfileSettings.current.object(forKey: Self.inStreamsKey) as? Bool ?? true
        scope = ProfileSettings.activeProfileScope
        database = Self.databaseURL(scope: scope).flatMap { OnDemandDatabase(url: $0) }
        publishCounts()
    }

    func setInStreams(_ on: Bool) {
        guard on != inStreams else { return }
        inStreams = on
        ProfileSettings.current.set(on, forKey: Self.inStreamsKey)
        if on { refreshIfNeeded() }
    }

    nonisolated static func databaseURL(scope: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("ondemand-\(scope).sqlite")
    }

    /// Reads the lists again when they're older than a day, or were read
    /// for another login.
    func refreshIfNeeded() {
        // Not while Live TV plays full screen: no work next to the picture.
        guard inStreams, importTask == nil, !LiveTVFullscreenState.shared.isActive,
              let account = XtreamAccountStore.load(), let database else { return }
        let sameAccount = database.meta("account") == account.id
        let updated = database.meta("updated").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let failed = database.meta("failedAt").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        // After a failure: once an hour, not on every title opened.
        if let failed, Date().timeIntervalSince(failed) < 3600, sameAccount { return }
        guard !sameAccount || updated.map({ Date().timeIntervalSince($0) > Self.refreshAge }) ?? true else { return }
        refresh()
    }

    /// Settings → Live TV → On Demand → Update Now, or when due.
    func refresh() {
        guard importTask == nil, let account = XtreamAccountStore.load(), let database else { return }
        let client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))
        let profileScope = scope
        if database.meta("account") != account.id {
            database.clear()
            database.setMeta("account", account.id)
        }
        status = .importing(L10n.string("livetv_ondemand_loading", fallback: "Loading movies & series"))
        importTask = Task { [weak self] in
            var errors: [String] = []
            for kind in OnDemandKind.allCases {
                guard !Task.isCancelled else { return }
                do {
                    let categories = (try? await (kind == .movie ? client.vodCategories() : client.seriesCategories())) ?? []
                    let data = try await client.onDemandList(kind)
                    let ok = await Task.detached(priority: .utility) { () -> Bool in
                        guard let items = OnDemandParse.items(data, kind: kind) else { return false }
                        database.replace(kind: kind, items: items, categories: categories)
                        return true
                    }.value
                    if !ok { errors.append(kind == .movie ? "movies" : "series") }
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            guard !Task.isCancelled, let self, self.scope == profileScope else { return }
            self.importTask = nil
            let now = String(Date().timeIntervalSince1970)
            if errors.count == OnDemandKind.allCases.count {
                database.setMeta("failedAt", now)
                self.status = .failed(errors.joined(separator: " · "))
            } else {
                database.setMeta("updated", now)
                database.setMeta("failedAt", nil)
                self.publishCounts()
            }
        }
    }

    private func publishCounts() {
        guard let database,
              let updated = database.meta("updated").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) else {
            status = .idle
            return
        }
        status = .ready(movies: database.count(.movie), series: database.count(.series), updated: updated)
    }

    private func reportActivity() {
        let id = "livetv.ondemand"
        switch status {
        case .importing(let label): ActivityCenter.shared.update(id, label: label)
        case .failed(let message):
            ActivityCenter.shared.fail(id, message: L10n.string("livetv_ondemand_title", fallback: "On Demand") + ": " + message)
        case .idle, .ready: ActivityCenter.shared.finish(id)
        }
    }
}

/// SQLite behind `OnDemandLibrary`; every call holds one lock, so lookups
/// wait while a list is written (a few seconds, once a day).
final class OnDemandDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    init?(url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_exec(db, """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS items (kind TEXT NOT NULL, id INTEGER NOT NULL, name TEXT NOT NULL, key TEXT NOT NULL,
                cat TEXT NOT NULL, ext TEXT, tmdb INTEGER, year INTEGER, PRIMARY KEY (kind, id));
            CREATE INDEX IF NOT EXISTS items_key ON items (kind, key);
            CREATE INDEX IF NOT EXISTS items_tmdb ON items (kind, tmdb);
            CREATE TABLE IF NOT EXISTS categories (kind TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY (kind, id));
            CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
            """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    func meta(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM meta WHERE k = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, onDemandTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    func setMeta(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let sql = value == nil ? "DELETE FROM meta WHERE k = ?" : "INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, onDemandTransient)
        if let value { sqlite3_bind_text(statement, 2, value, -1, onDemandTransient) }
        sqlite3_step(statement)
    }

    /// Another login: nothing of the old one stays.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM items; DELETE FROM categories; DELETE FROM meta;", nil, nil, nil)
    }

    /// One kind's list and categories, replaced in one transaction.
    func replace(kind: OnDemandKind, items: [OnDemandItem], categories: [XtreamCategory]) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        run("DELETE FROM items WHERE kind = ?", kind.rawValue)
        run("DELETE FROM categories WHERE kind = ?", kind.rawValue)
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO items (kind, id, name, key, cat, ext, tmdb, year) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK {
            for item in items {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
                sqlite3_bind_int64(statement, 2, Int64(item.id))
                sqlite3_bind_text(statement, 3, item.name, -1, onDemandTransient)
                sqlite3_bind_text(statement, 4, item.key, -1, onDemandTransient)
                sqlite3_bind_text(statement, 5, item.categoryID, -1, onDemandTransient)
                if let ext = item.ext { sqlite3_bind_text(statement, 6, ext, -1, onDemandTransient) } else { sqlite3_bind_null(statement, 6) }
                if let tmdb = item.tmdb { sqlite3_bind_int64(statement, 7, Int64(tmdb)) } else { sqlite3_bind_null(statement, 7) }
                if let year = item.year { sqlite3_bind_int64(statement, 8, Int64(year)) } else { sqlite3_bind_null(statement, 8) }
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO categories (kind, id, name) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK {
            for category in categories {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
                sqlite3_bind_text(statement, 2, category.id, -1, onDemandTransient)
                sqlite3_bind_text(statement, 3, category.name, -1, onDemandTransient)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func count(_ kind: OnDemandKind) -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM items WHERE kind = ?", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    /// Copies that could be the title: same TMDB id or same match key.
    func candidates(kind: OnDemandKind, tmdb: Int?, key: String) -> [OnDemandItem] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let sql = "SELECT id, name, key, cat, ext, tmdb, year FROM items WHERE kind = ? AND (key = ? OR tmdb = ?) LIMIT 200"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
        sqlite3_bind_text(statement, 2, key, -1, onDemandTransient)
        sqlite3_bind_int64(statement, 3, Int64(tmdb ?? -1))
        var out: [OnDemandItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            func number(_ column: Int32) -> Int? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
            }
            out.append(OnDemandItem(
                kind: kind, id: number(0) ?? 0, name: text(1) ?? "", key: text(2) ?? "",
                categoryID: text(3) ?? "", ext: text(4), tmdb: number(5), year: number(6)))
        }
        return out
    }

    func categoryNames(_ kind: OnDemandKind) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name FROM categories WHERE kind = ?", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
        var out: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
            out[String(cString: id)] = String(cString: name)
        }
        return out
    }

    private func run(_ sql: String, _ value: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, value, -1, onDemandTransient)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
}

/// `SQLITE_TRANSIENT` isn't imported into Swift.
private let onDemandTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
