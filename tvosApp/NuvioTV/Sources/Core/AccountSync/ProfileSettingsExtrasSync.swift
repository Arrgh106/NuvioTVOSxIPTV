import Foundation

/// Profile settings that nuvio.tv and Android TV keep in the shared settings
/// blob but upstream NuvioTVOS ignores: Trakt options, Up Next and trailers.
///
/// Reads the `tv` blob first (what nuvio.tv's TV tab and Android TV write) and
/// falls back to the `mobile` blob. Local changes are written back into the
/// `tv` blob's Android features, so nuvio.tv and Android TV see them too.
/// Field names come from NuvioPlusIPTV `data/local/TraktSettingsDataStore.kt`
/// and `TrailerSettingsDataStore.kt`.
@MainActor
enum ProfileSettingsExtrasSync {
    private enum ValueType: String { case string, boolean, int }

    private struct Field {
        let feature: String
        let key: String
        let type: ValueType
        let settingsKey: String
    }

    /// `tv` blob features (Android TV / nuvio.tv TV tab).
    private static let tvFields: [Field] = [
        Field(feature: "trakt_settings", key: "watch_progress_source", type: .string, settingsKey: SettingsKey.traktWatchProgressSource),
        Field(feature: "trakt_settings", key: "library_source_mode", type: .string, settingsKey: SettingsKey.traktLibrarySourceMode),
        Field(feature: "trakt_settings", key: "more_like_this_source", type: .string, settingsKey: SettingsKey.traktMoreLikeThisSource),
        Field(feature: "trakt_settings", key: "continue_watching_days_cap", type: .int, settingsKey: SettingsKey.traktContinueWatchingDaysCap),
        Field(feature: "trakt_settings", key: "show_meta_comments", type: .boolean, settingsKey: SettingsKey.traktShowMetaComments),
        Field(feature: "trakt_settings", key: "show_unaired_next_up", type: .boolean, settingsKey: SettingsKey.showUnairedNextUp),
        Field(feature: "trakt_settings", key: "next_up_from_furthest_episode", type: .boolean, settingsKey: SettingsKey.upNextFromFurthestEpisode),
        Field(feature: "trailer_settings", key: "trailer_enabled", type: .boolean, settingsKey: SettingsKey.trailersEnabled),
        Field(feature: "trailer_settings", key: "trailer_delay_seconds", type: .int, settingsKey: SettingsKey.trailerDelay)
    ]

    /// `mobile` blob fallbacks: `trakt_settings_payload` is a JSON string with
    /// camelCase keys; comments live in their own feature.
    private static let mobilePayloadFields: [(key: String, settingsKey: String)] = [
        ("watchProgressSource", SettingsKey.traktWatchProgressSource),
        ("librarySourceMode", SettingsKey.traktLibrarySourceMode),
        ("moreLikeThisSource", SettingsKey.traktMoreLikeThisSource),
        ("continueWatchingDaysCap", SettingsKey.traktContinueWatchingDaysCap)
    ]

    private static let baselinePrefix = "nuvio.tv.accountSync.settingsExtras.baseline"

    // MARK: - Pull

    static func pull(
        session: AuthSession,
        remoteProfileId: Int,
        localProfileId: String,
        ensureValid: () throws -> Void
    ) async throws {
        try ensureValid()
        guard ProfileSettings.activeProfileID == localProfileId else { return }
        let store = ProfileSettings.store(for: localProfileId)
        let baselineKey = "\(baselinePrefix).\(session.userId).\(remoteProfileId)"

        // Local edits since the last sync win: push them instead.
        if let baseline = store.string(forKey: baselineKey), baseline != fingerprint(store) {
            try await push(session: session, remoteProfileId: remoteProfileId, store: store, ensureValid: ensureValid)
            store.set(fingerprint(store), forKey: baselineKey)
            return
        }

        async let tvRequest = pullBlob(session: session, remoteProfileId: remoteProfileId, platform: "tv")
        async let mobileRequest = pullBlob(session: session, remoteProfileId: remoteProfileId, platform: "mobile")
        let tvFeatures = (try await tvRequest)?["features"] as? [String: Any] ?? [:]
        let mobileFeatures = (try? await mobileRequest)?["features"] as? [String: Any] ?? [:]
        try ensureValid()

        var values: [String: Any] = [:]
        if let payload = jsonObject(mobileFeatures["trakt_settings_payload"]) {
            for (key, settingsKey) in mobilePayloadFields {
                if let value = payload[key] { values[settingsKey] = value }
            }
        }
        if let comments = mobileFeatures["trakt_comments_settings"] as? [String: Any],
           let value = decode(comments["comments_enabled"], as: .boolean) {
            values[SettingsKey.traktShowMetaComments] = value
        }
        for field in tvFields {
            guard let feature = tvFeatures[field.feature] as? [String: Any],
                  let value = decode(feature[field.key], as: field.type) else { continue }
            values[field.settingsKey] = value
        }
        apply(values, to: store)
        store.set(fingerprint(store), forKey: baselineKey)
    }

