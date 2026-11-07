import Foundation

/// Minimal RPC client for the account-sync extensions in this folder.
///
/// It talks to the same backend as `NuvioAPIClient` (the official
/// `api.nuvio.tv`, or a custom server the user configured), but lives apart
/// from it so this fork does not have to edit the large upstream sync file
/// beyond two small hooks.
enum AccountSyncRPC {
    static func call(
        _ name: String,
        session authSession: AuthSession,
        params: [String: Any]
    ) async throws -> Any {
        guard AuthConfig.isConfigured else {
            throw AuthError(message: "Account backend is not configured.")
        }
        guard let url = URL(string: "\(AuthConfig.normalizedAPIBaseURL)/rest/v1/rpc/\(name)") else {
            throw AuthError(message: "Invalid backend URL")
        }
        var resolvedParams = params
        if name.hasPrefix("sync_push_") || name.hasPrefix("sync_seed_") {
            resolvedParams["p_origin_client_id"] = SyncClientIdentity.current()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(AuthConfig.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: resolvedParams)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError(message: errorMessage(data: data, status: http.statusCode), statusCode: http.statusCode)
        }
        if data.isEmpty { return NSNull() }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
    }

    private static func errorMessage(data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error_description", "msg", "error", "hint"] {
                if let message = object[key] as? String, !message.isEmpty { return message }
            }
        }
        return "Server error (\(status))"
    }
}

/// Stable JSON fingerprint used to detect local changes since the last sync.
enum AccountSyncFingerprint {
    static func of(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
