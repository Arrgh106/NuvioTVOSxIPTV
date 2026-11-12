import SwiftUI

/// Rename a channel or a group (step 10a), as Android's "Rename channel":
/// empty goes back to the provider's name. Built like the other settings
/// sheets (Jellyfin server, guide sources).
struct LiveTVRenameSheet: View {
    struct Target: Identifiable {
        enum Kind {
            case channel(Int)
            case group(String)
            /// One of your own groups (step 10c): no provider's name.
            case customGroup(String)
            /// A new group of yours, with the channel it was made for.
            case newGroup(channel: Int?)
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
            case .customGroup(let groupID): return "m" + groupID
            case .newGroup(let channel): return "n\(channel ?? 0)"
            }
        }

        static func newGroup(for channel: Int? = nil) -> Target {
            Target(kind: .newGroup(channel: channel), current: "", providerName: "")
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

    /// Yours: a plain name, nothing from the provider.
    private var isMine: Bool {
        switch target.kind {
        case .customGroup, .newGroup: return true
        case .channel, .group: return false
        }
    }

    private var isNew: Bool {
        if case .newGroup = target.kind { return true }
        return false
    }

    private var title: String {
        if isNew { return L10n.string("livetv_group_new", fallback: "New Group") }
        return isChannel
            ? L10n.string("livetv_rename_channel", fallback: "Rename Channel")
            : L10n.string("livetv_rename_group", fallback: "Rename Group")
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)

                if isMine {
                    LiveTVSettingsRows.group(
                        title: isNew ? L10n.string("livetv_group_mine", fallback: "Your Group") : target.current,
                        subtitle: L10n.string("livetv_group_mine_detail", fallback: "Above the provider's groups. Its channels stay in their own groups too.")
                    ) {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_rename_name", fallback: "Name"),
                            subtitle: "",
                            placeholder: LiveTVCustomGroups.fallbackName,
                            text: $name,
                            fieldWidth: 520
                        )
                    }
                } else {
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
        let edits = LiveTVChannelEdits.shared
        if case .newGroup(let channel) = target.kind {
            edits.createCustomGroup(name: value, with: channel)
            return
        }
        // Unchanged: nothing to keep.
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) != target.current else { return }
        switch target.kind {
        case .customGroup(let groupID): edits.renameCustomGroup(id: groupID, to: value)
        case .newGroup: break
        case .channel(let streamID): edits.renameChannel(id: streamID, providerName: target.providerName, to: value)
        case .group(let groupID): edits.renameGroup(id: groupID, providerName: target.providerName, to: value)
        }
    }
}
