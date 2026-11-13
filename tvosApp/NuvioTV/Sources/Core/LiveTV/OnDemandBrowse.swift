import Combine
import Foundation

/// Cards for the provider's titles (step 12b): the VOD page and the
/// Home row. Opening one goes through `OnDemandDetails.target`.
@MainActor
enum OnDemandBrowse {
    static func meta(_ item: OnDemandItem, tags: Set<String>) -> NuvioMeta {
        let name = OnDemandTitle.searchName(item.name, tags: tags)
        return NuvioMeta(
            id: OnDemandID.make(item.kind, item.id),
            name: name.isEmpty ? item.name : name,
            description: nil,
            posterUrl: item.icon,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: item.tmdb,
            type: item.kind == .series ? "series" : "movie",
            year: item.year,
            genres: nil,
            rating: item.rating.flatMap(Double.init),
            releaseInfo: item.year.map(String.init),
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil
        )
    }

    /// Categories the parental controls hide now: locked with the PIN, or
    /// adult ones with the automatic lock.
    static func isHidden(kind: OnDemandKind, categoryID: String, categoryName: String) -> Bool {
        let parental = LiveTVParentalControls.shared
        guard parental.isEnabled else { return false }
        let lockID = OnDemandLookup.lockID(kind: kind, category: categoryID)
        if parental.lockedGroups.contains(lockID), !parental.unlocked.contains(lockID) { return true }
        return parental.lockAdult && LiveTVParental.isAdult(categoryName)
    }

    static func isHidden(_ item: OnDemandItem, categoryName: String) -> Bool {
        if isHidden(kind: item.kind, categoryID: item.categoryID, categoryName: categoryName) { return true }
        let parental = LiveTVParentalControls.shared
        return parental.isEnabled && parental.lockAdult && LiveTVParental.isAdult(item.name)
    }
}

/// Home's VOD row: what the provider added last, movies and series
/// together. Settings → Appearance → Home Rows → VOD.
@MainActor
final class OnDemandHomeRowModel: ObservableObject {
    static let shared = OnDemandHomeRowModel()
    static let sectionID = "livetv_ondemand_row"

    @Published private(set) var metas: [NuvioMeta] = []
    private var observers: [NSObjectProtocol] = []
    private var revisionObserver: AnyCancellable?

    private init() {
        for name in [
            ProfileSettings.settingsChangedNotification, ProfileSettings.activeProfileChangedNotification,
            LiveTVParentalControls.changedNotification,
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        revisionObserver = OnDemandLibrary.shared.$revision.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    func reload() {
        let enabled = ProfileSettings.current.object(forKey: SettingsKey.onDemandHomeRow) as? Bool ?? true
        guard enabled, XtreamAccountStore.load() != nil, let database = OnDemandLibrary.shared.database else {
            if !metas.isEmpty { metas = [] }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let items = database.recentlyAdded(limit: 80)
            let names = [OnDemandKind.movie: database.categoryNames(.movie), .series: database.categoryNames(.series)]
            let tags = [OnDemandKind.movie: database.tags(.movie), .series: database.tags(.series)]
            await MainActor.run {
                guard let self else { return }
                let shown = items.filter { !OnDemandBrowse.isHidden($0, categoryName: names[$0.kind]?[$0.categoryID] ?? "") }
                let next = shown.prefix(40).map { OnDemandBrowse.meta($0, tags: tags[$0.kind] ?? []) }
                if next != self.metas { self.metas = Array(next) }
            }
        }
    }
}
