import SwiftUI

// MARK: - Settings → Live TV

/// Settings → Live TV (LIVE_TV_DESIGN.md, step 5), in the app's settings
/// style. The options that work today; setup (account, groups) stays in Live
/// TV's header for now, more options come with their features.
struct LiveTVSettingsView: View {
    let accentColor: Color
    @ObservedObject private var settings = LiveTVSettings.shared
    @ObservedObject private var reminders = LiveTVReminders.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            LiveTVSettingsRows.group(
                title: L10n.string("livetv_settings_guide", fallback: "Guide"),
                subtitle: L10n.string("livetv_settings_guide_subtitle", fallback: "What the guide shows")
            ) {
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_info_panel", fallback: "Info Panel"),
                    subtitle: L10n.string("livetv_settings_info_panel_detail", fallback: "The panel above the guide with what's on"),
                    isOn: $settings.showInfoPanel,
                    accentColor: accentColor
                )
                .settingsEntryAnchor()
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_description", fallback: "Description"),
                    subtitle: L10n.string("livetv_settings_description_detail", fallback: "Two lines about the show in the info panel"),
                    isOn: $settings.showDescription,
                    accentColor: accentColor,
                    enabled: settings.showInfoPanel
                )
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_preview", fallback: "Preview Window"),
                    subtitle: L10n.string("livetv_settings_preview_detail", fallback: "OK plays a channel small in the info panel first; off: straight to full screen"),
                    isOn: $settings.showPreview,
                    accentColor: accentColor,
                    enabled: settings.showInfoPanel
                )
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_small_header", fallback: "Smaller Top"),
                    subtitle: L10n.string("livetv_settings_small_header_detail", fallback: "Title and account in one line, more room for channels"),
                    isOn: $settings.smallHeader,
                    accentColor: accentColor
                )
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_group_counts", fallback: "Channel Counts"),
                    subtitle: L10n.string("livetv_settings_group_counts_detail", fallback: "The number of channels beside each group"),
                    isOn: $settings.showGroupCounts,
                    accentColor: accentColor
                )
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_separators", fallback: "Hide Separator Rows"),
                    subtitle: L10n.string("livetv_settings_separators_detail", fallback: "Leave out the provider's \"##### …\" heading rows"),
                    isOn: $settings.hideSeparators,
                    accentColor: accentColor
                )
                LiveTVSettingsRows.option(
                    title: L10n.string("livetv_settings_clock", fallback: "Clock"),
                    subtitle: L10n.string("livetv_settings_clock_detail", fallback: "Times in the guide, the info bar and the overlay"),
                    selection: Binding(
                        get: { settings.clock.rawValue },
                        set: { settings.clock = LiveTVSettings.Clock(rawValue: $0) ?? .system }),
                    options: LiveTVSettings.Clock.allCases.map(\.rawValue),
                    accentColor: accentColor,
                    optionLabel: { LiveTVSettings.Clock(rawValue: $0)?.label ?? $0 }
                )
            }

            LiveTVSettingsRows.group(
                title: L10n.string("livetv_settings_playback", fallback: "Playback"),
                subtitle: L10n.string("livetv_settings_playback_subtitle", fallback: "Watching channels")
            ) {
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_last_group", fallback: "Open on Last Group"),
                    subtitle: L10n.string("livetv_settings_last_group_detail", fallback: "Live TV opens on the group you browsed last; off: All channels"),
                    isOn: $settings.rememberLastGroup,
                    accentColor: accentColor
                )
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_info_bar", fallback: "Info Bar When Switching"),
                    subtitle: L10n.string("livetv_settings_info_bar_detail", fallback: "Show the channel and what's on after channel up / down"),
                    isOn: $settings.infoBarOnZap,
                    accentColor: accentColor
                )
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_reverse_zap", fallback: "Reverse Channel Up / Down"),
                    subtitle: L10n.string("livetv_settings_reverse_zap_detail", fallback: "Up goes to the next channel, down to the previous one"),
                    isOn: $settings.reverseZap,
                    accentColor: accentColor
                )
            }

            LiveTVSettingsRows.group(
                title: L10n.string("livetv_settings_integration", fallback: "Integration"),
                subtitle: L10n.string("livetv_settings_integration_subtitle", fallback: "Live TV in the rest of the app")
            ) {
                LiveTVSettingsRows.toggle(
                    title: L10n.string("livetv_settings_home_row", fallback: "Row on Home"),
                    subtitle: L10n.string("livetv_settings_home_row_detail", fallback: "Your channels with what's on, at the top of Home; OK plays full screen"),
                    isOn: $settings.homeRow,
                    accentColor: accentColor
                )
                LiveTVSettingsRows.option(
                    title: L10n.string("livetv_settings_home_row_source", fallback: "Channels in the Row"),
                    subtitle: L10n.string("livetv_settings_home_row_source_detail", fallback: "Favorites (recently watched while there are none), or recently watched"),
                    selection: Binding(
                        get: { settings.homeRowSource.rawValue },
                        set: { settings.homeRowSource = LiveTVSettings.HomeRowSource(rawValue: $0) ?? .favorites }),
                    options: LiveTVSettings.HomeRowSource.allCases.map(\.rawValue),
                    accentColor: accentColor,
                    optionLabel: { LiveTVSettings.HomeRowSource(rawValue: $0)?.label ?? $0 }
                )
            }

            reminderList
        }
    }
}

