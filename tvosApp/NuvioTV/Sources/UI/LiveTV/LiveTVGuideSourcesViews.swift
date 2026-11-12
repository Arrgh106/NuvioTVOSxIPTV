import SwiftUI

// MARK: - Settings → Live TV → Guide Sources

/// Where the guide comes from (step 9), as Android's "EPG sources": the
/// provider's own guide and XMLTV guides added by link, each with how it
/// did at the last update.
struct LiveTVGuideSourcesGroup: View {
    let accentColor: Color
    @ObservedObject private var sources = LiveTVEPGSources.shared
    @ObservedObject private var guide = LiveTVGuide.shared
    @State private var editing: LiveTVGuideSourceEditor.Target?

    var body: some View {
        LiveTVSettingsRows.group(
            title: L10n.string("livetv_settings_sources", fallback: "Guide Sources"),
            subtitle: L10n.string("livetv_settings_sources_subtitle", fallback: "Where the programmes come from. A channel takes the guide with real listings that goes furthest ahead")
        ) {
            LiveTVSettingsRows.toggle(
                title: L10n.string("livetv_epg_provider", fallback: "Provider's guide"),
                subtitle: resultText(""),
                isOn: Binding(get: { sources.providerGuide }, set: { sources.setProviderGuide($0) }),
                accentColor: accentColor
            )
            ForEach(sources.sources) { source in
                LiveTVSettingsRows.action(
                    title: source.name,
                    subtitle: LiveTVEPGSourceRules.host(of: sources.url(of: source)) + "  ·  "
                        + (source.enabled ? resultText(source.id) : L10n.string("livetv_epg_source_off", fallback: "Off")),
                    value: L10n.string("livetv_epg_source_edit", fallback: "Edit"),
                    accentColor: accentColor,
                    action: { editing = .init(source: source, url: sources.url(of: source), isNew: false) }
                )
            }
            LiveTVSettingsRows.action(
                title: L10n.string("livetv_epg_source_add", fallback: "Add XMLTV Guide"),
                subtitle: L10n.string("livetv_epg_source_add_detail", fallback: "Extra listings from a link ending in .xml or .xml.gz"),
                value: "",
                accentColor: accentColor,
                action: {
                    editing = .init(
                        source: LiveTVEPGSource(id: LiveTVEPGSource.newID(), name: ""), url: "", isNew: true)
                }
            )
            LiveTVSettingsRows.action(
                title: L10n.string("livetv_epg_sources_refresh", fallback: "Update Guides Now"),
                subtitle: updatedText,
                value: "",
                accentColor: accentColor,
                action: { sources.refreshNow() }
            )
        }
        .sheet(item: $editing) { target in
            LiveTVSettingsRows.clearSheetBackground(LiveTVGuideSourceEditor(target: target, accentColor: accentColor))
        }
    }

    /// "1,234 programmes for 56 channels", the error, or not read yet.
    private func resultText(_ id: String) -> String {
        guard let result = guide.results[id] else {
            return L10n.string("livetv_epg_source_not_read", fallback: "Not read yet")
        }
        if let error = result.error, result.channels == 0 { return error }
        return L10n.format(
            "livetv_epg_source_result", fallback: "%@ programmes for %@ channels",
            result.programmes.formatted(), result.channels.formatted())
    }

