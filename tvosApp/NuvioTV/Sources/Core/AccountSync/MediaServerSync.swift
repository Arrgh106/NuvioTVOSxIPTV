import CryptoKit
import Foundation

/// Syncs Jellyfin servers with the Nuvio account's media servers
/// (`sync_pull_media_servers` / `sync_push_media_servers`), so a server added
/// on nuvio.tv or on Android TV shows up here and the other way round.
///
/// Ported from NuvioPlusIPTV `core/sync/MediaServerSyncService.kt` and
/// `data/mediaserver/ServerSync.kt`. Servers of other providers (Emby, Plex)
/// are kept on the account untouched, since this app only has a Jellyfin
/// client.
@MainActor
enum MediaServerSync {
    private static let provider = "jellyfin"
    private static let stateKeyPrefix = "nuvio.tv.accountSync.mediaServers"
    private static var isRunning = false

    /// Bookkeeping per account + remote profile, kept in the profile store.
    private struct State: Codable {
        /// Local server id → remote key (`provider|server id|user id`).
        var links: [String: String] = [:]
        /// Remote keys present after the last successful sync. `nil` before
        /// the first sync on this device.
        var syncedKeys: [String]?
        /// Fingerprint of the local servers after the last successful sync.
        var baseline: String?
    }

    /// Pull, merge and push when needed. Local edits made since the last sync
    /// win; otherwise the account wins.
    static func sync(
        session: AuthSession,
        remoteProfileId: Int,
        localProfileId: String,
        ensureValid: () throws -> Void
    ) async throws {
        try ensureValid()
        guard !isRunning, ProfileSettings.activeProfileID == localProfileId else { return }
        isRunning = true
        defer { isRunning = false }

        let store = ProfileSettings.store(for: localProfileId)
        let stateKey = "\(stateKeyPrefix).\(session.userId).\(remoteProfileId)"
        var state = loadState(store, key: stateKey)

        JellyfinServerStore.shared.reload()
        let local = JellyfinServerStore.shared.servers
        let localChanged = state.baseline != nil && state.baseline != fingerprint(local, profileScope: localProfileId)

        let remoteAll = try await pull(session: session, remoteProfileId: remoteProfileId)
        try ensureValid()
        let remoteOthers = (remoteAll ?? []).filter { providerID(of: $0) != provider }
        let remoteJellyfin = (remoteAll ?? []).filter { providerID(of: $0) == provider }
        let syncedKeys = state.syncedKeys.map(Set.init)

        var target: [[String: Any]]
        var needsPush = false

        if localChanged {
            // Local edits win. Keep servers that another device added since
            // our last sync; drop the ones removed here.
            let localEntries = await remoteEntries(for: local, state: state, remote: remoteJellyfin, profileScope: localProfileId)
            let localKeys = Set(localEntries.compactMap(key(of:)))
            let addedElsewhere = remoteJellyfin.filter { entry in
                guard let key = key(of: entry) else { return false }
                return !localKeys.contains(key) && !(syncedKeys?.contains(key) ?? false)
            }
            target = localEntries + addedElsewhere
            needsPush = true
        } else {
            target = remoteJellyfin
            let remoteKeys = Set(remoteJellyfin.compactMap(key(of:)))
            // Servers added on this device that the account doesn't know yet.
            let unsynced = local.filter { server in
                guard let link = state.links[server.id] else { return !matchesRemote(server, remoteJellyfin) }
                return remoteAll == nil && !remoteKeys.contains(link)
            }
            if !unsynced.isEmpty {
                let entries = await remoteEntries(for: unsynced, state: state, remote: remoteJellyfin, profileScope: localProfileId)
                target += entries.filter { entry in
                    guard let key = key(of: entry) else { return false }
                    return !remoteKeys.contains(key)
                }
                needsPush = true
            }
        }

        // Converting local servers talks to the Jellyfin servers, so check
        // again before uploading anything.
        try ensureValid()
        if needsPush {
            try await push(remoteOthers + target, session: session, remoteProfileId: remoteProfileId)
            try ensureValid()
        }

        let didChange = await apply(target, removeMissing: remoteAll != nil || localChanged, state: &state, profileScope: localProfileId)
        state.syncedKeys = target.compactMap(key(of:))
        state.baseline = fingerprint(JellyfinServerStore.shared.servers, profileScope: localProfileId)
        saveState(state, store, key: stateKey)

        if didChange {
            await JellyfinSessionManager.shared.connectAll(autoSync: true)
        }
    }

