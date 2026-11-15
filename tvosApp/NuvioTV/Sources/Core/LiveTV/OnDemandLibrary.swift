import CryptoKit
import Foundation
import SQLite3

/// The provider's movies and series on the device (step 12), as Android's
/// VOD index: read once a day from the Xtream login, kept in SQLite
/// per profile. Looked up when a title in Nuvio searches its streams
/// (`OnDemandLookup`, 12a) and shown on the VOD page and Home row
/// (12b).
@MainActor
final class OnDemandLibrary: ObservableObject {
    static let shared = OnDemandLibrary()

    enum Status: Equatable {
        case idle
        /// `fraction`: of the list being downloaded, when the size is known.
        case importing(String, fraction: Double?)
        case ready(movies: Int, series: Int, updated: Date)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle {
        didSet { reportActivity() }
    }
    /// The provider's copies in Nuvio's stream lists (Android's "VOD
    /// in Streams", on by default).
    @Published private(set) var inStreams = true
    /// Goes up when new lists are in (the VOD page and Home row
    /// read again).
    @Published private(set) var revision = 0

    static let refreshAge: TimeInterval = 24 * 3600
    private static let inStreamsKey = "nuvio.tv.livetv.onDemandInStreams"
    private var importTask: Task<Void, Never>?
    private var profileObserver: NSObjectProtocol?
    private var sourcesObserver: NSObjectProtocol?
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
        // A login added, removed or with VOD turned on or off (step 13c):
        // read again when the set changed.
        sourcesObserver = NotificationCenter.default.addObserver(
            forName: LiveTVSourceStore.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfNeeded() }
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
        let logins = OnDemandSources.all()
        guard isWanted, importTask == nil, !LiveTVFullscreenState.shared.isActive,
              !logins.isEmpty, let database else { return }
        let sameAccount = database.meta("logins") == OnDemandSources.fingerprint(logins)
        let failed = database.meta("failedAt").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        // After a failure: once an hour, not on every title opened.
        if let failed, Date().timeIntervalSince(failed) < 3600, sameAccount { return }
        guard !sameAccount || !Self.due(logins, in: database).isEmpty else { return }
        refresh(force: false)
    }

    /// The logins to read: new, changed, or read more than a day ago (step
    /// 13c: turning one on or off leaves the others as they are).
    private static func due(_ logins: [LiveTVSource], in database: OnDemandDatabase) -> [LiveTVSource] {
        logins.filter { login in
            guard database.meta("login.s\(login.slot)") == OnDemandSources.key(login),
                  let updated = database.meta("updated.s\(login.slot)").flatMap(Double.init) else { return true }
            return Date().timeIntervalSince1970 - updated > refreshAge
        }
    }

    /// Read at all: for the stream lists, the VOD page or the Home row.
    var isWanted: Bool {
        let settings = ProfileSettings.current
        return inStreams
            || (settings.object(forKey: SettingsKey.showOnDemandTab) as? Bool ?? true)
            || (settings.object(forKey: SettingsKey.onDemandHomeRow) as? Bool ?? true)
    }

