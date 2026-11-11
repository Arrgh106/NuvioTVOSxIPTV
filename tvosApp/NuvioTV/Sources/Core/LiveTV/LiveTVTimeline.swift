import Foundation

/// Anything with a start and an end in the guide (`XtreamProgram`, test
/// doubles). Foundation only, so the timeline logic is tested on Linux in CI.
protocol LiveTVTimed {
    var start: Date { get }
    var end: Date { get }
}

/// The guide's time logic (LIVE_TV_DESIGN.md, step 1), as on Android
/// (`LiveTvGuideScreen.kt`): a fixed window of two hours that moves in half
/// hour slots, and a cursor that always sits on one block of a row: a
/// programme, or a gap with nothing listed.
///
/// `cursor == nil` means "on what's on now": the guide follows the clock.
/// Right steps to the next block, Left back; Left on what's on now leaves the
/// grid (to the groups). Without catch-up the past isn't reachable.
struct LiveTVTimeline: Equatable {
    static let slot: TimeInterval = 30 * 60
    static let window: TimeInterval = 2 * 3600

    /// Left edge of the visible two hours, always on a slot boundary.
    private(set) var windowStart: Date
    /// nil: resting on what's on now.
    private(set) var cursor: Date?

    init(now: Date) {
        windowStart = Self.floorSlot(now)
        cursor = nil
    }

    var windowEnd: Date { windowStart.addingTimeInterval(Self.window) }

    /// The instant the cursor points at.
    func cursorTime(now: Date) -> Date { cursor ?? now }

    /// A block of a row: a programme, or a gap (`programme == nil`).
    struct Block<P: LiveTVTimed & Equatable>: Equatable {
        let start: Date
        let end: Date
        let programme: P?
    }

    // MARK: Moving

    /// Right: onto the next block. Returns false at the end of the guide.
    @discardableResult
    mutating func moveRight<P: LiveTVTimed & Equatable>(in programmes: [P], now: Date, limit: Date) -> Bool {
        let from = cursorTime(now: now)
        let block = Self.block(at: from, in: programmes)
        guard block.end < limit else { return false }
        cursor = block.end
        // Keep the cursor away from the right edge (half a slot), as Android.
        while block.end >= windowEnd.addingTimeInterval(-Self.slot / 2) {
            // Moves at least one slot per pass, so this ends.
            windowStart = windowStart.addingTimeInterval(Self.slot)
        }
        return true
    }

    /// Left: back one block. Returns false when the cursor is on what's on
    /// now (or earliest reachable), so the caller can move focus out.
    /// `earliest` (channels with catch-up): Left goes on into the past, down
    /// to that point, before it leaves the grid.
    mutating func moveLeft<P: LiveTVTimed & Equatable>(in programmes: [P], now: Date, earliest: Date? = nil) -> Bool {
        if let earliest {
            let block = Self.block(at: cursorTime(now: now), in: programmes)
            // Nothing earlier to reach: leave the grid.
            guard block.start > earliest, block.start.addingTimeInterval(-1) >= earliest else {
                resetToNow(now)
                return false
            }
            let target = block.start.addingTimeInterval(-1)
            cursor = target
            while target < windowStart {
                windowStart = windowStart.addingTimeInterval(-Self.slot)
            }
            return true
        }
        guard let cursor else { return false }
        let block = Self.block(at: cursor, in: programmes)
        let floor = earliest ?? now
        // On what's on now, or nothing earlier to reach: leave the grid.
        if block.contains(now) || block.start <= floor {
            resetToNow(now)
            return false
        }
        let target = block.start.addingTimeInterval(-1)
        self.cursor = target
        while target < windowStart {
            windowStart = windowStart.addingTimeInterval(-Self.slot)
        }
        // Stepped back onto what's on now: rest there (follow the clock).
        if Self.block(at: target, in: programmes).contains(now) {
            resetToNow(now)
        }
        return true
    }

    mutating func resetToNow(_ now: Date) {
        cursor = nil
        windowStart = Self.floorSlot(now)
    }

    /// Clock tick: while resting on now, the window follows the clock.
    /// Returns true when the window moved.
    @discardableResult
    mutating func tick(now: Date) -> Bool {
        guard cursor == nil else { return false }
        let start = Self.floorSlot(now)
        guard start != windowStart else { return false }
        windowStart = start
        return true
    }

    // MARK: Blocks

    static func floorSlot(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / slot).rounded(.down) * slot)
    }

    /// What sits at `date` in a row (`programmes` sorted by start): the
    /// programme, the whole gap between two programmes (one highlight, one
    /// press of Right to get past it), or a half hour slot before the first
    /// or after the last listing, trimmed against its neighbours.
    static func block<P: LiveTVTimed & Equatable>(at date: Date, in programmes: [P]) -> Block<P> {
        // Binary search: the last programme starting at or before `date`.
        var low = 0
        var high = programmes.count
        while low < high {
            let mid = (low + high) / 2
            if programmes[mid].start <= date { low = mid + 1 } else { high = mid }
        }
        let beforeIndex = low - 1
        if beforeIndex >= 0 {
            let candidate = programmes[beforeIndex]
            if date < candidate.end, candidate.end > candidate.start {
                return Block(start: candidate.start, end: candidate.end, programme: candidate)
            }
        }
        // Where the listing before `date` ended (it ended at or before `date`).
        let before = beforeIndex >= 0 ? min(programmes[beforeIndex].end, date) : nil
        let after = low < programmes.count ? programmes[low].start : nil
        if let before, let after { return Block(start: before, end: after, programme: nil) }
        var start = floorSlot(date)
        var end = start.addingTimeInterval(slot)
        if let before, before > start { start = before }
        if let after, after < end { end = after }
        return Block(start: start, end: end, programme: nil)
    }

    /// The blocks that cover the visible window, left to right.
    func visibleBlocks<P: LiveTVTimed & Equatable>(in programmes: [P]) -> [Block<P>] {
        var result: [Block<P>] = []
        var time = windowStart
        while time < windowEnd, result.count < 200 {
            var block = Self.block(at: time, in: programmes)
            guard block.end > time else { break }
            // Overlapping listings: the later one starts where the earlier
            // one is drawn to, so tiles never overlap.
            if let previous = result.last, block.start < previous.end {
                block = Block(start: previous.end, end: block.end, programme: block.programme)
            }
            result.append(block)
            time = block.end
        }
        return result
    }

    /// 0...1 across the window, for drawing.
    func fraction(of date: Date) -> Double {
        date.timeIntervalSince(windowStart) / Self.window
    }
}

extension LiveTVTimeline.Block {
    func contains(_ date: Date) -> Bool { start <= date && date < end }
}
