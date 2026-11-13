import SwiftUI

// MARK: - Settings → Live TV → Parental Controls

/// The PIN, the automatic adult lock and turning it all off (step 11), as
/// Android's "Parental Controls". Locking a group: long press it in the guide.
struct LiveTVParentalGroup: View {
    let accentColor: Color
    @ObservedObject private var parental = LiveTVParentalControls.shared
    @State private var pinPurpose: LiveTVPinSheet.Purpose?

    var body: some View {
        LiveTVSettingsRows.group(
            title: L10n.string("livetv_parental_title", fallback: "Parental Controls"),
            subtitle: L10n.string("livetv_parental_subtitle", fallback: "Lock a group: long press it in the guide. Locked groups need the PIN to open and stay out of All Channels, search, favorites and your groups.")
        ) {
            LiveTVSettingsRows.action(
                title: parental.hasPin
                    ? L10n.string("livetv_parental_change_pin", fallback: "Change PIN")
                    : L10n.string("livetv_parental_set_pin", fallback: "Set a PIN"),
                subtitle: parental.hasPin
                    ? L10n.string("livetv_parental_on", fallback: "Parental controls are on")
                    : L10n.string("livetv_parental_turns_on", fallback: "Turns parental controls on"),
                value: parental.hasPin
                    ? L10n.string("livetv_parental_state_on", fallback: "On")
                    : L10n.string("livetv_names_off", fallback: "Off"),
                accentColor: accentColor,
                action: { pinPurpose = .setPin }
            )
            if parental.hasPin {
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_parental_adult", fallback: "Lock Adult Content Automatically"),
                    subtitle: L10n.string("livetv_parental_adult_detail", fallback: "Locks groups with names like Adult, XXX or 18+. Turning it off asks for the PIN."),
                    isOn: Binding(
                        get: { parental.lockAdult },
                        set: { on in
                            if on { parental.setLockAdult(true) } else { pinPurpose = .adultOff }
                        }),
                    accentColor: accentColor
                )
                LiveTVSettingsRows.action(
                    title: L10n.string("livetv_parental_off", fallback: "Turn Off Parental Controls"),
                    subtitle: L10n.string("livetv_parental_off_detail", fallback: "Removes the PIN. Your locked groups are remembered."),
                    value: L10n.format("livetv_parental_locked_count", fallback: "%@ locked", parental.lockedGroups.count.formatted()),
                    accentColor: accentColor,
                    action: { pinPurpose = .turnOff }
                )
            }
        }
        .sheet(item: $pinPurpose) { purpose in
            LiveTVSettingsRows.clearSheetBackground(
                LiveTVPinSheet(purpose: purpose, accentColor: accentColor))
        }
    }
}