    /// Settings → Live TV → VOD → Update Now, or when due.
    /// `force` (Update Now): every login; else only the ones due.
    func refresh(force: Bool = true) {
        let logins = OnDemandSources.all()
        guard importTask == nil, !logins.isEmpty, let database else { return }
        let routes = OnDemandSources.routes()
        let profileScope = scope
        // Before step 13c one login was read: its index is kept (slot 0).
        if let old = database.meta("account"), !logins.contains(where: { $0.slot == 0 && $0.id == old }) {
            database.clear()
        }
        database.setMeta("account", nil)
        // Logins removed or with VOD off: their titles go now.
        database.keepOnly(slots: Set(logins.map(\.slot)))
        let dueIDs = Set((force ? logins : Self.due(logins, in: database)).map(\.id))
        guard !dueIDs.isEmpty else {
            database.setMeta("logins", OnDemandSources.fingerprint(logins))
            publishCounts()
            return
        }
        status = .importing(L10n.string("livetv_ondemand_loading", fallback: "Loading movies & series"), fraction: nil)
        importTask = Task { [weak self] in
            var errors: [String] = []
            var attempts = 0
            for (position, login) in logins.enumerated() where dueIDs.contains(login.id) {
              guard let route = routes[login.slot] else { continue }
              var loginFailed = false
              // Stalker (step 13f): movies and series come in one read.
              var stalkerCatalog: OnDemandStalker.Catalog?
              // The login's name with several (step 13c).
              let named = logins.count > 1 ? " \u{00B7} " + login.displayName : ""
              for kind in OnDemandKind.allCases {
                guard !Task.isCancelled else { return }
                attempts += 1
                // As Jellyfin's: how many are in, then how many are saved.
                let loading = (kind == .movie
                    ? L10n.string("livetv_ondemand_loading_movies", fallback: "Loading movies")
                    : L10n.string("livetv_ondemand_loading_series", fallback: "Loading series")) + named
                let saving = (kind == .movie
                    ? L10n.string("livetv_ondemand_saving_movies", fallback: "Saving movies")
                    : L10n.string("livetv_ondemand_saving_series", fallback: "Saving series")) + named
                self?.status = .importing(loading, fraction: nil)
                do {
                    let slot = login.slot
                    let hashKey = "hash.s\(slot).\(kind.rawValue)"
                    if let stalker = route.stalker {
                        if stalkerCatalog == nil {
                            let raw = try await stalker.vodCatalog { titles in
                                Task { @MainActor in
                                    guard let self, self.importTask != nil, titles > 0 else { return }
                                    self.status = .importing(Self.progressText(loading, titles), fraction: nil)
                                }
                            }
                            stalkerCatalog = OnDemandStalker.Catalog(
                                movies: raw.movies, movieCategories: raw.movieCategories,
                                series: raw.series, seriesCategories: raw.seriesCategories)
                        }
                        guard let catalog = stalkerCatalog else { continue }
                        let part = kind == .movie ? catalog.movies : catalog.series
                        let categories = kind == .movie ? catalog.movieCategories : catalog.seriesCategories
                        let hash = Self.digest(OnDemandStalker.digestData(part), categories: categories, position: position)
                        if database.meta(hashKey) == hash { continue }
                        self?.status = .importing(saving, fraction: nil)
                        await Task.detached(priority: .utility) {
                            let list = OnDemandStalker.items(part, kind: kind)
                            let items = slot == 0 ? list.items : list.items.map { $0.inSource(slot: slot) }
                            let shownCategories = slot == 0 ? categories : categories.map { $0.inSource(slot: slot) }
                            database.replace(
                                kind: kind, slot: slot, position: position, items: items, categories: shownCategories,
                                tags: list.tags)
                        }.value
                        database.setMeta(hashKey, hash)
                        continue
                    }
                    guard let client = route.xtream else { continue }
                    let categories = (try? await (kind == .movie ? client.vodCategories() : client.seriesCategories())) ?? []
                    let data = try await client.onDemandList(kind) { titles in
                        Task { @MainActor in
                            guard let self, self.importTask != nil, titles > 0 else { return }
                            self.status = .importing(Self.progressText(loading, titles), fraction: nil)
                        }
                    }
                    // The same list as last time: nothing to save again.
                    let hash = Self.digest(data, categories: categories, position: position)
                    if database.meta(hashKey) == hash { continue }
                    let saved = await Task.detached(priority: .utility) { () -> Int? in
                        guard let list = OnDemandParse.list(data, kind: kind) else { return nil }
                        let total = list.items.count
                        let items = slot == 0 ? list.items : list.items.map { $0.inSource(slot: slot) }
                        let shownCategories = slot == 0 ? categories : categories.map { $0.inSource(slot: slot) }
                        database.replace(
                            kind: kind, slot: slot, position: position, items: items, categories: shownCategories,
                            tags: list.tags
                        ) { done in
                            Task { @MainActor in
                                guard let self, self.importTask != nil else { return }
                                self.status = .importing(Self.progressText(saving, done), fraction: nil)
                            }
                        }
                        return total
                    }.value
                    if saved == nil {
                        errors.append((kind == .movie ? "movies" : "series") + named)
                        loginFailed = true
                    } else {
                        database.setMeta(hashKey, hash)
                    }
                } catch {
                    errors.append(error.localizedDescription + named)
                    loginFailed = true
                }
              }
              // This login read: not again until it's due.
              if !loginFailed {
                  database.setMeta("login.s\(login.slot)", OnDemandSources.key(login))
                  database.setMeta("updated.s\(login.slot)", String(Date().timeIntervalSince1970))
              }
            }
            guard !Task.isCancelled, let self, self.scope == profileScope else { return }
            self.importTask = nil
            let now = String(Date().timeIntervalSince1970)
            if errors.count >= attempts {
                database.setMeta("failedAt", now)
                self.status = .failed(errors.joined(separator: " · "))
            } else {
                database.setMeta("updated", now)
                database.setMeta("failedAt", nil)
                database.setMeta("logins", OnDemandSources.fingerprint(logins))
                self.publishCounts()
            }
        }
    }

