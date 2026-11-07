import Foundation

/// Syncs API keys with the Nuvio account's provider credentials
/// (`sync_pull_provider_credentials` / `sync_push_provider_credentials`).
///
/// nuvio.tv and the Android apps keep these keys out of the profile settings
/// blob and store them per profile in their own table. Upstream NuvioTVOS
/// only reads the old blob fields, so keys entered on nuvio.tv never reached
/// the Apple TV. Ported from NuvioPlusIPTV
/// `core/sync/ProviderCredentialSyncService.kt`.
enum ProviderCredentialSync {
    struct Mapping {
        let provider: String
        let field: String
        let settingsKey: String
    }

    /// Providers this app has a setting for. AnimeSkip and IntroDB keys are
    /// left alone: the Apple TV app has no setting for them, and leaving them
    /// out of the push keeps the account's values untouched.
    static let mappings: [Mapping] = [
        Mapping(provider: "tmdb", field: "api_key", settingsKey: SettingsKey.tmdbApiKey),
        Mapping(provider: "mdblist", field: "api_key", settingsKey: SettingsKey.mdbListApiKey),
        Mapping(provider: "debrid:torbox", field: "api_key", settingsKey: SettingsKey.torboxAccessToken),
        Mapping(provider: "debrid:premiumize", field: "api_key", settingsKey: SettingsKey.premiumizeAccessToken),
        Mapping(provider: "debrid:realdebrid", field: "api_key", settingsKey: SettingsKey.realDebridAccessToken)
    ]

    private static let baselineKey = "nuvio.tv.accountSync.providerCredentials.baseline"

    /// Pull, merge and (when needed) push. Local edits made since the last
    /// sync win; otherwise the account wins. Must run while the profile's
    /// settings store is the one being synced.
    static func sync(session: AuthSession, remoteProfileId: Int, localProfileId: String) async throws {
        let store = ProfileSettings.store(for: localProfileId)
        let local = snapshot(in: store)
        let baselineFingerprint = store.string(forKey: baselineKey(for: session, remoteProfileId))
        let localChanged = baselineFingerprint != nil && baselineFingerprint != AccountSyncFingerprint.of(local)

        if localChanged {
            try await push(local, session: session, remoteProfileId: remoteProfileId)
        }

        let rows = try await pull(session: session, remoteProfileId: remoteProfileId)
        let remoteProviders = Set(rows.keys)

        // First sync of this profile on the account: upload keys the account
        // does not have yet. The seed RPC never overwrites existing rows.
        if mappings.contains(where: { !remoteProviders.contains($0.provider) && !(local[$0.provider] ?? "").isEmpty }) {
            try await seed(local, session: session, remoteProfileId: remoteProfileId)
        }

        var merged = local
        if !localChanged {
            let isFirstSync = baselineFingerprint == nil
            var keptLocal = false
            for mapping in mappings {
                guard let value = rows[mapping.provider] else { continue }
                // On this device's first sync an empty account value must not
                // wipe a key that was entered here before signing in.
                if isFirstSync, value.isEmpty, !(local[mapping.provider] ?? "").isEmpty {
                    keptLocal = true
                    continue
                }
                merged[mapping.provider] = value
            }
            apply(merged, previous: local, to: store)
            if keptLocal {
                try await push(merged, session: session, remoteProfileId: remoteProfileId)
            }
        }
        store.set(AccountSyncFingerprint.of(merged), forKey: baselineKey(for: session, remoteProfileId))
    }

    /// Pushes only when the keys changed locally since the last sync.
    static func pushIfChanged(session: AuthSession, remoteProfileId: Int, localProfileId: String) async throws {
        let store = ProfileSettings.store(for: localProfileId)
        guard let baseline = store.string(forKey: baselineKey(for: session, remoteProfileId)) else { return }
        let local = snapshot(in: store)
        let fingerprint = AccountSyncFingerprint.of(local)
        guard fingerprint != baseline else { return }
        try await push(local, session: session, remoteProfileId: remoteProfileId)
        store.set(fingerprint, forKey: baselineKey(for: session, remoteProfileId))
    }