    private var updatedText: String {
        switch guide.status {
        case .downloading, .importing:
            return L10n.string("livetv_epg_sources_updating", fallback: "Updating…")
        default:
            guard let updated = guide.updated else {
                return L10n.string("livetv_epg_source_not_read", fallback: "Not read yet")
            }
            return L10n.string("livetv_epg_sources_updated", fallback: "Updated ")
                + updated.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

// MARK: - Editor

/// Adding or changing an XMLTV guide: name, link, on / off, time shift.
/// Built like the Jellyfin and SMB server sheets, so it looks like the rest
/// of Settings.
struct LiveTVGuideSourceEditor: View {
    struct Target: Identifiable {
        var source: LiveTVEPGSource
        var url: String
        let isNew: Bool
        var id: String { source.id }
    }

    let target: Target
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @State private var name: String
    @State private var url: String
    @State private var enabled: Bool
    @State private var shift: Int
    @State private var invalid = false
    @State private var asksUpdate = false

    init(target: Target, accentColor: Color) {
        self.target = target
        self.accentColor = accentColor
        _name = State(initialValue: target.source.name)
        _url = State(initialValue: target.url)
        _enabled = State(initialValue: target.source.enabled)
        _shift = State(initialValue: target.source.shiftMinutes)
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(target.isNew
                         ? L10n.string("livetv_epg_source_new", fallback: "Add XMLTV Guide")
                         : L10n.string("livetv_epg_source_change", fallback: "Edit XMLTV Guide"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_epg_source_group", fallback: "Guide"),
                        subtitle: L10n.string("livetv_epg_source_hint", fallback: "A link to an XMLTV file (.xml or .xml.gz). The link is kept in the Keychain of this Apple TV.")
                    ) {
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_epg_source_name", fallback: "Name"),
                            subtitle: L10n.string("livetv_epg_source_name_detail", fallback: "Shown in Guide Sources and Assign EPG. Empty: the link's server"),
                            placeholder: L10n.string("livetv_epg_source_name_placeholder", fallback: "e.g. Germany"),
                            text: $name
                        )
                        LiveTVSettingsRows.textField(
                            title: L10n.string("livetv_epg_source_url", fallback: "XMLTV Link"),
                            subtitle: L10n.string("livetv_epg_source_url_detail", fallback: "e.g. http://example.com/epg.xml.gz"),
                            placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                            text: $url,
                            fieldWidth: 520,
                            status: invalid
                                ? L10n.string("livetv_epg_source_invalid", fallback: "Enter a link starting with http:// or https://")
                                : nil,
                            statusColor: .orange
                        )
                    }

                    LiveTVSettingsRows.group(
                        title: L10n.string("livetv_epg_source_options", fallback: "Options"),
                        subtitle: L10n.string("livetv_epg_source_options_detail", fallback: "Takes effect at the next guide update")
                    ) {
                        LiveTVSettingsRows.toggle(
                            title: L10n.string("livetv_epg_source_use", fallback: "Use This Guide"),
                            subtitle: L10n.string("livetv_epg_source_use_detail", fallback: "Off: kept here, but not read"),
                            isOn: $enabled,
                            accentColor: accentColor
                        )
                        LiveTVSettingsRows.stepper(
                            title: L10n.string("livetv_epg_source_shift", fallback: "Time Shift"),
                            subtitle: L10n.string("livetv_epg_source_shift_detail", fallback: "Moves this guide's listings later (+) or earlier (−), for guides out of step with what's playing"),
                            value: $shift,
                            range: (LiveTVEPGSourceRules.shiftChoices.first ?? -720)...(LiveTVEPGSourceRules.shiftChoices.last ?? 720),
                            step: 30,
                            accentColor: accentColor,
                            label: { LiveTVEPGSourceRules.shiftLabel($0, none: L10n.string("livetv_epg_source_shift_none", fallback: "None")) }
                        )
                    }

                    HStack(spacing: 24) {
                        LiveTVSettingsRows.dialogButton(
                            title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false
                        ) {
                            dismiss()
                        }
                        Spacer()
                        if !target.isNew {
                            LiveTVSettingsRows.deleteButton {
                                LiveTVEPGSources.shared.remove(target.source)
                                asksUpdate = true
                            }
                        }
                        LiveTVSettingsRows.dialogButton(
                            title: L10n.string("action_save", fallback: "Save"),
                            isPrimary: true,
                            enabled: !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            action: save
                        )
                    }
                    .focusSection()
                }
                .padding(40)
            }
        }
        // Read the guides now, or at the next update (opening Live TV, every 12 h).
        .alert(L10n.string("livetv_epg_source_ask_title", fallback: "Update the guide now?"), isPresented: $asksUpdate) {
            Button(L10n.string("livetv_epg_source_ask_now", fallback: "Update now")) {
                LiveTVEPGSources.shared.refreshNow()
                dismiss()
            }
            Button(L10n.string("livetv_epg_source_ask_later", fallback: "Later"), role: .cancel) {
                dismiss()
            }
        } message: {
            Text(L10n.string("livetv_epg_source_ask_detail", fallback: "All guides are downloaded and read again. Later: when Live TV opens next."))
        }
    }

    private func save() {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: link), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host?.isEmpty == false else {
            invalid = true
            return
        }
        invalid = false
        var source = target.source
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        source.name = cleanName.isEmpty ? LiveTVEPGSourceRules.host(of: link) : cleanName
        source.enabled = enabled
        source.shiftMinutes = shift
        LiveTVEPGSources.shared.save(source, url: link)
        asksUpdate = true
    }
}

