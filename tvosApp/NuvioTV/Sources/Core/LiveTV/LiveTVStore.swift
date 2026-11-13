import Combine
import Foundation
import Security
import SwiftUI

// MARK: - Account persistence

/// The Xtream account lives in per-profile settings; its password stays in the
/// Keychain (same pattern as `SMBCredentialStore`).
enum XtreamAccountStore {
    private static let accountKey = "nuvio.tv.livetv.xtreamAccount"
    private static let keychainService = "com.nuvio.tv.livetv.xtream"

    static func load(settings: UserDefaults = ProfileSettings.current) -> XtreamAccount? {
        guard let data = settings.data(forKey: accountKey) else { return nil }
        return try? JSONDecoder().decode(XtreamAccount.self, from: data)
    }

    static func save(_ account: XtreamAccount, password: String, settings: UserDefaults = ProfileSettings.current) {
        if let data = try? JSONEncoder().encode(account) {
            settings.set(data, forKey: accountKey)
        }
        savePassword(password, accountID: account.id)
    }

    static func remove(settings: UserDefaults = ProfileSettings.current) {
        if let account = load(settings: settings) {
            SecItemDelete(query(accountID: account.id) as CFDictionary)
        }
        settings.removeObject(forKey: accountKey)
    }

    static func password(for account: XtreamAccount) -> String {
        var q = query(accountID: account.id)
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func savePassword(_ password: String, accountID: String) {
        let data = Data(password.utf8)
        var add = query(accountID: accountID)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query(accountID: accountID) as CFDictionary,
                          [kSecValueData as String: data] as CFDictionary)
        }
    }

    private static func query(accountID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(accountID).\(ProfileSettings.activeProfileScope)",
        ]
    }
}

// MARK: - Channel cache

/// Last loaded channel list, so the tab opens instantly and works while the
/// provider is slow. Refreshed in the background when older than `maxAge`.
private struct LiveTVCache: Codable {
    var accountID: String
    var savedAt: Date
    var userInfoAllowedFormats: [String]
    var categories: [XtreamCategory]
    var channels: [XtreamLiveChannel]

    static let maxAge: TimeInterval = 12 * 60 * 60

