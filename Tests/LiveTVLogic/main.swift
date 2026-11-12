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
check(LiveTVEPGSourceRules.shiftChoices.count == 49 && LiveTVEPGSourceRules.shiftChoices.contains(0), "shift choices")
check(LiveTVEPGSourceRules.host(of: " http://epg.example.test/guide.xml.gz ") == "epg.example.test", "host")
let feedA = LiveTVGuideFeed(sourceID: "xabc", name: "A", url: URL(string: "http://a.test/e.xml")!, shiftMinutes: 0)
let feedB = LiveTVGuideFeed(sourceID: "xabc", name: "A", url: URL(string: "http://a.test/e.xml")!, shiftMinutes: 60)
check(LiveTVEPGSourceRules.fingerprint([feedA]) != LiveTVEPGSourceRules.fingerprint([feedB]), "shift changes the fingerprint")
check(!LiveTVEPGSourceRules.fingerprint([feedA]).contains("a.test"), "no link in the fingerprint")

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

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
