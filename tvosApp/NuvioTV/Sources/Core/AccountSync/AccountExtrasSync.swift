import Foundation

/// Entry point for the account data that upstream NuvioTVOS doesn't sync yet:
/// API keys (provider credentials), Jellyfin servers and the Trakt / Up Next /
/// trailer settings that nuvio.tv and Android TV keep in the settings blob.
///
/// `NuvioSyncManager` calls `pull` during every account pull (right after the
/// profile settings) and `pushIfChanged` after every settings push. Each part
/// fails on its own, so a broken Jellyfin entry never blocks the API keys or
/// the rest of the upstream sync. `ensureValid` throws once the account or
/// profile changed (sign-out, profile switch); it is checked after every
/// network call, before anything is written locally or pushed.
@MainActor
enum AccountExtrasSync {
    static func pull(
        session: AuthSession,
        remoteProfileId: Int,
        localProfileId: String,
        ensureValid: () throws -> Void
    ) async throws {
        do {
            try await ProviderCredentialSync.sync(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId, ensureValid: ensureValid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[AccountExtrasSync] provider credentials sync failed: \(error.localizedDescription)")
        }
        do {
            try await MediaServerSync.sync(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId, ensureValid: ensureValid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[AccountExtrasSync] media server sync failed: \(error.localizedDescription)")
        }
        do {
            try await ProfileSettingsExtrasSync.pull(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId, ensureValid: ensureValid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[AccountExtrasSync] settings extras sync failed: \(error.localizedDescription)")
        }
    }

    static func pushIfChanged(
        session: AuthSession,
        remoteProfileId: Int,
        localProfileId: String,
        ensureValid: () throws -> Void
    ) async throws {
        do {
            try await ProviderCredentialSync.pushIfChanged(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId, ensureValid: ensureValid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[AccountExtrasSync] provider credentials push failed: \(error.localizedDescription)")
        }
        do {
            try await MediaServerSync.pushIfChanged(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId, ensureValid: ensureValid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[AccountExtrasSync] media server push failed: \(error.localizedDescription)")
        }
        do {
            try await ProfileSettingsExtrasSync.pushIfChanged(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId, ensureValid: ensureValid)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[AccountExtrasSync] settings extras push failed: \(error.localizedDescription)")
        }
    }
}
