import Foundation

/// "Assign EPG" (step 8b): the guide channel chosen by hand for a channel,
/// per profile. Stream id → guide channel id, or "" for no guide at all.
/// The guide import applies them (they win over the automatic match).
enum LiveTVEPGOverrides {
    private static let key = "nuvio.tv.livetv.epgOverrides"

    static func load() -> [Int: String] {
        let stored = ProfileSettings.current.dictionary(forKey: key) as? [String: String] ?? [:]
        var result: [Int: String] = [:]
        for (stream, guideID) in stored {
            if let id = Int(stream) { result[id] = guideID }
        }
        return result
    }

    /// `guideID`: a guide channel, "" for none, nil for automatic again.
    static func set(streamID: Int, guideID: String?) {
        var stored = ProfileSettings.current.dictionary(forKey: key) as? [String: String] ?? [:]
        stored[String(streamID)] = guideID
        ProfileSettings.current.set(stored, forKey: key)
    }

    static func choice(streamID: Int) -> String? {
        load()[streamID]
    }
}