    // MARK: - Local state

    static func snapshot(in store: UserDefaults) -> [String: String] {
        var values: [String: String] = [:]
        for mapping in mappings {
            values[mapping.provider] = (store.string(forKey: mapping.settingsKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    private static func apply(_ values: [String: String], previous: [String: String], to store: UserDefaults) {
        var changed = false
        for mapping in mappings {
            let value = values[mapping.provider] ?? ""
            guard value != previous[mapping.provider] else { continue }
            store.set(value, forKey: mapping.settingsKey)
            changed = true
        }
        guard changed else { return }

        // A TMDB / MDBList key from the account should take effect without a
        // second trip to Settings, matching how the key alone enables them on
        // Android. An explicit "off" set on this device is kept.
        if !(values["tmdb"] ?? "").isEmpty, store.object(forKey: SettingsKey.tmdbEnabled) == nil {
            store.set(true, forKey: SettingsKey.tmdbEnabled)
        }
        if !(values["mdblist"] ?? "").isEmpty, store.object(forKey: SettingsKey.mdbListEnabled) == nil {
            store.set(true, forKey: SettingsKey.mdbListEnabled)
        }

        // Keep the selected debrid provider usable: pick the first provider
        // with a key when none is selected or the selected one lost its key.
        let current = DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
        let candidates: [(DebridProviderKind, String)] = [
            (.torbox, "debrid:torbox"),
            (.premiumize, "debrid:premiumize"),
            (.realDebrid, "debrid:realdebrid")
        ]
        let currentHasKey = candidates.contains { $0.0 == current && !(values[$0.1] ?? "").isEmpty }
        if !currentHasKey, let next = candidates.first(where: { !(values[$0.1] ?? "").isEmpty })?.0 {
            store.set(next.rawValue, forKey: SettingsKey.debridProvider)
        }
        let selected = DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
        if selected != .none {
            store.set(DebridCredentials.token(for: selected, store: store), forKey: SettingsKey.debridApiKey)
        }
    }

    // MARK: - Remote

    private static func pull(session: AuthSession, remoteProfileId: Int) async throws -> [String: String] {
        let raw = try await AccountSyncRPC.call(
            "sync_pull_provider_credentials",
            session: session,
            params: ["p_profile_id": remoteProfileId]
        )
        guard let rows = raw as? [[String: Any]] else { return [:] }
        var values: [String: String] = [:]
        for row in rows {
            guard let provider = (row["provider"] as? String)?.lowercased(),
                  let mapping = mappings.first(where: { $0.provider == provider }) else { continue }
            let json = row["credential_json"] as? [String: Any] ?? [:]
            let value = (json[mapping.field] as? String) ?? ""
            values[provider] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    private static func push(_ values: [String: String], session: AuthSession, remoteProfileId: Int) async throws {
        _ = try await AccountSyncRPC.call(
            "sync_push_provider_credentials",
            session: session,
            params: params(values, remoteProfileId: remoteProfileId)
        )
    }

    private static func seed(_ values: [String: String], session: AuthSession, remoteProfileId: Int) async throws {
        _ = try await AccountSyncRPC.call(
            "sync_seed_provider_credentials",
            session: session,
            params: params(values, remoteProfileId: remoteProfileId)
        )
    }

    private static func params(_ values: [String: String], remoteProfileId: Int) -> [String: Any] {
        [
            "p_profile_id": remoteProfileId,
            "p_credentials": mappings.map { mapping in
                [
                    "provider": mapping.provider,
                    "credential_json": [mapping.field: values[mapping.provider] ?? ""]
                ] as [String: Any]
            }
        ]
    }

    private static func baselineKey(for session: AuthSession, _ remoteProfileId: Int) -> String {
        "\(baselineKey).\(session.userId).\(remoteProfileId)"
    }
}
