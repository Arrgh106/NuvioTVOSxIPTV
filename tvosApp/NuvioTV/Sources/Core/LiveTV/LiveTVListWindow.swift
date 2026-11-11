import Foundation

/// The rows a list shows around its highlight, as Android's `keepVisible`:
/// the list moves one row at a time once the highlight reaches the top or
/// bottom row (the next row peeking in), and a big jump (wrapping round,
/// another group) lands the highlight with a few rows above it.
///
/// Only the rows on screen are drawn, so a list of 50 000 channels costs the
/// same as one of ten (no scroll view, nothing to lay out off screen).
struct LiveTVListWindow: Equatable {
    /// First row on screen.
    private(set) var top = 0
    /// Rows that fit on screen.
    var rows: Int

    init(rows: Int) {
        self.rows = max(1, rows)
    }

    /// Rows on screen for `count` items.
    func range(count: Int) -> Range<Int> {
        let start = min(top, max(0, count - rows))
        return start..<min(count, start + rows)
    }

    /// Moves the window so `index` stays on screen with a row of context.
    mutating func follow(_ index: Int, count: Int) {
        guard count > 0 else { top = 0; return }
        let maxTop = max(0, count - rows)
        let first = min(top, maxTop)
        let last = first + rows - 1
        let context = rows >= 3 ? 1 : 0
        if index < first - rows || index > last + rows {
            // A jump: a few rows above it.
            top = index - min(3, rows / 2)
        } else if index < first + context {
            top = index - context
        } else if index > last - context {
            top = index - rows + 1 + context
        } else {
            top = first
        }
        top = min(max(0, top), maxTop)
    }

    /// Puts `index` on the top row (a day's heading, picking a date).
    mutating func begin(at index: Int, count: Int) {
        top = min(max(0, index), max(0, count - rows))
    }

    /// Puts `index` near the top (opening a list).
    mutating func land(on index: Int, count: Int) {
        top = min(max(0, index - min(3, rows / 2)), max(0, count - rows))
    }
}
