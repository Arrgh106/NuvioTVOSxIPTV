import SwiftUI

/// One line of a picker window: a choice (with a check when chosen) or an
/// action.
struct LiveTVPickerOption: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
}

/// Fork: a list to pick from, in Nuvio's settings look (as its Add-ons
/// page): the page behind darkened away, a title and subtitle on top, the
/// choices as Nuvio's settings rows on a glass panel (the chosen one
/// checked), Done at the bottom. Used for every list the Live TV, Calendar
/// and Sports pages open, instead of the system's dialog. Picking a choice
/// closes it.
struct LiveTVPickerWindow: View {
    let title: String
    var subtitle: String? = nil
    var systemImage = "list.bullet"
    let options: [LiveTVPickerOption]
    /// The chosen option (nil for a list of actions).
    var selected: String? = nil
    var accentColor: Color = LiveTVTheme.accent
    let onPick: (String) -> Void
    let onClose: () -> Void

    @FocusState private var focused: String?

    private static let doneID = "\u{0}done"

    var body: some View {
        ZStack {
            // Over the page as a page of its own (the rows read on any page).
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    Image(systemName: systemImage)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(accentColor)
                        .frame(width: 56, height: 56)
                        .modifier(LiveTVGlass(shape: Circle(), prominent: true))
                    VStack(alignment: .leading, spacing: 6) {
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
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(options) { option in
                                row(option).id(option.id)
                            }
                        }
                        .padding(24)
                    }
                    .frame(maxHeight: 640)
                    .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
                    .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
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
                .focusSection()
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        HStack(spacing: 10) {
                            Image(systemName: selected == nil ? "xmark" : "checkmark")
                                .font(.system(size: 18, weight: .bold))
                            Text(selected == nil ? L10n.string("cancel", fallback: "Cancel")
                                                 : L10n.string("tvos_common_done", fallback: "Done"))
                                .font(.system(size: 21, weight: .bold))
                        }
                        .foregroundColor(focused == Self.doneID ? .black : .white)
                        .padding(.horizontal, 26)
                        .frame(height: 58)
                        .background(Capsule().fill(focused == Self.doneID ? Color.white : Color.white.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($focused, equals: Self.doneID)
                    .focusEffectDisabledIfAvailable()
                    .scaleEffect(focused == Self.doneID ? 1.06 : 1)
                    .animation(.easeOut(duration: 0.14), value: focused == Self.doneID)
                }
                .focusSection()
            }
            .frame(width: 1100)
            .padding(.vertical, 50)
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
                        .font(.system(size: 22, weight: .semibold))
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
    /// A picker window over everything (a full-screen cover with the page
    /// showing through, darkened).
    func liveTVPicker<Window: View>(isPresented: Binding<Bool>, @ViewBuilder window: @escaping () -> Window) -> some View {
        fullScreenCover(isPresented: isPresented) {
            LiveTVSettingsRows.clearSheetBackground(window())
        }
    }
}
