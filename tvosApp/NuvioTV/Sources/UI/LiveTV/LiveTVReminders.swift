import SwiftUI
import UIKit

/// Programme reminders (LIVE_TV_DESIGN.md, step 7a), as Android's
/// `LiveTvReminderHost`: per profile, checked every 10 s while the app is
/// open. A minute before the start a prompt comes up over any screen with
/// Watch (Live TV, full screen, on the channel) and Dismiss.
///
/// The prompts are tvOS alerts: they take the remote from whatever screen is
/// below (guide, full screen, Home) without that screen having to give up
/// focus itself.
@MainActor
final class LiveTVReminders: ObservableObject {
    static let shared = LiveTVReminders()
    /// The guide redraws its bells on this.
    static let changedNotification = Notification.Name("nuvio.tv.livetv.reminders.changed")

    @Published private(set) var list = LiveTVReminderList()
    /// Watch on a prompt: Live TV plays this channel full screen.
    @Published var pendingWatch: LiveTVReminder?

    private static let key = "nuvio.tv.livetv.reminders"
    private var canPrompt: () -> Bool = { false }
    private var canWatch: () -> Bool = { false }
    private var openLiveTV: () -> Void = {}
    private var shown: Set<String> = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    private init() {
        load()
        // Another profile: its own reminders.
        observer = NotificationCenter.default.addObserver(
            forName: ProfileSettings.settingsChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    /// Called once by the app. `canPrompt`: not on the sign-in or profile
    /// screens; `canWatch`: not while a film plays (Dismiss only then).
    func start(canPrompt: @escaping () -> Bool, canWatch: @escaping () -> Bool, openLiveTV: @escaping () -> Void) {
        self.canPrompt = canPrompt
        self.canWatch = canWatch
        self.openLiveTV = openLiveTV
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    func isSet(channelID: Int, start: Date) -> Bool {
        list.contains(channelID: channelID, start: start)
    }

    /// Remind me / Cancel reminder.
    func toggle(channel: XtreamLiveChannel, programme: XtreamProgram) {
        list.toggle(LiveTVReminder(
            channelID: channel.streamID, channelName: channel.name, title: programme.title, start: programme.start))
        changed()
    }

    func remove(_ reminder: LiveTVReminder) {
        list.remove(reminder)
        changed()
    }

    // MARK: Asking

    /// OK on a show to come (guide, overlay schedule): set or cancel its
    /// reminder.
    func ask(channel: XtreamLiveChannel, programme: XtreamProgram) {
        let set = isSet(channelID: channel.streamID, start: programme.start)
        var actions: [LiveTVAlert.Action] = []
        if set {
            actions.append(.init(
                title: L10n.string("livetv_reminder_cancel", fallback: "Cancel reminder"), style: .destructive
            ) { [weak self] in self?.toggle(channel: channel, programme: programme) })
        } else {
            actions.append(.init(
                title: L10n.string("livetv_reminder_set", fallback: "Remind me"), style: .default, preferred: true
            ) { [weak self] in self?.toggle(channel: channel, programme: programme) })
        }
        actions.append(.init(title: L10n.string("livetv_reminder_close", fallback: "Close"), style: .cancel) {})
        LiveTVAlert.present(
            title: programme.title,
            message: LiveTVInfoPanel.clock(programme.start, now: Date()) + "  ·  " + channel.name,
            actions: actions)
    }

    // MARK: Firing

    private func check() {
        let now = Date()
        if list.prune(now: now) { changed() }
        guard !LiveTVAlert.isShowing, canPrompt(),
              let reminder = list.due(now: now, shown: shown) else { return }
        shown.insert(reminder.id)
        prompt(reminder, now: now)
    }

    private func prompt(_ reminder: LiveTVReminder, now: Date) {
        let started = now >= reminder.start
        let title = started
            ? L10n.string("livetv_reminder_now", fallback: "Starting now")
            : L10n.string("livetv_reminder_soon", fallback: "Starting in a minute")
        let message = reminder.title + "\n" + LiveTVSettings.shared.time(reminder.start) + "  ·  " + reminder.channelName
        var actions: [LiveTVAlert.Action] = []
        if canWatch() {
            actions.append(.init(
                title: L10n.string("livetv_reminder_watch", fallback: "Watch"), style: .default, preferred: true
            ) { [weak self] in
                guard let self else { return }
                self.remove(reminder)
                self.pendingWatch = reminder
                self.openLiveTV()
            })
        }
        actions.append(.init(title: L10n.string("livetv_reminder_dismiss", fallback: "Dismiss"), style: .cancel) {
            [weak self] in self?.remove(reminder)
        })
        // Gone by itself after two minutes, as on Android.
        LiveTVAlert.present(title: title, message: message, actions: actions, closeAfter: 120) { [weak self] in
            self?.remove(reminder)
        }
    }

    // MARK: Storage

    private func changed() {
        if let data = try? JSONEncoder().encode(list.items) {
            ProfileSettings.current.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func load() {
        let items = ProfileSettings.current.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([LiveTVReminder].self, from: $0) } ?? []
        let loaded = LiveTVReminderList(items)
        guard loaded != list else { return }
        list = loaded
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }
}

/// A tvOS alert over whatever is on screen, for Live TV's questions.
@MainActor
enum LiveTVAlert {
    struct Action {
        let title: String
        let style: UIAlertAction.Style
        var preferred = false
        let handler: () -> Void
    }

    /// Full screen takes the remote back on this.
    static let closedNotification = Notification.Name("nuvio.tv.livetv.alert.closed")

    private static weak var current: UIAlertController?

    /// An alert is up: the full-screen swipes and Play/Pause leave it alone.
    static var isShowing: Bool { current != nil }

    static func present(
        title: String, message: String, actions: [Action],
        closeAfter seconds: Double? = nil, onTimeout: @escaping () -> Void = {}
    ) {
        guard current == nil, let top = topController() else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for action in actions {
            let item = UIAlertAction(title: action.title, style: action.style) { _ in
                action.handler()
                closed()
            }
            alert.addAction(item)
            if action.preferred { alert.preferredAction = item }
        }
        current = alert
        top.present(alert, animated: true)
        if let seconds {
            Task { @MainActor [weak alert] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let alert, alert === current, alert.presentingViewController != nil else { return }
                alert.dismiss(animated: true)
                onTimeout()
                closed()
            }
        }
    }

    private static func closed() {
        current = nil
        NotificationCenter.default.post(name: closedNotification, object: nil)
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
