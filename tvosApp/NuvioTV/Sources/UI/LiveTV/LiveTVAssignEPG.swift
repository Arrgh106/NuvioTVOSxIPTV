import SwiftUI

/// "Assign EPG" (LIVE_TV_DESIGN.md, step 8b), as Android's `EpgSidePanel`:
/// choose the guide channel a channel reads its programmes from, or
/// Automatic / No guide. Suggestions first (closest names), search over all.
/// The guide is read again when the screen closes after a change.
struct LiveTVAssignEPG: View {
    let channel: XtreamLiveChannel
    /// Called when a choice was made (the guide has to be read again).
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss

    private struct GuideChannel: Identifiable, Hashable {
        let id: String
        let name: String
        let key: String
    }

    @State private var all: [GuideChannel] = []
    @State private var loaded = false
    @State private var search = ""
    @State private var choice: String?
    @State private var current: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("livetv_epg_title", fallback: "Guide for this channel"))
                    .font(.system(size: 40, weight: .bold))
                Text(channel.name + "  ·  " + currentText)
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }
            HStack(spacing: 20) {
                TextField(L10n.string("livetv_epg_search", fallback: "Search the guide"), text: $search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(width: 600)
                Button {
                    pick(nil)
                } label: {
                    Label(L10n.string("livetv_epg_automatic", fallback: "Automatic"), systemImage: "wand.and.stars")
                }
                Button {
                    pick("")
                } label: {
                    Label(L10n.string("livetv_epg_none", fallback: "No guide"), systemImage: "nosign")
                }
            }
            .focusSection()
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if all.isEmpty {
                Text(L10n.string("livetv_epg_no_guide", fallback: "No guide stored yet. Refresh Live TV first."))
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.6))
            } else {
                List {
                    if search.isEmpty {
                        Section(L10n.string("livetv_epg_suggestions", fallback: "Suggestions")) {
                            ForEach(suggestions) { row($0) }
                        }
                    }
                    Section(search.isEmpty
                            ? L10n.string("livetv_epg_all", fallback: "All guide channels")
                            : L10n.string("livetv_epg_results", fallback: "Found")) {
                        ForEach(results) { row($0) }
                    }
                }
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
        .task { await load() }
    }

    private func row(_ guide: GuideChannel) -> some View {
        Button {
            pick(guide.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(guide.name)
                        .font(.system(size: 26, weight: .medium))
                    Text(guide.id)
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.5))
                }
                Spacer()
                if guide.id == current {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private var currentText: String {
        switch choice {
        case .some(""):
            return L10n.string("livetv_epg_state_none", fallback: "No guide")
        case .some(let id):
            return L10n.string("livetv_epg_state_manual", fallback: "Chosen: ") + name(of: id)
        case .none:
            if let current {
                return L10n.string("livetv_epg_state_auto", fallback: "Automatic: ") + name(of: current)
            }
            return L10n.string("livetv_epg_state_auto_none", fallback: "Automatic: nothing found")
        }
    }

    private func name(of id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }

    /// Closest names to the channel's, as Android's `epgClosestRow`: the
    /// same key first, then the longest shared start.
    private var suggestions: [GuideChannel] {
        let key = LiveTVEPGMatch.normalize(channel.name)
        guard key.count >= 2 else { return [] }
        func score(_ guide: GuideChannel) -> Int {
            if guide.key == key { return 100_000 }
            let shared = zip(guide.key, key).prefix { $0 == $1 }.count
            guard shared >= 3 else { return Int.min }
            return shared * 100 - abs(guide.key.count - key.count)
        }
        return all.map { ($0, score($0)) }
            .filter { $0.1 > Int.min }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map(\.0)
    }

    /// Every word of the search somewhere in the name or id.
    private var results: [GuideChannel] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { guide in
            let text = (guide.name + " " + guide.id).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private func pick(_ guideID: String?) {
        LiveTVEPGOverrides.set(streamID: channel.streamID, guideID: guideID)
        onChanged()
        dismiss()
    }

    private func load() async {
        choice = LiveTVEPGOverrides.choice(streamID: channel.streamID)
        current = LiveTVGuide.shared.guideID(for: channel)?.lowercased()
        guard let reader = LiveTVGuide.shared.reader() else {
            loaded = true
            return
        }
        let list = await Task.detached(priority: .userInitiated) {
            reader.guideChannels().map {
                GuideChannel(id: $0.id, name: $0.name, key: LiveTVEPGMatch.normalize($0.name))
            }
        }.value
        all = list
        loaded = true
    }
}
