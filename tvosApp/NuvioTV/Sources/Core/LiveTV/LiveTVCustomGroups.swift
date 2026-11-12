import Foundation

/// A group you make yourself (step 10c), as Android's custom groups: it
/// holds channels by reference (the channel stays in its provider group).
struct LiveTVCustomGroup: Codable, Equatable, Sendable, Identifiable {
    static let prefix = "custom:"

    let id: String
    var name: String
    /// Stream ids in your order.
    var channelIDs: [Int]

    static func isCustom(_ groupID: String) -> Bool { groupID.hasPrefix(prefix) }
}

/// The changes to your groups. Pure, so the logic tests run them on Linux.
enum LiveTVCustomGroups {
    static let fallbackName = "My Group"

    /// A new group at the end (empty names get `fallbackName`).
    static func create(_ groups: [LiveTVCustomGroup], name: String, id: String) -> [LiveTVCustomGroup] {
        groups + [LiveTVCustomGroup(id: id, name: cleanName(name) ?? fallbackName, channelIDs: [])]
    }

    /// Empty names keep the old one.
    static func rename(_ groups: [LiveTVCustomGroup], id: String, to name: String) -> [LiveTVCustomGroup] {
        guard let clean = cleanName(name) else { return groups }
        return groups.map { $0.id == id ? LiveTVCustomGroup(id: $0.id, name: clean, channelIDs: $0.channelIDs) : $0 }
    }

    static func delete(_ groups: [LiveTVCustomGroup], id: String) -> [LiveTVCustomGroup] {
        groups.filter { $0.id != id }
    }

    /// At the end of the group; once only.
    static func add(_ groups: [LiveTVCustomGroup], id: String, channel: Int) -> [LiveTVCustomGroup] {
        groups.map { group in
            guard group.id == id, !group.channelIDs.contains(channel) else { return group }
            var changed = group
            changed.channelIDs.append(channel)
            return changed
        }
    }

    static func remove(_ groups: [LiveTVCustomGroup], id: String, channel: Int) -> [LiveTVCustomGroup] {
        groups.map { group in
            guard group.id == id else { return group }
            var changed = group
            changed.channelIDs.removeAll { $0 == channel }
            return changed
        }
    }

    /// Reorder Channels in your group: the order shown, then the ones not
    /// shown now (gone from the provider for a while) at the end, so they
    /// aren't lost.
    static func setOrder(_ groups: [LiveTVCustomGroup], id: String, shown: [Int]) -> [LiveTVCustomGroup] {
        groups.map { group in
            guard group.id == id else { return group }
            let shownSet = Set(shown)
            var seen = Set<Int>()
            let mine = Set(group.channelIDs)
            let ordered = shown.filter { mine.contains($0) && seen.insert($0).inserted }
                + group.channelIDs.filter { !shownSet.contains($0) }
            var changed = group
            changed.channelIDs = ordered
            return changed
        }
    }

    private static func cleanName(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
