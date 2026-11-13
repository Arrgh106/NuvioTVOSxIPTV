import SwiftUI

// MARK: - Shared rows

/// Rows of cards like Home's (step 12b), for the VOD and Jellyfin
/// pages in the sidebar.
struct BrowseRowsList: View {
    let sections: [TVHomeSection]
    let onSelect: (NuvioMeta) -> Void
    /// Near the end of a row: load more of it.
    var onApproachEnd: (String) -> Void = { _ in }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 36) {
            ForEach(sections) { section in
                TVCatalogRow(
                    id: section.id,
                    title: section.title,
                    showAddonName: false,
                    horizontalEdgeInset: 60,
                    items: section.items,
                    initialFocusCardKey: nil,
                    landscapeFocusedId: nil,
                    onInitialFocusRequested: {},
                    onFocus: { _ in },
                    onBlur: { _ in },
                    onApproachEnd: { _ in onApproachEnd(section.id) },
                    onSelect: onSelect
                )
            }
        }
    }
}

/// Title, optional Movies / Series switch, and a note when there's nothing.
private struct BrowseHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 60)
        .focusSection()
    }
}

private struct BrowsePill: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: selected ? .bold : .semibold))
                .foregroundColor(focused ? .black : .white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(focused ? Color.white : (selected ? Color.white.opacity(0.28) : Color.white.opacity(0.1)))
                )
        }
        .buttonStyle(.plain)
        .focused($focused)
        .scaleEffect(focused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// The note when a page has nothing, with a way to Settings: something
/// focusable, or focus is stuck on the page (no Menu, no sidebar).
private struct BrowseEmpty: View {
    let text: String
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Text(text)
                .font(.system(size: 26))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            Button(L10n.string("nav_settings", fallback: "Settings"), action: onOpenSettings)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 120)
        .focusSection()
    }
}

// MARK: - VOD page

/// The provider's movies and series (step 12b), as Android's VOD
/// page: a row per category in the provider's order. Categories the
/// parental controls lock (or adult ones, with the automatic lock) are left
/// out. Settings → Appearance → Sidebar → VOD.
struct OnDemandPageView: View {
    let onOpen: (String, String) -> Void
    let onOpenSettings: () -> Void
    @ObservedObject private var library = OnDemandLibrary.shared
    @AppStorage("nuvio.tv.ondemand.page.kind") private var kindRaw = OnDemandKind.movie.rawValue
    @State private var sections: [TVHomeSection] = []
    @State private var loadedKind: OnDemandKind?
    @State private var loaded = false
    @State private var offsets: [String: Int] = [:]
    @State private var loadingMore: Set<String> = []
    /// "Merge Duplicates": what each row has shown so far.
    @State private var dedupes: [String: OnDemandDedupe] = [:]
    @State private var managing = false
    private static let page = 30

