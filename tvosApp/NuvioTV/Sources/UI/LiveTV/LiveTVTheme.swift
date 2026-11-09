import SwiftUI
import UIKit

/// Live TV design tokens, in one place (LIVE_TV_DESIGN.md, step 0). SwiftUI
/// views and the UIKit cells read the same values, so the guide, lists and
/// overlays look like one app.
enum LiveTVTheme {
    // MARK: Color

    /// The app's accent ("Match Theme"): the profile's theme from
    /// Settings → Appearance. White is the app default.
    static var accent: Color {
        SettingsAccent.color(for: themeRaw)
    }

    static var accentUIColor: UIColor {
        UIColor(accent)
    }

    /// White accent can't mark anything on a white focus fill, so marks that
    /// sit inside focused cells (playing channel, now line) fall back to the
    /// app's red "live" color.
    static var markColor: Color {
        isWhiteAccent ? Color(red: 0.95, green: 0.27, blue: 0.27) : accent
    }

    /// The app default; white marks need a different treatment on white focus.
    static var isWhiteAccent: Bool {
        themeRaw == SettingsAccent.white.rawValue
    }

    static var markUIColor: UIColor {
        UIColor(markColor)
    }

    private static var themeRaw: String {
        ProfileSettings.current.string(forKey: SettingsKey.theme) ?? SettingsAccent.white.rawValue
    }

    /// Text on dark backgrounds.
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.6)
    static let tertiaryText = Color.white.opacity(0.4)

    // MARK: Type

    enum Font {
        static let screenTitle: CGFloat = 44
        static let programmeTitle: CGFloat = 40
        static let row: CGFloat = 26
        static let secondary: CGFloat = 22
        static let small: CGFloat = 20
        static let badge: CGFloat = 16
    }

    // MARK: Metrics

    enum Metric {
        static let rowHeight: CGFloat = 92
        static let compactRowHeight: CGFloat = 72
        static let groupRowHeight: CGFloat = 64
        static let rowSpacing: CGFloat = 8
        static let cornerRadius: CGFloat = 14
        static let panelCornerRadius: CGFloat = 28
        static let screenMargin: CGFloat = 60
        static let columnSpacing: CGFloat = 40
    }

    // MARK: Motion

    enum Motion {
        static let focusScale: CGFloat = 1.02
        static let focus = Animation.easeOut(duration: 0.12)
        /// How long focus must rest before dependent views (info panel,
        /// group contents) update, so flicking through rows stays smooth.
        /// Android uses 400 ms for groups.
        static let settleDelay: Duration = .milliseconds(350)
    }
}

// MARK: - Glass panel

/// The one panel style for overlays: info panel, quick menu, activity pill.
struct LiveTVGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = LiveTVTheme.Metric.panelCornerRadius

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
    }
}

extension View {
    func liveTVGlass(cornerRadius: CGFloat = LiveTVTheme.Metric.panelCornerRadius) -> some View {
        modifier(LiveTVGlassPanel(cornerRadius: cornerRadius))
    }
}