    /// One file per profile. `scope` is resolved on the main actor and handed
    /// in, so loading and saving can run off the main thread.
    static func fileURL(scope: String) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LiveTV", isDirectory: true)
        guard let dir else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("xtream-\(scope).json")
    }

    /// Tens of thousands of channels take seconds to decode: never call this
    /// on the main thread.
    static func load(from url: URL?) -> LiveTVCache? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LiveTVCache.self, from: data)
    }

    func save(to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear(scope: String) {
        guard let url = fileURL(scope: scope) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Store

/// A channel group in the sidebar. `all` shows every channel.
struct LiveTVGroup: Identifiable, Hashable {
    static let allID = "__all__"
    static let favoritesID = "__favorites__"
    static let recentID = "__recent__"
    static let searchID = "__search__"
    let id: String
    let name: String
    let count: Int
    /// Needs the parental PIN (step 11): shown with a lock, no channels.
    var locked = false

    /// Favorites, Recently watched, Search and All: built by the app, not
    /// provider categories (can't be hidden).
    var isSpecial: Bool { id.hasPrefix("__") && id != LiveTVGroup.otherID }
}

@MainActor
final class LiveTVStore: ObservableObject {
    /// One store for the app: going back into Live TV shows the channels at
    /// once instead of reading and sorting the whole list again.
    static let shared = LiveTVStore()

    enum LoadState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    @Published private(set) var account: XtreamAccount?
    @Published private(set) var userInfo: XtreamUserInfo? {
        didSet {
            // Kept for replays before the next login.
            if let zone = userInfo?.serverTimeZone, !zone.isEmpty {
                ProfileSettings.current.set(zone, forKey: Self.serverTimeZoneKey)
            }
        }
    }
    private static let serverTimeZoneKey = "nuvio.tv.livetv.serverTimeZone"
    @Published private(set) var groups: [LiveTVGroup] = []
    @Published private(set) var state: LoadState = .idle {
        didSet {
            let id = "livetv.channels"
            switch state {
            case .loading:
                ActivityCenter.shared.update(id, label: L10n.string("livetv_loading_label", fallback: "Loading channels"))
            case .idle:
                ActivityCenter.shared.finish(id)
            case .failed(let message):
                ActivityCenter.shared.fail(id, message: message)
            }
        }
    }
    @Published private(set) var lastUpdated: Date?
    @Published var selectedGroupID: String = LiveTVGroup.allID {
        didSet {
            // Live TV reopens in the group you were last browsing (as on Android).
            if selectedGroupID != oldValue, !groups.isEmpty {
                ProfileSettings.current.set(selectedGroupID, forKey: Self.lastGroupKey)
            }
        }
    }
    /// Bumped whenever the channel lists are replaced, so views reload.
    @Published private(set) var listRevision = 0

    private static let lastGroupKey = "nuvio.tv.livetv.lastGroup"
    private static let hiddenGroupsKey = "nuvio.tv.livetv.hiddenGroups"
    private static let favoritesKey = "nuvio.tv.livetv.favorites"
    private static let recentKey = "nuvio.tv.livetv.recent"
    private static let recentLimit = 30

    /// Provider categories (and "Other"), hidden ones included: what the
    /// group manager lists.
    @Published private(set) var categoryGroups: [LiveTVGroup] = []
    @Published private(set) var hiddenGroupIDs: Set<String> = []
    @Published private(set) var favoriteIDs: [Int] = []
    @Published private(set) var recentIDs: [Int] = []
    @Published private(set) var searchQuery = ""

    private var allowedFormats: [String] = []
    /// The provider's lists as loaded: built again when names change (step 10a).
    private var rawCategories: [XtreamCategory] = []
    private var rawChannels: [XtreamLiveChannel] = []
    private var editsObserver: NSObjectProtocol?
    private var customGroupsObserver: NSObjectProtocol?
    private var parentalObserver: NSObjectProtocol?
    private var profileObserver: NSObjectProtocol?
    /// Another profile: its own account, names, favorites and groups, even
    /// with the same provider login.
    private var needsReload = false
    /// Groups that need the PIN now (step 11): their channels stay out of
    /// every list until unlocked.
    private var lockedGroupIDs: Set<String> = []
    /// The same with the ones unlocked this session: kept out of what's
    /// saved (the Home row), so a restart doesn't show them.
    private var savedLockedGroupIDs: Set<String> = []
    private var renameTask: Task<Void, Never>?
    private var channels: [XtreamLiveChannel] = []
    private var channelsByGroup: [String: [XtreamLiveChannel]] = [:]
    private var channelsByID: [Int: XtreamLiveChannel] = [:]
    private var knownCategoryIDs: Set<String> = []
    /// "All channels" without hidden groups; rebuilt when they change.
    private var allVisible: [XtreamLiveChannel] = []
    private var searchResults: [XtreamLiveChannel] = []
    /// "##### …" heading rows of the provider's list (`isSeparator`).
    private var separatorIDs: Set<Int> = []
    /// The groups without those rows, while the option hides them.
    private var channelsByGroupWithoutSeparators: [String: [XtreamLiveChannel]] = [:]
    private var hidesSeparators: Bool { LiveTVSettings.shared.hideSeparators && !separatorIDs.isEmpty }
    private var settingsObserver: AnyCancellable?
    private var loadTask: Task<Void, Never>?

    init() {
        reloadAccount()
        // The option changes the lists at once (the guide reloads).
        settingsObserver = LiveTVSettings.shared.$hideSeparators
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.rebuildSeparatorLists()
                    self.rebuildGroups()
                    self.listRevision &+= 1
                }
            }
        // Renamed channels and groups, name cleanup: the list again, same order.
        editsObserver = NotificationCenter.default.addObserver(
            forName: LiveTVChannelEdits.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyNames() }
        }
        // Another profile: built again the next time Live TV opens.
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileSettings.activeProfileChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // At once (not a task later): the views of the new profile may
            // appear right away and call reloadAccount.
            MainActor.assumeIsolated { self?.needsReload = true }
        }
        // Parental controls (step 11): locked groups and their channels.
        parentalObserver = NotificationCenter.default.addObserver(
            forName: LiveTVParentalControls.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.channels.isEmpty else { return }
                self.rebuildGroups()
                self.listRevision &+= 1
            }
        }
        // Your own groups (step 10c): the sidebar and their lists only.
        customGroupsObserver = NotificationCenter.default.addObserver(
            forName: LiveTVChannelEdits.customGroupsChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.channels.isEmpty else { return }
                self.rebuildGroups()
            }
        }
    }

    var hasAccount: Bool { account != nil }

    var visibleChannels: [XtreamLiveChannel] {
        channels(inGroup: selectedGroupID)
    }

    /// The channels a group shows (also for groups not selected, e.g. the
    /// guide over the full-screen picture).
    func channels(inGroup groupID: String) -> [XtreamLiveChannel] {
        if lockedGroupIDs.contains(groupID) { return [] }
        switch groupID {
        case LiveTVGroup.allID: return allVisible
        case LiveTVGroup.favoritesID: return unlockedChannels(favoriteIDs)
        case LiveTVGroup.recentID: return unlockedChannels(recentIDs)
        case LiveTVGroup.searchID: return searchResults
        case _ where LiveTVCustomGroup.isCustom(groupID): return customChannels(groupID)
        default: return (hidesSeparators ? channelsByGroupWithoutSeparators : channelsByGroup)[groupID] ?? []
        }
    }

    /// Your group's channels, from every channel (also ones in hidden
    /// groups, as on Android).
    private func customChannels(_ groupID: String) -> [XtreamLiveChannel] {
        let ids = LiveTVChannelEdits.shared.customGroup(id: groupID)?.channelIDs ?? []
        let skip = hidesSeparators ? separatorIDs : []
        return unlockedChannels(ids.filter { !skip.contains($0) })
    }

    /// The channels for these ids, without ones in a locked group.
    private func unlockedChannels(_ ids: [Int], locked: Set<String>? = nil) -> [XtreamLiveChannel] {
        let locked = locked ?? lockedGroupIDs
        return ids.compactMap { id in
            guard let channel = channelsByID[id] else { return nil }
            return !locked.isEmpty && locked.contains(groupID(of: channel)) ? nil : channel
        }
    }

    private func groupID(of channel: XtreamLiveChannel) -> String {
        let category = channel.categoryID ?? ""
        return knownCategoryIDs.contains(category) ? category : LiveTVGroup.otherID
    }

    private func isLocked(_ channel: XtreamLiveChannel) -> Bool {
        !lockedGroupIDs.isEmpty && lockedGroupIDs.contains(groupID(of: channel))
    }

    /// The group needs the PIN now.
    func isLocked(groupID: String) -> Bool { lockedGroupIDs.contains(groupID) }

    /// Right after a group was unlocked: the lists at once, before the
    /// change notice comes round.
    func refreshLocks() {
        guard !channels.isEmpty else { return }
        rebuildGroups()
        listRevision &+= 1
    }

    /// Provider groups and yours that need the PIN; adult names count by
    /// the shown and the provider's name.
    private func computeLockedGroups(ignoringUnlocked: Bool = false) -> Set<String> {
        let parental = LiveTVParentalControls.shared
        guard parental.isEnabled else { return [] }
        var providerNames: [String: String] = [:]
        if parental.lockAdult {
            for category in rawCategories where providerNames[category.id] == nil { providerNames[category.id] = category.name }
        }
        var candidates = categoryGroups.map { (id: $0.id, name: $0.name + " " + (providerNames[$0.id] ?? "")) }
        candidates += LiveTVChannelEdits.shared.customGroups.map { (id: $0.id, name: $0.name) }
        return parental.lockedIDs(candidates, ignoringUnlocked: ignoringUnlocked)
    }

    /// The group open now is one of yours.
    var selectedCustomGroupID: String? {
        LiveTVCustomGroup.isCustom(selectedGroupID) ? selectedGroupID : nil
    }

    // MARK: Full guide

    /// Loads the provider's XMLTV guide for the channels in visible groups
    /// (in the background; the set is built off the main thread).
    /// `reuseDownloads`: read the guide files kept from last time (after
    /// Assign EPG) instead of downloading them again.
    func refreshGuide(force: Bool, reuseDownloads: Bool = false) {
        guard let account else { return }
        let password = XtreamAccountStore.password(for: account)
        // Channels in your groups from hidden groups get their guide too.
        var visible = allVisible
        var shownIDs = Set(visible.map(\.streamID))
        for group in LiveTVChannelEdits.shared.customGroups {
            for id in group.channelIDs where !shownIDs.contains(id) {
                if let channel = channelsByID[id] {
                    visible.append(channel)
                    shownIDs.insert(id)
                }
            }
        }
        Task { [weak self] in
            // Every visible channel: those without a guide id are matched
            // by name (step 8a).
            let channels = await Task.detached(priority: .utility) {
                visible.map { LiveTVEPGChannelRef(streamID: $0.streamID, epgID: $0.epgChannelID, name: $0.originalName) }
            }.value
            guard let self, self.account == account else { return }
            let sources = LiveTVEPGSources.shared
            LiveTVGuide.shared.refreshIfNeeded(
                account: account, password: password, channels: channels,
                overrides: LiveTVEPGOverrides.load(), extra: sources.feeds(),
                providerGuide: sources.providerGuide, force: force, reuseDownloads: reuseDownloads)
        }
    }

    // MARK: Groups, favorites, recent, search

    func isFavorite(_ channel: XtreamLiveChannel) -> Bool {
        favoriteIDs.contains(channel.streamID)
    }

    func toggleFavorite(_ channel: XtreamLiveChannel) {
        if let index = favoriteIDs.firstIndex(of: channel.streamID) {
            favoriteIDs.remove(at: index)
        } else {
            favoriteIDs.append(channel.streamID)
        }
        ProfileSettings.current.set(favoriteIDs, forKey: Self.favoritesKey)
        rebuildGroups()
    }

    /// Groups whose channels can be put in your order (not Search or
    /// Recently watched, which have their own order).
    func canReorder(_ groupID: String) -> Bool {
        groupID != LiveTVGroup.searchID && groupID != LiveTVGroup.recentID
    }

    /// Saves the order Reorder Channels left a group in. Favorites keep it
    /// in their own list (ones not shown stay at the end).
    func saveChannelOrder(groupID: String, ids: [Int]) {
        guard canReorder(groupID) else { return }
        if LiveTVCustomGroup.isCustom(groupID) {
            LiveTVChannelEdits.shared.setCustomGroupOrder(id: groupID, shown: ids)
            return
        }
        if groupID == LiveTVGroup.favoritesID {
            let shown = Set(ids)
            let ordered = ids + favoriteIDs.filter { !shown.contains($0) }
            guard ordered != favoriteIDs else { return }
            favoriteIDs = ordered
            ProfileSettings.current.set(favoriteIDs, forKey: Self.favoritesKey)
            rebuildGroups()
            return
        }
        LiveTVChannelEdits.shared.setChannelOrder(groupID: groupID, ids: ids)
    }

    /// Saves the order Reorder Groups left the provider's groups in.
    func saveGroupOrder(_ ids: [String]) {
        LiveTVChannelEdits.shared.setGroupOrder(ids.filter { $0 == LiveTVGroup.otherID || !$0.hasPrefix("__") })
    }

    /// What the provider calls a group (before a rename or cleanup).
    func providerGroupName(_ id: String) -> String {
        if id == LiveTVGroup.otherID { return groupNames.other }
        if let custom = LiveTVChannelEdits.shared.customGroup(id: id) { return custom.name }
        return rawCategories.first { $0.id == id }?.name ?? id
    }

    func channel(id: Int) -> XtreamLiveChannel? {
        channelsByID[id]
    }

    /// Called when a channel starts playing.
    func recordWatched(_ channel: XtreamLiveChannel) {
        var ids = recentIDs.filter { $0 != channel.streamID }
        ids.insert(channel.streamID, at: 0)
        recentIDs = Array(ids.prefix(Self.recentLimit))
        ProfileSettings.current.set(recentIDs, forKey: Self.recentKey)
        // Don't reorder the list under the user while they browse it.
        if selectedGroupID != LiveTVGroup.recentID { rebuildGroups() } else { publishHomeChannels() }
    }

    /// Favorites and recently watched for Home's Live TV row (step 7b),
    /// which has no store of its own.
    private func publishHomeChannels() {
        guard !channelsByID.isEmpty else { return }
        LiveTVHomeRowModel.shared.remember(
            favorites: unlockedChannels(favoriteIDs, locked: savedLockedGroupIDs),
            recent: unlockedChannels(recentIDs, locked: savedLockedGroupIDs))
    }

    func setHidden(_ ids: Set<String>, hidden: Bool) {
        if hidden { hiddenGroupIDs.formUnion(ids) } else { hiddenGroupIDs.subtract(ids) }
        ProfileSettings.current.set(Array(hiddenGroupIDs), forKey: Self.hiddenGroupsKey)
        rebuildGroups()
    }

    /// Searches channel names in the visible groups; an empty query ends the
    /// search.
    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = trimmed
        if trimmed.isEmpty {
            searchResults = []
            if selectedGroupID == LiveTVGroup.searchID { selectedGroupID = LiveTVGroup.allID }
        } else {
            searchResults = allVisible.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
        rebuildGroups()
        if !trimmed.isEmpty { selectedGroupID = LiveTVGroup.searchID }
    }

    private func loadPreferences() {
        let store = ProfileSettings.current
        hiddenGroupIDs = Set(store.stringArray(forKey: Self.hiddenGroupsKey) ?? [])
        favoriteIDs = (store.array(forKey: Self.favoritesKey) as? [Int]) ?? []
        recentIDs = (store.array(forKey: Self.recentKey) as? [Int]) ?? []
    }

    /// Sidebar: Search (while searching), Favorites, Recently watched, All,
    /// then the provider's groups that aren't hidden.
    private func rebuildGroups() {
        lockedGroupIDs = computeLockedGroups()
        savedLockedGroupIDs = LiveTVParentalControls.shared.unlocked.isEmpty
            ? lockedGroupIDs : computeLockedGroups(ignoringUnlocked: true)
        publishHomeChannels()
        let hideSeparators = hidesSeparators
        let separators = separatorIDs
        let locked = lockedGroupIDs
        allVisible = hiddenGroupIDs.isEmpty && !hideSeparators && locked.isEmpty ? channels : channels.filter { channel in
            if hideSeparators, separators.contains(channel.streamID) { return false }
            let group = groupID(of: channel)
            return !hiddenGroupIDs.contains(group) && !locked.contains(group)
        }
        if !searchQuery.isEmpty {
            searchResults = allVisible.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
        var result: [LiveTVGroup] = []
        if !searchQuery.isEmpty {
            result.append(LiveTVGroup(
                id: LiveTVGroup.searchID,
                name: L10n.string("livetv_search_group", fallback: "Search") + ": " + searchQuery,
                count: searchResults.count))
        }
        let favorites = unlockedChannels(favoriteIDs).count
        if favorites > 0 {
            result.append(LiveTVGroup(
                id: LiveTVGroup.favoritesID,
                name: L10n.string("livetv_favorites", fallback: "Favorites"), count: favorites))
        }
        let recent = unlockedChannels(recentIDs).count
        if recent > 0 {
            result.append(LiveTVGroup(
                id: LiveTVGroup.recentID,
                name: L10n.string("livetv_recent", fallback: "Recently watched"), count: recent))
        }
        if !channels.isEmpty {
            result.append(LiveTVGroup(id: LiveTVGroup.allID, name: groupNames.all, count: allVisible.count))
        }
        let provider = categoryGroups.filter { !hiddenGroupIDs.contains($0.id) }.map { group in
            var shown = hideSeparators
                ? LiveTVGroup(id: group.id, name: group.name, count: channelsByGroupWithoutSeparators[group.id]?.count ?? 0)
                : group
            shown.locked = locked.contains(group.id)
            return shown
        }
        // Your own groups first, then the provider's (step 10c); Reorder
        // Groups arranges them together.
        let edits = LiveTVChannelEdits.shared
        let custom = edits.customGroups.map { group in
            LiveTVGroup(
                id: group.id, name: group.name, count: customChannels(group.id).count,
                locked: locked.contains(group.id))
        }
        result += custom.isEmpty ? provider : LiveTVListOrder.ordered(custom + provider, saved: edits.edits.groupOrder, id: \.id)
        groups = result
        if !channels.isEmpty, !result.contains(where: { $0.id == selectedGroupID }) || locked.contains(selectedGroupID) {
            selectedGroupID = LiveTVGroup.allID
        }
    }

    /// Picks up the account of the active profile (profiles can switch while
    /// the app runs).
    func reloadAccount() {
        let stored = XtreamAccountStore.load()
        guard stored != account || needsReload else {
            refreshIfStale()
            return
        }
        needsReload = false
        // The store lives on between visits and profiles: nothing of the
        // last account or profile may stay, and its loads must not land.
        loadTask?.cancel()
        renameTask?.cancel()
        account = stored
        userInfo = nil
        channels = []
        rawCategories = []
        rawChannels = []
        channelsByGroup = [:]
        channelsByID = [:]
        knownCategoryIDs = []
        allVisible = []
        separatorIDs = []
        channelsByGroupWithoutSeparators = [:]
        lockedGroupIDs = []
        savedLockedGroupIDs = []
        allowedFormats = []
        lastUpdated = nil
        categoryGroups = []
        searchQuery = ""
        searchResults = []
        state = .idle
        loadPreferences()
        groups = []
        selectedGroupID = LiveTVGroup.allID
        listRevision &+= 1
        guard let stored else { return }
        // Decoding and sorting a large list blocks for seconds; on the main
        // thread tvOS kills the app (seen with ~56k channels).
        let url = LiveTVCache.fileURL(scope: ProfileSettings.activeProfileScope)
        let names = groupNames
        state = .loading
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) { () -> (LiveTVCache, Prepared)? in
                guard let cache = LiveTVCache.load(from: url), cache.accountID == stored.id else { return nil }
                return (cache, LiveTVStore.prepare(
                    categories: cache.categories, channels: cache.channels, names: names,
                    edits: LiveTVChannelEdits.read()))
            }.value
            guard !Task.isCancelled, let self, self.account == stored, !self.needsReload else { return }
            self.state = .idle
            guard let prepared else {
                self.refresh()
                return
            }
            let (cache, result) = prepared
            self.rawCategories = cache.categories
            self.rawChannels = cache.channels
            self.apply(result)
            self.allowedFormats = cache.userInfoAllowedFormats
            self.lastUpdated = cache.savedAt
            if Date().timeIntervalSince(cache.savedAt) > LiveTVCache.maxAge {
                self.refresh()
            } else {
                self.refreshAccountInfo()
            }
        }
    }

    // MARK: Account

    /// Verifies the login, then saves it and loads the channels.
    func signIn(server: String, username: String, password: String, format: XtreamStreamFormat) async throws {
        let client = XtreamClient(server: server, username: username, password: password)
        let info = try await client.login()
        let normalised = XtreamAccount.normaliseServer(server)
        let account = XtreamAccount(
            id: self.account?.id ?? UUID().uuidString,
            name: URL(string: normalised)?.host ?? normalised,
            server: normalised,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            streamFormat: format
        )
        XtreamAccountStore.save(account, password: password)
        LiveTVCache.clear(scope: ProfileSettings.activeProfileScope)
        self.account = account
        self.userInfo = info
        self.allowedFormats = info.allowedOutputFormats
        // The login was just checked; don't ask the panel for it again.
        refresh(verifiedInfo: info)
    }

    func signOut() {
        loadTask?.cancel()
        XtreamAccountStore.remove()
        LiveTVCache.clear(scope: ProfileSettings.activeProfileScope)
        account = nil
        userInfo = nil
        channels = []
        channelsByGroup = [:]
        channelsByID = [:]
        categoryGroups = []
        allVisible = []
        searchResults = []
        searchQuery = ""
        groups = []
        state = .idle
        lastUpdated = nil
    }

    func password() -> String {
        guard let account else { return "" }
        return XtreamAccountStore.password(for: account)
    }

    // MARK: Loading

    /// Loads account, categories, then channels one after another, like
    /// Android and TiviMate. Several requests at once (right after a login)
    /// made some panels answer HTTP 404; each step also gets one retry.
    /// Live TV opened again with the list kept: a new list from the
    /// provider in the background once the kept one is old.
    private func refreshIfStale() {
        guard state == .idle, !channels.isEmpty, let lastUpdated,
              Date().timeIntervalSince(lastUpdated) > LiveTVCache.maxAge else { return }
        refresh()
    }

    func refresh(verifiedInfo: XtreamUserInfo? = nil) {
        guard let account else { return }
        let password = XtreamAccountStore.password(for: account)
        // Where this account's list is kept, fixed now (the profile may
        // change while it loads).
        let scopeURL = LiveTVCache.fileURL(scope: ProfileSettings.activeProfileScope)
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            let client = XtreamClient(account: account, password: password)
            do {
                let info: XtreamUserInfo
                if let verifiedInfo {
                    info = verifiedInfo
                } else {
                    info = try await Self.withRetry { try await client.login() }
                }
                // Optional, as on Android: without categories everything lands in "Other".
                let categories = (try? await Self.withRetry { try await client.liveCategories() }) ?? []
                let channels = try await Self.withRetry { try await client.liveChannels() }
                let names = await MainActor.run { LiveTVStore.groupNamesValue() }
                let edits = LiveTVChannelEdits.read()
                let prepared = await Task.detached(priority: .userInitiated) {
                    LiveTVStore.prepare(categories: categories, channels: channels, names: names, edits: edits)
                }.value
                guard !Task.isCancelled, let self, self.account == account, !self.needsReload else { return }
                self.renameTask?.cancel()
                self.rawCategories = categories
                self.rawChannels = channels
                self.userInfo = info
                self.allowedFormats = info.allowedOutputFormats
                self.apply(prepared)
                let now = Date()
                self.lastUpdated = now
                self.state = .idle
                let cache = LiveTVCache(
                    accountID: account.id,
                    savedAt: now,
                    userInfoAllowedFormats: info.allowedOutputFormats,
                    categories: categories,
                    channels: channels
                )
                Task.detached(priority: .utility) { cache.save(to: scopeURL) }
            } catch {
                guard !Task.isCancelled, let self, self.account == account else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshAccountInfo() {
        guard let account else { return }
        let client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))
        Task { [weak self] in
            guard let info = try? await client.login(),
                  let self, self.account == account, !self.needsReload else { return }
            self.userInfo = info
            self.allowedFormats = info.allowedOutputFormats
        }
    }

    /// One more try after a short pause for errors that are often momentary
    /// (busy panel, flood protection, network). Wrong logins aren't retried.
    nonisolated static func withRetry<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard isTransient(error) else { throw error }
            try await Task.sleep(for: .seconds(2))
            return try await operation()
        }
    }

    nonisolated static func isTransient(_ error: Error) -> Bool {
        if let xtream = error as? XtreamError {
            if case .badStatus(let code) = xtream {
                return code == 404 || code == 429 || code >= 500
            }
            return xtream == .invalidResponse
        }
        if let url = error as? URLError { return url.code != .cancelled }
        return false
    }

    struct GroupNames: Sendable {
        let all: String
        let other: String
    }

    struct Prepared: Sendable {
        let channels: [XtreamLiveChannel]
        let channelsByGroup: [String: [XtreamLiveChannel]]
        let channelsByID: [Int: XtreamLiveChannel]
        /// stream id → XMLTV channel id (for the full guide).
        let epgIDs: [Int: String]
        /// Provider categories in panel order (+ "Other"), without "All".
        let groups: [LiveTVGroup]
        let knownCategoryIDs: Set<String>
    }

    /// Rows like "##### AT&T #####" that providers put between channels as
    /// headings; they aren't channels.
    nonisolated static func isSeparator(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("###")
            || (trimmed.hasPrefix("--") && trimmed.hasSuffix("--"))
            || (trimmed.hasPrefix("==") && trimmed.hasSuffix("=="))
    }

    private var groupNames: GroupNames { Self.groupNamesValue() }

    static func groupNamesValue() -> GroupNames {
        GroupNames(
            all: L10n.string("livetv_all_channels", fallback: "All channels"),
            other: L10n.string("livetv_other_group", fallback: "Other")
        )
    }

    /// Sorting and grouping; pure, so it runs off the main thread.
    nonisolated static func prepare(
        categories: [XtreamCategory],
        channels: [XtreamLiveChannel],
        names: GroupNames,
        edits: LiveTVNameEdits = .none
    ) -> Prepared {
        // Renamed and cleaned names (step 10a).
        var channels = channels
        let display = edits.isEmpty
            ? [:] : edits.channelDisplayNames(channels.map { (id: $0.streamID, name: $0.name) })
        if !display.isEmpty {
            channels = channels.map { channel in display[channel.streamID].map { channel.shown(as: $0) } ?? channel }
        }
        let terms = LiveTVNameCleaner.terms(edits.removals)
        let groupCleaner = edits.cleanGroups && !terms.isEmpty ? LiveTVNameCleaner.Cleaner(terms: terms) : nil
        let sortedByNumber = channels.enumerated().sorted { lhs, rhs in
            switch (lhs.element.number, rhs.element.number) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        // Your order (step 10b): All channels, then each group.
        let sorted = LiveTVListOrder.ordered(sortedByNumber, saved: edits.channelOrder[LiveTVGroup.allID], id: \.streamID)
        // Separator rows stay in: Live TV's option hides them.
        var byGroup = Dictionary(grouping: sortedByNumber, by: { $0.categoryID ?? "" })
        let byID = Dictionary(sorted.map { ($0.streamID, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [LiveTVGroup] = []
        var known = Set<String>()
        for category in categories {
            let count = byGroup[category.id]?.count ?? 0
            guard count > 0, known.insert(category.id).inserted else { continue }
            result.append(LiveTVGroup(
                id: category.id,
                name: edits.groupDisplayName(id: category.id, name: category.name, cleaner: groupCleaner),
                count: count))
        }
        // Channels whose category the panel didn't list.
        let orphanKeys = byGroup.keys.filter { !known.contains($0) }
        if !orphanKeys.isEmpty {
            var orphans: [XtreamLiveChannel] = []
            for key in orphanKeys { orphans += byGroup[key] ?? [] }
            byGroup[LiveTVGroup.otherID] = orphans
            result.append(LiveTVGroup(
                id: LiveTVGroup.otherID,
                name: edits.groupNames[LiveTVGroup.otherID] ?? names.other, count: orphans.count))
        }
        for (groupID, order) in edits.channelOrder where groupID != LiveTVGroup.allID {
            guard let list = byGroup[groupID] else { continue }
            byGroup[groupID] = LiveTVListOrder.ordered(list, saved: order, id: \.streamID)
        }
        result = LiveTVListOrder.ordered(result, saved: edits.groupOrder, id: \.id)
        var epgIDs: [Int: String] = [:]
        for channel in sorted {
            if let id = channel.epgChannelID, !id.isEmpty { epgIDs[channel.streamID] = id }
        }
        return Prepared(
            channels: sorted, channelsByGroup: byGroup, channelsByID: byID, epgIDs: epgIDs,
            groups: result, knownCategoryIDs: known)
    }

    /// The list again with other names or your order (steps 10a, 10b): the
    /// same channels, so the guide keeps its place and only relabels.
    private func applyNames() {
        guard !rawChannels.isEmpty else { return }
        let categories = rawCategories
        let raw = rawChannels
        let names = groupNames
        let edits = LiveTVChannelEdits.read()
        renameTask?.cancel()
        renameTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                LiveTVStore.prepare(categories: categories, channels: raw, names: names, edits: edits)
            }.value
            guard !Task.isCancelled, let self, self.rawChannels.count == raw.count else { return }
            self.apply(prepared, namesOnly: true)
        }
    }

    private func apply(_ prepared: Prepared, namesOnly: Bool = false) {
        channels = prepared.channels
        channelsByGroup = prepared.channelsByGroup
        channelsByID = prepared.channelsByID
        knownCategoryIDs = prepared.knownCategoryIDs
        separatorIDs = Set(prepared.channels.lazy.filter { Self.isSeparator($0.originalName) }.map(\.streamID))
        rebuildSeparatorLists()
        let restoring = groups.isEmpty
        categoryGroups = prepared.groups
        if namesOnly {
            rebuildGroups()
            return
        }
        listRevision &+= 1
        LiveTVEPG.shared.register(epgIDs: prepared.epgIDs)
        rebuildGroups()
        refreshGuide(force: false)
        if restoring, LiveTVSettings.shared.rememberLastGroup,
           let last = ProfileSettings.current.string(forKey: Self.lastGroupKey),
           groups.contains(where: { $0.id == last }), !lockedGroupIDs.contains(last) {
            selectedGroupID = last
        } else if !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = LiveTVGroup.allID
        }
    }

    private func rebuildSeparatorLists() {
        guard hidesSeparators else {
            channelsByGroupWithoutSeparators = [:]
            return
        }
        let separators = separatorIDs
        channelsByGroupWithoutSeparators = channelsByGroup.mapValues { list in
            list.filter { !separators.contains($0.streamID) }
        }
    }

    // MARK: Playback

    struct PlaybackItem {
        let url: URL
        let meta: NuvioMeta
        let headers: [String: String]
    }

    /// Replay links for a show on a channel with catch-up, the likeliest
    /// first (`LiveTVCatchup.xtreamURLs`).
    func catchupLinks(for channel: XtreamLiveChannel, programme: XtreamProgram) -> (urls: [URL], headers: [String: String])? {
        guard let account, channel.archiveDays > 0 else { return nil }
        let client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))
        let zoneID = userInfo?.serverTimeZone ?? ProfileSettings.current.string(forKey: Self.serverTimeZoneKey)
        let urls = LiveTVCatchup.xtreamURLs(
            server: client.server,
            username: client.username,
            password: client.password,
            streamID: channel.streamID,
            start: programme.start,
            end: programme.end,
            now: Date(),
            fileExtension: XtreamClient.fileExtension(for: account.streamFormat, allowedFormats: allowedFormats),
            serverTimeZone: zoneID.flatMap(TimeZone.init(identifier:)))
        guard !urls.isEmpty else { return nil }
        return (urls, client.httpHeaders)
    }

    func playbackItem(for channel: XtreamLiveChannel) -> PlaybackItem? {
        guard let account else { return nil }
        let client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))
        guard let url = client.liveURL(
            streamID: channel.streamID,
            format: account.streamFormat,
            allowedFormats: allowedFormats
        ) else { return nil }
        return PlaybackItem(url: url, meta: .liveChannel(channel), headers: client.httpHeaders)
    }
}

extension LiveTVGroup {
    static let otherID = "__other__"
}

extension NuvioMeta {
    /// Placeholder meta so a live channel can flow through the player. The
    /// `iptv:` id and `channel` type make the player treat it as live
    /// (`PlayerViewModel.isLiveStream`), which skips resume/scrobbling.
    static func liveChannel(_ channel: XtreamLiveChannel) -> NuvioMeta {
        NuvioMeta(
            id: "iptv:xtream:\(channel.streamID)",
            // The player shows the channel number with the name.
            name: channel.number.map { "\($0)  \(channel.name)" } ?? channel.name,
            description: nil,
            posterUrl: channel.logoURL, backgroundUrl: nil, logoUrl: channel.logoURL,
            imdbId: nil, tmdbId: nil, type: "channel", year: nil, genres: nil,
            rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil,
            writer: nil, certification: nil, country: nil, released: nil
        )
    }
}
