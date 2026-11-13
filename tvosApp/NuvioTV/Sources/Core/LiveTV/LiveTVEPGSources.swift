import Foundation
import Security

/// Guides next to the provider's (step 9), per profile: Android's
/// "EPG sources". The list lives in the profile's settings, each link in the
/// Keychain (links often carry a user name and password).
@MainActor
final class LiveTVEPGSources: ObservableObject {
    static let shared = LiveTVEPGSources()

    /// Posted when the guides to read change (the guide is read again).
    /// `userInfo["force"]`: read even if the list looks the same.
    static let changedNotification = Notification.Name("nuvio.tv.livetv.epgSources.changed")

    @Published private(set) var sources: [LiveTVEPGSource] = []

    private static let listKey = "nuvio.tv.livetv.epgSources"
    private static let keychainService = "com.nuvio.tv.livetv.epg"
    private var profileObserver: NSObjectProtocol?

    private init() {
        load()
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileSettings.activeProfileChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    func load() {
        let settings = ProfileSettings.current
        sources = settings.data(forKey: Self.listKey)
            .flatMap { try? JSONDecoder().decode([LiveTVEPGSource].self, from: $0) } ?? []
    }

    func url(of source: LiveTVEPGSource) -> String {
        var q = query(source.id)
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Adds or updates a guide (matched by id).
    func save(_ source: LiveTVEPGSource, url: String) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        saveURL(url.trimmingCharacters(in: .whitespacesAndNewlines), id: source.id)
        store()
    }

    func remove(_ source: LiveTVEPGSource) {
        sources.removeAll { $0.id == source.id }
        SecItemDelete(query(source.id) as CFDictionary)
        store()
    }

    /// A source's own guide on or off (step 13a: per source, was "Provider's
    /// guide"). Takes effect at the next update.
    func setBuiltInGuide(_ source: LiveTVSource, _ on: Bool) {
        guard source.builtInGuide != on else { return }
        var changed = source
        changed.builtInGuide = on
        LiveTVSourceStore.shared.save(changed, password: nil)
    }

    /// Read all guides again now.
    func refreshNow() {
        changed(force: true)
    }

    /// The added guides to read, in order, with their links.
    func feeds() -> [LiveTVGuideFeed] {
        sources.filter(\.enabled).compactMap { source in
            guard let url = URL(string: url(of: source)), url.scheme?.hasPrefix("http") == true else { return nil }
            return LiveTVGuideFeed(sourceID: source.id, name: source.name, url: url, shiftMinutes: source.shiftMinutes)
        }
    }

    /// Read at the next update; Settings asks whether that's now.
    private func store() {
        if let data = try? JSONEncoder().encode(sources) {
            ProfileSettings.current.set(data, forKey: Self.listKey)
        }
    }

    private func changed(force: Bool) {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil, userInfo: ["force": force])
    }

    private func saveURL(_ url: String, id: String) {
        let data = Data(url.utf8)
        var add = query(id)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    private func query(_ id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "\(id).\(ProfileSettings.activeProfileScope)",
        ]
    }
}
