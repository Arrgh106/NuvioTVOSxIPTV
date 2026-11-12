import Foundation

/// Channel and group names you change (step 10a), per profile. The Live TV
/// list reads them when it's built (`LiveTVStore.prepare`), and builds again
/// when they change (`changedNotification`).
@MainActor
final class LiveTVChannelEdits: ObservableObject {
    static let shared = LiveTVChannelEdits()
    static let changedNotification = Notification.Name("nuvio.tv.livetv.channelEdits.changed")

    @Published private(set) var edits = LiveTVNameEdits.none

    nonisolated private static let channelNamesKey = "nuvio.tv.livetv.channelNames"
    nonisolated private static let groupNamesKey = "nuvio.tv.livetv.groupNames"
    nonisolated private static let removalsKey = "nuvio.tv.livetv.nameRemovals"
    nonisolated private static let cleanGroupsKey = "nuvio.tv.livetv.cleanGroupNames"
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
        edits = Self.read()
    }

    /// The active profile's edits, straight from its settings (the list is
    /// built with these, also while a profile switch is under way).
    nonisolated static func read() -> LiveTVNameEdits {
        let settings = ProfileSettings.current
        var loaded = LiveTVNameEdits()
        let channels = settings.dictionary(forKey: channelNamesKey) as? [String: String] ?? [:]
        for (key, name) in channels { if let id = Int(key) { loaded.channelNames[id] = name } }
        loaded.groupNames = settings.dictionary(forKey: groupNamesKey) as? [String: String] ?? [:]
        loaded.removals = settings.string(forKey: removalsKey) ?? ""
        loaded.cleanGroups = settings.bool(forKey: cleanGroupsKey)
        return loaded
    }

    /// Empty: back to the automatic name (the provider's, after Name
    /// Cleanup). The provider's own name is kept as a rename, so cleanup
    /// leaves it whole.
    func renameChannel(id: Int, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = edits.channelNames
        names[id] = clean.isEmpty ? nil : clean
        guard names != edits.channelNames else { return }
        edits.channelNames = names
        ProfileSettings.current.set(
            Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) }), forKey: Self.channelNamesKey)
        changed()
    }

    func renameGroup(id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = edits.groupNames
        names[id] = clean.isEmpty ? nil : clean
        guard names != edits.groupNames else { return }
        edits.groupNames = names
        ProfileSettings.current.set(names, forKey: Self.groupNamesKey)
        changed()
    }

    func setRemovals(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != edits.removals else { return }
        edits.removals = clean
        ProfileSettings.current.set(clean, forKey: Self.removalsKey)
        changed()
    }

    func setCleanGroups(_ on: Bool) {
        guard on != edits.cleanGroups else { return }
        edits.cleanGroups = on
        ProfileSettings.current.set(on, forKey: Self.cleanGroupsKey)
        changed()
    }

    func resetChannelNames() {
        guard !edits.channelNames.isEmpty else { return }
        edits.channelNames = [:]
        ProfileSettings.current.removeObject(forKey: Self.channelNamesKey)
        changed()
    }

    func resetGroupNames() {
        guard !edits.groupNames.isEmpty else { return }
        edits.groupNames = [:]
        ProfileSettings.current.removeObject(forKey: Self.groupNamesKey)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }
}
