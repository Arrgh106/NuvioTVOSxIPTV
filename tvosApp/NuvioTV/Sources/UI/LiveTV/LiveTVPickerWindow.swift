import SwiftUI

/// One line of a picker window: a choice (with a check when chosen) or an
/// action.
struct LiveTVPickerOption: Identifiable, Hashable {
    let id: String
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    var destructive = false
}

/// Fork: Nuvio's own picker window (as its language picker in Settings): a
/// glass panel over the page with an icon, a title and a subtitle, the
/// choices as glass capsules (the chosen one checked), and Done. Used for
/// every list the Live TV, Calendar and Sports pages open, instead of the
/// system's dialog. Picking a choice closes it.
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
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    Image(systemName: systemImage)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(accentColor)
                        .frame(width: 58, height: 58)
                        .modifier(LiveTVGlass(shape: Circle(), prominent: true))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 19, weight: .medium))
                                .foregroundColor(.white.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(options) { option in
                                row(option)
                                    .id(option.id)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                    }
                    .frame(maxHeight: 520)
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
                    .buttonStyle(LiveTVInvisibleButtonStyle())
                    .focused($focused, equals: Self.doneID)
                    .scaleEffect(focused == Self.doneID ? 1.06 : 1)
                    .animation(.easeOut(duration: 0.14), value: focused == Self.doneID)
                }
                .focusSection()
            }
            .padding(34)
            .frame(width: 900)
            .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 34, style: .continuous), prominent: true))
            .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
        }
        .onExitCommand(perform: onClose)
    }

    private func row(_ option: LiveTVPickerOption) -> some View {
        let isFocused = focused == option.id
        let isSelected = option.id == selected
        return Button {
            onPick(option.id)
            onClose()
        } label: {
            HStack(spacing: 16) {
                if let symbol = option.systemImage {
                    Image(systemName: symbol)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(option.destructive ? .red : accentColor)
                        .frame(width: 34)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(option.destructive ? .red : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.56))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 24)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .black))
                        .foregroundColor(accentColor)
                }
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 72)
            .modifier(LiveTVGlass(shape: Capsule(), prominent: isFocused))
            .overlay(Capsule().strokeBorder(isFocused ? Color.white : Color.white.opacity(isSelected ? 0.28 : 0.12),
                                            lineWidth: isFocused ? 3 : 1))
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused, equals: option.id)
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
    /// showing through).
    func liveTVPicker<Window: View>(isPresented: Binding<Bool>, @ViewBuilder window: @escaping () -> Window) -> some View {
        fullScreenCover(isPresented: isPresented) {
            LiveTVSettingsRows.clearSheetBackground(window())
        }
    }
}