    private var kind: OnDemandKind { OnDemandKind(rawValue: kindRaw) ?? .movie }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 36) {
                BrowseHeader(
                    title: L10n.string("livetv_ondemand_title", fallback: "VOD"),
                    subtitle: subtitle
                ) {
                    HStack(spacing: 16) {
                        BrowsePill(title: L10n.string("livetv_ondemand_movies", fallback: "Movies"), selected: kind == .movie) {
                            kindRaw = OnDemandKind.movie.rawValue
                        }
                        BrowsePill(title: L10n.string("livetv_ondemand_series", fallback: "Series"), selected: kind == .series) {
                            kindRaw = OnDemandKind.series.rawValue
                        }
                        BrowsePill(title: L10n.string("livetv_vod_categories", fallback: "Categories"), selected: false) {
                            managing = true
                        }
                    }
                }
                if sections.isEmpty {
                    BrowseEmpty(text: loaded ? emptyText : L10n.string("livetv_ondemand_busy", fallback: "Loading…"), onOpenSettings: onOpenSettings)
                } else {
                    BrowseRowsList(sections: sections, onSelect: { onOpen($0.id, $0.type) }, onApproachEnd: loadMore)
                }
            }
            .padding(.vertical, 40)
        }
        .task(id: "\(kindRaw)|\(library.revision)") { await load() }
        .onReceive(NotificationCenter.default.publisher(for: LiveTVParentalControls.changedNotification)) { _ in
            Task { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: OnDemandPreferences.changedNotification)) { _ in
            Task { await load() }
        }
        .onAppear { library.refreshIfNeeded() }
        .sheet(isPresented: $managing) {
            LiveTVSettingsRows.clearSheetBackground(OnDemandCategoriesSheet(initialKind: kind))
        }
    }

    private var subtitle: String {
        if case .ready(let movies, let series, _) = library.status {
            return L10n.format("livetv_ondemand_page_counts", fallback: "%@ movies · %@ series", movies.formatted(), series.formatted())
        }
        return ""
    }

    private var emptyText: String {
        switch library.status {
        case .importing: return L10n.string("livetv_ondemand_loading", fallback: "Loading movies & series")
        case .failed(let message): return message
        default: return L10n.string("livetv_ondemand_empty", fallback: "Nothing here yet. Your provider's movies and series are read once a day.")
        }
    }

    /// The first page of every category that's shown.
    private func load() async {
        guard let database = library.database else {
            sections = []
            loaded = true
            return
        }
        let kind = self.kind
        let page = Self.page
        let tags = database.tags(kind)
        let rows = await Task.detached(priority: .userInitiated) {
            database.categories(kind).map { category in
                (category, database.items(kind: kind, category: category.id, offset: 0, limit: page))
            }
        }.value
        guard kind == self.kind else { return }
        var next: [TVHomeSection] = []
        var nextOffsets: [String: Int] = [:]
        var nextDedupes: [String: OnDemandDedupe] = [:]
        let merge = OnDemandPreferences.shared.mergeDuplicates
        for (category, items) in rows {
            guard !OnDemandBrowse.isHidden(kind: kind, categoryID: category.id, categoryName: category.name) else { continue }
            let id = "ondemand_\(kind.rawValue)_\(category.id)"
            var dedupe = OnDemandDedupe()
            let metas = items
                .filter { !OnDemandBrowse.isHidden($0, categoryName: category.name) && (!merge || dedupe.isNew($0)) }
                .map { OnDemandBrowse.meta($0, tags: tags) }
            guard !metas.isEmpty else { continue }
            next.append(TVHomeSection(id: id, title: category.name, items: metas))
            nextOffsets[id] = items.count < page ? -1 : page
            nextDedupes[id] = dedupe
        }
        sections = next
        offsets = nextOffsets
        dedupes = nextDedupes
        loadedKind = kind
        loaded = true
    }

    /// The next page of one category (-1: all there).
    private func loadMore(_ sectionID: String) {
        guard let offset = offsets[sectionID], offset >= 0, !loadingMore.contains(sectionID),
              let database = library.database, let kind = loadedKind else { return }
        let category = String(sectionID.dropFirst("ondemand_\(kind.rawValue)_".count))
        let name = sections.first { $0.id == sectionID }?.title ?? ""
        let page = Self.page
        let tags = database.tags(kind)
        loadingMore.insert(sectionID)
        Task {
            let items = await Task.detached(priority: .userInitiated) {
                database.items(kind: kind, category: category, offset: offset, limit: page)
            }.value
            loadingMore.remove(sectionID)
            guard kind == loadedKind, let index = sections.firstIndex(where: { $0.id == sectionID }) else { return }
            let merge = OnDemandPreferences.shared.mergeDuplicates
            var dedupe = dedupes[sectionID] ?? OnDemandDedupe()
            let metas = items
                .filter { !OnDemandBrowse.isHidden($0, categoryName: name) && (!merge || dedupe.isNew($0)) }
                .map { OnDemandBrowse.meta($0, tags: tags) }
            dedupes[sectionID] = dedupe
            sections[index].items += metas
            offsets[sectionID] = items.count < page ? -1 : offset + page
        }
    }
}

// MARK: - Jellyfin page

/// Every Jellyfin library as a row (step 12b), the same titles as Home's
/// Jellyfin rows. Settings → Appearance → Sidebar → Jellyfin.
struct JellyfinPageView: View {
    let onOpen: (String, String) -> Void
    let onOpenSettings: () -> Void
    @State private var sections: [TVHomeSection] = []
    @State private var loaded = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 36) {
                BrowseHeader(title: "Jellyfin", subtitle: "") { EmptyView() }
                if sections.isEmpty {
                    BrowseEmpty(text: loaded
                        ? L10n.string("jellyfin_page_empty", fallback: "No Jellyfin titles yet. Add a server and read its libraries in Settings.")
                        : L10n.string("livetv_ondemand_busy", fallback: "Loading…"),
                        onOpenSettings: onOpenSettings)
                } else {
                    BrowseRowsList(sections: sections, onSelect: { onOpen($0.id, $0.type) })
                }
            }
            .padding(.vertical, 40)
        }
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: JellyfinLibraryIndex.changedNotification).receive(on: RunLoop.main)) { _ in
            load()
        }
    }

    /// One row per library (server order, then name), titles A–Z, as Home.
    private func load() {
        let index = JellyfinLibraryIndex.shared
        let titles = index.titles()
        let serverOrder = Dictionary(uniqueKeysWithValues: JellyfinServerStore.shared.servers.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let grouped = Dictionary(grouping: titles) { title in
            "\(title.serverID)\u{1}\(title.libraryID ?? "")"
        }
        let keys = grouped.keys.sorted { lhs, rhs in
            let l = grouped[lhs]?.first, r = grouped[rhs]?.first
            let lo = l.flatMap { serverOrder[$0.serverID] } ?? Int.max
            let ro = r.flatMap { serverOrder[$0.serverID] } ?? Int.max
            if lo != ro { return lo < ro }
            return (l?.libraryName ?? "") < (r?.libraryName ?? "")
        }
        sections = keys.compactMap { key in
            guard let group = grouped[key] else { return nil }
            let metas = group
                .sorted { $0.name != $1.name ? $0.name < $1.name : $0.contentId < $1.contentId }
                .compactMap { index.meta(forContentId: $0.contentId) }
            guard !metas.isEmpty else { return nil }
            let title = group.first?.libraryName ?? "Jellyfin"
            return TVHomeSection(id: "jellyfin_page_" + key.replacingOccurrences(of: "\u{1}", with: "_"), title: title, items: metas)
        }
        loaded = true
    }
}
