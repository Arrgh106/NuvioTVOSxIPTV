import SwiftUI

// MARK: - Settings → Live TV → On Demand

/// The provider's movies and series in Nuvio's stream lists (step 12a), as
/// Android's "On Demand in Streams" and "Update Movies & Series Now".
struct OnDemandSettingsGroup: View {
    let accentColor: Color
    @ObservedObject private var library = OnDemandLibrary.shared

    var body: some View {
        LiveTVSettingsRows.group(
            title: L10n.string("livetv_ondemand_title", fallback: "On Demand"),
            subtitle: L10n.string("livetv_ondemand_subtitle", fallback: "Your provider's movies and series show up as \u{201C}On Demand\u{201D} in a title's stream list, next to your add-ons. Read once a day.")
        ) {
            LiveTVSettingsRows.toggle(
                title: L10n.string("livetv_ondemand_in_streams", fallback: "On Demand in Streams"),
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
