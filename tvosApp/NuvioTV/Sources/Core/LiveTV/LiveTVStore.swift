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
    let id: String
    let name: String
    let count: Int
}

@MainActor
final class LiveTVStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    @Published private(set) var account: XtreamAccount?
    @Published private(set) var userInfo: XtreamUserInfo?
    @Published private(set) var groups: [LiveTVGroup] = []
    @Published private(set) var state: LoadState = .idle
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

    private var allowedFormats: [String] = []
    private var channels: [XtreamLiveChannel] = []
    private var channelsByGroup: [String: [XtreamLiveChannel]] = [:]
    private var loadTask: Task<Void, Never>?

    init() {
        reloadAccount()
    }

    var hasAccount: Bool { account != nil }

    var visibleChannels: [XtreamLiveChannel] {
        if selectedGroupID == LiveTVGroup.allID { return channels }
        return channelsByGroup[selectedGroupID] ?? []
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
        refresh()
    }

    func signOut() {
        loadTask?.cancel()
        XtreamAccountStore.remove()
        LiveTVCache.clear(scope: ProfileSettings.activeProfileScope)
        account = nil
        userInfo = nil
        channels = []
        channelsByGroup = [:]
        groups = []
        state = .idle
        lastUpdated = nil
    }

    func password() -> String {
        guard let account else { return "" }
        return XtreamAccountStore.password(for: account)
    }

    // MARK: Loading

    func refresh() {
        guard let account else { return }
        let password = XtreamAccountStore.password(for: account)
        loadTask?.cancel()
        state = .loading
        loadTask = Task { [weak self] in
            let client = XtreamClient(account: account, password: password)
            do {
                async let infoResult = client.login()
                async let categoriesResult = client.liveCategories()
                async let channelsResult = client.liveChannels()
                let (info, categories, channels) = try await (infoResult, categoriesResult, channelsResult)
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

    struct GroupNames: Sendable {
        let all: String
        let other: String
    }

    struct Prepared: Sendable {
        let channels: [XtreamLiveChannel]
        let channelsByGroup: [String: [XtreamLiveChannel]]
        let groups: [LiveTVGroup]
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
        var byGroup = Dictionary(grouping: sorted, by: { $0.categoryID ?? "" })

        var result = [LiveTVGroup(id: LiveTVGroup.allID, name: names.all, count: sorted.count)]
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
        return Prepared(channels: sorted, channelsByGroup: byGroup, groups: result)
    }

    private func apply(_ prepared: Prepared) {
        channels = prepared.channels
        channelsByGroup = prepared.channelsByGroup
        let restoring = groups.isEmpty
        groups = prepared.groups
        listRevision &+= 1
        if restoring, let last = ProfileSettings.current.string(forKey: Self.lastGroupKey),
           groups.contains(where: { $0.id == last }) {
            selectedGroupID = last
        } else if !groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = LiveTVGroup.allID
        }
    }

    // MARK: Playback

    struct PlaybackItem {
        let url: URL
        let meta: NuvioMeta
        let headers: [String: String]
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
