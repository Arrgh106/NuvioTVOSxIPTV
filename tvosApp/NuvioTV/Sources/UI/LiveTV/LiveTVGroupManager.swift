import SwiftUI

/// Show or hide provider groups (as on Android). With tens of thousands of
/// channels most users only want a few countries: filter by text (e.g. "DE")
/// and hide or show everything that matches in one go.
struct LiveTVGroupManager: View {
    @ObservedObject var store: LiveTVStore
    let onDone: () -> Void

    @State private var filter = ""

    private var matching: [LiveTVGroup] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.categoryGroups }
        return store.categoryGroups.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        let groups = matching
        let ids = Set(groups.map(\.id))
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("livetv_manage_groups", fallback: "Manage groups"))
                    .font(.system(size: 44, weight: .bold))
                Spacer()
                Text(L10n.format(
                    "livetv_groups_visible_count",
                    fallback: "%d of %d shown",
                    store.categoryGroups.count - store.hiddenGroupIDs.count,
                    store.categoryGroups.count
                ))
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.6))
            }

            HStack(spacing: 20) {
                TextField(L10n.string("livetv_filter_groups", fallback: "Filter groups (e.g. DE)"), text: $filter)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 560)
                Button(L10n.string("livetv_show_matching", fallback: "Show these")) {
                    store.setHidden(ids, hidden: false)
                }
                Button(L10n.string("livetv_hide_matching", fallback: "Hide these")) {
                    store.setHidden(ids, hidden: true)
                }
                Button(L10n.string("livetv_hide_others", fallback: "Only these")) {
                    let others = Set(store.categoryGroups.map(\.id)).subtracting(ids)
                    store.setHidden(others, hidden: true)
                    store.setHidden(ids, hidden: false)
                }
                .disabled(filter.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button(L10n.string("livetv_done", fallback: "Done"), action: onDone)
            }
            .focusSection()

            LiveTVGroupToggleCollection(
                groups: groups,
                hiddenIDs: store.hiddenGroupIDs,
                onToggle: { group in
                    store.setHidden([group.id], hidden: !store.hiddenGroupIDs.contains(group.id))
                }
            )
            .focusSection()
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
        .onExitCommand(perform: onDone)
    }
}
