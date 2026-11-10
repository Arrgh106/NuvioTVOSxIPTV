// Live TV guide logic tests. Plain Swift (no Xcode, no simulator), so CI runs
// them on Linux in seconds:
//   swiftc tvosApp/NuvioTV/Sources/Core/LiveTV/LiveTVTimeline.swift \
//          Tests/LiveTVLogic/main.swift -o livetv-tests && ./livetv-tests
import Foundation

struct Show: LiveTVTimed, Equatable {
    let title: String
    let start: Date
    let end: Date
}

var failures = 0
var passed = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

/// 2026-11-09 20:00 UTC as the base; minutes from there.
let base = Date(timeIntervalSince1970: 1_793_822_400)
func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
func show(_ title: String, _ from: Double, _ to: Double) -> Show { Show(title: title, start: at(from), end: at(to)) }

// A row: 20:00–20:15 News, 20:15–21:45 Film, gap 21:45–22:00, 22:00–23:00 Late.
let row = [show("News", 0, 15), show("Film", 15, 105), show("Late", 120, 180)]
let limit = at(3 * 24 * 60)

// MARK: floorSlot

check(LiveTVTimeline.floorSlot(at(0)) == at(0), "floor on boundary")
check(LiveTVTimeline.floorSlot(at(29)) == at(0), "floor inside slot")
check(LiveTVTimeline.floorSlot(at(31)) == at(30), "floor second slot")

// MARK: block(at:)

check(LiveTVTimeline.block(at: at(20), in: row).programme?.title == "Film", "inside a programme")
check(LiveTVTimeline.block(at: at(15), in: row).programme?.title == "Film", "on a start boundary")
let gap = LiveTVTimeline.block(at: at(110), in: row)
check(gap.programme == nil && gap.start == at(105) && gap.end == at(120), "gap between two programmes is one block")
let before = LiveTVTimeline.block(at: at(-50), in: row)
check(before.programme == nil && before.start == at(-60) && before.end == at(-30), "before the first listing: half hour slot")
let trimmed = LiveTVTimeline.block(at: at(-10), in: row)
check(trimmed.start == at(-30) && trimmed.end == at(0), "slot trimmed against the next programme")
let after = LiveTVTimeline.block(at: at(190), in: row)
check(after.programme == nil && after.start == at(180) && after.end == at(210), "after the last listing: slot trimmed to its end")
let empty = LiveTVTimeline.block(at: at(40), in: [Show]())
check(empty.start == at(30) && empty.end == at(60), "no listings at all: half hour slots")

// MARK: Moving

var timeline = LiveTVTimeline(now: at(20))
check(timeline.cursor == nil && timeline.windowStart == at(0), "starts on now, window on the slot")
check(timeline.moveRight(in: row, now: at(20), limit: limit), "right from now")
check(timeline.cursor == at(105), "right lands on the gap after the film")
check(timeline.windowStart == at(30), "half a slot from the right edge: the window moves one slot")
timeline.moveRight(in: row, now: at(20), limit: limit)
check(timeline.cursor == at(120), "right again: next programme")
check(timeline.windowStart == at(30), "still far enough from the edge: the window stays")
check(timeline.windowEnd > at(120).addingTimeInterval(LiveTVTimeline.slot / 2), "cursor at least half a slot from the right edge")

check(timeline.moveLeft(in: row, now: at(20)), "left from Late")
check(LiveTVTimeline.block(at: timeline.cursor!, in: row).start == at(105), "left lands on the gap")
let movedBack = timeline.moveLeft(in: row, now: at(20))
check(movedBack, "left from the gap")
check(timeline.cursor == nil, "stepping back onto what's on now rests on now")
check(timeline.windowStart == at(0), "window back on the current slot")
check(!timeline.moveLeft(in: row, now: at(20)), "left on now leaves the grid")

