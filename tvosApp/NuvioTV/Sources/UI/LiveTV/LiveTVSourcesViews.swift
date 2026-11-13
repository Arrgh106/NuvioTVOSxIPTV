import SwiftUI

// MARK: - Settings → Live TV / VOD → Sources

/// Where the channels come from (step 13a), as Android's "Playlists" and
/// built like Nuvio's Jellyfin servers: a row per source with its state,
/// buttons under it, and Add at the end. Several sources show in one
/// guide, each with a heading in the group column.
struct LiveTVSourcesGroup: View {
    let accentColor: Color
    @ObservedObject private var sources = LiveTVSourceStore.shared
    @ObservedObject private var store = LiveTVStore.shared
    @State private var editing: LiveTVSourceEditor.Target?
    @State private var deleting: LiveTVSource?

    var body: some View {
        LiveTVSettingsRows.group(
            title: L10n.string("livetv_sources", fallback: "Sources"),
            subtitle: L10n.string("livetv_sources_subtitle", fallback: "Where your channels come from. Several at once, all in one guide, each with a heading in the group column")
        ) {
            ForEach(sources.sources) { source in
                LiveTVSourceRow(
                    source: source,
                    status: store.sourceStatus[source.id],
                    isFirst: source.id == sources.sources.first?.id,
                    isLast: source.id == sources.sources.last?.id,
                    accentColor: accentColor,
                    onEdit: { editing = .init(source: source, isNew: false) },
                    onDelete: { deleting = source }
                )
            }
            LiveTVSettingsRows.action(
                title: L10n.string("livetv_sources_add_xtream", fallback: "Add Xtream Codes Login"),
                subtitle: L10n.string("livetv_sources_add_xtream_detail", fallback: "Sign in with the server, username and password from your provider. Its TV guide comes with it."),
                value: "",
                accentColor: accentColor,
                action: { editing = .init(source: sources.newXtream(), isNew: true) }
            )
        }
        .sheet(item: $editing) { target in
            LiveTVSettingsRows.clearSheetBackground(LiveTVSourceEditor(target: target, accentColor: accentColor))
        }
        .alert(
            L10n.format("livetv_source_delete_title", fallback: "Delete \u{201C}%@\u{201D}?", deleting?.displayName ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(L10n.string("action_cancel", fallback: "Cancel"), role: .cancel) { deleting = nil }
            Button(L10n.string("livetv_source_delete", fallback: "Delete"), role: .destructive) {
                if let source = deleting { sources.remove(source.id) }
                deleting = nil
            }
        } message: {
            Text(L10n.string("livetv_source_delete_detail", fallback: "Its channels leave the guide. Favorites, names and groups for them are kept in case you add it back."))
        }
    }
}

/// One source: name and state (channels, update, end of the account or
/// the error), Edit on OK, then Update, On / Off, Up, Down and Delete.
private struct LiveTVSourceRow: View {
    let source: LiveTVSource
    let status: LiveTVSourceStatus?
    let isFirst: Bool
    let isLast: Bool
    let accentColor: Color
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LiveTVSettingsRows.action(
                title: source.displayName + "  \u{00B7}  " + L10n.string("livetv_source_kind_xtream", fallback: "Xtream"),
                subtitle: statusText,
                value: source.enabled
                    ? L10n.string("livetv_source_on", fallback: "On")
                    : L10n.string("livetv_source_off", fallback: "Off"),
                accentColor: accentColor,
                action: onEdit
            )
            HStack(spacing: 12) {
                LiveTVSettingsRows.rowButton(
                    title: status?.loading == true
                        ? L10n.string("livetv_source_updating", fallback: "Updating…")
                        : L10n.string("livetv_source_update", fallback: "Update Now"),
                    accentColor: accentColor,
                    enabled: source.enabled,
                    isLoading: status?.loading == true
                ) {
                    LiveTVStore.shared.refresh(sourceID: source.id)
                }
                LiveTVSettingsRows.rowButton(
                    title: source.enabled
                        ? L10n.string("livetv_source_disable", fallback: "Turn Off")
                        : L10n.string("livetv_source_enable", fallback: "Turn On"),
                    accentColor: accentColor
                ) {
                    LiveTVSourceStore.shared.setEnabled(source.id, !source.enabled)
                }
                LiveTVSettingsRows.rowButton(
                    title: L10n.string("livetv_source_up", fallback: "Move Up"), accentColor: accentColor, enabled: !isFirst
                ) {
                    LiveTVSourceStore.shared.move(source.id, by: -1)
                }
                LiveTVSettingsRows.rowButton(
                    title: L10n.string("livetv_source_down", fallback: "Move Down"), accentColor: accentColor, enabled: !isLast
                ) {
                    LiveTVSourceStore.shared.move(source.id, by: 1)
                }
                Spacer()
                LiveTVSettingsRows.deleteButton(action: onDelete)
            }
            .focusSection()
        }
        .padding(.bottom, 4)
    }

    /// As Android's: "1,234 channels · Updated …", the error, not read yet,
    /// or off; with the login's end.
    private var statusText: String {
        var parts: [String] = []
        if let server = source.xtream?.server { parts.append(URL(string: server)?.host ?? server) }
        if !source.enabled {
            parts.append(L10n.string("livetv_source_disabled", fallback: "Disabled"))
            return parts.joined(separator: "  \u{00B7}  ")
        }
        if let status {
            if status.loading, status.updated == nil {
                parts.append(L10n.string("livetv_source_loading", fallback: "Loading channels…"))
            } else if let updated = status.updated {
                parts.append(L10n.format("livetv_source_channels", fallback: "%@ channels", status.channels.formatted()))
                parts.append(L10n.string("livetv_epg_sources_updated", fallback: "Updated ")
                    + updated.formatted(date: .abbreviated, time: .shortened))
            }
            if let error = status.error {
                parts.append(L10n.string("livetv_source_error", fallback: "Error: ") + error)
            }
            if let expires = status.expires {
                parts.append(L10n.string("livetv_expires", fallback: "Expires") + " "
                    + expires.formatted(date: .abbreviated, time: .omitted))
            }
            if let max = status.maxConnections {
                parts.append(L10n.string("livetv_connections", fallback: "Connections") + " \(status.activeConnections ?? 0)/\(max)")
            }
        } else {
            parts.append(L10n.string("livetv_source_not_read", fallback: "Not downloaded yet"))
        }
        return parts.joined(separator: "  \u{00B7}  ")
    }
}