extension LiveTVSettingsView {
    /// Upcoming reminders, as Android's "Reminders (select to remove)".
    @ViewBuilder
    var reminderList: some View {
        let now = Date()
        let upcoming = reminders.list.upcoming(now: now)
        LiveTVSettingsRows.group(
            title: L10n.string("livetv_settings_reminders", fallback: "Reminders"),
            subtitle: upcoming.isEmpty
                ? L10n.string("livetv_settings_reminders_none", fallback: "None set. OK on a show to come in the guide: Remind me")
                : L10n.string("livetv_settings_reminders_detail", fallback: "A minute before the start a prompt offers to watch. Select one to remove it")
        ) {
            ForEach(upcoming) { reminder in
                LiveTVSettingsRows.action(
                    title: reminder.title,
                    subtitle: LiveTVInfoPanel.clock(reminder.start, now: now) + "  ·  " + reminder.channelName,
                    value: L10n.string("livetv_settings_reminders_remove", fallback: "Remove"),
                    accentColor: accentColor,
                    action: { reminders.remove(reminder) }
                )
            }
        }
    }
}

extension LiveTVSettings.HomeRowSource {
    var label: String {
        switch self {
        case .favorites: return L10n.string("livetv_favorites", fallback: "Favorites")
        case .recent: return L10n.string("livetv_recent", fallback: "Recently watched")
        }
    }
}

extension LiveTVSettings.Clock {
    var label: String {
        switch self {
        case .system: return L10n.string("livetv_settings_clock_system", fallback: "As the system")
        case .hours24: return L10n.string("livetv_settings_clock_24", fallback: "24-hour")
        case .hours12: return L10n.string("livetv_settings_clock_12", fallback: "12-hour")
        }
    }
}

// MARK: - Quick menu

/// The guide's gear (as Android's `GuideGearPanel`): the options for how the
/// guide looks, top right, so the guide can be seen changing behind it.
struct LiveTVQuickMenu: View {
    @ObservedObject var settings: LiveTVSettings
    let onClose: () -> Void
    @FocusState private var focused: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("livetv_quick_menu", fallback: "Guide display"))
                    .font(.system(size: LiveTVTheme.Font.secondary, weight: .bold))
                Spacer()
                Text(L10n.string("livetv_quick_menu_hint", fallback: "The guide changes as you go"))
                    .font(.system(size: LiveTVTheme.Font.badge))
                    .foregroundColor(LiveTVTheme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            toggle(0, L10n.string("livetv_settings_info_panel", fallback: "Info Panel"), $settings.showInfoPanel)
            toggle(1, L10n.string("livetv_settings_description", fallback: "Description"), $settings.showDescription,
                   enabled: settings.showInfoPanel)
            toggle(2, L10n.string("livetv_settings_preview", fallback: "Preview Window"), $settings.showPreview,
                   enabled: settings.showInfoPanel)
            toggle(3, L10n.string("livetv_settings_small_header", fallback: "Smaller Top"), $settings.smallHeader)
            toggle(4, L10n.string("livetv_settings_group_counts", fallback: "Channel Counts"), $settings.showGroupCounts)
            toggle(5, L10n.string("livetv_settings_separators", fallback: "Hide Separator Rows"), $settings.hideSeparators)
            row(6, title: L10n.string("livetv_settings_clock", fallback: "Clock"), value: settings.clock.label) {
                let all = LiveTVSettings.Clock.allCases
                let index = all.firstIndex(of: settings.clock) ?? 0
                settings.clock = all[(index + 1) % all.count]
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 6)
            Text(L10n.string("livetv_quick_menu_more", fallback: "More options: Settings → Live TV"))
                .font(.system(size: LiveTVTheme.Font.badge))
                .foregroundColor(LiveTVTheme.secondaryText)
                .padding(.horizontal, 10)
        }
        .padding(18)
        .frame(width: 620)
        .liveTVGlass(cornerRadius: 24)
        .focusSection()
        .onAppear { focused = 0 }
        .onExitCommand(perform: onClose)
    }

    private func toggle(_ id: Int, _ title: String, _ isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        row(id, title: title, value: nil, isOn: isOn.wrappedValue, enabled: enabled) { isOn.wrappedValue.toggle() }
    }

    private func row(
        _ id: Int, title: String, value: String?, isOn: Bool? = nil, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        let isFocused = focused == id
        return Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: LiveTVTheme.Font.small, weight: isFocused ? .semibold : .regular))
                Spacer(minLength: 12)
                if let value {
                    Text(value)
                        .font(.system(size: LiveTVTheme.Font.small))
                        .opacity(0.7)
                }
                if let isOn {
                    Capsule()
                        .fill(isOn ? (isFocused ? Color.black : LiveTVTheme.markColor) : Color.white.opacity(isFocused ? 0.5 : 0.24))
                        .frame(width: 50, height: 28)
                        .overlay(alignment: isOn ? .trailing : .leading) {
                            Circle().fill(Color.white).frame(width: 22, height: 22).padding(3)
                        }
                }
            }
            .foregroundColor(isFocused ? .black : LiveTVTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
            )
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused, equals: id)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
