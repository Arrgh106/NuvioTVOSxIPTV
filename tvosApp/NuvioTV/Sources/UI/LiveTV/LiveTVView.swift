import SwiftUI

/// Live TV tab: Xtream login, channel groups and channel list.
struct LiveTVView: View {
    @StateObject private var store = LiveTVStore()
    @State private var isEditingAccount = false
    @State private var isManagingGroups = false
    @State private var searchText = ""
    @Namespace private var focusNamespace
    /// Back from the player only the guide can take focus (tvOS picked the
    /// search field or the groups otherwise).
    @ObservedObject private var returnLock = LiveTVReturnLock.shared
    /// Not observed here: only the info panel redraws when focus moves.
    @State private var info = LiveTVInfoModel()
    /// Preview window and full screen: one player (step 3).
    @ObservedObject private var player = LiveTVPlayer.shared
    /// Live TV options (quick menu, Settings → Live TV).
    @ObservedObject private var settings = LiveTVSettings.shared
    /// The quick menu (gear in the header).
    @State private var showsQuickMenu = false
    /// Assign EPG for this channel (long press in the guide).
    @State private var assignEPGChannel: XtreamLiveChannel?
    @State private var epgChanged = false
    /// Rename a channel or group (long press, step 10a).
    @State private var renaming: LiveTVRenameSheet.Target?
    /// Reorder Channels / Reorder Groups (step 10b): set while it runs.
    @State private var reorderChannelStart: Int?
    @State private var reorderGroupStart: String?
    /// The channel or group picked up now, for the hint.
    @State private var reorderPicked: String?
    /// Back while reordering: the guide or the groups save and finish.
    @State private var reorderFinish = 0
    private var isReordering: Bool { reorderChannelStart != nil || reorderGroupStart != nil }
    /// Watch from outside Live TV (reminder, Home row): the channel full
    /// screen. Not observed: nothing here redraws for it.
    private var watch: LiveTVWatch { LiveTVWatch.shared }
    /// The app's film player. Not used since step 3 (Live TV plays in its
    /// own player, see LiveTVPlayer); kept so the app's call site stays as is.
    let onPlayChannel: (URL, NuvioMeta, [String: String]) -> Void

    var body: some View {
        Group {
            if !store.hasAccount || isEditingAccount {
                XtreamLoginForm(
                    store: store,
                    isEditing: store.hasAccount,
                    onDone: { isEditingAccount = false }
                )
            } else if isManagingGroups {
                LiveTVGroupManager(store: store, onDone: { isManagingGroups = false })
            } else {
                channelBrowser
            }
        }
        .onAppear { store.reloadAccount() }
    }

    // MARK: Browser

