import Foundation

/// Multiview's layouts (Live TV step 15), as Android's `MultiviewLayout`:
/// one to four panes, eight arrangements. Foundation only, so it is tested
/// on Linux in CI.
enum LiveTVMultiviewLayout: String, CaseIterable, Sendable {
    // One to four first: "the layout with N panes" is the first with N.
    case one, two, three, four
    case twoStacked, threeWideTop, threeBigLeft, fourWideTop

    static let maxPanes = 4

    var paneCount: Int {
        switch self {
        case .one: return 1
        case .two, .twoStacked: return 2
        case .three, .threeWideTop, .threeBigLeft: return 3
        case .four, .fourWideTop: return 4
        }
    }

    /// The first layout with room for `count` panes.
    static func fitting(_ count: Int) -> LiveTVMultiviewLayout {
        let wanted = min(max(count, 1), maxPanes)
        return allCases.first { $0.paneCount == wanted } ?? .two
    }

    /// A pane's place as fractions of the screen (left, top, width, height).
    struct Frame: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    var frames: [Frame] {
        func f(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Frame { Frame(x: l, y: t, width: r - l, height: b - t) }
        switch self {
        case .one: return [f(0, 0, 1, 1)]
        case .two: return [f(0, 0, 0.5, 1), f(0.5, 0, 1, 1)]
        case .three: return [f(0, 0, 0.5, 0.5), f(0.5, 0, 1, 0.5), f(0, 0.5, 1, 1)]
        case .four: return [f(0, 0, 0.5, 0.5), f(0.5, 0, 1, 0.5), f(0, 0.5, 0.5, 1), f(0.5, 0.5, 1, 1)]
        case .twoStacked: return [f(0, 0, 1, 0.5), f(0, 0.5, 1, 1)]
        case .threeWideTop: return [f(0, 0, 1, 0.6), f(0, 0.6, 0.5, 1), f(0.5, 0.6, 1, 1)]
        case .threeBigLeft: return [f(0, 0, 0.6, 1), f(0.6, 0, 1, 0.5), f(0.6, 0.5, 1, 1)]
        case .fourWideTop: return [f(0, 0, 1, 0.6), f(0, 0.6, 1.0 / 3, 1), f(1.0 / 3, 0.6, 2.0 / 3, 1), f(2.0 / 3, 0.6, 1, 1)]
        }
    }

    enum Direction { case left, right, up, down }

    /// The pane an arrow goes to, as Android's: never out of the picture,
    /// never round the edge. The same pane when there is none that way.
    func next(from pane: Int, _ direction: Direction) -> Int {
        let p = min(max(pane, 0), paneCount - 1)
        switch self {
        case .one:
            return p
        case .two:
            switch direction {
            case .left: return 0
            case .right: return 1
            default: return p
            }
        case .three:
            switch direction {
            case .left: return p == 1 ? 0 : p
            case .right: return p == 0 ? 1 : p
            case .up: return p == 2 ? 0 : p
            case .down: return 2
            }
        case .four:
            switch direction {
            case .left: return p % 2 == 1 ? p - 1 : p
            case .right: return p % 2 == 0 ? p + 1 : p
            case .up: return p >= 2 ? p - 2 : p
            case .down: return p < 2 ? p + 2 : p
            }
        case .twoStacked:
            switch direction {
            case .up: return 0
            case .down: return 1
            default: return p
            }
        case .threeWideTop:
            switch direction {
            case .left: return p == 2 ? 1 : p
            case .right: return p == 1 ? 2 : p
            case .up: return 0
            case .down: return p == 0 ? 1 : p
            }
        case .threeBigLeft:
            switch direction {
            case .left: return 0
            case .right: return p == 0 ? 1 : p
            case .up: return p == 2 ? 1 : p
            case .down: return p == 1 ? 2 : p
            }
        case .fourWideTop:
            switch direction {
            case .left: return p >= 2 ? p - 1 : p
            case .right: return (1...2).contains(p) ? p + 1 : p
            case .up: return 0
            case .down: return p == 0 ? 2 : p
            }
        }
    }

    /// A pane in the top row: Up from it goes to the bar.
    func isTop(_ pane: Int) -> Bool {
        frames.indices.contains(pane) && frames[pane].y == 0
    }

    /// What Back does, one level at a time (Android's `multiviewBackAction`).
    enum Back: Equatable { case closePicker, allPanes, hideOverlays, leave }

    static func back(pickerOpen: Bool, fullScreen: Bool, overlaysShown: Bool) -> Back {
        if pickerOpen { return .closePicker }
        if fullScreen { return .allPanes }
        if overlaysShown { return .hideOverlays }
        return .leave
    }

    /// Left / Right in full screen: the next pane with a channel, round.
    static func nextFull(_ filled: [Int], from: Int, forward: Bool) -> Int {
        guard !filled.isEmpty else { return from }
        guard let at = filled.firstIndex(of: from) else { return filled[0] }
        return filled[(at + (forward ? 1 : -1) + filled.count) % filled.count]
    }
}
