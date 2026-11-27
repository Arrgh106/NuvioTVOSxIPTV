import SwiftUI

/// One line of a picker window: a choice (with a check when chosen) or an
/// action.
struct LiveTVPickerOption: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
}

/// Fork: a page in Nuvio's settings-sheet look (as its AI Subtitles
/// sheet): the app's background, a title and a line under it, and the
/// rows on one glass panel. Presented with `.sheet`, as Nuvio's own; the
/// Menu button closes it.
struct LiveTVSheetPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.white)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white.opacity(0.62))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // Lazy: long lists (languages, leagues) scroll smoothly.
                    LazyVStack(spacing: 12) {
                        content
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
                    .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .frame(width: 1_000, alignment: .leading)
                .padding(.horizontal, 52)
                .padding(.vertical, 38)
            }
            .focusSection()
        }
    }
}

/// Fork: a list to pick from, as Nuvio's settings sheets: its rows on the
/// sheet's glass panel, the chosen one checked. Used for every list the
/// Live TV, Calendar and Sports pages open, instead of the system's
/// dialog. Picking a choice closes it.
struct LiveTVPickerWindow: View {
    let title: String
    var subtitle: String? = nil
    /// Kept for the callers; Nuvio's sheets show no icon.
    var systemImage = "list.bullet"
    let options: [LiveTVPickerOption]
    /// The chosen option (nil for a list of actions).
    var selected: String? = nil
    var accentColor: Color = LiveTVTheme.accent
    let onPick: (String) -> Void
    let onClose: () -> Void

    @FocusState private var focused: String?

    var body: some View {
        ScrollViewReader { proxy in
            LiveTVSheetPage(title: title, subtitle: subtitle) {
                ForEach(options) { option in
                    row(option).id(option.id)
                }
            }
            .onAppear {
                let start = options.first { $0.id == selected }?.id ?? options.first?.id
                DispatchQueue.main.async {
                    if let start {
                        proxy.scrollTo(start, anchor: .center)
                        focused = start
                    }
                }
            }
        }
        .onExitCommand(perform: onClose)
    }

    private func row(_ option: LiveTVPickerOption) -> some View {
        Button {
            onPick(option.id)
            onClose()
        } label: {
            LiveTVSettingsRows.rowShell(isFocused: focused == option.id, accentColor: accentColor) {
                if let symbol = option.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(accentColor)
                        .frame(width: 36)
                }
                if let subtitle = option.subtitle {
                    LiveTVSettingsRows.rowText(title: option.title, subtitle: subtitle)
                } else {
                    Text(option.title)
                        .font(.appFont(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 24)
                if option.id == selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .black))
                        .foregroundColor(accentColor)
                }
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused, equals: option.id)
        .focusEffectDisabledIfAvailable()
    }
}

/// Nuvio's settings glass (liquid glass on tvOS 26), for the fork's own
/// panels.
struct LiveTVGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var prominent = false

    func body(content: Content) -> some View {
        LiveTVSettingsRows.glass(content, shape: shape, prominent: prominent)
    }
}

extension View {
    /// A picker window as Nuvio's settings sheets (the system sheet over
    /// the page).
    func liveTVPicker<Window: View>(isPresented: Binding<Bool>, @ViewBuilder window: @escaping () -> Window) -> some View {
        sheet(isPresented: isPresented) { window() }
    }
}