// Right stops at the end of the guide.
var nearEnd = LiveTVTimeline(now: at(20))
check(!nearEnd.moveRight(in: row, now: at(20), limit: at(100)), "no further than the guide's end")
check(nearEnd.cursor == nil, "cursor unchanged at the end")

// MARK: Clock

var ticking = LiveTVTimeline(now: at(20))
check(!ticking.tick(now: at(25)), "same slot: no move")
check(ticking.tick(now: at(31)) && ticking.windowStart == at(30), "window follows the clock on now")
ticking.moveRight(in: row, now: at(31), limit: limit)
check(!ticking.tick(now: at(65)), "browsing ahead: the window stays")

// MARK: Visible blocks

let visible = LiveTVTimeline(now: at(20)).visibleBlocks(in: row)
check(visible.map { $0.programme?.title ?? "-" } == ["News", "Film", "-"], "blocks across the window")
check(visible.first?.start == at(0) && visible.last?.end == at(120), "first and last block")
let later = LiveTVTimeline(now: at(100)).visibleBlocks(in: row)
check(later.map { $0.programme?.title ?? "-" } == ["Film", "-", "Late", "-"], "window 21:30–23:30")
check(later.first?.start == at(15), "a programme that started before the window keeps its real start")
check(LiveTVTimeline(now: at(20)).visibleBlocks(in: [Show]()).count == 4, "empty row: four half hours")

// Overlapping listings don't loop or go backwards.
let overlapping = [show("A", 0, 60), show("B", 30, 90)]
let overlapBlocks = LiveTVTimeline(now: at(0)).visibleBlocks(in: overlapping)
check(zip(overlapBlocks, overlapBlocks.dropFirst()).allSatisfy { $0.end <= $1.start }, "blocks never go backwards")

// MARK: Info panel

let info = LiveTVProgrammeInfo(start: at(15), end: at(105), title: "Film", description: nil)
check(info.isOn(at: at(15)) && !info.isOn(at: at(105)), "on from start, not at end")
check(abs(info.progress(at: at(60)) - 0.5) < 0.0001, "half way")
check(info.progress(at: at(0)) == 0 && info.progress(at: at(200)) == 1, "progress clamped")
check(info.minutesLeft(at: at(33)) == 72, "1 h 12 min left")
check(info.minutesLeft(at: at(104.5)) == 1, "30 s left shows 1 min")
check(info.minutesLeft(at: at(110)) == 0, "over: 0 min")
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
check(LiveTVProgrammeInfo.dayOffset(of: at(180), from: at(0), calendar: utc) == 0, "23:00 is today")
check(LiveTVProgrammeInfo.dayOffset(of: at(300), from: at(0), calendar: utc) == 1, "01:00 is tomorrow")

// MARK: List window (guide over the video)

var window = LiveTVListWindow(rows: 10)
window.follow(5, count: 100)
check(window.range(count: 100) == 0..<10, "inside: no move")
window.follow(9, count: 100)
check(window.range(count: 100) == 1..<11, "bottom row: one row down, the next peeks in")
window.follow(0, count: 100)
check(window.range(count: 100) == 0..<10, "back to the top")
window.follow(99, count: 100)
check(window.range(count: 100) == 90..<100, "wrap to the end: last rows")
window.land(on: 50, count: 100)
check(window.range(count: 100) == 47..<57, "opening: a few rows above")
var short = LiveTVListWindow(rows: 10)
short.follow(4, count: 5)
check(short.range(count: 5) == 0..<5, "short list: all of it")
var stepping = LiveTVListWindow(rows: 10)
var alwaysContext = true
for index in 0..<100 {
    stepping.follow(index, count: 100)
    let range = stepping.range(count: 100)
    if !range.contains(index) || (index < 99 && index == range.upperBound - 1) { alwaysContext = false }
}
check(alwaysContext, "stepping down: on screen, never on the last row before the end")
check(LiveTVListWindow(rows: 10).range(count: 0).isEmpty, "empty list")

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
