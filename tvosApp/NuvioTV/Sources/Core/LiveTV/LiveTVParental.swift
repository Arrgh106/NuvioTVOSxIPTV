import Foundation

/// Parental controls (step 11), as Android's `ParentalControls`: groups
/// that need the PIN. Adult groups can be locked by name. Pure, so the logic
/// tests run it on Linux.
enum LiveTVParental {
    /// Android's pattern for adult group names.
    private static let adult = try! NSRegularExpression(
        pattern: #"(\bxxx\b|\badults?\b|\bporn|\b18\s*\+|\+\s*18\b|\berotic|\bplayboy\b|\bhustler\b|\bbrazzers\b|\bredlight\b|\bsexy?\b|\bnsfw\b)"#,
        options: [.caseInsensitive])

    static func isAdult(_ name: String) -> Bool {
        adult.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// 4 to 8 digits.
    static func isValidPin(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func normalized(_ pin: String) -> String {
        pin.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The groups that need the PIN now: locked by you, or adult by name
    /// with the automatic lock on; not ones unlocked since the app started.
    /// Nothing without a PIN.
    static func lockedIDs(
        groups: [(id: String, name: String)], locked: Set<String>, lockAdult: Bool,
        unlocked: Set<String>, enabled: Bool
    ) -> Set<String> {
        guard enabled else { return [] }
        var out = Set<String>()
        for group in groups where !unlocked.contains(group.id) {
            if locked.contains(group.id) || (lockAdult && isAdult(group.name)) { out.insert(group.id) }
        }
        return out
    }
}
