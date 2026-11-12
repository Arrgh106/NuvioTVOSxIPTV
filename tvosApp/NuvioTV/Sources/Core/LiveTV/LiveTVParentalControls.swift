import Foundation
import Security

/// Parental controls (step 11), per profile, as on Android: a PIN of 4 to 8
/// digits (in the Keychain), the groups you locked, and the automatic lock
/// for adult group names. A group unlocked with the PIN stays open until the
/// app is closed (or the profile changes).
@MainActor
final class LiveTVParentalControls: ObservableObject {
    static let shared = LiveTVParentalControls()
    static let changedNotification = Notification.Name("nuvio.tv.livetv.parental.changed")

    @Published private(set) var hasPin = false
    @Published private(set) var lockedGroups: Set<String> = []
    @Published private(set) var lockAdult = false
    /// Unlocked with the PIN since the app started.
    @Published private(set) var unlocked: Set<String> = []

    private static let lockedKey = "nuvio.tv.livetv.lockedGroups"
    private static let lockAdultKey = "nuvio.tv.livetv.lockAdultContent"
    /// Wrong PINs in a row and the time of the last one, per profile, so
    /// closing the app doesn't reset the wait.
    private static let failuresKey = "nuvio.tv.livetv.pinFailures"
    private static let lastFailureKey = "nuvio.tv.livetv.pinLastFailure"
    private static let keychainService = "nuvio.tv.livetv.parental"
    private var pin = ""
    private var profileObserver: NSObjectProtocol?

    private init() {
        load()
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileSettings.activeProfileChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.load() }
        }
    }

    var isEnabled: Bool { hasPin }

    func load() {
        let settings = ProfileSettings.current
        pin = readPin()
        hasPin = LiveTVParental.isValidPin(pin)
        lockedGroups = Set(settings.stringArray(forKey: Self.lockedKey) ?? [])
        lockAdult = settings.bool(forKey: Self.lockAdultKey)
        unlocked = []
        changed()
    }

    /// Right PIN. Wrong ones in a row make the next try wait
    /// (`retryAfter`); while waiting every PIN counts as wrong.
    func check(_ entered: String) -> Bool {
        guard hasPin, retryAfter == nil else { return false }
        let settings = ProfileSettings.current
        if LiveTVParental.normalized(entered) == pin {
            settings.removeObject(forKey: Self.failuresKey)
            settings.removeObject(forKey: Self.lastFailureKey)
            return true
        }
        settings.set(settings.integer(forKey: Self.failuresKey) + 1, forKey: Self.failuresKey)
        settings.set(Date().timeIntervalSince1970, forKey: Self.lastFailureKey)
        return false
    }

    /// Seconds to wait before the next PIN, nil when one can be tried now.
    var retryAfter: Int? {
        let settings = ProfileSettings.current
        let wait = LiveTVParental.lockout(afterFailures: settings.integer(forKey: Self.failuresKey))
        guard wait > 0 else { return nil }
        let last = Date(timeIntervalSince1970: settings.double(forKey: Self.lastFailureKey))
        let left = last.addingTimeInterval(wait).timeIntervalSinceNow
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// The groups of these that need the PIN now; `ignoringUnlocked`: also
    /// the ones opened this session (for what's saved, e.g. the Home row).
    func lockedIDs(_ groups: [(id: String, name: String)], ignoringUnlocked: Bool = false) -> Set<String> {
        LiveTVParental.lockedIDs(
            groups: groups, locked: lockedGroups, lockAdult: lockAdult,
            unlocked: ignoringUnlocked ? [] : unlocked, enabled: hasPin)
    }

    func isLockSet(_ groupID: String) -> Bool { lockedGroups.contains(groupID) }

    /// Opens the group until the app is closed, if the PIN is right.
    func unlock(_ groupID: String, pin entered: String) -> Bool {
        guard check(entered) else { return false }
        open(groupID)
        return true
    }

    /// Opens the group until the app is closed (the caller checked the PIN).
    func open(_ groupID: String) {
        unlocked.insert(groupID)
        changed()
    }

    func lock(_ groupID: String) {
        lockedGroups.insert(groupID)
        unlocked.remove(groupID)
        storeLocked()
        changed()
    }

    /// Takes your lock off (the caller checked the PIN).
    func removeLock(_ groupID: String) {
        guard lockedGroups.remove(groupID) != nil else { return }
        storeLocked()
        changed()
    }

    /// Returns false when the PIN isn't 4 to 8 digits.
    func setPin(_ newPin: String) -> Bool {
        let clean = LiveTVParental.normalized(newPin)
        guard LiveTVParental.isValidPin(clean) else { return false }
        savePin(clean)
        pin = clean
        hasPin = true
        unlocked = []
        changed()
        return true
    }

    /// Removes the PIN; your locked groups are remembered.
    func turnOff() {
        deletePin()
        pin = ""
        hasPin = false
        unlocked = []
        changed()
    }

    func setLockAdult(_ on: Bool) {
        guard on != lockAdult else { return }
        lockAdult = on
        ProfileSettings.current.set(on, forKey: Self.lockAdultKey)
        changed()
    }

    private func storeLocked() {
        ProfileSettings.current.set(Array(lockedGroups).sorted(), forKey: Self.lockedKey)
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    // MARK: Keychain

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: "pin.\(ProfileSettings.activeProfileScope)",
        ]
    }

    private func readPin() -> String {
        var q = query()
        q[kSecReturnData as String] = kCFBooleanTrue
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func savePin(_ value: String) {
        let data = Data(value.utf8)
        var add = query()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    private func deletePin() {
        SecItemDelete(query() as CFDictionary)
    }
}
