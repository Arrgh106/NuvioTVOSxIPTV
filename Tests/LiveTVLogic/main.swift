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

/// 2026-11-04 20:00 UTC as the base; minutes from there.
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
var dates = LiveTVListWindow(rows: 10)
dates.begin(at: 40, count: 100)
check(dates.range(count: 100) == 40..<50, "a date: its heading on the top row")
dates.begin(at: 95, count: 100)
check(dates.range(count: 100) == 90..<100, "a date near the end: the last rows")

// MARK: Catch-up

// The row again (20:00 News, 20:15–21:45 Film, 22:00 Late), now 21:00 on Film.
var past = LiveTVTimeline(now: at(60))
let earliest = at(-60)
check(past.moveLeft(in: row, now: at(60), earliest: earliest), "catch-up: left from now goes back")
check(LiveTVTimeline.block(at: past.cursorTime(now: at(60)), in: row).programme?.title == "News", "onto News")
check(past.windowStart <= at(0), "the window follows into the past")
check(past.moveLeft(in: row, now: at(60), earliest: earliest), "before News: the slot before the first listing")
check(!past.moveLeft(in: row, now: at(60), earliest: at(-10)), "nothing before the earliest: leaves the grid")
check(past.cursor == nil, "and rests on now again")
var noArchive = LiveTVTimeline(now: at(60))
check(!noArchive.moveLeft(in: row, now: at(60)), "without catch-up Left on now still leaves")

check(LiveTVCatchup.isAvailable(start: at(0), archiveDays: 1, now: at(60)), "an hour ago, one day archive")
check(!LiveTVCatchup.isAvailable(start: at(0), archiveDays: 0, now: at(60)), "no archive")
check(!LiveTVCatchup.isAvailable(start: at(90), archiveDays: 3, now: at(60)), "not started yet")
check(!LiveTVCatchup.isAvailable(start: at(-3000), archiveDays: 1, now: at(60)), "older than the archive")
check(LiveTVCatchup.earliest(archiveDays: 7, now: at(60)) == at(60 - 24 * 60), "the guide keeps 24 h back")
check(LiveTVCatchup.earliest(archiveDays: 0, now: at(60)) == nil, "no archive, no past")

let berlin = TimeZone(identifier: "Europe/Berlin")!
// 2026-11-04 20:00 UTC is 21:00 in Berlin.
check(LiveTVCatchup.stamp(at(0), in: berlin) == "2026-11-04:21-00", "server time")
let links = LiveTVCatchup.xtreamURLs(
    server: "http://example.test:8080", username: "user", password: "p+ss", streamID: 42,
    start: at(15), end: at(105), now: at(200), fileExtension: "m3u8", serverTimeZone: berlin)
check(links.first?.absoluteString == "http://example.test:8080/timeshift/user/p%2Bss/90/2026-11-04:21-15/42.m3u8", "timeshift link first")
check(links.count > 1 && links[1].absoluteString.hasSuffix("/42.ts"), "then the other extension")
check(links.contains { $0.absoluteString.contains("timeshift.php?") && $0.absoluteString.contains("password=p%2Bss") }, "timeshift.php form")
check(!links.contains { $0.absoluteString.contains("2026-11-04:20-15") }, "server zone known: no other-clock guess")
let onAir = LiveTVCatchup.xtreamURLs(
    server: "http://example.test", username: "u", password: "p", streamID: 1,
    start: at(15), end: at(105), now: at(45), fileExtension: "ts", serverTimeZone: nil)
check(onAir.contains { $0.absoluteString.contains("/30/") }, "on air: the aired 30 minutes")
check(Set(onAir.map(\.absoluteString)).count == onAir.count, "no link twice")

// MARK: Reminders

func reminder(_ channel: Int, _ minutes: Double, _ title: String = "Show") -> LiveTVReminder {
    LiveTVReminder(channelID: channel, channelName: "Ch \(channel)", title: title, start: at(minutes))
}
var reminders = LiveTVReminderList()
check(reminders.toggle(reminder(1, 60, "Late")), "toggle sets a reminder")
check(reminders.toggle(reminder(2, 30, "Early")), "a second one")
check(reminders.items.map(\.title) == ["Early", "Late"], "sorted by start")
check(reminders.contains(channelID: 1, start: at(60)), "found by channel and start")
check(!reminders.contains(channelID: 1, start: at(30)), "not another start")
check(!reminders.toggle(reminder(1, 60)), "toggle again cancels it")
check(reminders.items.count == 1, "one left")
// Due a minute before, until ten minutes after; shown ones not again.
check(reminders.due(now: at(28.5), shown: []) == nil, "not due 90 s before")
check(reminders.due(now: at(29), shown: [])?.title == "Early", "due a minute before")
check(reminders.due(now: at(39.9), shown: [])?.title == "Early", "still due just under ten minutes after")
check(reminders.due(now: at(40), shown: []) == nil, "not ten minutes after")
check(reminders.due(now: at(30), shown: [reminder(2, 30).id]) == nil, "shown already")
check(reminders.upcoming(now: at(35)).count == 1, "upcoming while it can still show")
check(reminders.upcoming(now: at(41)).isEmpty, "not upcoming after that")
// Dropped half an hour after the start.
check(!reminders.prune(now: at(60)), "kept 30 minutes after")
check(reminders.prune(now: at(60.5)), "dropped after that")
check(reminders.items.isEmpty, "empty")

// MARK: Guide matching (step 8a)

check(LiveTVEPGMatch.normalize("DE: Sky Cinema Action HD") == "skycinemaaction", "prefix and quality go")
check(LiveTVEPGMatch.normalize("Das Erste (FHD)") == "daserste", "brackets go")
check(LiveTVEPGMatch.normalize("UK| BBC One [backup]") == "bbcone", "| prefix and [..] go")
check(LiveTVEPGMatch.normalize("ProSieben 4K") == "prosieben", "4K goes")
check(LiveTVEPGMatch.idName("DasErste.de") == "daserste", "id: country end goes")
check(LiveTVEPGMatch.idName("GloboSP.br") == "globosp", "id: .br goes")

func ref(_ id: Int, _ epg: String?, _ name: String) -> LiveTVEPGChannelRef {
    LiveTVEPGChannelRef(streamID: id, epgID: epg, name: name)
}
var picker = LiveTVEPGMatch.Picker(channels: [
    ref(1, "DasErste.de", "DE: Das Erste HD"),   // id
    ref(2, nil, "ZDF HD"),                       // name
    ref(3, "wrong.id", "Sky Sport 1"),           // wrong id: name
    ref(4, nil, "Nothing Like It"),              // none
    ref(5, nil, "RTL"),                          // by hand
    ref(6, "daserste.de", "Das Erste"),          // by hand: no guide
], overrides: [5: "rtl.manual", 6: ""])
check(picker.saw(guideID: "daserste.de", names: ["Das Erste"]), "id match kept")
check(picker.saw(guideID: "zdf.de", names: ["ZDF"]), "name match kept")
check(picker.saw(guideID: "skysport1.de", names: ["Sky Sport 1 HD"]), "name match despite wrong id")
check(picker.saw(guideID: "zdf.backup", names: ["ZDF"]), "second name match kept")
check(picker.saw(guideID: "rtl.manual", names: ["Something else"]), "manual kept")
check(!picker.saw(guideID: "other.tv", names: ["Other"]), "nobody's: not kept")
let all: Set = ["daserste.de", "zdf.de", "skysport1.de", "zdf.backup", "rtl.manual"]
let guideLinks = picker.links(listed: all)
check(guideLinks[1] == "daserste.de", "by id")
check(guideLinks[2] == "zdf.de", "by name, the first")
check(guideLinks[3] == "skysport1.de", "by name when the id isn't in the guide")
check(guideLinks[4] == nil, "no match")
check(guideLinks[5] == "rtl.manual", "by hand wins")
check(guideLinks[6] == nil, "by hand: no guide")
check(picker.links(listed: all.subtracting(["zdf.de"]))[2] == "zdf.backup", "only guide channels with programmes")

// MARK: Several guides (step 9)

check(LiveTVEPGMatch.isPlaceholder(" No Information. "), "placeholder title")
check(!LiveTVEPGMatch.isPlaceholder("Tagesschau"), "real title")
var stat = LiveTVEPGMatch.ChannelStat()
for _ in 0..<8 { stat.add(stop: 100, placeholder: true) }
stat.add(stop: 50, placeholder: false); stat.add(stop: 50, placeholder: false)
check(!stat.isReal && stat.lastStop == 100, "80 % placeholders: not real")
stat.add(stop: 50, placeholder: false)
check(stat.isReal, "under 80 %: real")

let extraKey = LiveTVEPGSourceRules.key(sourceID: "xabc", guideID: "ZDF.de")
check(extraKey == "xabc|zdf.de", "added guide key")
check(LiveTVEPGSourceRules.key(sourceID: "", guideID: "ZDF.de") == "zdf.de", "provider key as it was")
check(LiveTVEPGSourceRules.guideID(fromKey: extraKey) == "zdf.de", "id back from key")
check(LiveTVEPGSourceRules.guideID(fromKey: "zdf.de") == "zdf.de", "provider id stays")

