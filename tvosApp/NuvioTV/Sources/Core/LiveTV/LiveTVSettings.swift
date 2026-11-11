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
    }

    private var loading = false
    private var formatter = LiveTVSettings.makeFormatter(.system)
    private var observer: NSObjectProtocol?

    private init() {
        load()
        // Another profile: its own options.
        observer = NotificationCenter.default.addObserver(
            forName: ProfileSettings.settingsChangedNotification, object: nil, queue: .main
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
