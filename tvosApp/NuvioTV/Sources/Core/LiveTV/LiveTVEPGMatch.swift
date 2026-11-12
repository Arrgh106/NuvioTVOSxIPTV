import Foundation

/// One of the provider's channels, as the guide import sees it.
struct LiveTVEPGChannelRef: Codable, Sendable {
    let streamID: Int
    let epgID: String?
    let name: String
}

/// Which guide channel belongs to which provider channel (step 8a), as
/// Android's `buildProgramsInner`: a manual choice ("Assign EPG") first, then
/// the provider's guide id, then the name. No UIKit or SQLite, so the rules
/// have Linux tests (Tests/LiveTVLogic).
enum LiveTVEPGMatch {
    // MARK: Names

    private static let qualityTokens = try! NSRegularExpression(
        pattern: "\\b(fhd|uhd|hd|sd|4k|8k|hevc|h265|h264|1080p|720p|backup|raw)\\b")
    private static let prefixToken = try! NSRegularExpression(pattern: "^[a-z]{2,3}\\s*[:|]\\s*")
    private static let bracketed = try! NSRegularExpression(pattern: "\\[.*?\\]|\\(.*?\\)")
    private static let countryEnd = try! NSRegularExpression(
        pattern: "(\\.(com|co|net|tv))?\\.[a-z]{2}$", options: .caseInsensitive)

    /// "DE: Sky Cinema Action HD" and "Sky Cinema Action" → "skycinemaaction".
    static func normalize(_ name: String) -> String {
        var text = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        text = replace(prefixToken, in: text, with: "")
        text = replace(bracketed, in: text, with: " ")
        text = replace(qualityTokens, in: text, with: " ")
        return String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// A guide id as a name: "GloboSP.br" → "globosp", "DasErste.de" → "daserste".
    static func idName(_ id: String) -> String {
        normalize(replace(countryEnd, in: id.trimmingCharacters(in: .whitespaces), with: ""))
    }

    /// The keys a guide channel is known by: its names and its id.
    static func guideKeys(id: String, names: [String]) -> Set<String> {
        var keys = Set(names.map(normalize))
        keys.insert(normalize(id))
        keys.insert(idName(id))
        keys.remove("")
        return keys
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    // MARK: Placeholders

    /// "Programming", "No information", "To be announced"…: no real show
    /// (Android's `PLACEHOLDER_TITLES`). A guide channel with mostly these
    /// loses against one with real listings.
    private static let placeholders: Set<String> = [
        "programming", "program", "programme", "no information", "no info", "no program information",
        "no programme information", "to be announced", "tba", "tbd", "n/a", "na", "off air", "no data",
        "no epg", "not available", "information not available", "regular programming",
        "scheduled programming", "paid programming", "coming soon", "no program guide available",
    ]

    static func isPlaceholder(_ title: String) -> Bool {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        return placeholders.contains(text)
    }

    // MARK: Picking

    /// What a guide channel brought: its listings kept, how many of them
    /// were placeholders, and how far ahead they go.
    struct ChannelStat: Sendable {
        var count = 0
        var placeholders = 0
        var lastStop: Int64 = 0

        mutating func add(stop: Int64, placeholder: Bool) {
            count += 1
            if placeholder { placeholders += 1 }
            lastStop = max(lastStop, stop)
        }

        /// Under 80 % placeholders (as on Android).
        var isReal: Bool { placeholders * 10 < count * 8 }
    }

    /// Built from the provider's channels before the import; told about each
    /// guide channel as the import meets it, in every guide; gives the links
    /// at the end.
    struct Picker {
        /// How a guide channel was found for a stream.
        enum Kind: Int {
            case name = 1
            case id = 2
            case manual = 3
        }

        private struct Candidate {
            let key: String
            let kind: Kind
            /// The guide's place in the list (added guides first).
            let guide: Int
            /// Where in the files it came (the first wins a tie).
            let order: Int
        }

        private var byID: [String: [Int]] = [:]
        private var byName: [String: [Int]] = [:]
        private var manual: [String: [Int]] = [:]
        private var candidates: [Int: [Candidate]] = [:]
        private var order = 0

        /// `overrides`: stream → guide channel key, or "" for no guide at all.
        init(channels: [LiveTVEPGChannelRef], overrides: [Int: String] = [:]) {
            for channel in channels {
                if let choice = overrides[channel.streamID] {
                    if !choice.isEmpty { manual[choice.lowercased(), default: []].append(channel.streamID) }
                    continue
                }
                var keys = Set([LiveTVEPGMatch.normalize(channel.name)])
                if let id = channel.epgID?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
                    byID[id.lowercased(), default: []].append(channel.streamID)
                    let name = LiveTVEPGMatch.idName(id)
                    if name.count >= 3 { keys.insert(name) }
                }
                keys.remove("")
                for key in keys { byName[key, default: []].append(channel.streamID) }
            }
        }

        /// A guide channel: `key` as stored (`LiveTVEPGSourceRules.key`),
        /// `id` its id in the file (lowercased), `guide` the guide's place.
        /// True when one of the provider's channels may use it, so its
        /// programmes are worth keeping.
        mutating func saw(key: String, id: String, names: [String], guide: Int = 0) -> Bool {
            order += 1
            var found = false
            let order = self.order
            func add(_ streams: [Int]?, _ kind: Kind) {
                guard let streams else { return }
                found = true
                for stream in streams {
                    candidates[stream, default: []].append(Candidate(key: key, kind: kind, guide: guide, order: order))
                }
            }
            add(manual[key], .manual)
            add(byID[id], .id)
            for name in LiveTVEPGMatch.guideKeys(id: id, names: names) { add(byName[name], .name) }
            return found
        }

        /// The provider's guide alone: key and id are the same.
        mutating func saw(guideID: String, names: [String]) -> Bool {
            saw(key: guideID, id: guideID, names: names)
        }

        /// Stream → guide channel key, as Android's `choose()`: only guide
        /// channels with listings count; a choice by hand wins; then real
        /// listings over placeholders, an id match over a name, the one going
        /// further ahead (in half days), the guide higher in the list, the
        /// first in the file.
        func links(stats: [String: ChannelStat], now: Int64) -> [Int: String] {
            func score(_ candidate: Candidate, _ stat: ChannelStat) -> Int64 {
                if candidate.kind == .manual { return Int64.max }
                let halfDays = min(999, max(0, stat.lastStop - now) / (12 * 3600))
                return (stat.isReal ? 4_000_000 : 0) + (candidate.kind == .id ? 2_000_000 : 0)
                    + halfDays * 1_000 - Int64(candidate.guide)
            }
            var result: [Int: String] = [:]
            for (stream, list) in candidates {
                var best: (score: Int64, order: Int, key: String)?
                for candidate in list {
                    guard let stat = stats[candidate.key], stat.count > 0 else { continue }
                    let value = score(candidate, stat)
                    if let current = best, current.score > value || current.score == value && current.order <= candidate.order {
                        continue
                    }
                    best = (value, candidate.order, candidate.key)
                }
                if let best { result[stream] = best.key }
            }
            return result
        }

        /// Only which guide channels have listings known (all real, today).
        func links(listed: Set<String>) -> [Int: String] {
            var stats: [String: ChannelStat] = [:]
            for key in listed { stats[key] = ChannelStat(count: 1, placeholders: 0, lastStop: 0) }
            return links(stats: stats, now: 0)
        }
    }
}
