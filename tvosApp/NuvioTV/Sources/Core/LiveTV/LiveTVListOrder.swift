import Foundation

/// Your order for channels in a group and for the groups (step 10b), as
/// Android's "Reorder channels" / "Reorder groups". Pure, so the logic tests
/// run it on Linux.
enum LiveTVListOrder {
    /// The saved ones first, in the saved order. One not saved (new from the
    /// provider, or hidden while you reordered) waits right behind the
    /// nearest saved one above it in the provider's order, not at the end.
    /// Saved ones the provider dropped are skipped.
    static func ordered<T, ID: Hashable>(_ list: [T], saved: [ID]?, id: (T) -> ID) -> [T] {
        guard let saved, !saved.isEmpty else { return list }
        var byID: [ID: T] = [:]
        byID.reserveCapacity(list.count)
        for item in list where byID[id(item)] == nil { byID[id(item)] = item }
        var placedIDs = Set<ID>()
        var placed: [T] = []
        for key in saved {
            guard let item = byID[key], placedIDs.insert(key).inserted else { continue }
            placed.append(item)
        }
        if placed.count == list.count { return placed }
        var behind: [ID?: [T]] = [:]
        var above: ID?
        for item in list {
            let key = id(item)
            if placedIDs.contains(key) { above = key } else { behind[above, default: []].append(item) }
        }
        var out: [T] = []
        out.reserveCapacity(list.count)
        out += behind[nil] ?? []
        for item in placed {
            out.append(item)
            out += behind[id(item)] ?? []
        }
        return out
    }

    /// Moves the item at `from` to `to`: it takes that place, the ones in
    /// between move up or down by one.
    static func move<T>(_ list: [T], from: Int, to: Int) -> [T] {
        guard list.indices.contains(from), list.indices.contains(to), from != to else { return list }
        var out = list
        let item = out.remove(at: from)
        out.insert(item, at: to)
        return out
    }
}
