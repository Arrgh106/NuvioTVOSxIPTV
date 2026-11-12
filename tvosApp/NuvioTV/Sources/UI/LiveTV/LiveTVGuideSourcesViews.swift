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
                        source: LiveTVEPGSource(id: LiveTVEPGSource.newID(), name: "XMLTV"), url: "", isNew: true)
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
        .fullScreenCover(item: $editing) { target in
            LiveTVGuideSourceEditor(target: target)
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
struct LiveTVGuideSourceEditor: View {
    struct Target: Identifiable {
        var source: LiveTVEPGSource
        var url: String
        let isNew: Bool
        var id: String { source.id }
    }

    let target: Target
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var enabled = true
    @State private var shift = 0
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(target.isNew
                     ? L10n.string("livetv_epg_source_new", fallback: "Add XMLTV Guide")
                     : L10n.string("livetv_epg_source_change", fallback: "XMLTV Guide"))
                    .font(.system(size: 40, weight: .bold))
                Text(L10n.string("livetv_epg_source_hint", fallback: "A link to an XMLTV file (.xml or .xml.gz). The link is kept in the Keychain of this Apple TV."))
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 16) {
                TextField(L10n.string("livetv_epg_source_name", fallback: "Name"), text: $name)
                    .autocorrectionDisabled()
                    .frame(width: 900)
                TextField(L10n.string("livetv_epg_source_url", fallback: "XMLTV link (http://…/epg.xml.gz)"), text: $url)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(width: 900)
                if invalid {
                    Text(L10n.string("livetv_epg_source_invalid", fallback: "Enter a link starting with http:// or https://"))
                        .font(.system(size: 22))
                        .foregroundColor(.orange)
                }
            }
            .focusSection()
            HStack(spacing: 20) {
                Button {
                    enabled.toggle()
                } label: {
                    Label(enabled
                          ? L10n.string("livetv_epg_source_on", fallback: "On")
                          : L10n.string("livetv_epg_source_off", fallback: "Off"),
                          systemImage: enabled ? "checkmark.circle.fill" : "circle")
                }
                Button {
                    shift = max(LiveTVEPGSourceRules.shiftChoices.first ?? -720, shift - 30)
                } label: {
                    Image(systemName: "minus")
                }
                VStack(spacing: 2) {
                    Text(L10n.string("livetv_epg_source_shift", fallback: "Time shift"))
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                    Text(LiveTVEPGSourceRules.shiftLabel(
                        shift, none: L10n.string("livetv_epg_source_shift_none", fallback: "None")))
                        .font(.system(size: 26, weight: .semibold))
                        .monospacedDigit()
                }
                .frame(width: 160)
                Button {
                    shift = min(LiveTVEPGSourceRules.shiftChoices.last ?? 720, shift + 30)
                } label: {
                    Image(systemName: "plus")
                }
            }
            .focusSection()
            Text(L10n.string("livetv_epg_source_shift_detail", fallback: "Moves this guide's listings later (+) or earlier (−), for guides out of step with what's playing"))
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.5))
            HStack(spacing: 20) {
                Button(action: save) {
                    Label(L10n.string("livetv_epg_source_save", fallback: "Save"), systemImage: "checkmark")
                }
                if !target.isNew {
                    Button(role: .destructive) {
                        LiveTVEPGSources.shared.remove(target.source)
                        dismiss()
                    } label: {
                        Label(L10n.string("livetv_epg_source_delete", fallback: "Delete"), systemImage: "trash")
                    }
                }
                Button {
                    dismiss()
                } label: {
                    Text(L10n.string("livetv_epg_source_cancel", fallback: "Cancel"))
                }
            }
            .focusSection()
            Spacer()
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
        .onAppear {
            name = target.source.name
            url = target.url
            enabled = target.source.enabled
            shift = target.source.shiftMinutes
        }
    }

    private func save() {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: link), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host?.isEmpty == false else {
            invalid = true
            return
        }
        var source = target.source
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        source.name = cleanName.isEmpty ? LiveTVEPGSourceRules.host(of: link) : cleanName
        source.enabled = enabled
        source.shiftMinutes = shift
        LiveTVEPGSources.shared.save(source, url: link)
        dismiss()
    }
}
