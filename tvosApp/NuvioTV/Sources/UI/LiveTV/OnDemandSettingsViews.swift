import SwiftUI

// MARK: - Settings → Live TV → VOD

/// The provider's movies and series in Nuvio's stream lists (step 12a), as
/// Android's "VOD in Streams" and "Update Movies & Series Now".
struct OnDemandSettingsGroup: View {
    let accentColor: Color
    @ObservedObject private var library = OnDemandLibrary.shared
    @ObservedObject private var preferences = OnDemandPreferences.shared
    @State private var managing = false

    var body: some View {
        LiveTVSettingsRows.group(
            title: L10n.string("livetv_ondemand_title", fallback: "VOD"),
            subtitle: L10n.string("livetv_ondemand_subtitle", fallback: "Your provider's movies and series show up as \u{201C}VOD\u{201D} in a title's stream list, next to your add-ons. Read once a day.")
        ) {
            LiveTVSettingsRows.toggle(
                title: L10n.string("livetv_ondemand_in_streams", fallback: "VOD in Streams"),
                subtitle: L10n.string("livetv_ondemand_in_streams_detail", fallback: "Matched by the title\u{2019}s TMDB id, otherwise by name and year. Auto-play picks it only when nothing else plays."),
                isOn: Binding(get: { library.inStreams }, set: { library.setInStreams($0) }),
                accentColor: accentColor
            )
            LiveTVSettingsRows.action(
                title: L10n.string("livetv_ondemand_update", fallback: "Update Movies & Series Now"),
                subtitle: statusText,
                value: isImporting ? L10n.string("livetv_ondemand_busy", fallback: "Loading…") : "",
                accentColor: accentColor,
                action: { library.refresh() }
            )
            // Step 12c.
            LiveTVSettingsRows.toggle(
                title: L10n.string("livetv_vod_in_search", fallback: "VOD in Search"),
                subtitle: L10n.string("livetv_vod_in_search_detail", fallback: "Your provider's titles that your add-ons don\u{2019}t find, at the end of the search results."),
                isOn: Binding(get: { preferences.inSearch }, set: { preferences.setInSearch($0) }),
                accentColor: accentColor
            )
            LiveTVSettingsRows.toggle(
                title: L10n.string("livetv_vod_merge", fallback: "Merge Duplicates"),
                subtitle: L10n.string("livetv_vod_merge_detail", fallback: "The same title in several qualities shows up once. Its stream list still offers every version."),
                isOn: Binding(get: { preferences.mergeDuplicates }, set: { preferences.setMergeDuplicates($0) }),
                accentColor: accentColor
            )
            LiveTVSettingsRows.action(
                title: L10n.string("livetv_vod_categories", fallback: "Categories"),
                subtitle: L10n.string("livetv_vod_categories_subtitle", fallback: "Hide categories or lock them with the parental PIN"),
                value: preferences.hidden.isEmpty
                    ? ""
                    : L10n.format("livetv_vod_hidden_count", fallback: "%@ hidden", preferences.hidden.count.formatted()),
                accentColor: accentColor,
                action: { managing = true }
            )
        }
        .sheet(isPresented: $managing) {
            LiveTVSettingsRows.clearSheetBackground(OnDemandCategoriesSheet(initialKind: .movie, accentColor: accentColor))
        }
    }

    private var isImporting: Bool {
        if case .importing = library.status { return true }
        return false
    }

    private var statusText: String {
        switch library.status {
        case .idle:
            return L10n.string("livetv_ondemand_none", fallback: "Not read yet")
        case .importing(let label):
            return label
        case .ready(let movies, let series, let updated):
            return L10n.format(
                "livetv_ondemand_counts", fallback: "%@ movies · %@ series · %@",
                movies.formatted(), series.formatted(), updated.formatted(date: .abbreviated, time: .shortened))
        case .failed(let message):
            return L10n.string("livetv_ondemand_failed", fallback: "Couldn\u{2019}t read the lists") + ": " + message
        }
    }
}