// MARK: - Editor

/// Adding or changing an Xtream login: name, server, username, password,
/// stream format, on / off and its own guide. Save checks the login first,
/// so a wrong password shows here. Built like the Jellyfin server sheet.
struct LiveTVSourceEditor: View {
    struct Target: Identifiable {
        let source: LiveTVSource
        let isNew: Bool
        var id: String { source.id }
    }

    let target: Target
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var name: String
    @State private var server: String
    @State private var username: String
    @State private var password: String
    @State private var format: String
    @State private var enabled: Bool
    @State private var builtInGuide: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(target: Target, accentColor: Color) {
        self.target = target
        self.accentColor = accentColor
        let source = target.source
        _name = State(initialValue: source.name)
        _server = State(initialValue: source.xtream?.server ?? "")
        _username = State(initialValue: source.xtream?.username ?? "")
        _password = State(initialValue: target.isNew ? "" : LiveTVSourceStore.shared.password(for: source))
        _format = State(initialValue: (source.xtream?.streamFormat ?? .auto).rawValue)
        _enabled = State(initialValue: source.enabled)
        _builtInGuide = State(initialValue: source.builtInGuide)
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(target.isNew
                         ? L10n.string("livetv_source_new_xtream", fallback: "Add Xtream Codes Login")
                         : L10n.string("livetv_source_edit_xtream", fallback: "Edit Xtream Codes Login"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_source_login", fallback: "Login"),
                        subtitle: L10n.string("livetv_source_login_detail", fallback: "From your provider. The password is kept in the Keychain of this Apple TV.")
                    ) {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_source_name", fallback: "Name"),
                            subtitle: L10n.string("livetv_source_name_detail", fallback: "Shown in the group column and here. Empty: the server"),
                            placeholder: L10n.string("livetv_source_name_placeholder", fallback: "e.g. My provider"),
                            text: $name
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_source_server", fallback: "Server"),
                            subtitle: L10n.string("livetv_source_server_detail", fallback: "e.g. http://example.com:8080"),
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $server,
                            fieldWidth: 520
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_username", fallback: "Username"),
                            subtitle: "",
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $username
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_password", fallback: "Password"),
                            subtitle: "",
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $password,
                            status: errorMessage,
                            statusColor: .orange,
                            isSecure: true
                        )
                    }

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_epg_source_options", fallback: "Options"),
                        subtitle: ""
                    ) {
                        LiveTVSettingsRows.option(
                            title: L10n.string("livetv_stream_format", fallback: "Stream format"),
                            subtitle: L10n.string("livetv_source_format_detail", fallback: "Auto: HLS when the account allows it, otherwise TS"),
                            selection: $format,
                            options: XtreamStreamFormat.allCases.map(\.rawValue),
                            accentColor: accentColor,
                            optionLabel: { XtreamStreamFormat(rawValue: $0)?.title ?? $0 }
                        )
                        LiveTVSettingsRows.toggle(
                            title: L10n.string("livetv_source_use", fallback: "Use This Source"),
                            subtitle: L10n.string("livetv_source_use_detail", fallback: "Off: kept here, its channels leave the guide"),
                            isOn: $enabled,
                            accentColor: accentColor
                        )
                        LiveTVSettingsRows.toggle(
                            title: L10n.string("livetv_source_builtin_guide", fallback: "Load Built-in Guide"),
                            subtitle: L10n.string("livetv_source_builtin_guide_detail", fallback: "The provider's own TV guide for these channels"),
                            isOn: $builtInGuide,
                            accentColor: accentColor
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
                            title: isSaving
                                ? L10n.string("livetv_source_checking", fallback: "Checking…")
                                : L10n.string("action_save", fallback: "Save"),
                            isPrimary: true,
                            enabled: !isSaving && !server.trimmed.isEmpty && !username.trimmed.isEmpty && !password.isEmpty,
                            action: save
                        )
                    }
                    .focusSection()
                }
                .padding(40)
            }
        }
    }

    /// A new or changed login is checked with the panel first; the rest
    /// is saved as it is.
    private func save() {
        let normalised = XtreamAccount.normaliseServer(server)
        let user = username.trimmed
        let old = target.source.xtream
        let loginChanged = target.isNew || old?.server != normalised || old?.username != user
            || LiveTVSourceStore.shared.password(for: target.source) != password
        var source = target.source
        source.name = name.trimmed
        source.enabled = enabled
        source.builtInGuide = builtInGuide
        source.xtream = XtreamAccount(
            id: source.id,
            name: URL(string: normalised)?.host ?? normalised,
            server: normalised,
            username: user,
            streamFormat: XtreamStreamFormat(rawValue: format) ?? .auto)
        guard loginChanged, enabled else {
            LiveTVSourceStore.shared.save(source, password: loginChanged ? password : nil)
            dismiss()
            return
        }
        errorMessage = nil
        isSaving = true
        let secret = password
        Task {
            defer { isSaving = false }
            do {
                let info = try await XtreamClient(server: normalised, username: user, password: secret).login()
                // Its first load doesn't ask the panel again.
                LiveTVStore.shared.rememberVerified(info, for: source.id)
                LiveTVSourceStore.shared.save(source, password: secret)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - From Live TV

/// Live TV's Sources button: the same list as in Settings, over the guide.
struct LiveTVSourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LiveTVSourcesGroup(accentColor: LiveTVTheme.accent)
                    LiveTVSettingsRows.dialogButton(
                        title: L10n.string("livetv_vod_categories_done", fallback: "Done"), isPrimary: true
                    ) {
                        dismiss()
                    }
                    .focusSection()
                }
                .padding(40)
            }
        }
    }
}
