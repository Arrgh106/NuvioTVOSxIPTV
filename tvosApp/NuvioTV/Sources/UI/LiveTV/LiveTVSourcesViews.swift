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
                title: L10n.string("livetv_sources_add_m3u", fallback: "Add M3U Playlist"),
                subtitle: L10n.string("livetv_sources_add_m3u_detail", fallback: "A channel list from the M3U link your provider gave you"),
                value: "",
                accentColor: accentColor,
                action: { editing = .init(source: sources.newPlaylist(), isNew: true) }
            )
            LiveTVSettingsRows.action(
                title: L10n.string("livetv_sources_add_xtream", fallback: "Add Xtream Codes Login"),
                subtitle: L10n.string("livetv_sources_add_xtream_detail", fallback: "Sign in with the server, username and password from your provider. Its TV guide comes with it."),
                value: "",
                accentColor: accentColor,
                action: { editing = .init(source: sources.newXtream(), isNew: true) }
            )
            LiveTVSettingsRows.action(
                title: L10n.string("livetv_sources_add_stalker", fallback: "Add Stalker Portal"),
                subtitle: L10n.string("livetv_sources_add_stalker_detail", fallback: "A Stalker / Ministra portal with the MAC address your provider registered. Its TV guide comes with it."),
                value: "",
                accentColor: accentColor,
                action: { editing = .init(source: sources.newStalker(), isNew: true) }
            )
        }
        .sheet(item: $editing) { target in
            if target.source.kind == .m3u {
                LiveTVSettingsRows.clearSheetBackground(LiveTVPlaylistEditor(target: target, accentColor: accentColor))
            } else if target.source.kind == .stalker {
                LiveTVSettingsRows.clearSheetBackground(LiveTVStalkerEditor(target: target, accentColor: accentColor))
            } else {
                LiveTVSettingsRows.clearSheetBackground(LiveTVSourceEditor(target: target, accentColor: accentColor))
            }
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
                title: source.displayName + "  \u{00B7}  " + kindLabel,
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

    private var kindLabel: String {
        switch source.kind {
        case .m3u: return L10n.string("livetv_source_kind_m3u", fallback: "M3U")
        case .stalker: return L10n.string("livetv_source_kind_stalker", fallback: "Stalker")
        case .xtream: return L10n.string("livetv_source_kind_xtream", fallback: "Xtream")
        }
    }

    /// As Android's: "1,234 channels · Updated …", the error, not read yet,
    /// or off; with the login's end.
    private var statusText: String {
        var parts: [String] = []
        if let server = source.xtream?.server ?? source.portal { parts.append(URL(string: server)?.host ?? server) }
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
    /// The form opens on its first field (not on the switches below).
    @Namespace private var formScope
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var name: String
    @State private var server: String
    @State private var username: String
    @State private var password: String
    @State private var format: String
    @State private var enabled: Bool
    @State private var builtInGuide: Bool
    @State private var importVOD: Bool
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
        _importVOD = State(initialValue: source.readsVOD)
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
                        .prefersDefaultFocus(true, in: formScope)
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
                            subtitle: L10n.string("livetv_source_builtin_guide_detail", fallback: "The provider's own TV guide, for these channels only (guides you add go for all)"),
                            isOn: $builtInGuide,
                            accentColor: accentColor
                        )
                        LiveTVSettingsRows.toggle(
                            title: L10n.string("livetv_source_import_vod", fallback: "Include Movies & Series (VOD)"),
                            subtitle: L10n.string("livetv_source_import_vod_detail", fallback: "Read the provider's movies and series at start, for the VOD page, Home and stream lists. Off: live channels only"),
                            isOn: $importVOD,
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
                .focusScope(formScope)
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
        source.importVOD = importVOD
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

/// Adding or changing an M3U playlist (step 13b), as Android's "Add M3U
/// playlist": name, link, user agent, on / off and the guide linked in it.
struct LiveTVPlaylistEditor: View {
    let target: LiveTVSourceEditor.Target
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    /// The form opens on its first field (not on the switches below).
    @Namespace private var formScope
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var name: String
    @State private var link: String
    @State private var userAgent: String
    @State private var enabled: Bool
    @State private var builtInGuide: Bool
    @State private var invalid = false

    init(target: LiveTVSourceEditor.Target, accentColor: Color) {
        self.target = target
        self.accentColor = accentColor
        let source = target.source
        _name = State(initialValue: source.name)
        _link = State(initialValue: target.isNew ? "" : LiveTVSourceStore.shared.password(for: source))
        _userAgent = State(initialValue: source.userAgent ?? "")
        _enabled = State(initialValue: source.enabled)
        _builtInGuide = State(initialValue: source.builtInGuide)
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(target.isNew
                         ? L10n.string("livetv_source_new_m3u", fallback: "Add M3U Playlist")
                         : L10n.string("livetv_source_edit_m3u", fallback: "Edit M3U Playlist"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_source_playlist", fallback: "Playlist"),
                        subtitle: L10n.string("livetv_source_playlist_detail", fallback: "The link is kept in the Keychain of this Apple TV (it often holds your login). Movies and series in the list are left out.")
                    ) {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_source_name", fallback: "Name"),
                            subtitle: L10n.string("livetv_source_name_detail_m3u", fallback: "Shown in the group column and here"),
                            placeholder: L10n.string("livetv_source_name_placeholder", fallback: "e.g. My provider"),
                            text: $name
                        )
                        .prefersDefaultFocus(true, in: formScope)
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_source_link", fallback: "Playlist Link"),
                            subtitle: L10n.string("livetv_source_link_detail", fallback: "e.g. http://example.com/playlist.m3u"),
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $link,
                            fieldWidth: 520,
                            status: invalid
                                ? L10n.string("livetv_epg_source_invalid", fallback: "Enter a link starting with http:// or https://")
                                : nil,
                            statusColor: .orange
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_source_user_agent", fallback: "User Agent"),
                            subtitle: L10n.string("livetv_source_user_agent_detail", fallback: "Optional. Empty: the app's (VLC). Some providers need their own"),
                            placeholder: L10n.string("livetv_source_user_agent_default", fallback: "Default"),
                            text: $userAgent,
                            fieldWidth: 520
                        )
                    }

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_epg_source_options", fallback: "Options"),
                        subtitle: ""
                    ) {
                        LiveTVSettingsRows.toggle(
                            title: L10n.string("livetv_source_use", fallback: "Use This Source"),
                            subtitle: L10n.string("livetv_source_use_detail", fallback: "Off: kept here, its channels leave the guide"),
                            isOn: $enabled,
                            accentColor: accentColor
                        )
                        LiveTVSettingsRows.toggle(
                            title: L10n.string("livetv_source_linked_guide", fallback: "Load Guide Linked in Playlist"),
                            subtitle: L10n.string("livetv_source_linked_guide_detail", fallback: "The TV guide the playlist names (x-tvg-url), read with the others"),
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
                            title: L10n.string("action_save", fallback: "Save"),
                            isPrimary: true,
                            enabled: !link.trimmed.isEmpty,
                            action: save
                        )
                    }
                    .focusSection()
                }
                .padding(40)
                .focusScope(formScope)
            }
        }
    }

    private func save() {
        let cleaned = link.trimmed
        guard let url = URL(string: cleaned), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else {
            invalid = true
            return
        }
        invalid = false
        var source = target.source
        source.name = name.trimmed.isEmpty ? (url.host ?? "") : name.trimmed
        source.enabled = enabled
        source.builtInGuide = builtInGuide
        source.userAgent = userAgent.trimmed.isEmpty ? nil : userAgent.trimmed
        let changed = target.isNew || LiveTVSourceStore.shared.password(for: target.source) != cleaned
        LiveTVSourceStore.shared.save(source, password: changed ? cleaned : nil)
        dismiss()
    }
}

