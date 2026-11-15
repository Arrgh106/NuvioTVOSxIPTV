import Foundation

/// Channel and group ids across several sources (step 13). Each source has
/// a slot that never changes and is never given again; the first source
/// (the login from before step 13) is slot 0 and keeps the provider's ids
/// as they were, so favorites, names, order, groups and locks stay. Other
/// slots put theirs above 2^32: `slot << 32 | stream id`.
enum LiveTVSourceIDs {
    private static let rawMask = 0xFFFF_FFFF

    /// The channel id the app uses for a source's stream id.
    static func channel(slot: Int, raw: Int) -> Int {
        slot == 0 ? raw : (slot << 32) | (raw & rawMask)
    }

    /// The source slot a channel id belongs to.
    static func slot(ofChannel id: Int) -> Int {
        id >> 32
    }

    /// The source's own stream id, for its links and API calls.
    static func raw(ofChannel id: Int) -> Int {
        id >> 32 == 0 ? id : id & rawMask
    }

    /// The group id the app uses for a source's category ("s2:17").
    static func group(slot: Int, category: String) -> String {
        slot == 0 ? category : "s\(slot):" + category
    }

    /// The source slot a group id belongs to (0 for the first source's and
    /// the app's own groups).
    static func slot(ofGroup id: String) -> Int {
        guard id.hasPrefix("s"), let colon = id.firstIndex(of: ":"),
              let slot = Int(id[id.index(after: id.startIndex)..<colon]) else { return 0 }
        return slot
    }

    /// The source's own category id.
    static func category(ofGroup id: String) -> String {
        guard slot(ofGroup: id) != 0, let colon = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: colon)...])
    }

    /// The heading of a source in the group column (more than one source).
    static let headingPrefix = "__source__:"

    static func heading(sourceID: String) -> String { headingPrefix + sourceID }

    static func sourceID(ofHeading id: String) -> String? {
        id.hasPrefix(headingPrefix) ? String(id.dropFirst(headingPrefix.count)) : nil
    }

    /// The next free slot: above every slot ever given (`highest`).
    static func nextSlot(after highest: Int) -> Int {
        max(1, highest + 1)
    }
}
