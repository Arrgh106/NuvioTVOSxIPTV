import Foundation
import Combine

/// Live TV options (LIVE_TV_DESIGN.md, step 5), per profile, in one place:
/// the guide's quick menu and Settings → Live TV both change these, and the
/// guide, player and overlay read them, so every change shows at once.
/// Only options that do something today; more come with their features.
@MainActor
final class LiveTVSettings: ObservableObject {
    static let shared = LiveTVSettings()

    enum Clock: String, CaseIterable {
        case system
        case hours24 = "24h"
        case hours12 = "12h"
    }

    /// The channels in Home's Live TV row (as Android's `homeRowSource`).
    enum HomeRowSource: String, CaseIterable {
        case favorites
        case recent
    }

    // Guide
    @Published var showInfoPanel = true { didSet { save(showInfoPanel, Key.showInfoPanel) } }
    @Published var showDescription = true { didSet { save(showDescription, Key.showDescription) } }
    @Published var showPreview = true { didSet { save(showPreview, Key.showPreview) } }
    @Published var smallHeader = false { didSet { save(smallHeader, Key.smallHeader) } }
    @Published var hideSeparators = false { didSet { save(hideSeparators, Key.hideSeparators) } }
    @Published var showGroupCounts = true { didSet { save(showGroupCounts, Key.showGroupCounts) } }
    @Published var clock: Clock = .system {
        didSet {
            formatter = Self.makeFormatter(clock)
            if !loading { ProfileSettings.current.set(clock.rawValue, forKey: Key.clock) }
            // The guide is drawn by UIKit: it redraws its times on this.
            NotificationCenter.default.post(name: Self.clockChangedNotification, object: nil)
        }
    }

    // Playback
    @Published var rememberLastGroup = true { didSet { save(rememberLastGroup, Key.rememberLastGroup) } }
    @Published var infoBarOnZap = true { didSet { save(infoBarOnZap, Key.infoBarOnZap) } }
    @Published var reverseZap = false { didSet { save(reverseZap, Key.reverseZap) } }
    /// A channel that won't play switches to another copy of it (step 15b,
    /// Android's "Backup channel"; Multiview panes for now).
    @Published var backupChannel = true { didSet { save(backupChannel, Key.backupChannel) } }
    /// The calendar's time zone ("": the Apple TV's), step 16.
    @Published var calendarTimeZone = "" {
        didSet { if !loading { ProfileSettings.current.set(calendarTimeZone, forKey: Key.calendarTimeZone) } }
    }
    /// The calendar hides titles, pictures and text of episodes past the
    /// next one you'd watch (on, as Android).
    @Published var calendarHideSpoilers = true { didSet { save(calendarHideSpoilers, Key.calendarHideSpoilers) } }
    /// The country of films' release dates ("": the Apple TV's region).
    @Published var calendarCountry = "" {
        didSet { if !loading { ProfileSettings.current.set(calendarCountry, forKey: Key.calendarCountry) } }
    }
    static let calendarCountries = [
        "", "US", "GB", "IE", "CA", "AU", "NZ", "DE", "AT", "CH", "FR", "BE", "NL", "LU", "ES", "PT", "IT",
        "DK", "SE", "NO", "FI", "PL", "CZ", "GR", "TR", "BR", "MX", "AR", "IN", "JP", "KR", "ZA",
    ]

    /// The calendar's choices: the Apple TV's, then zones around the world.
    static let calendarTimeZones = [
        "", "Europe/London", "Europe/Lisbon", "Europe/Berlin", "Europe/Paris", "Europe/Madrid", "Europe/Rome",
        "Europe/Amsterdam", "Europe/Vienna", "Europe/Zurich", "Europe/Stockholm", "Europe/Warsaw", "Europe/Athens",
        "Europe/Istanbul", "Europe/Moscow", "Asia/Dubai", "Asia/Kolkata", "Asia/Bangkok", "Asia/Singapore",
        "Asia/Tokyo", "Australia/Perth", "Australia/Sydney", "Pacific/Auckland", "America/St_Johns",
        "America/Halifax", "America/New_York", "America/Chicago", "America/Denver", "America/Phoenix",
        "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu", "America/Mexico_City", "America/Bogota",
        "America/Sao_Paulo", "America/Argentina/Buenos_Aires", "Africa/Johannesburg", "Africa/Lagos", "Africa/Cairo",
    ]
    /// Pause and rewind live TV (step 14, Android's "Pause and Rewind Live
    /// TV"): the channel playing is kept on the Apple TV for a while.
    @Published var timeshift = true { didSet { save(timeshift, Key.timeshift) } }
    /// How far back, in minutes (Android's "Keep Up To").
    @Published var timeshiftMinutes = 30 {
        didSet { if !loading { ProfileSettings.current.set(timeshiftMinutes, forKey: Key.timeshiftMinutes) } }
    }
    static let timeshiftChoices = [10, 30, 60, 120]

