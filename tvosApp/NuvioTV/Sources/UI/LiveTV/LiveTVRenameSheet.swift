import SwiftUI

/// Rename a channel or a group (step 10a), as Android's "Rename channel":
/// empty goes back to the provider's name. Built like the other settings
/// sheets (Jellyfin server, guide sources).
struct LiveTVRenameSheet: View {
    struct Target: Identifiable {
        enum Kind {
            case channel(Int)
            case group(String)
        }

        let kind: Kind
        /// The name shown now (renamed or cleaned).
        let current: String
        /// What the provider calls it.
        let providerName: String

        var id: String {
            switch kind {
            case .channel(let streamID): return "c\(streamID)"
            case .group(let groupID): return "g" + groupID
            }
        }

        static func channel(_ channel: XtreamLiveChannel) -> Target {
            Target(kind: .channel(channel.streamID), current: channel.name, providerName: channel.originalName)
        }
    }

    let target: Target
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var name: String

    init(target: Target, accentColor: Color) {
        self.target = target
        self.accentColor = accentColor
        _name = State(initialValue: target.current)
    }

    private var isChannel: Bool {
        if case .channel = target.kind { return true }
        return false
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(isChannel
                     ? L10n.string("livetv_rename_channel", fallback: "Rename Channel")
                     : L10n.string("livetv_rename_group", fallback: "Rename Group"))
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)

                LiveTVSettingsRows.group(
                    title: target.current,
                    subtitle: L10n.format(
                        "livetv_rename_provider", fallback: "Provider's name: %@", target.providerName)
                ) {
                    LiveTVSettingsRows.textField(
                        title: L10n.string("livetv_rename_name", fallback: "Name"),
                        subtitle: L10n.string("livetv_rename_empty", fallback: "Leave empty for the automatic name (the provider's, after Name Cleanup)"),
                        placeholder: target.providerName,
                        text: $name,
                        fieldWidth: 520
                    )
                    if target.current != target.providerName {
                        LiveTVSettingsRows.action(
                            title: L10n.string("livetv_rename_restore", fallback: "Use the Provider's Name"),
                            subtitle: target.providerName,
                            value: "",
                            accentColor: accentColor,
                            action: { save(target.providerName) }
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
                    LiveTVSettingsRows.dialogButton(
                        title: L10n.string("action_save", fallback: "Save"), isPrimary: true
                    ) {
                        save(name)
                    }
                }
                .focusSection()
                Spacer()
            }
            .padding(40)
        }
    }

    private func save(_ value: String) {
        defer { dismiss() }
        // Unchanged: nothing to keep.
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) != target.current else { return }
        let edits = LiveTVChannelEdits.shared
        switch target.kind {
        case .channel(let streamID): edits.renameChannel(id: streamID, to: value)
        case .group(let groupID): edits.renameGroup(id: groupID, to: value)
        }
    }
}
