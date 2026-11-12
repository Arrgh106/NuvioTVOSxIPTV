import SwiftUI

/// Long press a channel → Add to Group… (step 10c), as Android's group
/// picker: one of your groups, or a new one with this channel in it.
struct LiveTVAddToGroupSheet: View {
    struct Target: Identifiable {
        let channel: XtreamLiveChannel
        var id: Int { channel.streamID }
    }

    let target: Target
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @ObservedObject private var edits = LiveTVChannelEdits.shared
    @State private var newName = ""

    var body: some View {
        let channel = target.channel
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L10n.string("livetv_group_add_title", fallback: "Add to Group"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    if !edits.customGroups.isEmpty {
                        LiveTVSettingsRows.group(
                            title: channel.name,
                            subtitle: L10n.string("livetv_group_add_detail", fallback: "It stays in its own group too")
                        ) {
                            ForEach(edits.customGroups) { group in
                                let isIn = group.channelIDs.contains(channel.streamID)
                                LiveTVSettingsRows.action(
                                    title: group.name,
                                    subtitle: isIn
                                        ? L10n.string("livetv_group_in_detail", fallback: "Already in this group. Select to take it out.")
                                        : L10n.format("livetv_group_count", fallback: "%@ channels", group.channelIDs.count.formatted()),
                                    value: isIn ? L10n.string("livetv_group_in", fallback: "Added") : "",
                                    accentColor: accentColor,
                                    action: {
                                        if isIn {
                                            edits.removeFromCustomGroup(id: group.id, channel: channel.streamID)
                                        } else {
                                            edits.addToCustomGroup(id: group.id, channel: channel.streamID)
                                            dismiss()
                                        }
                                    }
                                )
                            }
                        }
                    }

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_group_new", fallback: "New Group"),
                        subtitle: L10n.string("livetv_group_new_detail", fallback: "Made with this channel in it, above the provider's groups")
                    ) {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_rename_name", fallback: "Name"),
                            subtitle: "",
                            placeholder: LiveTVCustomGroups.fallbackName,
                            text: $newName,
                            fieldWidth: 520
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
                            title: L10n.string("livetv_group_create", fallback: "Make Group"), isPrimary: true
                        ) {
                            edits.createCustomGroup(name: newName, with: channel.streamID)
                            dismiss()
                        }
                    }
                    .focusSection()
                }
                .padding(40)
            }
        }
    }
}