    /// Runs a sync only when the Jellyfin servers changed locally since the
    /// last sync. Called after a settings push.
    static func pushIfChanged(
        session: AuthSession,
        remoteProfileId: Int,
        localProfileId: String,
        ensureValid: () throws -> Void
    ) async throws {
        try ensureValid()
        guard ProfileSettings.activeProfileID == localProfileId else { return }
        let store = ProfileSettings.store(for: localProfileId)
        let state = loadState(store, key: "\(stateKeyPrefix).\(session.userId).\(remoteProfileId)")
        guard let baseline = state.baseline else { return }
        guard baseline != fingerprint(JellyfinServerStore.shared.servers, profileScope: localProfileId) else { return }
        try await sync(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId, ensureValid: ensureValid)
    }

    // MARK: - Apply remote → local

    /// Returns true when servers were added, removed or their connection
    /// details changed.
    private static func apply(
        _ entries: [[String: Any]],
        removeMissing: Bool,
        state: inout State,
        profileScope: String
    ) async -> Bool {
        let serverStore = JellyfinServerStore.shared
        var changed = false
        var keptIDs = Set<String>()
        var claimed = Set<String>()

        for entry in entries {
            guard let key = key(of: entry),
                  let address = (entry["address"] as? String).map(normaliseAddress),
                  !address.isEmpty else { continue }
            let remoteUserID = entry["remote_user_id"] as? String ?? ""
            let existing = serverStore.servers.first { server in
                !claimed.contains(server.id) && state.links[server.id] == key
            } ?? serverStore.servers.first { server in
                !claimed.contains(server.id) && state.links[server.id] == nil
                    && normaliseAddress(server.baseURLString) == address
                    && (server.userId.isEmpty || server.userId == remoteUserID)
            }

            let id = existing?.id ?? (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let libraries = entry["libraries"] as? [[String: Any]] ?? []
            var server = existing ?? JellyfinServerConfig(id: id, displayName: "", baseURLString: address, authKind: .login)
            server.displayName = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? address
            server.baseURLString = address
            server.username = entry["user_name"] as? String ?? server.username
            server.userId = remoteUserID.isEmpty ? server.userId : remoteUserID
            server.selectedLibraryIDs = libraries.compactMap { library in
                (library["selected"] as? Bool ?? false) ? library["id"] as? String : nil
            }
            if let enabled = entry["enabled"] as? Bool, existing == nil {
                server.syncAutomatically = enabled
            }

            let token = entry["token"] as? String ?? ""
            let tokenChanged = !token.isEmpty
                && token != JellyfinCredentialStore.token(forServerID: id, profileScope: profileScope)
            if tokenChanged {
                JellyfinCredentialStore.save(token, forServerID: id, profileScope: profileScope)
            }
            var serverChanged = tokenChanged
            if server != existing {
                serverChanged = serverChanged || existing == nil
                    || existing?.baseURLString != server.baseURLString
                    || existing?.userId != server.userId
                    || existing?.selectedLibraryIDs != server.selectedLibraryIDs
                serverStore.upsert(server)
            }
            if serverChanged {
                changed = true
                // Reconnect with the new details on the next connectAll().
                if existing != nil { await JellyfinSessionManager.shared.disconnect(server) }
            }

            state.links[id] = key
            keptIDs.insert(id)
            claimed.insert(id)
        }

        if removeMissing {
            for server in serverStore.servers where state.links[server.id] != nil && !keptIDs.contains(server.id) {
                serverStore.remove(server.id)
                state.links[server.id] = nil
                changed = true
            }
        }
        state.links = state.links.filter { id, _ in serverStore.servers.contains { $0.id == id } }
        return changed
    }

    private static func matchesRemote(_ server: JellyfinServerConfig, _ remote: [[String: Any]]) -> Bool {
        remote.contains { entry in
            normaliseAddress(entry["address"] as? String ?? "") == normaliseAddress(server.baseURLString)
                && (server.userId.isEmpty || server.userId == (entry["remote_user_id"] as? String ?? ""))
        }
    }

    // MARK: - Local → remote

    private static func remoteEntries(
        for servers: [JellyfinServerConfig],
        state: State,
        remote: [[String: Any]],
        profileScope: String
    ) async -> [[String: Any]] {
        var entries: [[String: Any]] = []
        for server in servers {
            let linkedKey = state.links[server.id]
            let existing = remote.first { linkedKey != nil && key(of: $0) == linkedKey }
                ?? remote.first { entry in
                    normaliseAddress(entry["address"] as? String ?? "") == normaliseAddress(server.baseURLString)
                        && (entry["remote_user_id"] as? String ?? "") == server.userId
                }
            var entry = existing ?? [:]
            let token = JellyfinCredentialStore.token(forServerID: server.id, profileScope: profileScope)

            var serverID = entry["remote_server_id"] as? String ?? ""
            if serverID.isEmpty, let key = linkedKey {
                serverID = key.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
            }
            if serverID.isEmpty, let baseURL = server.baseURL {
                serverID = (try? await publicServerID(baseURL: baseURL)) ?? ""
            }
            // Without the server id the entry would not match on Android; try
            // again on the next sync instead of uploading a broken entry.
            guard !serverID.isEmpty, !server.userId.isEmpty, !token.isEmpty else { continue }

            entry["id"] = (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? server.id
            entry["provider_id"] = provider
            entry["name"] = server.displayName
            entry["address"] = normaliseAddress(server.baseURLString)
            entry["remote_server_id"] = serverID
            entry["remote_user_id"] = server.userId
            entry["user_name"] = server.username
            entry["token"] = token
            entry["libraries"] = await libraries(for: server, token: token, cached: entry["libraries"] as? [[String: Any]] ?? [])
            if entry["enabled"] == nil { entry["enabled"] = true }
            if entry["use_catalog_metadata"] == nil { entry["use_catalog_metadata"] = false }
            entries.append(entry)
        }
        return entries
    }

    private static func libraries(
        for server: JellyfinServerConfig,
        token: String,
        cached: [[String: Any]]
    ) async -> [[String: Any]] {
        let selected = Set(server.selectedLibraryIDs)
        if let baseURL = server.baseURL,
           let views = try? await JellyfinClient(baseURL: baseURL, accessToken: token).libraries(userId: server.userId) {
            return views.compactMap { view in
                guard let kind = libraryKind(view.collectionType) else { return nil }
                return ["id": view.id, "name": view.name, "kind": kind, "selected": selected.contains(view.id)]
            }
        }
        // Server not reachable right now: reuse what the account knows and
        // only update the selection.
        var result = cached.map { library -> [String: Any] in
            var copy = library
            copy["selected"] = selected.contains(library["id"] as? String ?? "")
            return copy
        }
        let known = Set(cached.compactMap { $0["id"] as? String })
        for id in server.selectedLibraryIDs where !known.contains(id) {
            result.append(["id": id, "name": "", "kind": "mixed", "selected": true])
        }
        return result
    }

    /// Same mapping as Android's `libraryKind` in `MediaBrowserMapper.kt`.
    private static func libraryKind(_ collectionType: String?) -> String? {
        switch collectionType?.lowercased() {
        case "movies": return "movie"
        case "tvshows": return "series"
        case "boxsets": return "collection"
        case nil, "", "mixed": return "mixed"
        default: return nil
        }
    }

    private static func publicServerID(baseURL: URL) async throws -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("System/Info/Public"))
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["Id"] as? String
    }

