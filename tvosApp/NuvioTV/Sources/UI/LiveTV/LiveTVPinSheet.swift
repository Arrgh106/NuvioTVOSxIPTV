import SwiftUI

/// The parental PIN (step 11), as Android's PIN dialogs: open a locked
/// group, take a lock off, set or change the PIN, turn parental controls
/// off. Built like the other settings sheets.
struct LiveTVPinSheet: View {
    enum Purpose: Identifiable {
        case unlock(LiveTVGroup)
        case removeLock(LiveTVGroup)
        case setPin
        case turnOff
        case adultOff

        var id: String {
            switch self {
            case .unlock(let group): return "u" + group.id
            case .removeLock(let group): return "r" + group.id
            case .setPin: return "set"
            case .turnOff: return "off"
            case .adultOff: return "adult"
            }
        }
    }

    let purpose: Purpose
    let accentColor: Color
    /// After a group was opened with the PIN.
    var onUnlocked: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var current = ""
    @State private var newPin = ""
    @State private var repeated = ""
    @State private var problem: String?

    private var parental: LiveTVParentalControls { .shared }

    /// Setting a PIN while one is set asks for the old one first.
    private var asksCurrent: Bool {
        if case .setPin = purpose { return parental.hasPin }
        return true
    }

    private var asksNew: Bool {
        if case .setPin = purpose { return true }
        return false
    }

    private var title: String {
        switch purpose {
        case .unlock: return L10n.string("livetv_parental_locked", fallback: "Locked Group")
        case .removeLock: return L10n.string("livetv_parental_unlock_group", fallback: "Remove Parental Lock")
        case .setPin:
            return parental.hasPin
                ? L10n.string("livetv_parental_change_pin", fallback: "Change PIN")
                : L10n.string("livetv_parental_set_pin", fallback: "Set a PIN")
        case .turnOff: return L10n.string("livetv_parental_off", fallback: "Turn Off Parental Controls")
        case .adultOff: return L10n.string("livetv_parental_adult", fallback: "Lock Adult Content Automatically")
        }
    }

    private var detail: String {
        switch purpose {
        case .unlock(let group):
            return L10n.format("livetv_parental_unlock_detail", fallback: "\u{201C}%@\u{201D} needs the PIN. It stays open until the app is closed.", group.name)
        case .removeLock(let group):
            return L10n.format("livetv_parental_remove_detail", fallback: "\u{201C}%@\u{201D} opens without the PIN again.", group.name)
        case .setPin:
            return L10n.string("livetv_parental_pin_detail", fallback: "4 to 8 digits. Locked groups need it to open and stay out of All Channels, search, favorites and your groups.")
        case .turnOff:
            return L10n.string("livetv_parental_off_detail", fallback: "Removes the PIN. Your locked groups are remembered.")
        case .adultOff:
            return L10n.string("livetv_parental_adult_off_detail", fallback: "Groups with names like Adult, XXX or 18+ open without the PIN again.")
        }
    }

    private var confirmTitle: String {
        switch purpose {
        case .unlock: return L10n.string("livetv_parental_unlock", fallback: "Unlock")
        case .removeLock: return L10n.string("livetv_parental_remove", fallback: "Remove Lock")
        case .setPin: return L10n.string("action_save", fallback: "Save")
        case .turnOff, .adultOff: return L10n.string("livetv_parental_turn_off", fallback: "Turn Off")
        }
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)

                LiveTVSettingsRows.group(
                    title: L10n.string("livetv_parental_title", fallback: "Parental Controls"),
                    subtitle: detail
                ) {
                    if asksCurrent {
                        LiveTVSettingsRows.textField(
                            title: asksNew
                                ? L10n.string("livetv_parental_current", fallback: "Current PIN")
                                : L10n.string("livetv_parental_pin", fallback: "PIN"),
                            subtitle: "",
                            placeholder: "••••",
                            text: $current,
                            fieldWidth: 300,
                            status: asksNew ? nil : problem,
                            statusColor: .orange,
                            isSecure: true
                        )
                    }
                    if asksNew {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_parental_new", fallback: "New PIN"),
                            subtitle: "",
                            placeholder: "••••",
                            text: $newPin,
                            fieldWidth: 300,
                            status: problem,
                            statusColor: .orange,
                            isSecure: true
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_parental_repeat", fallback: "Repeat New PIN"),
                            subtitle: "",
                            placeholder: "••••",
                            text: $repeated,
                            fieldWidth: 300,
                            isSecure: true
                        )
                    }
                }

                HStack(spacing: 24) {
                    LiveTVSettingsRows.dialogButton(
                        title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false
                    ) {
                        dismiss()
                    }
                    Spacer()
                    LiveTVSettingsRows.dialogButton(title: confirmTitle, isPrimary: true) {
                        confirm()
                    }
                }
                .focusSection()
                Spacer()
            }
            .padding(40)
        }
    }

    private func confirm() {
        let wrong = L10n.string("livetv_parental_wrong", fallback: "Wrong PIN, try again")
        if asksCurrent, !parental.check(current) {
            problem = wrong
            current = ""
            return
        }
        switch purpose {
        case .unlock(let group):
            guard parental.unlock(group.id, pin: current) else { problem = wrong; return }
            dismiss()
            onUnlocked(group.id)
        case .removeLock(let group):
            parental.removeLock(group.id)
            dismiss()
        case .setPin:
            let pin = LiveTVParental.normalized(newPin)
            guard LiveTVParental.isValidPin(pin) else {
                problem = L10n.string("livetv_parental_pin_digits", fallback: "The PIN needs 4 to 8 digits")
                return
            }
            guard pin == LiveTVParental.normalized(repeated) else {
                problem = L10n.string("livetv_parental_pin_mismatch", fallback: "The two PINs aren\u{2019}t the same")
                repeated = ""
                return
            }
            _ = parental.setPin(pin)
            dismiss()
        case .turnOff:
            parental.turnOff()
            dismiss()
        case .adultOff:
            parental.setLockAdult(false)
            dismiss()
        }
    }
}