let hour: Int64 = 3600
let nowTime: Int64 = 1_000_000
var multi = LiveTVEPGMatch.Picker(channels: [
    ref(1, nil, "ZDF"),          // added guide goes further ahead
    ref(2, nil, "Arte"),         // provider real, added placeholders
    ref(3, "kika.de", "KiKA"),   // id in the provider's, name in the added one
    ref(4, nil, "3sat"),         // same in both: added guide first
    ref(5, nil, "Phoenix"),      // by hand in the added guide
], overrides: [5: "xabc|phoenix.tv"])
// Added guide (place 0), then the provider's (place 1).
check(multi.saw(key: "xabc|zdf.de", id: "zdf.de", names: ["ZDF"], guide: 0), "added: name")
check(multi.saw(key: "xabc|arte.fr", id: "arte.fr", names: ["Arte"], guide: 0), "added: arte")
check(multi.saw(key: "xabc|kika", id: "kika", names: ["KiKA"], guide: 0), "added: kika by name")
check(multi.saw(key: "xabc|3sat", id: "3sat", names: ["3sat"], guide: 0), "added: 3sat")
check(multi.saw(key: "xabc|phoenix.tv", id: "phoenix.tv", names: ["Something"], guide: 0), "added: by hand")
check(multi.saw(key: "zdf.de", id: "zdf.de", names: ["ZDF"], guide: 1), "provider: zdf")
check(multi.saw(key: "arte.de", id: "arte.de", names: ["Arte"], guide: 1), "provider: arte")
check(multi.saw(key: "kika.de", id: "kika.de", names: ["KiKA"], guide: 1), "provider: kika by id")
check(multi.saw(key: "3sat.de", id: "3sat.de", names: ["3sat"], guide: 1), "provider: 3sat")
check(!multi.saw(key: "phoenix.de", id: "phoenix.de", names: ["Phoenix"], guide: 1), "chosen by hand: no automatic match")
func stats(_ count: Int, placeholders: Int = 0, aheadHours: Int64) -> LiveTVEPGMatch.ChannelStat {
    LiveTVEPGMatch.ChannelStat(count: count, placeholders: placeholders, lastStop: nowTime + aheadHours * hour)
}
let multiLinks = multi.links(stats: [
    "xabc|zdf.de": stats(40, aheadHours: 72), "zdf.de": stats(20, aheadHours: 24),
    "xabc|arte.fr": stats(10, placeholders: 10, aheadHours: 72), "arte.de": stats(20, aheadHours: 24),
    "xabc|kika": stats(20, aheadHours: 24), "kika.de": stats(20, aheadHours: 24),
    "xabc|3sat": stats(20, aheadHours: 24), "3sat.de": stats(20, aheadHours: 24),
    "xabc|phoenix.tv": stats(1, placeholders: 1, aheadHours: 1), "phoenix.de": stats(20, aheadHours: 72),
], now: nowTime)
check(multiLinks[1] == "xabc|zdf.de", "further ahead wins")
check(multiLinks[2] == "arte.de", "real listings beat placeholders")
check(multiLinks[3] == "kika.de", "id match beats name match")
check(multiLinks[4] == "xabc|3sat", "a tie: the added guide first")
check(multiLinks[5] == "xabc|phoenix.tv", "by hand wins over everything")

check(LiveTVEPGSourceRules.shiftLabel(0) == "None", "no shift")
check(LiveTVEPGSourceRules.shiftLabel(90) == "+1:30 h", "+90 min")
check(LiveTVEPGSourceRules.shiftLabel(-30) == "−0:30 h", "−30 min")
check(LiveTVEPGSourceRules.shiftChoices.count == 97 && LiveTVEPGSourceRules.shiftChoices.contains(0)
      && LiveTVEPGSourceRules.shiftChoices.first == -1440 && LiveTVEPGSourceRules.shiftChoices.last == 1440,
      "shift choices: a day either way in half hours")
check(LiveTVEPGSourceRules.host(of: " http://epg.example.test/guide.xml.gz ") == "epg.example.test", "host")
let feedA = LiveTVGuideFeed(sourceID: "xabc", name: "A", url: URL(string: "http://a.test/e.xml")!, shiftMinutes: 0)
let feedB = LiveTVGuideFeed(sourceID: "xabc", name: "A", url: URL(string: "http://a.test/e.xml")!, shiftMinutes: 60)
check(LiveTVEPGSourceRules.fingerprint([feedA]) != LiveTVEPGSourceRules.fingerprint([feedB]), "shift changes the fingerprint")
check(!LiveTVEPGSourceRules.fingerprint([feedA]).contains("a.test"), "no link in the fingerprint")

// Step 13: a source's own guide in lower case, and only the sources' own
// guides read again when one comes or goes.
let ownKey = LiveTVEPGSourceRules.key(sourceID: "builtin:AB12-CD", guideID: "ARD.de")
check(ownKey == "builtin:ab12-cd|ard.de", "own guide key in lower case")
check(LiveTVEPGSourceRules.guideID(fromKey: ownKey) == "ard.de", "id back from an own guide's key")
check(LiveTVEPGSourceRules.sourceID(ofKey: ownKey) == "builtin:ab12-cd", "own guide from its key")
check(LiveTVEPGSourceRules.sourceID(ofKey: "xabc|zdf.de") == "xabc", "added guide from its key")
check(LiveTVEPGSourceRules.sourceID(ofKey: "zdf.de") == "", "first source's guide from its key")
check(LiveTVEPGSourceRules.isBuiltIn(sourceID: "") && LiveTVEPGSourceRules.isBuiltIn(sourceID: "builtin:x#2"), "own guides")
check(!LiveTVEPGSourceRules.isBuiltIn(sourceID: "xabc"), "added guide is not own")
let own0 = LiveTVGuideFeed(sourceID: "", name: "P", url: URL(string: "http://p.test/xmltv.php")!, shiftMinutes: 0, slot: 0)
let own1 = LiveTVGuideFeed(sourceID: "builtin:b1", name: "Q", url: URL(string: "http://q.test/xmltv.php")!, shiftMinutes: 0, slot: 1)
let printBoth = LiveTVEPGSourceRules.fingerprint([feedA, own0, own1])
let printFirst = LiveTVEPGSourceRules.fingerprint([feedA, own0])
let added = LiveTVEPGSourceRules.change(from: printFirst, to: printBoth)
check(added?.added == ["builtin:b1"] && added?.removed.isEmpty == true, "a source added: only its guide")
let removed = LiveTVEPGSourceRules.change(from: printBoth, to: printFirst)
check(removed?.removed == ["builtin:b1"] && removed?.added.isEmpty == true, "a source off: only its guide goes")
let firstOff = LiveTVEPGSourceRules.change(from: printBoth, to: LiveTVEPGSourceRules.fingerprint([feedA, own1]))
check(firstOff?.removed == [""], "the first source off")
check(LiveTVEPGSourceRules.change(from: printFirst, to: LiveTVEPGSourceRules.fingerprint([feedB, own0])) == nil,
      "an added guide changed: everything again")
check(LiveTVEPGSourceRules.change(from: LiveTVEPGSourceRules.fingerprint([own0]), to: printFirst) == nil,
      "an added guide new: everything again")

check(LiveTVEPGSourceRules.gzipHeaderLength([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3, 0xaa]) == 10, "plain gzip header")
let named: [UInt8] = [0x1f, 0x8b, 8, 0x08, 0, 0, 0, 0, 0, 3] + Array("epg.xml".utf8) + [0, 0xaa]
check(LiveTVEPGSourceRules.gzipHeaderLength(named) == 18, "gzip header with a file name")
check(LiveTVEPGSourceRules.gzipHeaderLength(Array("<?xml".utf8)) == nil, "not gzip")
check(!LiveTVEPGSourceRules.isGzip(Array("<tv>".utf8)), "xml isn't gzip")

// MARK: Channel names (step 10a)

check(LiveTVNameCleaner.terms(" HD, FHD ,HD, ,24/7") == ["24/7", "FHD", "HD"], "terms: trimmed, no doubles, longest first")
let cleaner = LiveTVNameCleaner.Cleaner(terms: LiveTVNameCleaner.terms("USA, US, UK, 24/7, FHD, HD"))
func cleaned(_ name: String, _ expected: String) {
    let result = cleaner.clean(name)
    check(result == expected, "clean \"\(name)\" -> \"\(result)\", expected \"\(expected)\"")
}
cleaned("USA: ESPN HD", "ESPN")
cleaned("USA Network", "USA Network")
cleaned("Sky Cinema FHD", "Sky Cinema")
cleaned("|UK| BBC One", "BBC One")
cleaned("Discovery", "Discovery")
cleaned("Music HD", "Music")
cleaned("HD", "HD")
cleaned("Movies 24/7", "Movies")
cleaned("[US] Fox News", "Fox News")
cleaned("  KiKA  ", "KiKA")
let tags = LiveTVNameCleaner.Cleaner(terms: LiveTVNameCleaner.terms(LiveTVNameCleaner.common))
check(tags.clean("ARD ᴴᴰ") == "ARD", "superscript tag stuck on")
check(LiveTVNameCleaner.Cleaner(terms: []).clean(" ZDF ") == " ZDF ", "no words: name untouched")

let usaList = ["USA ESPN", "USA CNN", "USA HBO", "USA FOX", "USA ABC", "USA Network"]
check(LiveTVNameCleaner.spacePrefixes(names: usaList, terms: ["USA", "HD"]) == ["usa"], "space prefix used by 5+ channels")
check(LiveTVNameCleaner.spacePrefixes(names: Array(usaList.prefix(4)), terms: ["USA"]).isEmpty, "fewer than 5: no space prefix")
let usa = LiveTVNameCleaner.Cleaner(terms: ["USA"], names: usaList)
check(usa.clean("USA CNN") == "CNN", "space prefix off")
check(usa.clean("USA USA Network") == "USA Network", "space prefix off only once")