    // Integration
    @Published var homeRow = true { didSet { save(homeRow, Key.homeRow) } }
    @Published var homeRowSource: HomeRowSource = .favorites {
        didSet { if !loading { ProfileSettings.current.set(homeRowSource.rawValue, forKey: Key.homeRowSource) } }
    }

    static let clockChangedNotification = Notification.Name("nuvio.tv.livetv.settings.clock")

    /// OK on a channel plays it small in the info panel (else full screen).
    var previewActive: Bool { showPreview && showInfoPanel }

    private enum Key {
        static let prefix = "nuvio.tv.livetv.settings."
        static let showInfoPanel = prefix + "showInfoPanel"
        static let showDescription = prefix + "showDescription"
        static let showPreview = prefix + "showPreview"
        static let smallHeader = prefix + "smallHeader"
        static let hideSeparators = prefix + "hideSeparators"
        static let showGroupCounts = prefix + "showGroupCounts"
        static let clock = prefix + "clock"
        static let rememberLastGroup = prefix + "rememberLastGroup"
        static let infoBarOnZap = prefix + "infoBarOnZap"
        static let reverseZap = prefix + "reverseZap"
        static let backupChannel = prefix + "backupChannel"
        static let calendarTimeZone = prefix + "calendarTimeZone"
        static let calendarHideSpoilers = prefix + "calendarHideSpoilers"
        static let calendarCountry = prefix + "calendarCountry"
        static let timeshift = prefix + "timeshift"
        static let timeshiftMinutes = prefix + "timeshiftMinutes"
        static let homeRow = prefix + "homeRow"
        static let homeRowSource = prefix + "homeRowSource"
    }

    private var loading = false
    private var formatter = LiveTVSettings.makeFormatter(.system)
    private var observer: NSObjectProtocol?
    private var profileObserver: NSObjectProtocol?

    private init() {
        load()
        // Another profile: its own options.
        observer = NotificationCenter.default.addObserver(
            forName: ProfileSettings.settingsChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
        // Switching profiles doesn't post the one above.
        profileObserver = NotificationCenter.default.addObserver(
            forName: ProfileSettings.activeProfileChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    /// A time as the clock option says ("21:15", "9:15 PM").
    func time(_ date: Date) -> String {
        formatter.string(from: date)
    }

    func load() {
        let store = ProfileSettings.current
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) == nil ? fallback : store.bool(forKey: key)
        }
        loading = true
        defer { loading = false }
        assign(\.showInfoPanel, bool(Key.showInfoPanel, true))
        assign(\.showDescription, bool(Key.showDescription, true))
        assign(\.showPreview, bool(Key.showPreview, true))
        assign(\.smallHeader, bool(Key.smallHeader, false))
        assign(\.hideSeparators, bool(Key.hideSeparators, false))
        assign(\.showGroupCounts, bool(Key.showGroupCounts, true))
        assign(\.rememberLastGroup, bool(Key.rememberLastGroup, true))
        assign(\.infoBarOnZap, bool(Key.infoBarOnZap, true))
        assign(\.reverseZap, bool(Key.reverseZap, false))
        assign(\.backupChannel, bool(Key.backupChannel, true))
        let zone = store.string(forKey: Key.calendarTimeZone) ?? ""
        if zone != calendarTimeZone { calendarTimeZone = zone }
        assign(\.calendarHideSpoilers, bool(Key.calendarHideSpoilers, true))
        let country = store.string(forKey: Key.calendarCountry) ?? ""
        if country != calendarCountry { calendarCountry = country }
        assign(\.timeshift, bool(Key.timeshift, true))
        let minutes = store.integer(forKey: Key.timeshiftMinutes)
        let keep = Self.timeshiftChoices.contains(minutes) ? minutes : 30
        if keep != timeshiftMinutes { timeshiftMinutes = keep }
        assign(\.homeRow, bool(Key.homeRow, true))
        let source = store.string(forKey: Key.homeRowSource).flatMap(HomeRowSource.init(rawValue:)) ?? .favorites
        if source != homeRowSource { homeRowSource = source }
        let clock = store.string(forKey: Key.clock).flatMap(Clock.init(rawValue:)) ?? .system
        if clock != self.clock { self.clock = clock }
    }

    /// Only real changes: assigning publishes, and every publish redraws.
    private func assign(_ path: ReferenceWritableKeyPath<LiveTVSettings, Bool>, _ value: Bool) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    private func save(_ value: Bool, _ key: String) {
        guard !loading else { return }
        ProfileSettings.current.set(value, forKey: key)
    }

    private static func makeFormatter(_ clock: Clock) -> DateFormatter {
        let formatter = DateFormatter()
        switch clock {
        case .system:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .hours24:
            formatter.dateFormat = "HH:mm"
        case .hours12:
            formatter.dateFormat = "h:mm a"
        }
        return formatter
    }
}