    /// What a list was: the provider's answer, its categories and the
    /// login's place (the same again needs no saving).
    nonisolated static func digest(_ data: Data, categories: [XtreamCategory], position: Int) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        let rest = categories.map { $0.id + "\t" + $0.name }.joined(separator: "\n") + "\n\(position)"
        hasher.update(data: Data(rest.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "Loading movies · 12,500".
    nonisolated static func progressText(_ label: String, _ done: Int) -> String {
        label + " \u{00B7} " + done.formatted()
    }

    private func publishCounts() {
        guard let database,
              let updated = database.meta("updated").flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) else {
            status = .idle
            return
        }
        status = .ready(movies: database.count(.movie), series: database.count(.series), updated: updated)
        revision &+= 1
    }

    private func reportActivity() {
        let id = "livetv.ondemand"
        switch status {
        case .importing(let label, let fraction): ActivityCenter.shared.update(id, label: label, fraction: fraction)
        case .failed(let message):
            ActivityCenter.shared.fail(id, message: L10n.string("livetv_ondemand_title", fallback: "VOD") + ": " + message)
        case .idle, .ready: ActivityCenter.shared.finish(id)
        }
    }
}

/// SQLite behind `OnDemandLibrary`; every call holds one lock, so lookups
/// wait while a list is written (a few seconds, once a day).
final class OnDemandDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    /// 2: pictures, dates, ratings and category order for the VOD
    /// page and Home row (step 12b).
    /// 3: languages (12c). 4: the Nordic group. 5: Stalker's play column
    /// (13f; added to a version 4 table, the lists stay).
    private static let schemaVersion: Int32 = 5