var nameEdits = LiveTVNameEdits()
check(nameEdits.isEmpty, "no edits")
nameEdits.channelNames = [1: "Mine"]
nameEdits.removals = "HD"
let shownNames = nameEdits.channelDisplayNames([(id: 1, name: "ZDF HD"), (id: 2, name: "ARD HD"), (id: 3, name: "KiKA")])
check(shownNames == [1: "Mine", 2: "ARD"], "rename first, then cleanup, unchanged left out")
nameEdits.groupNames = ["g1": "News"]
let groupCleaner = LiveTVNameCleaner.Cleaner(terms: ["DE"])
check(nameEdits.groupDisplayName(id: "g1", name: "DE | Nachrichten", cleaner: groupCleaner) == "News", "group rename wins")
check(nameEdits.groupDisplayName(id: "g2", name: "DE | Sport", cleaner: groupCleaner) == "DE | Sport", "group cleanup off")
nameEdits.cleanGroups = true
check(nameEdits.groupDisplayName(id: "g2", name: "DE | Sport", cleaner: groupCleaner) == "Sport", "group cleanup on")

var resets = LiveTVNameEdits()
check(resets.channelRename("ZDF", providerName: "ZDF") == nil, "back to the provider's name: nothing kept")
check(resets.channelRename("  ", providerName: "ZDF") == nil, "empty: nothing kept")
check(resets.channelRename("Zweites", providerName: "ZDF") == "Zweites", "a real rename is kept")
resets.removals = "HD"
check(resets.channelRename("ZDF", providerName: "ZDF") == nil, "cleanup can't change it: nothing kept")
check(resets.channelRename("ZDF HD", providerName: "ZDF HD") == "ZDF HD", "cleanup would change it: kept whole")
resets.removals = "DE"
check(resets.channelRename("DE ZDF", providerName: "DE ZDF") == "DE ZDF", "maybe a space prefix: kept whole")
check(resets.groupRename("DE | Sport", providerName: "DE | Sport") == nil, "group cleanup off: nothing kept")
resets.cleanGroups = true
check(resets.groupRename("DE | Sport", providerName: "DE | Sport") == "DE | Sport", "group cleanup on: kept whole")
check(resets.groupRename("Sport", providerName: "DE | Sport") == nil, "the cleaned name: nothing kept")

// MARK: Your order (step 10b)

