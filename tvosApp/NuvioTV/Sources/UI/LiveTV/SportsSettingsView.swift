import SwiftUI

/// Settings → Sports (step 17): the Sports page's own place in Settings, as
/// Android's Sports settings: your region, which scores show, the leagues
/// in All Events. (The gear on the Sports page has the same.)
struct SportsSettingsView: View {
    let accentColor: Color
    @ObservedObject private var settings = SportsSettings.shared
    @State private var showsLeagues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            LiveTVSettingsRows.group(
                title: L10n.string("nav_sports", fallback: "Sports"),
                subtitle: L10n.string("livetv_settings_sports_subtitle", fallback: "Live scores, tables and the teams you follow (ESPN, OpenLigaDB)")
            ) {
                LiveTVSettingsRows.choice(
                    title: L10n.string("livetv_sports_region", fallback: "Your Region"),
                    subtitle: L10n.string("livetv_sports_region_detail", fallback: "Which leagues are on at first: a country gets what's on everywhere and its own football."),
                    selection: $settings.region,
                    options: [""] + SportsCatalog.regions.map(\.code),
                    accentColor: accentColor,
                    optionLabel: { code in
                        code.isEmpty
                            ? L10n.format("livetv_settings_calendar_zone_device", fallback: "Apple TV: %@",
                                          SportsCatalog.regionName(SportsCatalog.region(ofCountry: SportsSettings.country)))
                            : SportsCatalog.regionName(code)
                    }
                )
                // Right from the sidebar lands here, the first row.
                .settingsEntryAnchor()
                LiveTVSettingsRows.choice(
                    title: L10n.string("livetv_sports_scores", fallback: "Scores"),
                    subtitle: L10n.string("livetv_sports_scores_detail", fallback: "Hide Live Scores: results of games that are over show, running games don't."),
                    selection: Binding(get: { settings.scoreMode.rawValue },
                                       set: { settings.scoreMode = SportsSettings.ScoreMode(rawValue: $0) ?? .all }),
                    options: SportsSettings.ScoreMode.allCases.map(\.rawValue),
                    accentColor: accentColor,
                    optionLabel: { SportsSettings.ScoreMode(rawValue: $0)?.title ?? $0 }
                )
                LiveTVSettingsRows.action(
                    title: L10n.string("livetv_sports_leagues_title", fallback: "Leagues in All Events"),
                    subtitle: L10n.string("livetv_sports_leagues_detail", fallback: "Your region's leagues are on; turn any on or off."),
                    value: L10n.format("livetv_sports_leagues_on_format", fallback: "%d on", settings.shownLeagues.count),
                    accentColor: accentColor,
                    action: { showsLeagues = true }
                )
            }
        }
        .fullScreenCover(isPresented: $showsLeagues) { SportsLeaguesPicker() }
    }
}
