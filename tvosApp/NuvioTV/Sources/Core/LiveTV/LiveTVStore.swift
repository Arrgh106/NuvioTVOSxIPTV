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

    /// Favorites, Recently watched, Search and All: built by the app, not
    /// provider categories (can't be hidden).
    var isSpecial: Bool { id.hasPrefix("__") && id != LiveTVGroup.otherID }
}

@MainActor
final class LiveTVStore: ObservableObject {
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
    }

    var hasAccount: Bool { account != nil }

    var visibleChannels: [XtreamLiveChannel] {
        channels(inGroup: selectedGroupID)
    }

    /// The channels a group shows (also for groups not selected, e.g. the
    /// guide over the full-screen picture).
    func channels(inGroup groupID: String) -> [XtreamLiveChannel] {
        switch groupID {
        case LiveTVGroup.allID: return allVisible
        case LiveTVGroup.favoritesID: return favoriteIDs.compactMap { channelsByID[$0] }
        case LiveTVGroup.recentID: return recentIDs.compactMap { channelsByID[$0] }
        case LiveTVGroup.searchID: return searchResults
        default: return (hidesSeparators ? channelsByGroupWithoutSeparators : channelsByGroup)[groupID] ?? []
        }
    }

    // MARK: Full guide

    /// Loads the provider's XMLTV guide for the channels in visible groups
    /// (in the background; the set is built off the main thread).
    func refreshGuide(force: Bool) {
        guard let account else { return }
        let password = XtreamAccountStore.password(for: account)
        let visible = allVisible
        Task { [weak self] in
            let ids = await Task.detached(priority: .utility) {
                Set(visible.compactMap { channel -> String? in
                    guard let id = channel.epgChannelID, !id.isEmpty else { return nil }
                    return id.lowercased()
                })
            }.value
            guard let self, self.account == account else { return }
            LiveTVGuide.shared.refreshIfNeeded(account: account, password: password, epgIDs: ids, force: force)
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
            favorites: favoriteIDs.compactMap { channelsByID[$0] },
            recent: recentIDs.compactMap { channelsByID[$0] })
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
        publishHomeChannels()
        let hideSeparators = hidesSeparators
        let separators = separatorIDs
        allVisible = hiddenGroupIDs.isEmpty && !hideSeparators ? channels : channels.filter { channel in
            if hideSeparators, separators.contains(channel.streamID) { return false }
            let category = channel.categoryID ?? ""
            let group = knownCategoryIDs.contains(category) ? category : LiveTVGroup.otherID
            return !hiddenGroupIDs.contains(group)
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
        let favorites = favoriteIDs.filter { channelsByID[$0] != nil }.count
        if favorites > 0 {
            result.append(LiveTVGroup(
                id: LiveTVGroup.favoritesID,
                name: L10n.string("livetv_favorites", fallback: "Favorites"), count: favorites))
        }
        let recent = recentIDs.filter { channelsByID[$0] != nil }.count
        if recent > 0 {
            result.append(LiveTVGroup(
                id: LiveTVGroup.recentID,
                name: L10n.string("livetv_recent", fallback: "Recently watched"), count: recent))
        }
        if !channels.isEmpty {
            result.append(LiveTVGroup(id: LiveTVGroup.allID, name: groupNames.all, count: allVisible.count))
        }
        result += categoryGroups.filter { !hiddenGroupIDs.contains($0.id) }.map { group in
            guard hideSeparators else { return group }
            return LiveTVGroup(id: group.id, name: group.name, count: channelsByGroupWithoutSeparators[group.id]?.count ?? 0)
        }
        groups = result
        if !channels.isEmpty, !result.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = LiveTVGroup.allID
        }
    }

    /// Picks up the account of the active profile (profiles can switch while
    /// the app runs).
    func reloadAccount() {
        let stored = XtreamAccountStore.load()
        guard stored != account else { return }
        account = stored
        userInfo = nil
        channels = []
        channelsByGroup = [:]
        channelsByID = [:]
        categoryGroups = []
        searchQuery = ""
        searchResults = []
        loadPreferences()
        groups = []
        selectedGroupID = LiveTVGroup.allID
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
                return (cache, LiveTVStore.prepare(categories: cache.categories, channels: cache.channels, names: names))
            }.value
            guard !Task.isCancelled, let self, self.account == stored else { return }
            self.state = .idle
            guard let prepared else {
                self.refresh()
                return
            }
            let (cache, result) = prepared
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
    func refresh(verifiedInfo: XtreamUserInfo? = nil) {
        guard let account else { return }
        let password = XtreamAccountStore.password(for: account)
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
                let scopeURL = await MainActor.run { LiveTVCache.fileURL(scope: ProfileSettings.activeProfileScope) }
                let names = await MainActor.run { LiveTVStore.groupNamesValue() }
                let prepared = await Task.detached(priority: .userInitiated) {
                    LiveTVStore.prepare(categories: categories, channels: channels, names: names)
                }.value
                guard !Task.isCancelled, let self else { return }
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
                guard !Task.isCancelled, let self else { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshAccountInfo() {
        guard let account else { return }
        let client = XtreamClient(account: account, password: XtreamAccountStore.password(for: account))
        Task { [weak self] in
            guard let info = try? await client.login() else { return }
            self?.userInfo = info
            self?.allowedFormats = info.allowedOutputFormats
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
        names: GroupNames
    ) -> Prepared {
        let sorted = channels.enumerated().sorted { lhs, rhs in
            switch (lhs.element.number, rhs.element.number) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
        // Separator rows stay in: Live TV's option hides them.
        var byGroup = Dictionary(grouping: sorted, by: { $0.categoryID ?? "" })
        let byID = Dictionary(sorted.map { ($0.streamID, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [LiveTVGroup] = []
        var known = Set<String>()
        for category in categories {
            let count = byGroup[category.id]?.count ?? 0
            guard count > 0, known.insert(category.id).inserted else { continue }
            result.append(LiveTVGroup(id: category.id, name: category.name, count: count))
        }
        // Channels whose category the panel didn't list.
        let orphanKeys = byGroup.keys.filter { !known.contains($0) }
        if !orphanKeys.isEmpty {
            var orphans: [XtreamLiveChannel] = []
            for key in orphanKeys { orphans += byGroup[key] ?? [] }
            byGroup[LiveTVGroup.otherID] = orphans
            result.append(LiveTVGroup(id: LiveTVGroup.otherID, name: names.other, count: orphans.count))
        }
        var epgIDs: [Int: String] = [:]
        for channel in sorted {
            if let id = channel.epgChannelID, !id.isEmpty { epgIDs[channel.streamID] = id }
        }
        return Prepared(
            channels: sorted, channelsByGroup: byGroup, channelsByID: byID, epgIDs: epgIDs,
            groups: result, knownCategoryIDs: known)
    }

    private func apply(_ prepared: Prepared) {
        channels = prepared.channels
        channelsByGroup = prepared.channelsByGroup
        channelsByID = prepared.channelsByID
        knownCategoryIDs = prepared.knownCategoryIDs
        separatorIDs = Set(prepared.channels.lazy.filter { Self.isSeparator($0.name) }.map(\.streamID))
        rebuildSeparatorLists()
        let restoring = groups.isEmpty
        categoryGroups = prepared.groups
        listRevision &+= 1
        LiveTVEPG.shared.register(epgIDs: prepared.epgIDs)
        rebuildGroups()
        refreshGuide(force: false)
        if restoring, LiveTVSettings.shared.rememberLastGroup,
           let last = ProfileSettings.current.string(forKey: Self.lastGroupKey),
           groups.contains(where: { $0.id == last }) {
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
