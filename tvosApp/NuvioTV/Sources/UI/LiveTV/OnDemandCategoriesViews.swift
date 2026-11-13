import SwiftUI

// MARK: - VOD categories (step 12c)

/// Show, hide and lock the provider's VOD categories, as Android's
/// "Manage groups". From Settings → Live TV / VOD → VOD → Categories and
/// the VOD page. Hidden ones are out everywhere (pages, Home, search,
/// stream lists); locked ones need the parental PIN.
struct OnDemandCategoriesSheet: View {
    let initialKind: OnDemandKind
    var accentColor: Color = .white
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @ObservedObject private var preferences = OnDemandPreferences.shared
    @ObservedObject private var parental = LiveTVParentalControls.shared
    @State private var kind: OnDemandKind?
    @State private var categories: [Category] = []
    @State private var loaded = false
    @State private var pinPurpose: LiveTVPinSheet.Purpose?

    private var shownKind: OnDemandKind { kind ?? initialKind }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("livetv_vod_categories_title", fallback: "VOD Categories"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.string(
                        "livetv_vod_categories_detail",
                        fallback: "Hidden categories stay out of the VOD page, Home, search and the stream lists. Locked ones need the parental PIN."
                    ))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
                }

                HStack(spacing: 16) {
                    CategoryPill(title: L10n.string("livetv_ondemand_movies", fallback: "Movies"), selected: shownKind == .movie) {
                        kind = .movie
                    }
                    CategoryPill(title: L10n.string("livetv_ondemand_series", fallback: "Series"), selected: shownKind == .series) {
                        kind = .series
                    }
                    Spacer()
                    if hiddenCount > 0 {
                        CategoryPill(
                            title: L10n.format("livetv_vod_show_all", fallback: "Show All (%@ hidden)", hiddenCount.formatted()),
                            selected: false
                        ) {
                            preferences.showAll(kind: shownKind)
                        }
                    }
                    CategoryPill(title: L10n.string("action_done", fallback: "Done"), selected: false) {
                        dismiss()
                    }
                }
                .focusSection()

                if categories.isEmpty {
                    Text(loaded
                        ? L10n.string("livetv_vod_categories_empty", fallback: "No categories yet. Your provider's movies and series are read once a day.")
                        : L10n.string("livetv_ondemand_busy", fallback: "Loading…"))
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(categories) { category in
                                row(category)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .focusSection()
                }
            }
            .padding(60)
        }
        .task(id: shownKind) { await load() }
        .sheet(item: $pinPurpose) { purpose in
            LiveTVSettingsRows.clearSheetBackground(
                LiveTVPinSheet(purpose: purpose, accentColor: accentColor))
        }
    }

    private var hiddenCount: Int {
        categories.filter { preferences.isHidden(lockID($0.id)) }.count
    }

    private func lockID(_ category: String) -> String {
        OnDemandLookup.lockID(kind: shownKind, category: category)
    }

    @ViewBuilder
    private func row(_ category: Category) -> some View {
        let id = lockID(category.id)
        let hidden = preferences.isHidden(id)
        let autoLocked = parental.isEnabled && parental.lockAdult && LiveTVParental.isAdult(category.name)
        let locked = parental.isEnabled && (parental.isLockSet(id) || autoLocked)
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.name)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white.opacity(hidden ? 0.45 : 1))
                    .lineLimit(1)
                Text(L10n.format("livetv_vod_category_count", fallback: "%@ titles", category.count.formatted()))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            CategoryPill(
                title: hidden
                    ? L10n.string("livetv_vod_hidden", fallback: "Hidden")
                    : L10n.string("livetv_vod_shown", fallback: "Shown"),
                symbol: hidden ? "eye.slash" : "eye",
                selected: !hidden
            ) {
                preferences.setHidden(id, !hidden)
            }
            if parental.isEnabled {
                CategoryPill(
                    title: autoLocked
                        ? L10n.string("livetv_vod_locked_auto", fallback: "Locked (adult)")
                        : (locked
                            ? L10n.string("livetv_vod_locked", fallback: "Locked")
                            : L10n.string("livetv_vod_lock", fallback: "Lock")),
                    symbol: locked ? "lock.fill" : "lock.open",
                    selected: locked
                ) {
                    guard !autoLocked else { return }
                    if locked {
                        pinPurpose = .removeLock(LiveTVGroup(id: id, name: category.name, count: category.count))
                    } else {
                        parental.lock(id)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
        .focusSection()
    }

    private func load() async {
        guard let database = OnDemandLibrary.shared.database else {
            categories = []
            loaded = true
            return
        }
        let kind = shownKind
        let found = await Task.detached(priority: .userInitiated) {
            database.categories(kind).map { Category(id: $0.id, name: $0.name, count: $0.count) }
        }.value
        guard kind == shownKind else { return }
        categories = found
        loaded = true
    }
}

private struct Category: Identifiable, Sendable {
    let id: String
    let name: String
    let count: Int
}

private struct CategoryPill: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 22, weight: selected ? .bold : .semibold))
            .foregroundColor(focused ? .black : .white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
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

// MARK: - VOD languages (step 12c)

/// Pick the languages VOD shows, read from the provider's tags ("DE - ",
/// "4K-AR: ") and category names. None picked: every language. Picked
/// ones are the only ones on the VOD page, Home, search and in the stream
/// lists; titles nothing tells the language of stay unless turned off.
struct OnDemandLanguagesSheet: View {
    var accentColor: Color = .white
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @ObservedObject private var preferences = OnDemandPreferences.shared
    @State private var languages: [LanguageCount] = []
    @State private var unknownCount = 0
    @State private var loaded = false

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("livetv_vod_languages_title", fallback: "VOD Languages"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text(filter.isActive
                        ? L10n.string("livetv_vod_languages_active", fallback: "Only the languages picked show up on the VOD page, Home, search and in the stream lists.")
                        : L10n.string("livetv_vod_languages_none", fallback: "Nothing picked: every language shows. Pick the ones you want to see."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
                }

                HStack(spacing: 16) {
                    if filter.isActive {
                        CategoryPill(title: L10n.string("livetv_vod_languages_all", fallback: "Show All Languages"), selected: false) {
                            preferences.showAllLanguages()
                        }
                    }
                    Spacer()
                    CategoryPill(title: L10n.string("action_done", fallback: "Done"), selected: false) {
                        dismiss()
                    }
                }
                .focusSection()

                if languages.isEmpty {
                    Text(loaded
                        ? L10n.string("livetv_vod_languages_empty", fallback: "No languages found in your provider's names and categories yet.")
                        : L10n.string("livetv_ondemand_busy", fallback: "Loading…"))
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(languages) { language in
                                row(
                                    title: Self.name(language.id),
                                    count: language.count,
                                    shown: filter.languages.contains(language.id),
                                    shownTitle: L10n.string("livetv_vod_language_picked", fallback: "Picked"),
                                    otherTitle: L10n.string("livetv_vod_language_pick", fallback: "Pick")
                                ) {
                                    preferences.setLanguage(language.id, shown: !filter.languages.contains(language.id))
                                }
                            }
                            if unknownCount > 0 {
                                row(
                                    title: L10n.string("livetv_vod_language_unknown", fallback: "No language given"),
                                    count: unknownCount,
                                    shown: filter.keepUnknown,
                                    shownTitle: L10n.string("livetv_vod_shown", fallback: "Shown"),
                                    otherTitle: L10n.string("livetv_vod_hidden", fallback: "Hidden")
                                ) {
                                    preferences.setKeepUnknownLanguage(!filter.keepUnknown)
                                }
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .focusSection()
                }
            }
            .padding(60)
        }
        .task { await load() }
    }

    private var filter: OnDemandLanguageFilter { preferences.languageFilter }

    static func name(_ code: String) -> String {
        OnDemandLanguage.displayName(code)
    }

    private func row(
        title: String, count: Int, shown: Bool, shownTitle: String, otherTitle: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(L10n.format("livetv_vod_category_count", fallback: "%@ titles", count.formatted()))
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
            CategoryPill(title: shown ? shownTitle : otherTitle, symbol: shown ? "checkmark.circle.fill" : "circle", selected: shown, action: action)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
        .focusSection()
    }

    private func load() async {
        guard let database = OnDemandLibrary.shared.database else {
            loaded = true
            return
        }
        let counts = await Task.detached(priority: .userInitiated) { () -> [String?: Int] in
            var out: [String?: Int] = [:]
            for kind in OnDemandKind.allCases {
                for entry in database.languages(kind) { out[entry.code, default: 0] += entry.count }
            }
            return out
        }.value
        unknownCount = counts[nil] ?? 0
        languages = counts.compactMap { entry in entry.key.map { LanguageCount(id: $0, count: entry.value) } }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
        loaded = true
    }
}

private struct LanguageCount: Identifiable, Sendable {
    let id: String
    let count: Int
}
