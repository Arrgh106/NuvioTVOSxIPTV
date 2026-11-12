import Foundation

/// Channel and group names you change (step 10a), per profile. The Live TV
/// list reads them when it's built (`LiveTVStore.prepare`), and builds again
/// when they change (`changedNotification`).
@MainActor
final class LiveTVChannelEdits: ObservableObject {
    static let shared = LiveTVChannelEdits()
    static let changedNotification = Notification.Name("nuvio.tv.livetv.channelEdits.changed")
    /// Your own groups changed (step 10c): only the sidebar and their lists
    /// are built again, not the whole channel list.
    static let customGroupsChangedNotification = Notification.Name("nuvio.tv.livetv.customGroups.changed")

    @Published private(set) var edits = LiveTVNameEdits.none
    @Published private(set) var customGroups: [LiveTVCustomGroup] = []

    nonisolated private static let channelNamesKey = "nuvio.tv.livetv.channelNames"
    nonisolated private static let groupNamesKey = "nuvio.tv.livetv.groupNames"
    nonisolated private static let removalsKey = "nuvio.tv.livetv.nameRemovals"
    nonisolated private static let cleanGroupsKey = "nuvio.tv.livetv.cleanGroupNames"
    nonisolated private static let channelOrderKey = "nuvio.tv.livetv.channelOrder"
    nonisolated private static let groupOrderKey = "nuvio.tv.livetv.groupOrder"
    nonisolated private static let customGroupsKey = "nuvio.tv.livetv.customGroups"
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
        customGroups = ProfileSettings.current.data(forKey: Self.customGroupsKey)
            .flatMap { try? JSONDecoder().decode([LiveTVCustomGroup].self, from: $0) } ?? []
        NotificationCenter.default.post(name: Self.customGroupsChangedNotification, object: nil)
    }

    // MARK: Your groups (step 10c)

    func customGroup(id: String) -> LiveTVCustomGroup? {
        customGroups.first { $0.id == id }
    }

    /// Returns the new group's id.
    @discardableResult
    func createCustomGroup(name: String, with channel: Int? = nil) -> String {
        let id = LiveTVCustomGroup.prefix + String(UUID().uuidString.prefix(8)).lowercased()
        var groups = LiveTVCustomGroups.create(customGroups, name: name, id: id)
        if let channel { groups = LiveTVCustomGroups.add(groups, id: id, channel: channel) }
        setCustomGroups(groups)
        return id
    }

    func renameCustomGroup(id: String, to name: String) {
        setCustomGroups(LiveTVCustomGroups.rename(customGroups, id: id, to: name))
    }

    func deleteCustomGroup(id: String) {
        setCustomGroups(LiveTVCustomGroups.delete(customGroups, id: id))
    }

    func addToCustomGroup(id: String, channel: Int) {
        setCustomGroups(LiveTVCustomGroups.add(customGroups, id: id, channel: channel))
    }

    func removeFromCustomGroup(id: String, channel: Int) {
        setCustomGroups(LiveTVCustomGroups.remove(customGroups, id: id, channel: channel))
    }

    func setCustomGroupOrder(id: String, shown: [Int]) {
        setCustomGroups(LiveTVCustomGroups.setOrder(customGroups, id: id, shown: shown))
    }

    func deleteAllCustomGroups() {
        setCustomGroups([])
    }

    private func setCustomGroups(_ groups: [LiveTVCustomGroup]) {
        guard groups != customGroups else { return }
        customGroups = groups
        if groups.isEmpty {
            ProfileSettings.current.removeObject(forKey: Self.customGroupsKey)
        } else if let data = try? JSONEncoder().encode(groups) {
            ProfileSettings.current.set(data, forKey: Self.customGroupsKey)
        }
        NotificationCenter.default.post(name: Self.customGroupsChangedNotification, object: nil)
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
        loaded.channelOrder = settings.data(forKey: channelOrderKey)
            .flatMap { try? JSONDecoder().decode([String: [Int]].self, from: $0) } ?? [:]
        loaded.groupOrder = settings.stringArray(forKey: groupOrderKey) ?? []
        return loaded
    }

    /// Empty: back to the automatic name (the provider's, after Name
    /// Cleanup). The provider's own name is kept as a rename only while
    /// cleanup would change it.
    func renameChannel(id: Int, providerName: String, to name: String) {
        var names = edits.channelNames
        names[id] = edits.channelRename(name, providerName: providerName)
        guard names != edits.channelNames else { return }
        edits.channelNames = names
        ProfileSettings.current.set(
            Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) }), forKey: Self.channelNamesKey)
        changed()
    }

    func renameGroup(id: String, providerName: String, to name: String) {
        var names = edits.groupNames
        names[id] = edits.groupRename(name, providerName: providerName)
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

    /// Your order for a group's channels (Reorder Channels).
    func setChannelOrder(groupID: String, ids: [Int]) {
        guard edits.channelOrder[groupID] != ids else { return }
        edits.channelOrder[groupID] = ids
        storeChannelOrder()
        changed()
    }

    func setGroupOrder(_ ids: [String]) {
        guard ids != edits.groupOrder else { return }
        edits.groupOrder = ids
        ProfileSettings.current.set(ids, forKey: Self.groupOrderKey)
        changed()
    }

    func resetChannelOrder() {
        guard !edits.channelOrder.isEmpty else { return }
        edits.channelOrder = [:]
        ProfileSettings.current.removeObject(forKey: Self.channelOrderKey)
        changed()
    }

    func resetGroupOrder() {
        guard !edits.groupOrder.isEmpty else { return }
        edits.groupOrder = []
        ProfileSettings.current.removeObject(forKey: Self.groupOrderKey)
        changed()
    }

    private func storeChannelOrder() {
        if let data = try? JSONEncoder().encode(edits.channelOrder) {
            ProfileSettings.current.set(data, forKey: Self.channelOrderKey)
        }
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