    /// After an upstream settings push: write local changes of these fields
    /// back to the account.
    static func pushIfChanged(
        session: AuthSession,
        remoteProfileId: Int,
        localProfileId: String,
        ensureValid: () throws -> Void
    ) async throws {
        try ensureValid()
        guard ProfileSettings.activeProfileID == localProfileId else { return }
        let store = ProfileSettings.store(for: localProfileId)
        let baselineKey = "\(baselinePrefix).\(session.userId).\(remoteProfileId)"
        guard let baseline = store.string(forKey: baselineKey), baseline != fingerprint(store) else { return }
        try await push(session: session, remoteProfileId: remoteProfileId, store: store, ensureValid: ensureValid)
        store.set(fingerprint(store), forKey: baselineKey)
    }

    // MARK: - Apply

    private static func apply(_ values: [String: Any], to store: UserDefaults) {
        for (settingsKey, value) in values {
            switch settingsKey {
            case SettingsKey.traktWatchProgressSource:
                guard let raw = value as? String,
                      let source = TraktWatchProgressSource(rawValue: raw.uppercased()),
                      isUsable(source, in: store),
                      TraktSettingsStore.watchProgressSource(in: store) != source else { continue }
                TraktSettingsStore.watchProgressSource = source
            case SettingsKey.traktLibrarySourceMode:
                guard let raw = value as? String,
                      let mode = TraktLibrarySourceMode(rawValue: raw.uppercased()),
                      mode == .local || TraktWatchProgressSource(rawValue: mode.rawValue).map({ isUsable($0, in: store) }) == true,
                      TraktSettingsStore.librarySourceMode(in: store) != mode else { continue }
                TraktSettingsStore.librarySourceMode = mode
            case SettingsKey.traktMoreLikeThisSource:
                guard let raw = value as? String,
                      TraktMoreLikeThisSource(rawValue: raw.uppercased()) != nil else { continue }
                store.set(raw.uppercased(), forKey: settingsKey)
            case SettingsKey.traktContinueWatchingDaysCap:
                guard let days = (value as? NSNumber)?.intValue else { continue }
                let normalised = days == TraktDefaults.continueWatchingDaysCapAll ? days : min(max(days, 7), 365)
                store.set(normalised, forKey: settingsKey)
            case SettingsKey.trailerDelay:
                guard let seconds = (value as? NSNumber)?.intValue else { continue }
                store.set(min(max(seconds, 0), 60), forKey: settingsKey)
            default:
                if let bool = value as? Bool { store.set(bool, forKey: settingsKey) }
            }
        }
    }

    /// Only switch to a tracker this Apple TV is signed in to. Otherwise the
    /// Android default "TRAKT" would empty Continue Watching here until Trakt
    /// is connected; the next sync applies it once it is.
    private static func isUsable(_ source: TraktWatchProgressSource, in store: UserDefaults) -> Bool {
        source == .nuvioSync || RemoteTrackingState.isProgressSourceAuthenticated(source, in: store)
    }

    // MARK: - Push

    private static func push(
        session: AuthSession,
        remoteProfileId: Int,
        store: UserDefaults,
        ensureValid: () throws -> Void
    ) async throws {
        var blob = try await pullBlob(session: session, remoteProfileId: remoteProfileId, platform: "tv") ?? [:]
        try ensureValid()
        var features = blob["features"] as? [String: Any] ?? [:]
        for field in tvFields {
            guard let value = store.object(forKey: field.settingsKey) else { continue }
            var feature = features[field.feature] as? [String: Any] ?? [:]
            feature[field.key] = encode(value, as: field.type)
            features[field.feature] = feature
        }
        blob["features"] = features
        _ = try await AccountSyncRPC.call(
            "sync_push_profile_settings_blob",
            session: session,
            params: ["p_profile_id": remoteProfileId, "p_settings_json": blob, "p_platform": "tv"]
        )
    }

    // MARK: - Helpers

    private static func pullBlob(session: AuthSession, remoteProfileId: Int, platform: String) async throws -> [String: Any]? {
        let raw = try await AccountSyncRPC.call(
            "sync_pull_profile_settings_blob",
            session: session,
            params: ["p_profile_id": remoteProfileId, "p_platform": platform]
        )
        if let rows = raw as? [[String: Any]] { return rows.first?["settings_json"] as? [String: Any] }
        if let row = raw as? [String: Any] { return row["settings_json"] as? [String: Any] }
        return nil
    }

    private static func decode(_ raw: Any?, as type: ValueType) -> Any? {
        let value: Any?
        if let encoded = raw as? [String: Any] { value = encoded["value"] } else { value = raw }
        switch type {
        case .string: return value as? String
        case .boolean:
            if let bool = value as? Bool { return bool }
            if let string = value as? String { return ["true": true, "false": false][string.lowercased()] }
            return nil
        case .int:
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        }
    }

    private static func encode(_ value: Any, as type: ValueType) -> [String: Any] {
        switch type {
        case .string: return ["type": "string", "value": "\(value)"]
        case .boolean: return ["type": "boolean", "value": (value as? Bool) ?? false]
        case .int: return ["type": "int", "value": (value as? NSNumber)?.intValue ?? 0]
        }
    }

    private static func jsonObject(_ raw: Any?) -> [String: Any]? {
        if let object = raw as? [String: Any] {
            if let value = object["value"] as? String { return jsonObject(value) }
            return object
        }
        guard let string = raw as? String, let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func fingerprint(_ store: UserDefaults) -> String {
        var values: [String: Any] = [:]
        for field in tvFields {
            if let value = store.object(forKey: field.settingsKey) { values[field.settingsKey] = "\(value)" }
        }
        return AccountSyncFingerprint.of(values)
    }
}
