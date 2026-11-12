import SwiftUI

// MARK: - Settings → Live TV → Channel Names

/// Name Cleanup and resets for renamed channels and groups (step 10a), as
/// Android's "Channel Names". Renaming itself: long press in the guide.
struct LiveTVChannelNamesGroup: View {
    let accentColor: Color
    @ObservedObject private var names = LiveTVChannelEdits.shared
    @State private var editsCleanup = false

    var body: some View {
        let edits = names.edits
        let terms = LiveTVNameCleaner.terms(edits.removals)
        LiveTVSettingsRows.group(
            title: L10n.string("livetv_names_title", fallback: "Channel Names"),
            subtitle: L10n.string("livetv_names_subtitle", fallback: "Rename a channel or a group with a long press in the guide")
        ) {
            LiveTVSettingsRows.action(
                title: L10n.string("livetv_names_cleanup", fallback: "Name Cleanup"),
                subtitle: terms.isEmpty
                    ? L10n.string("livetv_names_cleanup_detail", fallback: "Words to take off the start or end of channel names, like USA, 24/7 or FHD")
                    : terms.joined(separator: ", "),
                value: terms.isEmpty
                    ? L10n.string("livetv_names_off", fallback: "Off")
                    : L10n.format("livetv_names_removed", fallback: "%@ words", terms.count.formatted()),
                accentColor: accentColor,
                action: { editsCleanup = true }
            )
            if terms.isEmpty {
                LiveTVSettingsRows.action(
                    title: L10n.string("livetv_names_common", fallback: "Add Common Prefixes & Suffixes"),
                    subtitle: LiveTVNameCleaner.common,
                    value: "",
                    accentColor: accentColor,
                    action: { names.setRemovals(LiveTVNameCleaner.common) }
                )
            }
            LiveTVSettingsRows.toggle(
                title: L10n.string("livetv_names_groups", fallback: "Also Clean Group Names"),
                subtitle: L10n.string("livetv_names_groups_detail", fallback: "The same words come off group names"),
                isOn: Binding(get: { edits.cleanGroups }, set: { names.setCleanGroups($0) }),
                accentColor: accentColor,
                enabled: !terms.isEmpty
            )
            if !edits.channelNames.isEmpty {
                LiveTVSettingsRows.action(
                    title: L10n.string("livetv_names_reset_channels", fallback: "Reset Channel Names"),
                    subtitle: L10n.string("livetv_names_reset_channels_detail", fallback: "Every renamed channel gets its automatic name back"),
                    value: L10n.format("livetv_names_renamed", fallback: "%@ renamed", edits.channelNames.count.formatted()),
                    accentColor: accentColor,
                    action: { names.resetChannelNames() }
                )
            }
            if !edits.groupNames.isEmpty {
                LiveTVSettingsRows.action(
                    title: L10n.string("livetv_names_reset_groups", fallback: "Reset Group Names"),
                    subtitle: L10n.string("livetv_names_reset_groups_detail", fallback: "Every renamed group gets its automatic name back"),
                    value: L10n.format("livetv_names_renamed", fallback: "%@ renamed", edits.groupNames.count.formatted()),
                    accentColor: accentColor,
                    action: { names.resetGroupNames() }
                )
            }
        }
        .sheet(isPresented: $editsCleanup) {
            LiveTVSettingsRows.clearSheetBackground(
                LiveTVNameCleanupSheet(removals: edits.removals, accentColor: accentColor))
        }
    }
}

/// The words Name Cleanup takes off, comma separated.
struct LiveTVNameCleanupSheet: View {
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var text: String

    init(removals: String, accentColor: Color) {
        self.accentColor = accentColor
        _text = State(initialValue: removals)
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(L10n.string("livetv_names_cleanup", fallback: "Name Cleanup"))
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)

                LiveTVSettingsRows.group(
                    title: L10n.string("livetv_names_cleanup_words", fallback: "Prefixes and Suffixes to Remove"),
                    subtitle: L10n.string("livetv_names_cleanup_hint", fallback: "Separated by commas. Only at the start or end of a name (\"USA: ESPN HD\" → \"ESPN\"), never in the middle, and never the whole name. Renamed channels keep their name.")
                ) {
                    LiveTVSettingsRows.textField(
                        title: L10n.string("livetv_names_cleanup_field", fallback: "Words"),
                        subtitle: "",
                        placeholder: "USA, US, UK, 24/7, FHD, HD",
                        text: $text,
                        fieldWidth: 700
                    )
                    LiveTVSettingsRows.action(
                        title: L10n.string("livetv_names_common", fallback: "Add Common Prefixes & Suffixes"),
                        subtitle: LiveTVNameCleaner.common,
                        value: "",
                        accentColor: accentColor,
                        action: {
                            let merged = LiveTVNameCleaner.terms(text + "," + LiveTVNameCleaner.common)
                            text = Self.inOrder(text, merged).joined(separator: ", ")
                        }
                    )
                }

                HStack(spacing: 24) {
                    LiveTVSettingsRows.dialogButton(
                        title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false
                    ) {
                        dismiss()
                    }
                    Spacer()
                    LiveTVSettingsRows.dialogButton(
                        title: L10n.string("action_save", fallback: "Save"), isPrimary: true
                    ) {
                        LiveTVChannelEdits.shared.setRemovals(
                            LiveTVNameCleaner.terms(text).isEmpty ? "" : text)
                        dismiss()
                    }
                }
                .focusSection()
                Spacer()
            }
            .padding(40)
        }
    }

    /// The words as typed first, then the added ones (the list is sorted
    /// longest first only when used).
    private static func inOrder(_ typed: String, _ all: [String]) -> [String] {
        let first = typed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        return (first + all).filter { seen.insert($0).inserted }
    }
}
