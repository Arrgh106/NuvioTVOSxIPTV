import Foundation

/// VOD options per profile (step 12c), as Android's: hidden categories,
/// "Merge Duplicates" and VOD in Nuvio's search. A hidden category is out
/// everywhere (pages, Home, search and stream lists), as on Android; it
/// comes back in Settings → Live TV / VOD → VOD → Categories.
@MainActor
final class OnDemandPreferences: ObservableObject {
    static let shared = OnDemandPreferences()
    static let changedNotification = Notification.Name("nuvio.tv.livetv.vod.preferences.changed")

    /// `OnDemandLookup.lockID` of each hidden category.
    @Published private(set) var hidden: Set<String> = []
    @Published private(set) var mergeDuplicates = true
    @Published private(set) var inSearch = true
    /// Which languages show (none picked: all).
    @Published private(set) var languageFilter = OnDemandLanguageFilter()

    private static let hiddenKey = "nuvio.tv.livetv.vodHiddenCategories"
    private static let mergeKey = "nuvio.tv.livetv.vodMergeDuplicates"
    private static let searchKey = "nuvio.tv.livetv.vodInSearch"
    private static let languagesKey = "nuvio.tv.livetv.vodLanguages"
    private static let unknownLanguageKey = "nuvio.tv.livetv.vodKeepUnknownLanguage"
    private var profileObserver: NSObjectProtocol?

    private init() {
        load()
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileSettings.activeProfileChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    private func load() {
        let settings = ProfileSettings.current
        hidden = Set(settings.stringArray(forKey: Self.hiddenKey) ?? [])
        mergeDuplicates = settings.object(forKey: Self.mergeKey) as? Bool ?? true
        inSearch = settings.object(forKey: Self.searchKey) as? Bool ?? true
        languageFilter = OnDemandLanguageFilter(
            languages: Set(settings.stringArray(forKey: Self.languagesKey) ?? []),
            keepUnknown: settings.object(forKey: Self.unknownLanguageKey) as? Bool ?? true)
    }

    func setLanguage(_ code: String, shown: Bool) {
        var next = languageFilter
        if shown { next.languages.insert(code) } else { next.languages.remove(code) }
        setLanguageFilter(next)
    }

    func setKeepUnknownLanguage(_ on: Bool) {
        var next = languageFilter
        next.keepUnknown = on
        setLanguageFilter(next)
    }

    /// Every language again.
    func showAllLanguages() {
        var next = languageFilter
        next.languages = []
        setLanguageFilter(next)
    }

    private func setLanguageFilter(_ next: OnDemandLanguageFilter) {
        guard next != languageFilter else { return }
        languageFilter = next
        ProfileSettings.current.set(Array(next.languages).sorted(), forKey: Self.languagesKey)
        ProfileSettings.current.set(next.keepUnknown, forKey: Self.unknownLanguageKey)
        changed()
    }

    func isHidden(_ lockID: String) -> Bool { hidden.contains(lockID) }

    func setHidden(_ lockID: String, _ on: Bool) {
        if on { guard hidden.insert(lockID).inserted else { return } } else { guard hidden.remove(lockID) != nil else { return } }
        ProfileSettings.current.set(Array(hidden).sorted(), forKey: Self.hiddenKey)
        changed()
    }

    /// Every category of a kind shown again.
    func showAll(kind: OnDemandKind) {
        let prefix = OnDemandLookup.lockID(kind: kind, category: "")
        let before = hidden.count
        hidden = hidden.filter { !$0.hasPrefix(prefix) }
        guard hidden.count != before else { return }
        ProfileSettings.current.set(Array(hidden).sorted(), forKey: Self.hiddenKey)
        changed()
    }

    func setMergeDuplicates(_ on: Bool) {
        guard on != mergeDuplicates else { return }
        mergeDuplicates = on
        ProfileSettings.current.set(on, forKey: Self.mergeKey)
        changed()
    }

    func setInSearch(_ on: Bool) {
        guard on != inSearch else { return }
        inSearch = on
        ProfileSettings.current.set(on, forKey: Self.searchKey)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }
}