let natural = [1, 2, 3, 4, 5]
check(LiveTVListOrder.ordered(natural, saved: nil, id: { $0 }) == natural, "no order: as it is")
check(LiveTVListOrder.ordered(natural, saved: [3, 1], id: { $0 }) == [3, 4, 5, 1, 2], "unsaved wait behind the saved one above")
check(LiveTVListOrder.ordered(natural, saved: [9, 2], id: { $0 }) == [1, 2, 3, 4, 5], "gone ones skipped, new ones on top stay on top")
check(LiveTVListOrder.ordered(natural, saved: [5, 4, 3, 2, 1, 1], id: { $0 }) == [5, 4, 3, 2, 1], "all saved, doubles once")
check(LiveTVListOrder.ordered(["a", "b", "c"], saved: ["c"], id: { $0 }) == ["a", "b", "c"], "saved last: same as before")
check(LiveTVListOrder.move(["a", "b", "c", "d"], from: 0, to: 2) == ["b", "c", "a", "d"], "move down takes the place")
check(LiveTVListOrder.move(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"], "move up takes the place")
check(LiveTVListOrder.move(["a", "b"], from: 0, to: 5) == ["a", "b"], "out of range: unchanged")

// MARK: Your groups (step 10c)

var mine = LiveTVCustomGroups.create([], name: "  ", id: "custom:a")
check(mine.count == 1 && mine[0].name == LiveTVCustomGroups.fallbackName, "empty name: My Group")
mine = LiveTVCustomGroups.create(mine, name: " Sport ", id: "custom:b")
check(mine[1].name == "Sport", "name trimmed")
mine = LiveTVCustomGroups.add(mine, id: "custom:b", channel: 7)
mine = LiveTVCustomGroups.add(mine, id: "custom:b", channel: 3)
mine = LiveTVCustomGroups.add(mine, id: "custom:b", channel: 7)
check(mine[1].channelIDs == [7, 3], "added at the end, once")
check(mine[0].channelIDs.isEmpty, "other group untouched")
mine = LiveTVCustomGroups.add(mine, id: "custom:b", channel: 9)
mine = LiveTVCustomGroups.setOrder(mine, id: "custom:b", shown: [9, 7])
check(mine[1].channelIDs == [9, 7, 3], "reordered; the one not shown kept at the end")
mine = LiveTVCustomGroups.setOrder(mine, id: "custom:b", shown: [5, 3, 3, 9])
check(mine[1].channelIDs == [3, 9, 7], "not yours and doubles ignored")
mine = LiveTVCustomGroups.remove(mine, id: "custom:b", channel: 9)
check(mine[1].channelIDs == [3, 7], "removed")
check(LiveTVCustomGroups.rename(mine, id: "custom:b", to: " ")[1].name == "Sport", "empty rename keeps the name")
check(LiveTVCustomGroups.rename(mine, id: "custom:b", to: "News")[1].name == "News", "renamed")
mine = LiveTVCustomGroups.delete(mine, id: "custom:a")
check(mine.map(\.id) == ["custom:b"], "deleted")
check(LiveTVCustomGroup.isCustom("custom:b") && !LiveTVCustomGroup.isCustom("__all__") && !LiveTVCustomGroup.isCustom("12"), "custom ids")

// MARK: Parental controls (step 11)

check(LiveTVParental.isAdult("XXX Movies") && LiveTVParental.isAdult("For Adults") && LiveTVParental.isAdult("Kino 18+"), "adult names")
check(LiveTVParental.isAdult("+18 Night") && LiveTVParental.isAdult("NSFW"), "adult names, more")
check(!LiveTVParental.isAdult("Sport") && !LiveTVParental.isAdult("Sussex News") && !LiveTVParental.isAdult("Kids 18"), "not adult")
check(LiveTVParental.isValidPin("1234") && LiveTVParental.isValidPin("12345678"), "valid PINs")
check(!LiveTVParental.isValidPin("123") && !LiveTVParental.isValidPin("123456789") && !LiveTVParental.isValidPin("12a4") && !LiveTVParental.isValidPin("１２３４"), "invalid PINs")
let parentalGroups: [(id: String, name: String)] = [("1", "Sport"), ("2", "XXX"), ("3", "News")]
check(LiveTVParental.lockedIDs(groups: parentalGroups, locked: ["3"], lockAdult: true, unlocked: [], enabled: false).isEmpty, "no PIN: nothing locked")
check(LiveTVParental.lockedIDs(groups: parentalGroups, locked: ["3"], lockAdult: true, unlocked: [], enabled: true) == ["2", "3"], "locked by you and by name")
check(LiveTVParental.lockedIDs(groups: parentalGroups, locked: ["3"], lockAdult: false, unlocked: [], enabled: true) == ["3"], "automatic lock off")
check(LiveTVParental.lockedIDs(groups: parentalGroups, locked: ["3"], lockAdult: true, unlocked: ["2"], enabled: true) == ["3"], "unlocked stays open")
check(LiveTVParental.lockout(afterFailures: 4) == 0 && LiveTVParental.lockout(afterFailures: 5) == 30, "wait after 5 wrong PINs")
check(LiveTVParental.lockout(afterFailures: 6) == 60 && LiveTVParental.lockout(afterFailures: 30) == 900, "wait doubles, at most 15 min")

// MARK: VOD (step 12a)

check(OnDemandTitle.key("EN - Dune (2021)", tags: ["en"]) == "dune", "learned tag, year in brackets off")
check(OnDemandTitle.key("|DE| Der Pate") == "derpate", "pipe tag off")
check(OnDemandTitle.key("Dune 2021 4K") == "dune", "year and quality off")
check(OnDemandTitle.key("1917") == "1917", "a year alone is the title")
check(OnDemandTitle.key("Nf - Dune") == "nfdune", "a tag not learned and not like one stays")
check(OnDemandTitle.yearInName("Dune (2021)") == 2021 && OnDemandTitle.yearInName("Dune 2021") == 2021, "year in name")
check(OnDemandTitle.yearInName("1917") == nil && OnDemandTitle.yearInName("2001: A Space Odyssey") == nil, "titles are no years")
check(OnDemandTitle.year(field: "2021-10-22") == 2021 && OnDemandTitle.year(field: nil) == nil && OnDemandTitle.year(field: "abc") == nil, "year field")
let tagNames = (0..<20).map { "EN - Film \($0)" } + ["NF: One", "NF: Two"]
check(OnDemandTitle.learnTags(tagNames) == ["en"], "tags learned from 15+ names only")
check(OnDemandTitle.quality("Dune 4K") == "4K" && OnDemandTitle.quality("Dune FHD") == "1080p" && OnDemandTitle.quality("Dune") == nil, "quality from name")

func vod(_ id: Int, _ name: String, tmdb: Int? = nil, year: Int? = nil) -> OnDemandItem {
    OnDemandItem(kind: .movie, id: id, name: name, key: OnDemandTitle.key(name), categoryID: "1", ext: "mkv", tmdb: tmdb, year: year)
}
let vods = [vod(1, "Dune", tmdb: 438631, year: 2021), vod(2, "Dune 4K", year: 2021), vod(3, "Dune", tmdb: 841, year: 1984), vod(4, "Dune", year: 2020)]
check(OnDemandMatch.copies(of: vods, name: "Dune", year: 2021, tmdb: 438631).map(\.id) == [1], "by TMDB id first")
check(OnDemandMatch.copies(of: vods, name: "Dune", year: 2021, tmdb: nil).map(\.id) == [2, 1, 4], "by name, year within one, 4K first")
check(OnDemandMatch.copies(of: vods, name: "Dune", year: 2021, tmdb: 999).map(\.id) == [2, 4], "another TMDB id is another title")
check(OnDemandMatch.copies(of: vods, name: "Arrival", year: 2016, tmdb: nil).isEmpty, "no match")

let episodeList = [
    OnDemandEpisode(id: 11, season: 1, episode: 1, ext: "mkv", title: "A"),
    OnDemandEpisode(id: 12, season: 1, episode: 2, ext: "mkv", title: "B"),
]
check(OnDemandMatch.episode(episodeList, season: 1, episode: 2)?.id == 12, "episode by season and number")
check(OnDemandMatch.episode(episodeList, season: 3, episode: 2)?.id == 12, "one season only: number alone")
check(OnDemandMatch.episode(episodeList + [OnDemandEpisode(id: 21, season: 2, episode: 1, ext: "mp4", title: "C")], season: 3, episode: 2) == nil, "several seasons: exact only")

let seriesJSON = #"{"episodes": {"2": [{"id": "21", "episode_num": 1, "container_extension": "mkv", "title": "C"}], "1": [{"id": 11, "season": "1", "episode_num": "1"}]}}"#
let parsedEpisodes = OnDemandParse.episodes(Data(seriesJSON.utf8))
check(parsedEpisodes.map(\.id) == [11, 21] && parsedEpisodes[0].ext == "mp4" && parsedEpisodes[1].season == 2, "series info parsed, sorted")

let listJSON = #"[{"stream_id": "5", "name": "Dune (2021)", "category_id": 7, "container_extension": "mkv", "tmdb": "438631"}, {"stream_id": 6, "name": "", "title": "Arrival", "year": "", "releaseDate": "2016-11-10", "tmdb": "0"}, {"name": "no id"}]"#
let parsedItems = OnDemandParse.items(Data(listJSON.utf8), kind: .movie) ?? []
check(parsedItems.count == 2, "entries without id left out")
check(parsedItems.first?.id == 5 && parsedItems.first?.tmdb == 438631 && parsedItems.first?.year == 2021 && parsedItems.first?.categoryID == "7" && parsedItems.first?.key == "dune", "numbers as strings, year from name")
check(parsedItems.last?.name == "Arrival" && parsedItems.last?.tmdb == nil && parsedItems.last?.year == 2016 && parsedItems.last?.ext == nil, "title fallback, tmdb 0 ignored, first non-empty year field")

// MARK: VOD page and Home row (step 12b)

check(OnDemandID.make(.movie, 5) == "ondemand:movie:5" && OnDemandID.episode(seriesID: 7, season: 1, episode: 2) == "ondemand:series:7:1:2", "ids")
let parsedID = OnDemandID.parse("ondemand:series:7:1:2")
check(parsedID?.kind == .series && parsedID?.id == 7 && parsedID?.season == 1 && parsedID?.episode == 2, "episode id parsed")
check(OnDemandID.parse("ondemand:movie:5")?.season == nil && OnDemandID.parse("tt123") == nil && OnDemandID.parse("ondemand:book:1") == nil, "title ids, others")
check(OnDemandTitle.searchName("EN - Dune (2021) 4K", tags: ["en"]) == "Dune", "search name: tag, year, quality off")
check(OnDemandTitle.searchName("|DE| Der Pate 1972") == "Der Pate", "search name: pipe tag, year at the end")
check(OnDemandTitle.searchName("1917") == "1917", "search name: a year alone stays")
let found: [(id: String, name: String, year: Int?)] = [("tt1", "Dune", 1984), ("tt2", "Dune", 2021), ("tt3", "Dune: Part Two", 2024)]
check(OnDemandMatch.pick(found, key: "dune", year: 2021) == "tt2", "closest year")
check(OnDemandMatch.pick(found, key: "dune", year: 2010) == nil, "year too far")
check(OnDemandMatch.pick(found, key: "dune", year: nil) == "tt1", "no year: first of that name")
check(OnDemandMatch.pick(found, key: "arrival", year: 2016) == nil, "other name")

// MARK: VOD search and duplicates (step 12c)

check(OnDemandTitle.searchWords("The Dark Knight 2008") == ["the", "dark", "knight"], "search words: year off")
check(OnDemandTitle.searchWords("Dune 4K") == ["dune"], "search words: quality off")
check(OnDemandTitle.searchWords("1917") == ["1917"], "search words: a year alone stays")
check(OnDemandTitle.searchWords("  ") == [], "search words: nothing")
func vod12c(_ id: Int, _ name: String, tmdb: Int? = nil, year: Int? = nil, kind: OnDemandKind = .movie) -> OnDemandItem {
    OnDemandItem(kind: kind, id: id, name: name, key: OnDemandTitle.key(name), categoryID: "1", ext: "mkv", tmdb: tmdb, year: year)
}
var dedupe = OnDemandDedupe()
let copies12c = [vod12c(1, "Dune 4K", tmdb: 438631, year: 2021), vod12c(2, "Dune", tmdb: 438631, year: 2021),
                 vod12c(3, "Dune", year: 1984), vod12c(4, "Dune HD", year: 2021), vod12c(5, "Dune", kind: .series), vod12c(6, "Arrival", year: 2016)]
check(dedupe.filter(copies12c).map(\.id) == [1, 3, 5, 6], "dedupe: same TMDB id, same name and year; other years and kinds stay")
var noYear = OnDemandDedupe()
check(noYear.filter([vod12c(1, "Heat"), vod12c(2, "Heat", year: 1995)]).map(\.id) == [1], "dedupe: no year matches any year")
var keepsLater = OnDemandDedupe()
_ = keepsLater.filter([vod12c(1, "Up", year: 2009)])
check(keepsLater.filter([vod12c(2, "Up 4K", year: 2009), vod12c(3, "Cars", year: 2006)]).map(\.id) == [3], "dedupe: across pages")
let known12c: [(name: String, year: Int?, tmdb: Int?)] = [("Dune", 2021, nil), ("Arrival", nil, 329865)]
let only = OnDemandSearchMatch.providerOnly(
    [vod12c(1, "Dune", year: 2022), vod12c(2, "Dune", year: 1984), vod12c(3, "Arrival 2016", tmdb: 329865), vod12c(4, "Local Show")],
    known: known12c)
check(only.map(\.id) == [2, 4], "provider only: year within one and TMDB id count as known")
let movies12c = (1...30).map { vod12c($0, "M\($0)") }
let series12c = (100...104).map { vod12c($0, "S\($0)", kind: .series) }
let mixed = OnDemandSearchMatch.mix(movies: movies12c, series: series12c, limit: 20)
check(mixed.count == 20 && mixed.filter { $0.kind == .series }.count == 5, "mix: all series fit, movies fill up")
check(OnDemandSearchMatch.mix(movies: movies12c, series: (100...140).map { vod12c($0, "S\($0)", kind: .series) }, limit: 20)
    .filter { $0.kind == .movie }.count == 10, "mix: half each when both are long")

// MARK: VOD tags, languages, versions (step 12c)

check(OnDemandTitle.key("4K-NF - GOAT (2026)") == "goat", "tag-like: quality and service")
check(OnDemandTitle.key("4K-AR: GOAT (2026)") == "goat" && OnDemandTitle.key("4K-FR-HDR - Goat (2025)") == "goat", "tag-like: language with colon or dash")
check(OnDemandTitle.key("EN - Dune") == "dune" && OnDemandTitle.searchName("DE - Der Pate (1972)") == "Der Pate", "tag-like: language codes")
check(OnDemandTitle.key("CSI: Miami") == "csimiami" && OnDemandTitle.key("FBI: Most Wanted") == "fbimostwanted", "capitals alone are no tag")
check(OnDemandTitle.key("Mission: Impossible - Fallout") == "missionimpossiblefallout", "titles with separators stay")
check(OnDemandLanguage.code(name: "4K-AR: GOAT (2026)", category: "NETFLIX KIDS") == "ar", "language from the name's tag")
check(OnDemandLanguage.code(name: "Goat (2025)", category: "FR - ANIMATION") == "fr", "language from the category's tag")
check(OnDemandLanguage.code(name: "|TR| Kurtlar Vadisi", category: nil) == "tr", "language from a pipe tag")
check(OnDemandLanguage.code(name: "Goat", category: "\u{0623}\u{0641}\u{0644}\u{0627}\u{0645} \u{0623}\u{0637}\u{0641}\u{0627}\u{0644}") == "ar", "language from the category's script")
check(OnDemandLanguage.code(name: "Greek Movies", category: "Greek Movies") == "el", "language from a category word")
check(OnDemandLanguage.code(name: "4K-NF - GOAT (2026)", category: "NETFLIX KIDS") == nil, "no language given")
check(OnDemandLanguage.code(name: "Dune: Part Two", category: "Movies") == nil, "titles are no tags")
let languageFilter = OnDemandLanguageFilter(languages: ["de", "en"], keepUnknown: true)
check(languageFilter.allows("de") && !languageFilter.allows("ar") && languageFilter.allows(nil), "language filter: picked and unknown")
check(!OnDemandLanguageFilter(languages: ["de"], keepUnknown: false).allows(nil) && OnDemandLanguageFilter().allows("ar"), "language filter: unknown off, none picked")
check(!OnDemandLanguageFilter(languages: ["de"]).allows(nil), "language filter: unknown out by default once one is picked")
check(OnDemandLanguage.code(name: "4K-SC - GOAT (2026)", category: "NORDIC BARN") == OnDemandLanguage.nordic
      && OnDemandLanguage.code(name: "GOAT", category: "NORDIC FILM") == OnDemandLanguage.nordic, "language: Nordic packs")
check(OnDemandLanguage.code(name: "4K-A+ - Nocturne (2026) (US)", category: "APPLE+ SERIES") == nil
      && OnDemandLanguage.code(name: "4K-DE-DV - Nocturne (2026) (US)", category: "GERMANY DV") == "de", "language: the head tag, not the country after")
let versionLanguages: [String?] = ["de", nil, "nordic", nil]
check(OnDemandLanguageFilter(languages: ["de"], keepUnknown: true).versions(versionLanguages) { $0 } == ["de"]
      && OnDemandLanguageFilter(languages: ["fr"], keepUnknown: true).versions(versionLanguages) { $0 } == [nil, nil],
      "versions: unknown ones go when a picked language is there")
check(OnDemandLanguage.displayName("nordic") == "Nordic (Scandinavian)", "language: Nordic name")
let tiers12c = [vod(1, "Goat 4K", year: 2026), vod(2, "Goat 4K HDR", year: 2026), vod(3, "Goat UHD", year: 2026),
                vod(4, "Goat FHD", year: 2026), vod(5, "Goat HD", year: 2026), vod(6, "Goat 2160p", year: 2026)]
check(OnDemandMatch.copies(of: tiers12c, name: "Goat", year: 2026, tmdb: nil, limit: 4).map { OnDemandTitle.quality($0.name) }
    == ["4K", "1080p", "720p", "4K"], "versions: one of each quality before more 4K")

// MARK: Sources (step 13a)

check(LiveTVSourceIDs.channel(slot: 0, raw: 12345) == 12345 && LiveTVSourceIDs.group(slot: 0, category: "17") == "17",
      "sources: the first keeps the provider's ids")
let otherChannel = LiveTVSourceIDs.channel(slot: 3, raw: 12345)
check(otherChannel != 12345 && LiveTVSourceIDs.slot(ofChannel: otherChannel) == 3 && LiveTVSourceIDs.raw(ofChannel: otherChannel) == 12345,
      "sources: another slot's channel id goes back to its stream id")
check(LiveTVSourceIDs.slot(ofChannel: 987_654_321) == 0 && LiveTVSourceIDs.raw(ofChannel: 987_654_321) == 987_654_321,
      "sources: big stream ids of the first source")
let otherGroup = LiveTVSourceIDs.group(slot: 2, category: "17")
check(otherGroup == "s2:17" && LiveTVSourceIDs.slot(ofGroup: otherGroup) == 2 && LiveTVSourceIDs.category(ofGroup: otherGroup) == "17",
      "sources: another slot's group id")
check(LiveTVSourceIDs.slot(ofGroup: "__favorites__") == 0 && LiveTVSourceIDs.slot(ofGroup: "sports") == 0
      && LiveTVSourceIDs.slot(ofGroup: "s:x") == 0 && LiveTVSourceIDs.category(ofGroup: "sports") == "sports",
      "sources: the first's and the app's groups")
check(LiveTVSourceIDs.sourceID(ofHeading: LiveTVSourceIDs.heading(sourceID: "abc")) == "abc"
      && LiveTVSourceIDs.sourceID(ofHeading: "17") == nil, "sources: headings")
check(LiveTVSourceIDs.nextSlot(after: 0) == 1 && LiveTVSourceIDs.nextSlot(after: 4) == 5, "sources: next slot")

// MARK: M3U playlists (step 13b)

let m3uText = """
#EXTM3U url-tvg="http://guide.example/a.xml.gz,http://guide.example/b.xml" x-tvg-url="http://guide.example/a.xml.gz"
#EXTINF:-1 tvg-id="das.erste" tvg-name="Das Erste HD" tvg-logo="http://logo.example/1.png" group-title="DE | News;Extra" tvg-chno="7",Das Erste, HD
http://stream.example/live/1.m3u8
#EXTINF:-1 tvg-id="" group-title="",Plain
#EXTGRP:Sports
#EXTVLCOPT:http-user-agent=MyAgent/1.0
#EXTVLCOPT:http-referrer=http://ref.example/
http://stream.example/2.ts|Referer=http://other.example/&Origin=http://origin.example
#EXTINF:-1 group-title="Movies",Dune (2021)
http://stream.example/movie/u/p/55.mkv
#EXTINF:-1 group-title="News" user-agent="Agent2",Third
#EXTHTTP:{"Cookie":"a=b"}
http://stream.example/live/3
"""
let m3u = LiveTVM3U.parse(m3uText)
check(m3u.guideURLs == ["http://guide.example/a.xml.gz", "http://guide.example/b.xml"], "m3u: linked guides, once each")
check(m3u.entries.count == 3, "m3u: channels in, movies out")
let m3uFirst = m3u.entries[0]
check(m3uFirst.name == "Das Erste, HD" && m3uFirst.tvgID == "das.erste" && m3uFirst.tvgName == "Das Erste HD"
      && m3uFirst.logo == "http://logo.example/1.png" && m3uFirst.group == "DE | News" && m3uFirst.number == 7
      && m3uFirst.url == "http://stream.example/live/1.m3u8", "m3u: attributes, name after the comma outside quotes")
let m3uSecond = m3u.entries[1]
check(m3uSecond.tvgID == nil && m3uSecond.group == "Sports" && m3uSecond.url == "http://stream.example/2.ts"
      && m3uSecond.headers["User-Agent"] == "MyAgent/1.0" && m3uSecond.headers["Referer"] == "http://other.example/"
      && m3uSecond.headers["Origin"] == "http://origin.example", "m3u: #EXTGRP, #EXTVLCOPT, link headers win")
check(m3u.entries[2].headers["User-Agent"] == "Agent2" && m3u.entries[2].headers["Cookie"] == "a=b", "m3u: user-agent attribute, #EXTHTTP")
check(LiveTVM3U.groups(of: m3u.entries) == ["DE | News", "Sports", "News"], "m3u: groups in their order")
check(LiveTVM3U.isVOD(url: "http://x/series/u/p/1.mp4") && LiveTVM3U.isVOD(url: "http://x/a/film.mkv?t=1")
      && !LiveTVM3U.isVOD(url: "http://x/live/u/p/1.ts") && !LiveTVM3U.isVOD(url: "http://x/u/p/123"), "m3u: what counts as VOD")
let m3uIDs = LiveTVM3U.ids(for: m3u.entries)
check(Set(m3uIDs).count == 3 && m3uIDs.allSatisfy { $0 > 0 && $0 <= 0x7FFF_FFFF }, "m3u: ids, distinct and below 2^31")
var m3uMoved = m3u.entries
m3uMoved[0].url = "http://stream.example/live/1.m3u8?token=new"
check(LiveTVM3U.ids(for: m3uMoved) == m3uIDs, "m3u: a new link keeps the id")
let m3uTwins = [LiveTVM3UEntry(name: "Same", url: "http://a"), LiveTVM3UEntry(name: "Same", url: "http://b")]
check(Set(LiveTVM3U.ids(for: m3uTwins)).count == 2, "m3u: the same name twice gets two ids")
check(LiveTVM3U.parse("#EXTINF:-1,No link\n").entries.isEmpty && LiveTVM3U.parse("http://lonely\n").entries.isEmpty,
      "m3u: an entry needs both lines")

// MARK: A source's own guide (step 13a)

let firstSourceChannel = 7
let secondSourceChannel = LiveTVSourceIDs.channel(slot: 2, raw: 7)
var own = LiveTVEPGMatch.Picker(channels: [
    ref(firstSourceChannel, "zdf.de", "ZDF"),
    ref(secondSourceChannel, "zdf.de", "ZDF"),
    ref(LiveTVSourceIDs.channel(slot: 2, raw: 8), nil, "Phoenix"),
], overrides: [LiveTVSourceIDs.channel(slot: 2, raw: 8): "phoenix.tv"])
check(own.saw(key: "b2|zdf.de", id: "zdf.de", names: ["ZDF"], guide: 1, slot: 2), "own guide: kept for its source")
check(own.saw(key: "c|zdf.de", id: "zdf.de", names: ["ZDF"], guide: 2, slot: 5) == false, "own guide: not for another source")
check(own.saw(key: "phoenix.tv", id: "phoenix.tv", names: ["Phoenix"], guide: 0, slot: 0), "own guide: a choice by hand counts anyway")
let ownLinks = own.links(listed: ["b2|zdf.de", "phoenix.tv"])
check(ownLinks[secondSourceChannel] == "b2|zdf.de" && ownLinks[firstSourceChannel] == nil, "own guide: only its channel linked")

// MARK: VOD from every login (step 13c)

let vodFirst = OnDemandItem(kind: .movie, id: 55, name: "Dune", key: "dune", categoryID: "12", ext: "mkv", tmdb: 1, year: 2021)
check(vodFirst.inSource(slot: 0) == vodFirst, "vod sources: the first login keeps its ids")
var vodOtherSource = vodFirst
vodOtherSource.icon = "http://icon"
let vodMoved = vodOtherSource.inSource(slot: 3)
check(LiveTVSourceIDs.slot(ofChannel: vodMoved.id) == 3 && LiveTVSourceIDs.raw(ofChannel: vodMoved.id) == 55
      && vodMoved.categoryID == "s3:12" && vodMoved.icon == "http://icon" && vodMoved.key == "dune",
      "vod sources: another login's ids, the rest kept")

// MARK: M3U catch-up (step 13d)

let catchupList = LiveTVM3U.parse("""
#EXTM3U catchup="shift" catchup-days="3"
#EXTINF:-1 tvg-id="a",Shifted
http://cdn.example/a/index.m3u8
#EXTINF:-1 catchup="append" catchup-source="?start={utc}&end={utcend}" catchup-days="7",Appended
http://cdn.example/b.ts
#EXTINF:-1 catchup="flussonic",Fluss
http://fs.example/ch1/index.m3u8?token=x
""")
check(catchupList.entries[0].catchup == LiveTVM3UCatchup(type: "shift", source: nil, days: 3), "m3u catch-up: the playlist's for every entry")
check(catchupList.entries[1].catchup?.type == "append" && catchupList.entries[1].catchup?.days == 7, "m3u catch-up: the entry's own wins")
check(LiveTVM3UCatchup(attributes: ["tvg-rec": "2"])?.type == "default" && LiveTVM3UCatchup(attributes: [:]) == nil,
      "m3u catch-up: days alone mean default, nothing means none")
let cStart = Date(timeIntervalSince1970: 1_800_000_000)
let cEnd = cStart.addingTimeInterval(3600)
let cNow = cStart.addingTimeInterval(7200)
check(LiveTVCatchupM3U.urls(live: "http://cdn.example/a/index.m3u8", catchup: LiveTVM3UCatchup(type: "shift", source: nil, days: 3),
                            start: cStart, end: cEnd, now: cNow).first?.absoluteString
      == "http://cdn.example/a/index.m3u8?utc=1800000000&lutc=1800007200", "m3u catch-up: shift")
check(LiveTVCatchupM3U.urls(live: "http://cdn.example/b.ts", catchup: catchupList.entries[1].catchup!,
                            start: cStart, end: cEnd, now: cNow).first?.absoluteString
      == "http://cdn.example/b.ts?start=1800000000&end=1800003600", "m3u catch-up: append")
check(LiveTVCatchupM3U.urls(live: "http://fs.example/ch1/index.m3u8?token=x", catchup: LiveTVM3UCatchup(type: "flussonic", source: nil, days: 1),
                            start: cStart, end: cEnd, now: cNow).first?.absoluteString
      == "http://fs.example/ch1/index-1800000000-3600.m3u8?token=x", "m3u catch-up: flussonic")
let xcLinks = LiveTVCatchupM3U.urls(live: "http://xt.example:8080/user/pass/123.ts", catchup: LiveTVM3UCatchup(type: "xc", source: nil, days: 1),
                                    start: cStart, end: cEnd, now: cNow, serverTimeZone: TimeZone(identifier: "UTC"))
check(xcLinks.first?.absoluteString == "http://xt.example:8080/timeshift/user/pass/60/2027-01-15:08-00/123.ts" && xcLinks.count > 1,
      "m3u catch-up: xc as Xtream's forms")
check(LiveTVCatchupM3U.fill("{utc:Y-m-d H:M:S}|${duration:60}|{offset}", start: 1_800_000_000, end: 1_800_003_600,
                            now: 1_800_007_200, duration: 3600) == "2027-01-15 08:00:00|60|7200", "m3u catch-up: templates")

// Step 13e: Stalker portals.
check(LiveTVStalkerConfig.normalisedMAC("00-1a-79-ab-cd-ef") == "00:1A:79:AB:CD:EF", "stalker: MAC normalised")
check(LiveTVStalkerConfig.normalisedMAC("00:1A:79:AB:CD") == nil, "stalker: short MAC refused")
check(LiveTVStalkerWire.endpoints(portal: "http://portal.example:8080/c/")
      == ["http://portal.example:8080/portal.php", "http://portal.example:8080/server/load.php",
          "http://portal.example:8080/stalker_portal/server/load.php"], "stalker: /c/ portal")
check(LiveTVStalkerWire.endpoints(portal: "http://portal.example/stalker_portal/server/load.php")
      == ["http://portal.example/stalker_portal/server/load.php", "http://portal.example/stalker_portal/portal.php"],
      "stalker: load.php as given first")
check(LiveTVStalkerWire.endpoints(portal: "ftp://portal.example/c/").isEmpty, "stalker: not http")
check(LiveTVStalkerWire.installationBase("http://portal.example/stalker_portal/server/load.php")
      == "http://portal.example/stalker_portal/", "stalker: installation folder")
check(LiveTVStalkerWire.requestURL(endpoint: "http://portal.example/portal.php",
                                   parameters: [("type", "stb"), ("action", "handshake"), ("token", "")])?.absoluteString
      == "http://portal.example/portal.php?type=stb&action=handshake&token=&JsHttpRequest=1-xml", "stalker: request link")
check(LiveTVStalkerWire.requestURL(endpoint: "http://portal.example/portal.php",
                                   parameters: [("password", "a+b")])?.absoluteString.contains("a%2Bb") == true,
      "stalker: + escaped")
if case .value(let js) = LiveTVStalkerWire.unwrap(Data(#"{"js":{"token":"abc","random":"r"}}"#.utf8)),
   let object = js as? [String: Any] {
    check(LiveTVStalkerWire.text(object, "token") == "abc", "stalker: js envelope")
} else {
    check(false, "stalker: js envelope")
}
if case .unauthorised = LiveTVStalkerWire.unwrap(Data("Authorization failed.".utf8)) {
    check(true, "stalker: auth message")
} else {
    check(false, "stalker: auth message")
}
if case .invalid = LiveTVStalkerWire.unwrap(Data("<html>".utf8)) { check(true, "stalker: html refused") } else { check(false, "stalker: html refused") }
let stalkerRows = LiveTVStalkerWire.rows(["total_items": 2, "data": [["id": "1"], ["id": 2]]] as [String: Any])
check(stalkerRows?.count == 2 && LiveTVStalkerWire.text(stalkerRows![1], "id") == "2", "stalker: rows, number ids")
check(LiveTVStalkerWire.flag(["a": "1", "b": 0] as [String: Any], "a") == true
      && LiveTVStalkerWire.flag(["b": 0] as [String: Any], "b") == false, "stalker: flags")
check(LiveTVStalkerWire.direct("ffmpeg http://cdn.example/live/1.ts")?.absoluteString == "http://cdn.example/live/1.ts",
      "stalker: direct link without wrapper")
check(LiveTVStalkerWire.direct("ffmpeg http://localhost/ch/1_") == nil, "stalker: placeholder host needs create_link")
let loadPHP = "http://portal.example/stalker_portal/server/load.php"
check(LiveTVStalkerWire.resolved("ffrt http://cdn.example/a.m3u8?t=1", endpoint: loadPHP)?.absoluteString
      == "http://cdn.example/a.m3u8?t=1", "stalker: resolved absolute")
check(LiveTVStalkerWire.resolved("/media/42.mpg", endpoint: loadPHP)?.absoluteString
      == "http://portal.example/stalker_portal/media/42.mpg", "stalker: resolved path under the installation")
check(LiveTVStalkerWire.resolved("//cdn.example/b.ts", endpoint: loadPHP)?.absoluteString == "http://cdn.example/b.ts",
      "stalker: resolved protocol-relative")
check(LiveTVStalkerWire.image("/logos/1.png", endpoint: loadPHP) == "http://portal.example/logos/1.png", "stalker: logo path")
let stalkerUTC = TimeZone(identifier: "UTC")!
check(LiveTVStalkerWire.timestamp("1731700000", zone: stalkerUTC)?.timeIntervalSince1970 == 1_731_700_000, "stalker: unix time")
check(LiveTVStalkerWire.timestamp("1731700000000", zone: stalkerUTC)?.timeIntervalSince1970 == 1_731_700_000, "stalker: ms time")
check(LiveTVStalkerWire.timestamp("2027-01-15 08:00:00", zone: stalkerUTC)?.timeIntervalSince1970 == 1_800_000_000, "stalker: date time")
let keyedGuide: [String: Any] = ["data": ["12": [
    ["name": "News", "start_timestamp": "1800000000", "stop_timestamp": "1800003600", "descr": "Today"],
    ["name": "Broken", "start_timestamp": "1800003600", "stop_timestamp": "1800003600"],
]]]
let keyedProgrammes = LiveTVStalkerWire.programmes(keyedGuide, zone: stalkerUTC)
check(keyedProgrammes.count == 1 && keyedProgrammes[0].channel == "12" && keyedProgrammes[0].description == "Today",
      "stalker: guide keyed by channel, empty show left out")
let listGuide: [Any] = [["ch_id": 7, "title": "Film", "start": "2027-01-15 08:00:00", "stop": "2027-01-15 09:30:00"]]
check(LiveTVStalkerWire.programmes(listGuide, zone: stalkerUTC).first?.stop.timeIntervalSince1970 == 1_800_005_400,
      "stalker: guide list with ch_id")
check(LiveTVStalkerWire.xmltvTime(Date(timeIntervalSince1970: 1_800_000_000)) == "20270115080000 +0000", "stalker: XMLTV time")
check(LiveTVStalkerWire.xmlEscaped("A & B <\"C\">\u{01}") == "A &amp; B &lt;&quot;C&quot;&gt;", "stalker: XML escaped")

// Step 13f: Stalker movies, series and catch-up.
let movieRow: [String: Any] = [
    "id": "42", "name": "The Film (2019)", "cmd": "/media/file_42.mpg", "category_id": "7",
    "screenshot_uri": "/posters/42.jpg", "added": "2026-01-02 03:04:05", "rating_imdb": "7.1",
    "description": "A plot.", "use_http_tmp_link": "0", "has_files": 1,
]
let movieEntry = LiveTVStalkerWire.vodEntry(movieRow, endpoint: loadPHP, zone: stalkerUTC)
check(movieEntry?.isSeries == false && movieEntry?.ref.cmd == "/media/file_42.mpg" && movieEntry?.ref.fixed == true
      && movieEntry?.ref.hasFiles == true && movieEntry?.ref.plot == "A plot.", "stalker vod: movie row")
check(movieEntry?.poster == "http://portal.example/posters/42.jpg" && movieEntry?.rating == "7.1"
      && movieEntry?.added == 1_767_323_045, "stalker vod: poster, rating, added")
let vodSeriesRow: [String: Any] = ["id": "42", "name": "A Show", "is_series": "1", "cmd": "", "category_id": "3"]
check(LiveTVStalkerWire.vodEntry(vodSeriesRow, endpoint: loadPHP, zone: stalkerUTC)?.ref.variant == "v",
      "stalker vod: series in the movie list")
let ownSeriesRow: [String: Any] = ["id": "9", "name": "Old Show", "cmd": "/media/9.mpg", "series": [1, 2, "3", 0]]
let ownSeries = LiveTVStalkerWire.vodEntry(ownSeriesRow, endpoint: loadPHP, zone: stalkerUTC, variant: "c")
check(ownSeries?.ref.variant == "c" && ownSeries?.ref.selectors == "1,2,3", "stalker vod: own series with episode numbers")
let decodedRef = LiveTVStalkerWire.VODRef.decode(movieEntry?.ref.encoded())
check(decodedRef == movieEntry?.ref, "stalker vod: play ref round trip")
check(LiveTVStalkerWire.number(for: "42") == 42, "stalker vod: small id kept")
check(LiveTVStalkerWire.number(for: "42", salt: "v") != 42 && LiveTVStalkerWire.number(for: "42", salt: "v") > 0,
      "stalker vod: salted id apart")
check(LiveTVStalkerWire.number(for: "abc") == LiveTVStalkerWire.number(for: "abc"), "stalker vod: text id stable")
let stalkerItems = OnDemandStalker.items(
    [movieEntry!, LiveTVStalkerWire.vodEntry(["id": "42", "name": "Copy"], endpoint: loadPHP, zone: stalkerUTC)!],
    kind: .movie)
check(stalkerItems.items.count == 2 && stalkerItems.items[0].id == 42 && stalkerItems.items[1].id == 43
      && stalkerItems.items[0].year == 2019 && LiveTVStalkerWire.VODRef.decode(stalkerItems.items[0].play)?.id == "42",
      "stalker vod: items with unique ids, year and play ref")
let single = LiveTVStalkerWire.singleSeason(ownSeries!.ref, title: "Old Show")
check(single?.selectors == ["1", "2", "3"], "stalker vod: older portal's one season")
let classic = LiveTVStalkerWire.classicEpisodes(single!)
check(classic.count == 3 && classic[1].ref.selectors == "2" && classic[1].ref.cmd == "/media/9.mpg"
      && classic[1].number == 2, "stalker vod: classic episodes")
let seasonRows: [[String: Any]] = [["id": "s1", "name": "Season 1", "video_id": "77", "season_number": "1", "is_season": true],
                                   ["id": "x", "is_season": false]]
let vodSeasons = LiveTVStalkerWire.seasons(seasonRows, of: LiveTVStalkerWire.VODRef(id: "42", variant: "v"))
check(vodSeasons.count == 1 && vodSeasons[0].movieID == "77" && vodSeasons[0].number == 1, "stalker vod: seasons")
let episodeRows: [[String: Any]] = [["id": "e5", "name": "Pilot", "series_number": "1", "cmd": "/media/e5.mpg"]]
let vodEpisodes = LiveTVStalkerWire.episodes(episodeRows, of: vodSeasons[0], endpoint: loadPHP)
check(vodEpisodes.first?.ref.selectors == "1" && vodEpisodes.first?.ref.seasonID == "s1"
      && vodEpisodes.first?.ref.movieID == "77", "stalker vod: episodes")
let linkParameters = LiveTVStalkerWire.vodLinkParameters(vodEpisodes[0].ref, command: "/media/e5.mpg")
check(linkParameters.contains { $0 == ("series", "1") } && linkParameters.contains { $0 == ("season_id", "s1") }
      && linkParameters.contains { $0 == ("movie_id", "77") }, "stalker vod: create_link parameters")
check(LiveTVStalkerWire.archiveDays(["tv_archive": "1", "tv_archive_duration": "3"]) == 3
      && LiveTVStalkerWire.archiveDays(["tv_archive": 0, "tv_archive_duration": 3]) == 0, "stalker catch-up: archive days")
let archiveRows: [[String: Any]] = [
    ["id": "100", "start_timestamp": "1800000000", "mark_archive": "1"],
    ["id": "101", "start_timestamp": "1800000120", "mark_archive": "0"],
    ["id": "bad id", "start_timestamp": "1800000060", "mark_archive": "1"],
]
let shows = LiveTVStalkerWire.archivedShows(archiveRows, zone: stalkerUTC)
check(LiveTVStalkerWire.archivedShow(shows, start: Date(timeIntervalSince1970: 1_800_000_100)) == "100",
      "stalker catch-up: archived show nearest the start")
check(LiveTVStalkerWire.archivedShow(shows, start: Date(timeIntervalSince1970: 1_800_001_000)) == nil,
      "stalker catch-up: nothing within five minutes")
check(LiveTVStalkerWire.archiveCommand("100") == "auto /media/100.mpg", "stalker catch-up: command")
check(LiveTVStalkerWire.day(Date(timeIntervalSince1970: 1_800_000_000), zone: stalkerUTC) == "2027-01-15",
      "stalker catch-up: day in the portal's zone")

// Step 15: Multiview layouts.
check(LiveTVMultiviewLayout.allCases.allSatisfy { $0.frames.count == $0.paneCount }, "multiview: a frame per pane")
check(LiveTVMultiviewLayout.allCases.allSatisfy { layout in
    abs(layout.frames.reduce(0) { $0 + $1.width * $1.height } - 1) < 0.0001
}, "multiview: panes fill the screen")
check(LiveTVMultiviewLayout.fitting(3) == .three && LiveTVMultiviewLayout.fitting(9) == .four
      && LiveTVMultiviewLayout.fitting(0) == .one, "multiview: layout for a count")
check(LiveTVMultiviewLayout.four.next(from: 0, .right) == 1 && LiveTVMultiviewLayout.four.next(from: 1, .down) == 3
      && LiveTVMultiviewLayout.four.next(from: 1, .right) == 1, "multiview: 2 x 2 arrows, no wrap")
check(LiveTVMultiviewLayout.fourWideTop.next(from: 0, .down) == 2 && LiveTVMultiviewLayout.fourWideTop.next(from: 3, .up) == 0,
      "multiview: wide top")
check(LiveTVMultiviewLayout.threeBigLeft.next(from: 2, .left) == 0 && LiveTVMultiviewLayout.threeBigLeft.next(from: 1, .down) == 2,
      "multiview: big left")
check(LiveTVMultiviewLayout.three.isTop(1) && !LiveTVMultiviewLayout.three.isTop(2), "multiview: top row")
check(LiveTVMultiviewLayout.back(pickerOpen: true, fullScreen: true, overlaysShown: true) == .closePicker
      && LiveTVMultiviewLayout.back(pickerOpen: false, fullScreen: true, overlaysShown: true) == .allPanes
      && LiveTVMultiviewLayout.back(pickerOpen: false, fullScreen: false, overlaysShown: true) == .hideOverlays
      && LiveTVMultiviewLayout.back(pickerOpen: false, fullScreen: false, overlaysShown: false) == .leave,
      "multiview: back one level at a time")
check(LiveTVMultiviewLayout.nextFull([0, 2, 3], from: 3, forward: true) == 0
      && LiveTVMultiviewLayout.nextFull([0, 2, 3], from: 0, forward: false) == 3, "multiview: full screen goes round")

// Step 15b: backup copies.
check(LiveTVBackupNames.key("US: ESPN HD") == "espn" && LiveTVBackupNames.key("ESPN (Backup)") == "espn",
      "backup: prefix, quality and backup notes left out")
check(LiveTVBackupNames.key("UK | Sky Sports F1 FHD") == "sky sports f1", "backup: pipe prefix")
check(LiveTVBackupNames.key("DE - Sky Cinema 4K 50fps") == "sky cinema", "backup: dash prefix, fps")
check(LiveTVBackupNames.key("Discovery 5.1 RAW") == "discovery", "backup: sound layout")
check(LiveTVBackupNames.stationNote("FOX (WNYW)") == "wnyw" && LiveTVBackupNames.stationNote("FOX (HD)") == nil,
      "backup: station note, not quality")
let copies = [
    LiveTVBackupNames.Copy(id: 1, name: "US: ESPN HD", slot: 0),
    LiveTVBackupNames.Copy(id: 2, name: "ESPN Backup", slot: 0),
    LiveTVBackupNames.Copy(id: 3, name: "USA | ESPN FHD", slot: 1),
    LiveTVBackupNames.Copy(id: 4, name: "FOX (WNYW)", slot: 0),
    LiveTVBackupNames.Copy(id: 5, name: "FOX (KTTV)", slot: 1),
    LiveTVBackupNames.Copy(id: 6, name: "FOX", slot: 1),
    LiveTVBackupNames.Copy(id: 7, name: "A", slot: 1),
]
let backupIndex = LiveTVBackupNames.index(copies)
check(LiveTVBackupNames.backup(for: copies[0], in: backupIndex, tried: [1])?.id == 3, "backup: other source first")
check(LiveTVBackupNames.backup(for: copies[0], in: backupIndex, tried: [1, 3])?.id == 2, "backup: then the same source")
check(LiveTVBackupNames.backup(for: copies[0], in: backupIndex, tried: [1, 2, 3]) == nil, "backup: none left")
check(LiveTVBackupNames.backup(for: copies[3], in: backupIndex, tried: [4])?.id == 6, "backup: never another local station")
check(LiveTVBackupNames.backup(for: copies[6], in: backupIndex, tried: []) == nil, "backup: names too short")

// Step 16: the calendar.
func calEpisode(_ season: Int, _ number: Int, _ day: String = "2026-11-20", at stamp: Date? = nil,
                order: Int? = nil) -> LiveTVCalendarEpisode {
    LiveTVCalendarEpisode(season: season, number: number, name: nil, airstamp: stamp, airdate: day,
                          runtime: 45, image: nil, summary: nil, seasonEpisodes: order)
}
check(LiveTVCalendarLogic.tags(first: calEpisode(1, 1), last: calEpisode(1, 1), showEnded: false, highestSeason: 1)
      == [.seriesPremiere], "calendar: series premiere")
check(LiveTVCalendarLogic.tags(first: calEpisode(3, 1), last: calEpisode(3, 1, order: 8), showEnded: false, highestSeason: 3)
      == [.seasonPremiere], "calendar: season premiere, not a finale on E1")
check(LiveTVCalendarLogic.tags(first: calEpisode(3, 8), last: calEpisode(3, 8, order: 8), showEnded: false, highestSeason: 3)
      == [.seasonFinale], "calendar: season finale")
check(LiveTVCalendarLogic.tags(first: calEpisode(3, 8), last: calEpisode(3, 8, order: 8), showEnded: true, highestSeason: 3)
      == [.seriesFinale], "calendar: series finale")
check(LiveTVCalendarLogic.grouped([calEpisode(2, 1), calEpisode(2, 2), calEpisode(2, 3, "2026-11-21")], streaming: true).map(\.count)
      == [2, 1], "calendar: a drop on one day is one card")
check(LiveTVCalendarLogic.isNew(aired: true, watched: false, day: "2026-11-19", today: "2026-11-20")
      && !LiveTVCalendarLogic.isNew(aired: true, watched: false, day: "2026-11-18", today: "2026-11-20")
      && !LiveTVCalendarLogic.isNew(aired: false, watched: false, day: "2026-11-20", today: "2026-11-20"), "calendar: new")
check(LiveTVCalendarLogic.episodeName("Episode 4") == nil && LiveTVCalendarLogic.episodeName("TBA") == nil
      && LiveTVCalendarLogic.episodeName("Pilot") == "Pilot", "calendar: placeholder names")
check(LiveTVCalendarLogic.plainText("<p>Tom &amp; Jerry&#39;s day</p>") == "Tom & Jerry's day", "calendar: summary text")
check(!LiveTVCalendarLogic.isAhead(season: 2, episode: 4, furthest: (2, 3))
      && !LiveTVCalendarLogic.isAhead(season: 3, episode: 1, furthest: (2, 9))
      && LiveTVCalendarLogic.isAhead(season: 2, episode: 6, furthest: (2, 3)), "calendar: spoilers past the next one")
check(LiveTVCalendarLogic.isWatched(season: 1, episode: 4, marked: [], furthest: (2, 1))
      && LiveTVCalendarLogic.isWatched(season: 2, episode: 7, marked: ["2:7"], furthest: nil)
      && !LiveTVCalendarLogic.isWatched(season: 2, episode: 2, marked: [], furthest: (2, 1)), "calendar: watched")
check(LiveTVCalendarLogic.day("2026-12-31", plus: 1) == "2027-01-01" && LiveTVCalendarLogic.day("2026-03-01", plus: -1) == "2026-02-28",
      "calendar: day arithmetic")
// West Coast: an East Coast show at 20:00 ET airs at 20:00 PT on the Pacific feed.
let calPacific = TimeZone(identifier: "America/Los_Angeles")!
let calBerlin = TimeZone(identifier: "Europe/Berlin")!
let eightET = Date(timeIntervalSince1970: 1_795_222_800) // 2026-11-21 01:00 UTC = 20:00 EST
let pacificAir = LiveTVCalendarLogic.localAir(listed: eightET, networkZone: "America/New_York", scheduleTime: "20:00",
                                              streaming: false, local: calPacific)
var pacificCalendar = Calendar(identifier: .gregorian)
pacificCalendar.timeZone = calPacific
check(pacificAir.map { pacificCalendar.component(.hour, from: $0) } == 20, "calendar: Pacific feed at the same clock time")
check(LiveTVCalendarLogic.localAir(listed: eightET, networkZone: "America/New_York", scheduleTime: "20:00",
                                   streaming: false, local: calBerlin) == eightET, "calendar: abroad, the real time")
check(LiveTVCalendarLogic.localAir(listed: eightET, networkZone: "America/New_York", scheduleTime: "20:00",
                                   streaming: true, local: calPacific) == eightET, "calendar: streaming, the real time")
// Lists.
let utcZone = TimeZone(identifier: "UTC")!
let calNow = Date(timeIntervalSince1970: 1_795_176_000) // 2026-11-20 12:00 UTC
func calEntry(_ key: String, _ day: String, _ air: Date?, watched: Bool = false) -> LiveTVCalendarEntry {
    LiveTVCalendarEntry(key: key, kind: .episode, contentID: key, title: key, air: air, day: day, watched: watched, runtime: 60)
}
let calEntries = [
    calEntry("past", "2026-11-19", nil, watched: true),
    calEntry("morning", "2026-11-20", calNow.addingTimeInterval(-3 * 3600)),
    calEntry("running", "2026-11-20", calNow.addingTimeInterval(-1800)),
    calEntry("later", "2026-11-22", nil),
]
check(LiveTVCalendarLogic.upcoming(calEntries, now: calNow, zone: utcZone).map(\.key) == ["running", "later"],
      "calendar: upcoming keeps what's still on")
check(LiveTVCalendarLogic.recent(calEntries, now: calNow, zone: utcZone, unwatchedOnly: false).map(\.key)
      == ["running", "morning", "past"], "calendar: recent, newest first")
check(LiveTVCalendarLogic.recent(calEntries, now: calNow, zone: utcZone, unwatchedOnly: true).map(\.key)
      == ["running", "morning"], "calendar: unwatched only")
// Films.
let filmCards = LiveTVCalendarLogic.movieCards(
    .init(theatrical: "2026-11-25", digital: nil, disc: "2027-01-10"), from: "2026-10-21", to: "2027-03-20",
    label: { tag, day in "\(tag.rawValue) \(day)" })
check(filmCards.map(\.tag) == [.inTheaters, .onDisc] && filmCards.first?.note == "atHome ", "calendar: film cards")

// On my TV (16d).
check(LiveTVCalendarGuideMatch.normalize("Grey's Anatomy!") == "greys anatomy", "guide: names folded")
check(LiveTVCalendarGuideMatch.names("Tulsa King: Der Deal") == ["tulsa king der deal", "tulsa king"], "guide: title before a colon")
let guideAir = Date(timeIntervalSince1970: 1_800_000_000)
let guideHits = LiveTVCalendarGuideMatch.match(
    [.init(key: "ep", title: "Tulsa King", network: "Paramount Network", air: guideAir)],
    channels: [
        "one": [.init(id: 1, name: "Some Channel", logo: nil, favorite: false)],
        "two": [.init(id: 2, name: "Paramount Network HD", logo: nil, favorite: false)],
        "far": [.init(id: 3, name: "Other", logo: nil, favorite: true)],
    ],
    rows: { each in
        each("one", guideAir, guideAir.addingTimeInterval(3600), "Tulsa King")
        each("two", guideAir.addingTimeInterval(600), guideAir.addingTimeInterval(4200), "Tulsa King - Folge 7")
        each("far", guideAir.addingTimeInterval(6 * 3600), guideAir.addingTimeInterval(7 * 3600), "Tulsa King")
        each("one", guideAir, guideAir.addingTimeInterval(3600), "Tulsa Kingdom")
    })
check(guideHits["ep"]?.channelID == 2 && guideHits["ep"]?.others == 1, "guide: the network's channel first, not a rerun hours later")

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
