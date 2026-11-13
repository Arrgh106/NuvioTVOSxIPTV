import Foundation

/// What a source is (step 13): an Xtream login (13a), an M3U playlist (13b)
/// or a Stalker portal (13e).
enum LiveTVSourceKind: String, Codable, Sendable {
    case xtream
    case m3u
    case stalker
}

/// One source of channels, as Android's playlist entries: several at once,
/// in your order, each on or off. Per profile; passwords and links with
/// logins in them stay in the Keychain, never in this value.
struct LiveTVSource: Codable, Identifiable, Equatable, Sendable {
    var id: String
    /// Fixed for good: the channel and group ids hang on it
    /// (`LiveTVSourceIDs`). 0 is the login from before step 13.
    var slot: Int
    var kind: LiveTVSourceKind
    var name: String
    var enabled = true
    /// Xtream: server, username and stream format (`id` is the source's).
    var xtream: XtreamAccount?
    /// The source's own guide (Xtream's `xmltv.php`), as Android's "Load
    /// built-in guide".
    var builtInGuide = true

    /// The name shown: yours, or the server's.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let server = xtream?.server { return URL(string: server)?.host ?? server }
        return "Source"
    }
}

/// How one source did at its last load, for Settings → Sources.
struct LiveTVSourceStatus: Equatable, Sendable {
    var channels = 0
    var updated: Date?
    var error: String?
    var loading = false
    /// Xtream: the account's end and connections.
    var expires: Date?
    var activeConnections: Int?
    var maxConnections: Int?
}

/// The source list of the active profile (step 13a). The single login from
/// before becomes the first source (slot 0) the first time it's read.
@MainActor
final class LiveTVSourceStore: ObservableObject {
    static let shared = LiveTVSourceStore()
    static let changedNotification = Notification.Name("nuvio.tv.livetv.sources.changed")

    @Published private(set) var sources: [LiveTVSource] = []

    nonisolated private static let listKey = "nuvio.tv.livetv.sources"
    nonisolated private static let highestSlotKey = "nuvio.tv.livetv.sourcesHighestSlot"
    /// Before step 13: the one login and the provider guide option.
    nonisolated private static let legacyAccountKey = "nuvio.tv.livetv.xtreamAccount"
    nonisolated private static let legacyProviderGuideKey = "nuvio.tv.livetv.providerGuide"
    private var profileObserver: NSObjectProtocol?

    private init() {
        load()
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileSettings.activeProfileChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    private func load() {
        let settings = ProfileSettings.current
        let list = Self.read(settings: settings)
        // The login from before, written as the first source once.
        if settings.data(forKey: Self.listKey) == nil, !list.isEmpty {
            Self.write(list, settings: settings)
        }
        sources = list
    }

    /// The list as stored, off the main actor too (small JSON).
    nonisolated static func read(settings: UserDefaults = ProfileSettings.current) -> [LiveTVSource] {
        if let data = settings.data(forKey: listKey),
           let list = try? JSONDecoder().decode([LiveTVSource].self, from: data) {
            return list
        }
        guard let data = settings.data(forKey: legacyAccountKey),
              let account = try? JSONDecoder().decode(XtreamAccount.self, from: data) else { return [] }
        return [LiveTVSource(
            id: account.id, slot: 0, kind: .xtream, name: "", enabled: true, xtream: account,
            builtInGuide: settings.object(forKey: legacyProviderGuideKey) as? Bool ?? true)]
    }

    nonisolated private static func write(_ list: [LiveTVSource], settings: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { settings.set(data, forKey: listKey) }
        let highest = max(settings.integer(forKey: highestSlotKey), list.map(\.slot).max() ?? 0)
        settings.set(highest, forKey: highestSlotKey)
    }

    var enabled: [LiveTVSource] { sources.filter(\.enabled) }

    func source(id: String) -> LiveTVSource? { sources.first { $0.id == id } }

    func source(slot: Int) -> LiveTVSource? { sources.first { $0.slot == slot } }

    /// A new Xtream login with the next free slot (the first one gets 0).
    func newXtream() -> LiveTVSource {
        let settings = ProfileSettings.current
        let used = max(settings.integer(forKey: Self.highestSlotKey), sources.map(\.slot).max() ?? -1)
        let slot = sources.isEmpty && settings.object(forKey: Self.highestSlotKey) == nil
            ? 0 : LiveTVSourceIDs.nextSlot(after: used)
        let id = UUID().uuidString
        return LiveTVSource(
            id: id, slot: slot, kind: .xtream, name: "",
            xtream: XtreamAccount(id: id, name: "", server: "", username: "", streamFormat: .auto))
    }

    /// Adds or changes a source; `password` nil keeps the stored one.
    func save(_ source: LiveTVSource, password: String?) {
        var list = sources
        if let index = list.firstIndex(where: { $0.id == source.id }) {
            list[index] = source
        } else {
            list.append(source)
        }
        if let password, let account = source.xtream {
            XtreamAccountStore.savePassword(password, accountID: account.id)
        }
        commit(list)
    }

    func remove(_ id: String) {
        guard let source = source(id: id) else { return }
        if let account = source.xtream { XtreamAccountStore.removePassword(accountID: account.id) }
        commit(sources.filter { $0.id != id })
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard var source = source(id: id), source.enabled != on else { return }
        source.enabled = on
        save(source, password: nil)
    }

    /// Up (-1) or down (+1) in the list: the order of the group column.
    func move(_ id: String, by offset: Int) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard sources.indices.contains(target) else { return }
        var list = sources
        list.swapAt(index, target)
        commit(list)
    }

    func password(for source: LiveTVSource) -> String {
        source.xtream.map { XtreamAccountStore.password(for: $0) } ?? ""
    }

    private func commit(_ list: [LiveTVSource]) {
        guard list != sources else { return }
        sources = list
        Self.write(list, settings: ProfileSettings.current)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }
}