    // MARK: - Remote calls

    private static func pull(session: AuthSession, remoteProfileId: Int) async throws -> [[String: Any]]? {
        let raw = try await AccountSyncRPC.call(
            "sync_pull_media_servers",
            session: session,
            params: ["p_profile_id": remoteProfileId]
        )
        guard let rows = raw as? [[String: Any]], let first = rows.first else { return nil }
        return first["servers_json"] as? [[String: Any]] ?? []
    }

    private static func push(_ servers: [[String: Any]], session: AuthSession, remoteProfileId: Int) async throws {
        _ = try await AccountSyncRPC.call(
            "sync_push_media_servers",
            session: session,
            params: ["p_profile_id": remoteProfileId, "p_servers": servers]
        )
    }

    // MARK: - Helpers

    private static func providerID(of entry: [String: Any]) -> String {
        (entry["provider_id"] as? String ?? "").lowercased()
    }

    private static func key(of entry: [String: Any]) -> String? {
        let serverID = entry["remote_server_id"] as? String ?? ""
        let userID = entry["remote_user_id"] as? String ?? ""
        guard !serverID.isEmpty || !userID.isEmpty else { return nil }
        return "\(providerID(of: entry))|\(serverID)|\(userID)"
    }

    private static func normaliseAddress(_ value: String) -> String {
        var address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }

    private static func fingerprint(_ servers: [JellyfinServerConfig], profileScope: String) -> String {
        let items: [[String: Any]] = servers.sorted { $0.id < $1.id }.map { server in
            let token = JellyfinCredentialStore.token(forServerID: server.id, profileScope: profileScope)
            let tokenHash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
            return [
                "id": server.id,
                "name": server.displayName,
                "address": normaliseAddress(server.baseURLString),
                "user": server.username,
                "userId": server.userId,
                "libraries": server.selectedLibraryIDs.sorted(),
                "token": tokenHash
            ]
        }
        return AccountSyncFingerprint.of(items)
    }

    private static func loadState(_ store: UserDefaults, key: String) -> State {
        guard let data = store.data(forKey: key),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private static func saveState(_ state: State, _ store: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(state) {
            store.set(data, forKey: key)
        }
    }
}
