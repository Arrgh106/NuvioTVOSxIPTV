import Foundation

/// Background work the user should see (LIVE_TV_DESIGN.md, step 0): guide
/// download and import, channel refresh, Jellyfin sync, later VOD
/// imports. One queue, shown as a single pill in the corner of every screen,
/// like Android's "Reading guide … 17 % · 0:54".
@MainActor
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()

    struct Activity: Identifiable, Equatable {
        let id: String
        var label: String
        /// 0...1 when known.
        var fraction: Double?
        let startedAt: Date
        var failed = false
    }

    @Published private(set) var activities: [Activity] = []

    /// The one the pill shows: a failure first (so it isn't missed), else the
    /// most recent.
    var current: Activity? {
        activities.first(where: \.failed) ?? activities.last
    }

    /// Starts or updates an activity. Updates are cheap; callers already
    /// throttle progress (about 1 % steps).
    func update(_ id: String, label: String, fraction: Double? = nil) {
        if let index = activities.firstIndex(where: { $0.id == id }) {
            var activity = activities[index]
            guard activity.label != label || activity.fraction != fraction || activity.failed else { return }
            activity.label = label
            activity.fraction = fraction
            activity.failed = false
            activities[index] = activity
        } else {
            activities.append(Activity(id: id, label: label, fraction: fraction, startedAt: Date()))
        }
    }

    func finish(_ id: String) {
        activities.removeAll { $0.id == id }
    }

    /// Shows the failure for a few seconds, then removes it.
    func fail(_ id: String, message: String) {
        if let index = activities.firstIndex(where: { $0.id == id }) {
            activities[index].label = message
            activities[index].failed = true
            activities[index].fraction = nil
        } else {
            activities.append(Activity(id: id, label: message, fraction: nil, startedAt: Date(), failed: true))
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.activities.first(where: { $0.id == id })?.failed == true else { return }
            self.finish(id)
        }
    }
}