    private var channelBrowser: some View {
        VStack(alignment: .leading, spacing: settings.smallHeader ? 16 : 24) {
            header
                .disabled(returnLock.locked || showsQuickMenu || isReordering)
            if settings.showInfoPanel {
                LiveTVInfoPanel(model: info)
            }
            // Groups · channels · timeline (the guide gets the most room).
            HStack(alignment: .top, spacing: 30) {
                groupList
                    .frame(width: 400)
                    .disabled(returnLock.locked || showsQuickMenu)
                    // Its own focus section: Right from any group lands in
                    // the guide, Left from the guide comes back here.
                    .focusSection()
                channelList
                    .frame(maxWidth: .infinity)
                    .disabled(showsQuickMenu)
                    .focusSection()
                    // Back from the player the guide takes the first focus
                    // (on the channel watched last), not the groups.
                    .prefersDefaultFocus(LiveTVZapper.shared.currentChannel != nil, in: focusNamespace)
            }
        }
        .focusScope(focusNamespace)
        .padding(.horizontal, 60)
        .padding(.top, settings.smallHeader ? 16 : 30)
        // The quick menu, top right over the guide: the guide changes as
        // the options change.
        .overlay(alignment: .topTrailing) {
            if showsQuickMenu {
                LiveTVQuickMenu(settings: settings, onClose: { showsQuickMenu = false })
                    .padding(.top, 20)
                    .padding(.trailing, 40)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: showsQuickMenu)
        // How Reorder Channels / Groups works, while it runs.
        .overlay(alignment: .bottom) {
            if isReordering {
                reorderHint
                    .padding(.bottom, 40)
                    .transition(.opacity)
            }
        }
        // While reordering Back saves (in the guide or the groups) and
        // never opens the app's sidebar.
        .onExitCommand(perform: isReordering ? { reorderFinish &+= 1 } : nil)
        .onChange(of: showsQuickMenu) { _, shows in player.previewCovered = shows }
        // Leaving Live TV frees the provider connection.
        .onDisappear { player.stop() }
        .onAppear(perform: connectPlayer)
        // A guide channel chosen by hand whose programmes aren't stored yet
        // (or Automatic): the guide files from last time are read again once
        // the screen closes, without downloading.
        .fullScreenCover(item: $assignEPGChannel, onDismiss: {
            if epgChanged {
                epgChanged = false
                store.refreshGuide(force: true, reuseDownloads: true)
            }
        }) { channel in
            LiveTVAssignEPG(channel: channel, onChanged: { epgChanged = true })
        }
        .sheet(item: $renaming) { target in
            LiveTVSettingsRows.clearSheetBackground(
                LiveTVRenameSheet(target: target, accentColor: LiveTVTheme.accent))
        }
        // Watch from a reminder or the Home row, from anywhere in the app;
        // the channels may still be loading when Live TV opens for it.
        .onReceive(watch.$pending) { _ in
            // Sent before the value is stored: look once it is.
            Task { @MainActor in watchReminder() }
        }
        .onChange(of: store.listRevision) { _, _ in watchReminder() }
        // Preview window switched off while it plays: nothing shows the
        // picture any more, so it stops.
        .onChange(of: settings.previewActive) { _, active in
            if !active, !player.isFullscreen { player.stop() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            if settings.smallHeader {
                // More room for the guide: title and account in one line.
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(L10n.string("livetv_title", fallback: "Live TV"))
                        .font(.system(size: 30, weight: .bold))
                    accountSummary
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("livetv_title", fallback: "Live TV"))
                        .font(.system(size: 44, weight: .bold))
                    accountSummary
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            Spacer()
            if store.state == .loading {
                ProgressView()
            }
            // Search channel names; submitting an empty field ends the search.
            TextField(L10n.string("livetv_search_channels", fallback: "Search channels"), text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(width: 380)
                .onSubmit { store.search(searchText) }
            Button {
                isManagingGroups = true
            } label: {
                Label(L10n.string("livetv_groups_button", fallback: "Groups"), systemImage: "eye.slash")
            }
            Button {
                store.refresh()
                store.refreshGuide(force: true)
            } label: {
                Label(L10n.string("livetv_refresh", fallback: "Refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(store.state == .loading)
            Button {
                isEditingAccount = true
            } label: {
                Label(L10n.string("livetv_account", fallback: "Account"), systemImage: "person.badge.key")
            }
            Button {
                showsQuickMenu = true
            } label: {
                Image(systemName: "gearshape")
                    .accessibilityLabel(L10n.string("livetv_quick_menu", fallback: "Guide display"))
            }
        }
    }

    private var accountSummary: Text {
        var parts: [String] = []
        if let name = store.account?.name { parts.append(name) }
        if let info = store.userInfo {
            if let expires = info.expiresAt {
                parts.append(L10n.string("livetv_expires", fallback: "Expires") + " "
                    + expires.formatted(date: .abbreviated, time: .omitted))
            }
            if let max = info.maxConnections {
                parts.append(L10n.string("livetv_connections", fallback: "Connections")
                    + " \(info.activeConnections ?? 0)/\(max)")
            }
        }
        if case .failed(let message) = store.state {
            parts.append("⚠︎ " + message)
        }
        return Text(parts.joined(separator: "  ·  "))
    }

    private var groupList: some View {
        // UIKit list with cell reuse, like the channel list.
        LiveTVGroupCollection(
            groups: store.groups,
            selectedID: store.selectedGroupID,
            showCounts: settings.showGroupCounts,
            onSelect: { store.selectedGroupID = $0 },
            onRename: { group in
                renaming = .init(
                    kind: .group(group.id), current: group.name, providerName: store.providerGroupName(group.id))
            },
            reorderStartID: reorderGroupStart,
            reorderFinishRequest: reorderFinish,
            onReorderStart: { group in
                reorderPicked = group.name
                reorderGroupStart = group.id
            },
            onReorderPicked: { reorderPicked = $0 },
            onReorderDone: { ids in
                store.saveGroupOrder(ids)
                reorderGroupStart = nil
                reorderPicked = nil
            }
        )
    }

    /// Android's hint box for reordering, in the Live TV glass.
    private var reorderHint: some View {
        let groups = reorderGroupStart != nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(groups
                 ? L10n.string("livetv_reorder_groups", fallback: "Reorder Groups")
                 : L10n.string("livetv_reorder_channels", fallback: "Reorder Channels"))
                .font(.system(size: 26, weight: .bold))
            if let reorderPicked {
                Text(L10n.format("livetv_reorder_moving", fallback: "Moving: %@", reorderPicked))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(LiveTVTheme.accent == .white ? .orange : LiveTVTheme.accent)
                Text(L10n.string("livetv_reorder_place", fallback: "Up / Down: choose the place · OK: put it there"))
            } else {
                Text(groups
                     ? L10n.string("livetv_reorder_pick_group", fallback: "Up / Down: choose a group · OK: pick it up to move")
                     : L10n.string("livetv_reorder_pick", fallback: "Up / Down: choose a channel · OK: pick it up to move"))
            }
            Text(L10n.string("livetv_reorder_save", fallback: "Back: save and finish"))
                .foregroundColor(.white.opacity(0.6))
        }
        .font(.system(size: 22))
        .foregroundColor(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.8)))
    }

    @ViewBuilder
    private var channelList: some View {
        let channels = store.visibleChannels
        if channels.isEmpty {
            VStack(spacing: 20) {
                if store.state == .loading {
                    ProgressView()
                    Text(L10n.string("livetv_loading", fallback: "Loading channels…"))
                } else {
                    Image(systemName: "tv.slash").font(.system(size: 60))
                    Text(L10n.string("livetv_no_channels", fallback: "No channels in this group."))
                }
            }
            .font(.system(size: 26))
            .foregroundColor(.white.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // The guide: UIKit rows with cell reuse, stays fast with tens of
            // thousands of channels ("All channels" can hold 50k+).
            LiveTVGuideGrid(
                // Search text and hidden groups change the content of a
                // group without changing its id or always its size.
                listID: "\(store.selectedGroupID)|\(store.listRevision)|\(store.searchQuery)|\(store.hiddenGroupIDs.count)",
                channels: channels,
                favoriteIDs: Set(store.favoriteIDs),
                // Back from the player: on the channel watched last (also
                // after zapping), not on the groups.
                focusChannelID: LiveTVZapper.shared.currentChannel?.streamID,
                onSelect: play,
                onCatchup: playCatchup,
                onToggleFavorite: { store.toggleFavorite($0) },
                onAssignEPG: { assignEPGChannel = $0 },
                onRename: { renaming = .channel($0) },
                reorderStartID: reorderChannelStart,
                reorderFinishRequest: reorderFinish,
                canReorder: store.canReorder(store.selectedGroupID),
                onReorderStart: { channel in
                    reorderPicked = channel.name
                    reorderChannelStart = channel.streamID
                },
                onReorderPicked: { reorderPicked = $0 },
                onReorderDone: { ids in
                    store.saveChannelOrder(groupID: store.selectedGroupID, ids: ids)
                    reorderChannelStart = nil
                    reorderPicked = nil
                },
                info: info
            )
        }
    }

    /// OK on a channel, as on Android: plays it in the preview window; OK on
    /// the channel already playing there makes it full screen (same stream).
    /// A past show on a channel with catch-up: straight to full screen.
    private func playCatchup(_ channel: XtreamLiveChannel, _ programme: XtreamProgram) {
        guard let links = store.catchupLinks(for: channel, programme: programme) else { return }
        // Up/down from the replay go back to live channels of this group.
        let liveStore = store
        LiveTVZapper.shared.begin(channel: channel, in: liveStore.visibleChannels) { [weak liveStore] in
            liveStore?.playbackItem(for: $0)
        }
        store.recordWatched(channel)
        player.playCatchup(channel, programme: programme, urls: links.urls, headers: links.headers)
        LiveTVFocusLinks.beginReturn()
        player.isFullscreen = true
        player.showBar(.compact)
    }

    private func play(_ channel: XtreamLiveChannel) {
        // OK on the channel while it replays a show: live again.
        if player.channel?.streamID == channel.streamID, player.replay == nil {
            switch player.status {
            case .loading, .playing:
                // Back from full screen: on this channel, in the guide.
                LiveTVFocusLinks.beginReturn()
                player.isFullscreen = true
                return
            case .idle, .failed:
                break // try again
            }
        }
        // Up/down in full screen switches through this group.
        let liveStore = store
        LiveTVZapper.shared.begin(channel: channel, in: liveStore.visibleChannels) { [weak liveStore] in
            liveStore?.playbackItem(for: $0)
        }
        start(channel)
        // No preview window: straight to full screen.
        if !settings.previewActive {
            LiveTVFocusLinks.beginReturn()
            player.isFullscreen = true
        }
    }

    /// Watch from outside: the channel full screen, zapping through the
    /// request's channels (Home row) or the group shown when it's in it.
    private func watchReminder() {
        guard let request = watch.pending,
              let channel = store.channel(id: request.channelID) else { return }
        watch.pending = nil
        if let groupID = request.groupID, store.selectedGroupID != groupID,
           store.groups.contains(where: { $0.id == groupID }) {
            store.selectedGroupID = groupID
        }
        let requested = request.listIDs.compactMap { store.channel(id: $0) }
        let list: [XtreamLiveChannel]
        if requested.contains(where: { $0.streamID == channel.streamID }) {
            list = requested
        } else if store.visibleChannels.contains(where: { $0.streamID == channel.streamID }) {
            list = store.visibleChannels
        } else {
            list = [channel]
        }
        let liveStore = store
        LiveTVZapper.shared.begin(channel: channel, in: list) { [weak liveStore] in
            liveStore?.playbackItem(for: $0)
        }
        start(channel)
        LiveTVFocusLinks.beginReturn()
        player.isFullscreen = true
        player.showBar(.compact)
    }

    /// Plays `channel` where the picture is (preview or full screen).
    private func start(_ channel: XtreamLiveChannel) {
        guard let item = store.playbackItem(for: channel) else { return }
        store.recordWatched(channel)
        player.play(channel, item: item)
    }

    /// What the full-screen bar needs from the store.
    private func connectPlayer() {
        let liveStore = store
        player.recentChannels = { [weak liveStore] in
            guard let liveStore else { return [] }
            return liveStore.recentIDs.compactMap { liveStore.channel(id: $0) }
        }
        player.startChannel = { [weak liveStore, weak player] channel in
            guard let liveStore, let player, let item = liveStore.playbackItem(for: channel) else { return }
            // A channel from the row that isn't in the group: zap from the
            // row's list instead.
            if !LiveTVZapper.shared.channels.contains(where: { $0.streamID == channel.streamID }) {
                let recent = liveStore.recentIDs.compactMap { liveStore.channel(id: $0) }
                LiveTVZapper.shared.begin(channel: channel, in: recent) { [weak liveStore] in
                    liveStore?.playbackItem(for: $0)
                }
            } else {
                LiveTVZapper.shared.begin(channel: channel, in: LiveTVZapper.shared.channels) { [weak liveStore] in
                    liveStore?.playbackItem(for: $0)
                }
            }
            liveStore.recordWatched(channel)
            player.play(channel, item: item)
        }
        // The guide over the full-screen picture: a channel from another
        // group makes that group the one shown (and zapped through), so
        // going back lands on it in the guide too.
        player.overlay.store = liveStore
        player.overlay.onPlay = { [weak liveStore, weak player] channel, list, groupID in
            guard let liveStore, let player, let item = liveStore.playbackItem(for: channel) else { return }
            if liveStore.selectedGroupID != groupID { liveStore.selectedGroupID = groupID }
            LiveTVZapper.shared.begin(channel: channel, in: list) { [weak liveStore] in
                liveStore?.playbackItem(for: $0)
            }
            liveStore.recordWatched(channel)
            player.play(channel, item: item)
            player.showBar(.compact)
        }
        player.startReplay = { [weak liveStore, weak player] channel, programme in
            guard let liveStore, let player,
                  let links = liveStore.catchupLinks(for: channel, programme: programme) else { return }
            liveStore.recordWatched(channel)
            player.playCatchup(channel, programme: programme, urls: links.urls, headers: links.headers)
            player.showBar(.compact)
        }
        player.overlay.onCatchup = { [weak liveStore, weak player] channel, programme, list, groupID in
            guard let liveStore, let player else { return }
            if liveStore.selectedGroupID != groupID { liveStore.selectedGroupID = groupID }
            LiveTVZapper.shared.begin(channel: channel, in: list) { [weak liveStore] in
                liveStore?.playbackItem(for: $0)
            }
            player.startReplay(channel, programme)
        }
    }
}

// MARK: - Rows

struct LiveTVLogo: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Login

private struct XtreamLoginForm: View {
    @ObservedObject var store: LiveTVStore
    let isEditing: Bool
    let onDone: () -> Void

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var format: XtreamStreamFormat = .auto
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var showSignOutConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(L10n.string("livetv_xtream_title", fallback: "Xtream Codes login"))
                .font(.system(size: 44, weight: .bold))
            Text(L10n.string(
                "livetv_xtream_hint",
                fallback: "Enter the server address, username and password from your IPTV provider."
            ))
            .font(.system(size: 24))
            .foregroundColor(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 18) {
                TextField(L10n.string("livetv_server", fallback: "Server (e.g. http://example.com:8080)"), text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(L10n.string("livetv_username", fallback: "Username"), text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(L10n.string("livetv_password", fallback: "Password"), text: $password)
                    .textContentType(.password)
            }
            .frame(maxWidth: 1100)

            HStack(spacing: 16) {
                Text(L10n.string("livetv_stream_format", fallback: "Stream format"))
                    .font(.system(size: 24))
                ForEach(XtreamStreamFormat.allCases) { option in
                    Button {
                        format = option
                    } label: {
                        HStack(spacing: 8) {
                            if format == option { Image(systemName: "checkmark") }
                            Text(option.title)
                        }
                    }
                }
            }
            // Full-width focus sections: otherwise moving down from a format
            // button finds nothing below it (Sign in sits further left).
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 24))
                    .foregroundColor(.red)
            }

            HStack(spacing: 24) {
                Button {
                    signIn()
                } label: {
                    HStack(spacing: 12) {
                        if isSigningIn { ProgressView() }
                        Text(L10n.string("livetv_sign_in", fallback: "Sign in"))
                    }
                }
                .disabled(isSigningIn || server.isEmpty || username.isEmpty || password.isEmpty)

                if isEditing {
                    Button(L10n.string("livetv_cancel", fallback: "Cancel"), action: onDone)
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Text(L10n.string("livetv_remove_account", fallback: "Remove account"))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: fillFromAccount)
        .confirmationDialog(
            L10n.string("livetv_remove_account_confirm", fallback: "Remove this Xtream account from this profile?"),
            isPresented: $showSignOutConfirm
        ) {
            Button(L10n.string("livetv_remove_account", fallback: "Remove account"), role: .destructive) {
                store.signOut()
                onDone()
            }
        }
    }

    private func fillFromAccount() {
        guard let account = store.account else { return }
        server = account.server
        username = account.username
        password = store.password()
        format = account.streamFormat
    }

    private func signIn() {
        errorMessage = nil
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            do {
                try await store.signIn(server: server, username: username, password: password, format: format)
                onDone()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
