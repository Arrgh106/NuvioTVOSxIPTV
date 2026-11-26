import SwiftUI

/// Settings → Calendar (step 16): the calendar is for everything you
/// follow, not only Live TV, so it has its own place in Settings.
struct LiveTVCalendarSettingsView: View {
    let accentColor: Color
    @ObservedObject private var settings = LiveTVSettings.shared
    @State private var opensIn = LiveTVCalendarSettings.view

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            LiveTVSettingsRows.group(
                title: L10n.string("nav_calendar", fallback: "Calendar"),
                subtitle: L10n.string("livetv_settings_calendar_subtitle", fallback: "The days and times of your shows and films")
            ) {
                LiveTVSettingsRows.option(
                    title: L10n.string("livetv_settings_calendar_zone", fallback: "Time Zone"),
                    subtitle: L10n.string("livetv_settings_calendar_zone_detail", fallback: "The calendar shows days and air times in this time zone"),
                    selection: $settings.calendarTimeZone,
                    options: LiveTVSettings.calendarTimeZones,
                    accentColor: accentColor,
                    optionLabel: { Self.zoneLabel($0) }
                )
                // Right from the sidebar lands here, the first row.
                .settingsEntryAnchor()
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_calendar_spoilers", fallback: "Hide Spoilers"),
                    subtitle: L10n.string("livetv_settings_calendar_spoilers_detail", fallback: "Episodes past the next one you'd watch keep their title, picture and description hidden"),
                    isOn: $settings.calendarHideSpoilers,
                    accentColor: accentColor
                )
                LiveTVSettingsRows.option(
                    title: L10n.string("livetv_settings_calendar_country", fallback: "Country for Film Dates"),
                    subtitle: L10n.string("livetv_settings_calendar_country_detail", fallback: "Cinema, home and disc releases of films in this country (US when a film has none there). Needs TMDB"),
                    selection: $settings.calendarCountry,
                    options: LiveTVSettings.calendarCountries,
                    accentColor: accentColor,
                    optionLabel: { Self.countryLabel($0) }
                )
                LiveTVSettingsRows.option(
                    title: L10n.string("livetv_settings_calendar_opens", fallback: "Opens In"),
                    subtitle: L10n.string("livetv_settings_calendar_opens_detail", fallback: "The list by day, a week, or a month at a time"),
                    selection: Binding(get: { opensIn }, set: { opensIn = $0; LiveTVCalendarSettings.view = $0 }),
                    options: ["list", "week", "month"],
                    accentColor: accentColor,
                    optionLabel: { (LiveTVCalendarView.Mode(rawValue: $0) ?? .list).title }
                )
                LiveTVSettingsRows.option(
                    title: L10n.string("livetv_settings_calendar_ok", fallback: "OK on an Episode in Your Guide"),
                    subtitle: L10n.string("livetv_settings_calendar_ok_detail", fallback: "An episode that's in your Live TV guide opens its Live TV options (watch, remind, page) or the show's page"),
                    selection: $settings.calendarOkAction,
                    options: ["live", "page"],
                    accentColor: accentColor,
                    optionLabel: {
                        $0 == "page"
                            ? L10n.string("livetv_settings_calendar_ok_page", fallback: "Show page")
                            : L10n.string("livetv_settings_calendar_ok_live", fallback: "Live TV options")
                    }
                )
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_calendar_news", fallback: "Airing Today: Leave Out News & Talk"),
                    subtitle: L10n.string("livetv_settings_calendar_news_detail", fallback: "News, talk, sports and panel shows aren't listed in Airing today"),
                    isOn: $settings.calendarSkipNewsTalk,
                    accentColor: accentColor
                )
                LiveTVSettingsRows.option(
                    title: L10n.string("livetv_settings_calendar_languages", fallback: "Airing Today: Streaming Languages"),
                    subtitle: L10n.string("livetv_settings_calendar_languages_detail", fallback: "TV in your country is always shown. Streaming from elsewhere only in these languages"),
                    selection: $settings.calendarAiringLanguages,
                    options: LiveTVSettings.calendarAiringLanguageChoices,
                    accentColor: accentColor,
                    optionLabel: { Self.languagesLabel($0) }
                )
            }
            LiveTVSettingsRows.group(
                title: L10n.string("livetv_settings_calendar_ratings", fallback: "Ratings"),
                subtitle: L10n.string("livetv_settings_calendar_ratings_detail", fallback: "Shown for the card in focus, always in the same places, in the order of Settings → Rating Providers & Order")
            ) {
                ForEach(TvRatingVisual.all, id: \.source) { visual in
                    LiveTVSettingsRows.toggle(
                        title: visual.displayName,
                        subtitle: "",
                        isOn: rating(visual.source),
                        accentColor: accentColor
                    )
                }
            }
        }
    }

    /// One rating on or off.
    private func rating(_ source: String) -> Binding<Bool> {
        Binding(
            get: { settings.calendarRatings.split(separator: ",").contains { $0 == source } },
            set: { on in
                var list = settings.calendarRatings.split(separator: ",").map(String.init).filter { $0 != source }
                if on { list.append(source) }
                settings.calendarRatings = list.joined(separator: ",")
            })
    }

    /// "German", "German and English", "All languages".
    @MainActor static func languagesLabel(_ choice: String) -> String {
        let code = LiveTVCalendarSettings.mainLanguageCode
        let main = Locale.current.localizedString(forLanguageCode: code) ?? code
        switch choice {
        case "all": return L10n.string("livetv_settings_calendar_lang_all", fallback: "All languages")
        case "local": return main
        default: return L10n.format("livetv_cal_lang_and_english_format", fallback: "%@ and English", main)
        }
    }

    /// "Apple TV: Berlin (GMT+1)", "New York (GMT-5)".
    static func zoneLabel(_ id: String) -> String {
        let zone = id.isEmpty ? TimeZone.current : TimeZone(identifier: id) ?? .current
        let city = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
        let seconds = zone.secondsFromGMT()
        let offset = seconds % 3600 == 0
            ? String(format: "GMT%+d", seconds / 3600)
            : String(format: "GMT%+d:%02d", seconds / 3600, abs(seconds / 60 % 60))
        let place = "\(city) (\(offset))"
        return id.isEmpty ? L10n.format("livetv_settings_calendar_zone_device", fallback: "Apple TV: %@", place) : place
    }

    /// "Apple TV: Germany", "United States".
    static func countryLabel(_ code: String) -> String {
        let region = code.isEmpty ? (Locale.current.region?.identifier ?? "US") : code
        let name = Locale.current.localizedString(forRegionCode: region) ?? region
        return code.isEmpty ? L10n.format("livetv_settings_calendar_zone_device", fallback: "Apple TV: %@", name) : name
    }
}