    init?(url: URL) {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        var version: Int32 = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            version = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        if version == 4 {
            sqlite3_exec(db, "ALTER TABLE items ADD COLUMN play TEXT", nil, nil, nil)
        } else if version < Self.schemaVersion {
            // An older layout: read the lists again.
            sqlite3_exec(db, "DROP TABLE IF EXISTS items; DROP TABLE IF EXISTS categories; DROP TABLE IF EXISTS meta;", nil, nil, nil)
        }
        sqlite3_exec(db, """
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS items (kind TEXT NOT NULL, id INTEGER NOT NULL, name TEXT NOT NULL, key TEXT NOT NULL,
                cat TEXT NOT NULL, ext TEXT, tmdb INTEGER, year INTEGER, icon TEXT, added INTEGER, rating TEXT, lang TEXT,
                play TEXT, PRIMARY KEY (kind, id));
            CREATE INDEX IF NOT EXISTS items_key ON items (kind, key);
            CREATE INDEX IF NOT EXISTS items_tmdb ON items (kind, tmdb);
            CREATE INDEX IF NOT EXISTS items_cat ON items (kind, cat);
            CREATE INDEX IF NOT EXISTS items_added ON items (added);
            CREATE TABLE IF NOT EXISTS categories (kind TEXT NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, pos INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (kind, id));
            CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
            PRAGMA user_version = \(Self.schemaVersion);
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

    /// One kind's list and categories (in the provider's order), replaced
    /// in one transaction. The tags learned from the list are kept for
    /// cleaning titles later.
    func replace(
        kind: OnDemandKind, slot: Int = 0, position: Int = 0, items: [OnDemandItem], categories: [XtreamCategory],
        tags: Set<String>, progress: ((Int) -> Void)? = nil
    ) {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        // Only this login's titles go (step 13c: the others stay).
        sqlite3_exec(db, "DELETE FROM items WHERE kind = '\(kind.rawValue)' AND (id >> 32) = \(slot)", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM categories WHERE kind = '\(kind.rawValue)' AND \(Self.categorySlot(slot))", nil, nil, nil)
        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO items (kind, id, name, key, cat, ext, tmdb, year, icon, added, rating, lang, play) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        // The language (step 12c): from the name's tag, else the category.
        let categoryNames = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, item) in items.enumerated() {
                if index % 2000 == 0 { progress?(index) }
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
                sqlite3_bind_int64(statement, 2, Int64(item.id))
                sqlite3_bind_text(statement, 3, item.name, -1, onDemandTransient)
                sqlite3_bind_text(statement, 4, item.key, -1, onDemandTransient)
                sqlite3_bind_text(statement, 5, item.categoryID, -1, onDemandTransient)
                bind(statement, 6, item.ext)
                bind(statement, 7, item.tmdb)
                bind(statement, 8, item.year)
                bind(statement, 9, item.icon)
                bind(statement, 10, item.added)
                bind(statement, 11, item.rating)
                bind(statement, 12, OnDemandLanguage.code(name: item.name, category: categoryNames[item.categoryID]))
                bind(statement, 13, item.play)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO categories (kind, id, name, pos) VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK {
            for (index, category) in categories.enumerated() {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
                sqlite3_bind_text(statement, 2, category.id, -1, onDemandTransient)
                sqlite3_bind_text(statement, 3, category.name, -1, onDemandTransient)
                // The logins in your order, each in its provider's order.
                sqlite3_bind_int64(statement, 4, Int64(position) * 1_000_000 + Int64(index))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, Self.tagsKey(kind, slot: slot), -1, onDemandTransient)
            sqlite3_bind_text(statement, 2, tags.sorted().joined(separator: "\n"), -1, onDemandTransient)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Every login's learned tags.
    func tags(_ kind: OnDemandKind) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT v FROM meta WHERE k = ? OR k LIKE ?", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "tags." + kind.rawValue, -1, onDemandTransient)
        sqlite3_bind_text(statement, 2, "tags." + kind.rawValue + ".s%", -1, onDemandTransient)
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                result.formUnion(String(cString: text).split(separator: "\n").map(String.init))
            }
        }
        return result
    }

    private static func tagsKey(_ kind: OnDemandKind, slot: Int) -> String {
        slot == 0 ? "tags." + kind.rawValue : "tags.\(kind.rawValue).s\(slot)"
    }

    /// The categories of a login: "s2:…" for slot 2, none of those for 0.
    private static func categorySlot(_ slot: Int) -> String {
        slot == 0 ? "id NOT GLOB 's[0-9]*:*'" : "id LIKE 's\(slot):%'"
    }

    /// Titles of logins no longer read (removed, VOD off) go.
    func keepOnly(slots: Set<Int>) {
        lock.lock(); defer { lock.unlock() }
        let list = slots.sorted().map(String.init).joined(separator: ",")
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM items WHERE (id >> 32) NOT IN (\(list.isEmpty ? "-1" : list))", nil, nil, nil)
        if !slots.contains(0) {
            sqlite3_exec(db, "DELETE FROM categories WHERE \(Self.categorySlot(0))", nil, nil, nil)
        }
        sqlite3_exec(db, "DELETE FROM categories WHERE id GLOB 's[0-9]*:*' AND CAST(substr(id, 2, instr(id, ':') - 2) AS INTEGER) NOT IN (\(list.isEmpty ? "-1" : list))", nil, nil, nil)
        // A login turned on again is read again.
        sqlite3_exec(db, "DELETE FROM meta WHERE (k GLOB 'login.s*' OR k GLOB 'updated.s*' OR k GLOB 'hash.s*') AND CAST(substr(k, instr(k, '.s') + 2) AS INTEGER) NOT IN (\(list.isEmpty ? "-1" : list))", nil, nil, nil)
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

    private static let itemColumns = "kind, id, name, key, cat, ext, tmdb, year, icon, added, rating, lang, play"

    /// Copies that could be the title: same TMDB id or same match key.
    func candidates(kind: OnDemandKind, tmdb: Int?, key: String) -> [OnDemandItem] {
        items(
            "SELECT \(Self.itemColumns) FROM items WHERE kind = ? AND (key = ? OR tmdb = ?) LIMIT 200",
            [kind.rawValue, key, String(tmdb ?? -1)])
    }

    /// Titles whose match key has every word (step 12c, Nuvio's search):
    /// keys starting with them first, then the shortest.
    func search(kind: OnDemandKind, words: [String], limit: Int) -> [OnDemandItem] {
        guard !words.isEmpty else { return [] }
        let joined = words.joined()
        let match = words.map { _ in "instr(key, ?) > 0" }.joined(separator: " AND ")
        return items(
            "SELECT \(Self.itemColumns) FROM items WHERE kind = ? AND \(match) "
                + "ORDER BY (instr(key, ?) = 1) DESC, length(key), rowid LIMIT ?",
            [kind.rawValue] + words + [joined, String(limit)])
    }

    func item(kind: OnDemandKind, id: Int) -> OnDemandItem? {
        items("SELECT \(Self.itemColumns) FROM items WHERE kind = ? AND id = ?", [kind.rawValue, String(id)]).first
    }

    /// One category's titles in the provider's order, a page at a time.
    func items(kind: OnDemandKind, category: String, offset: Int, limit: Int) -> [OnDemandItem] {
        items(
            "SELECT \(Self.itemColumns) FROM items WHERE kind = ? AND cat = ? ORDER BY rowid LIMIT ? OFFSET ?",
            [kind.rawValue, category, String(limit), String(offset)])
    }

    /// Newest first (by the provider's "added"), movies and series together.
    func recentlyAdded(limit: Int) -> [OnDemandItem] {
        items("SELECT \(Self.itemColumns) FROM items WHERE added IS NOT NULL ORDER BY added DESC LIMIT ?", [String(limit)])
    }

    /// The provider's categories that have titles, in its order.
    func categories(_ kind: OnDemandKind) -> [(id: String, name: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let sql = """
            SELECT c.id, c.name, COUNT(i.id) FROM categories c JOIN items i ON i.kind = c.kind AND i.cat = c.id
            WHERE c.kind = ? GROUP BY c.id ORDER BY c.pos
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
        var out: [(id: String, name: String, count: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
            out.append((String(cString: id), String(cString: name), Int(sqlite3_column_int64(statement, 2))))
        }
        return out
    }

    /// How many titles each language has (nil: none known), most first.
    func languages(_ kind: OnDemandKind) -> [(code: String?, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT lang, COUNT(*) FROM items WHERE kind = ? GROUP BY lang ORDER BY COUNT(*) DESC", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind.rawValue, -1, onDemandTransient)
        var out: [(code: String?, count: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((sqlite3_column_text(statement, 0).map { String(cString: $0) }, Int(sqlite3_column_int64(statement, 1))))
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

    /// Rows of `itemColumns`; every value bound as text (SQLite compares
    /// numbers given as text by their column's type).
    private func items(_ sql: String, _ values: [String]) -> [OnDemandItem] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            if let number = Int64(value) {
                sqlite3_bind_int64(statement, Int32(index + 1), number)
            } else {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, onDemandTransient)
            }
        }
        var out: [OnDemandItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            func number(_ column: Int32) -> Int? {
                sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
            }
            guard let kind = text(0).flatMap(OnDemandKind.init(rawValue:)) else { continue }
            out.append(OnDemandItem(
                kind: kind, id: number(1) ?? 0, name: text(2) ?? "", key: text(3) ?? "",
                categoryID: text(4) ?? "", ext: text(5), tmdb: number(6), year: number(7),
                icon: text(8), added: number(9), rating: text(10), language: text(11), play: text(12)))
        }
        return out
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, onDemandTransient) } else { sqlite3_bind_null(statement, index) }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(statement, index, Int64(value)) } else { sqlite3_bind_null(statement, index) }
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
