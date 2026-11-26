import SwiftUI

/// Settings → Calendar (step 16): the calendar is for everything you
/// follow, not only Live TV, so it has its own place in Settings.
struct LiveTVCalendarSettingsView: View {
    let accentColor: Color
    @ObservedObject private var settings = LiveTVSettings.shared

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
            }
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
