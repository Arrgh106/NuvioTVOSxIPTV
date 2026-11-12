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

    func check(_ entered: String) -> Bool {
        hasPin && LiveTVParental.normalized(entered) == pin
    }

    /// The groups of these that need the PIN now.
    func lockedIDs(_ groups: [(id: String, name: String)]) -> Set<String> {
        LiveTVParental.lockedIDs(
            groups: groups, locked: lockedGroups, lockAdult: lockAdult, unlocked: unlocked, enabled: hasPin)
    }

    func isLockSet(_ groupID: String) -> Bool { lockedGroups.contains(groupID) }

    /// Opens the group until the app is closed, if the PIN is right.
    func unlock(_ groupID: String, pin entered: String) -> Bool {
        guard check(entered) else { return false }
        unlocked.insert(groupID)
        changed()
        return true
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