/// Adding or changing a Stalker / Ministra portal (step 13e), as Android's
/// "Add Stalker portal": the portal, the MAC address the provider
/// registered, a login where the portal asks for one, and the device ids
/// a few portals check. Save signs in first, so a wrong MAC shows here.
struct LiveTVStalkerEditor: View {
    let target: LiveTVSourceEditor.Target
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var name: String
    @State private var config: LiveTVStalkerConfig
    @State private var enabled: Bool
    @State private var builtInGuide: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(target: LiveTVSourceEditor.Target, accentColor: Color) {
        self.target = target
        self.accentColor = accentColor
        let source = target.source
        _name = State(initialValue: source.name)
        _config = State(initialValue: (target.isNew ? nil : LiveTVStalker.config(for: source.id))
            ?? LiveTVStalkerConfig(portal: "", mac: "", timezone: TimeZone.current.identifier))
        _enabled = State(initialValue: source.enabled)
        _builtInGuide = State(initialValue: source.builtInGuide)
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(target.isNew
                         ? L10n.string("livetv_source_new_stalker", fallback: "Add Stalker Portal")
                         : L10n.string("livetv_source_edit_stalker", fallback: "Edit Stalker Portal"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_stalker_portal_group", fallback: "Portal"),
                        subtitle: L10n.string("livetv_stalker_portal_group_detail", fallback: "From your provider. Kept in the Keychain of this Apple TV.")
                    ) {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_source_name", fallback: "Name"),
                            subtitle: L10n.string("livetv_source_name_detail", fallback: "Shown in the group column and here. Empty: the server"),
                            placeholder: L10n.string("livetv_source_name_placeholder", fallback: "e.g. My provider"),
                            text: $name
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_stalker_portal", fallback: "Portal Address"),
                            subtitle: L10n.string("livetv_stalker_portal_detail", fallback: "e.g. http://example.com:8080/c/"),
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $config.portal,
                            fieldWidth: 520
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_stalker_mac", fallback: "MAC Address"),
                            subtitle: L10n.string("livetv_stalker_mac_detail", fallback: "The one your provider registered, e.g. 00:1A:79:12:34:56"),
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $config.mac,
                            status: errorMessage,
                            statusColor: .orange
                        )
                    }

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_stalker_login_group", fallback: "Login (only if your provider gave you one)"),
                        subtitle: L10n.string("livetv_stalker_login_group_detail", fallback: "Most portals sign in with the MAC address alone")
                    ) {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_username", fallback: "Username"),
                            subtitle: "",
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $config.username
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_password", fallback: "Password"),
                            subtitle: "",
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $config.password,
                            isSecure: true
                        )
                    }

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_stalker_device_group", fallback: "Device (only if your provider asks)"),
                        subtitle: L10n.string("livetv_stalker_device_group_detail", fallback: "A few portals also check the box's serial number, device ids or signature")
                    ) {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_stalker_serial", fallback: "Serial Number"),
                            subtitle: "",
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $config.serialNumber
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_stalker_device_id", fallback: "Device ID"),
                            subtitle: "",
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $config.deviceID,
                            fieldWidth: 520
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_stalker_device_id2", fallback: "Device ID 2"),
                            subtitle: "",
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $config.deviceID2,
                            fieldWidth: 520
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_stalker_signature", fallback: "Signature"),
                            subtitle: "",
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $config.signature,
                            fieldWidth: 520
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_stalker_timezone", fallback: "Time Zone"),
                            subtitle: L10n.string("livetv_stalker_timezone_detail", fallback: "The portal's guide times, e.g. Europe/Berlin"),
                            placeholder: TimeZone.current.identifier,
                            text: $config.timezone
                        )
                    }

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_epg_source_options", fallback: "Options"),
                        subtitle: ""
                    ) {
                        LiveTVSettingsRows.toggle(
                            title: L10n.string("livetv_source_use", fallback: "Use This Source"),
                            subtitle: L10n.string("livetv_source_use_detail", fallback: "Off: kept here, its channels leave the guide"),
                            isOn: $enabled,
                            accentColor: accentColor
                        )
                        LiveTVSettingsRows.toggle(
                            title: L10n.string("livetv_source_builtin_guide", fallback: "Load Built-in Guide"),
                            subtitle: L10n.string("livetv_source_builtin_guide_detail", fallback: "The provider's own TV guide, for these channels only (guides you add go for all)"),
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
                            enabled: !isSaving && !config.portal.trimmed.isEmpty && !config.mac.trimmed.isEmpty,
                            action: save
                        )
                    }
                    .focusSection()
                }
                .padding(40)
            }
        }
    }

    /// A new or changed portal is signed in to first; the rest is saved
    /// as it is.
    private func save() {
        var cleaned = config
        cleaned.portal = config.portal.trimmed
        cleaned.username = config.username.trimmed
        cleaned.serialNumber = config.serialNumber.trimmed
        cleaned.deviceID = config.deviceID.trimmed
        cleaned.deviceID2 = config.deviceID2.trimmed
        cleaned.signature = config.signature.trimmed
        cleaned.timezone = TimeZone(identifier: config.timezone.trimmed) == nil
            ? TimeZone.current.identifier : config.timezone.trimmed
        guard let url = URL(string: cleaned.portal), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else {
            errorMessage = LiveTVStalkerError.invalidPortal.localizedDescription
            return
        }
        guard let mac = LiveTVStalkerConfig.normalisedMAC(config.mac) else {
            errorMessage = LiveTVStalkerError.invalidMAC.localizedDescription
            return
        }
        cleaned.mac = mac
        var source = target.source
        source.name = name.trimmed
        source.enabled = enabled
        source.builtInGuide = builtInGuide
        source.portal = cleaned.portal
        let changed = target.isNew || LiveTVStalker.config(for: source.id) != cleaned
        let secret = LiveTVStalker.encoded(cleaned)
        guard changed, enabled else {
            LiveTVSourceStore.shared.save(source, password: changed ? secret : nil)
            dismiss()
            return
        }
        errorMessage = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await LiveTVStalkerClient(config: cleaned).authenticate()
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
