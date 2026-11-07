import Foundation

/// Entry point for the account data that upstream NuvioTVOS doesn't sync yet:
/// API keys (provider credentials) and Jellyfin servers.
///
/// `NuvioSyncManager` calls `pull` during every account pull (right after the
/// profile settings) and `pushIfChanged` after every settings push. Each part
/// fails on its own, so a broken Jellyfin entry never blocks the API keys or
/// the rest of the upstream sync.
@MainActor
enum AccountExtrasSync {
    static func pull(session: AuthSession, remoteProfileId: Int, localProfileId: String) async {
        do {
            try await ProviderCredentialSync.sync(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId)
        } catch {
            print("[AccountExtrasSync] provider credentials sync failed: \(error.localizedDescription)")
        }
        do {
            try await MediaServerSync.sync(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId)
        } catch {
            print("[AccountExtrasSync] media server sync failed: \(error.localizedDescription)")
        }
    }

    static func pushIfChanged(session: AuthSession, remoteProfileId: Int, localProfileId: String) async {
        do {
            try await ProviderCredentialSync.pushIfChanged(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId)
        } catch {
            print("[AccountExtrasSync] provider credentials push failed: \(error.localizedDescription)")
        }
        do {
            try await MediaServerSync.pushIfChanged(session: session, remoteProfileId: remoteProfileId, localProfileId: localProfileId)
        } catch {
            print("[AccountExtrasSync] media server push failed: \(error.localizedDescription)")
        }
    }
}
