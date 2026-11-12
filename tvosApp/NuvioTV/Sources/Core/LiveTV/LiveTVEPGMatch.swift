import Foundation

/// One of the provider's channels, as the guide import sees it.
struct LiveTVEPGChannelRef: Sendable {
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

    // MARK: Picking

    /// Built from the provider's channels before the import; told about each
    /// guide channel as the import meets it; gives the links at the end.
    struct Picker {
        /// How a guide channel was found for a stream; higher wins.
        enum Kind: Int, Comparable {
            case name = 1
            case id = 2
            case manual = 3
            static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        private struct Candidate {
            let guideID: String
            let kind: Kind
            let order: Int
        }

        private var byID: [String: [Int]] = [:]
        private var byName: [String: [Int]] = [:]
        private var manual: [String: [Int]] = [:]
        private var candidates: [Int: [Candidate]] = [:]
        private var order = 0

        /// `overrides`: stream → guide id, or "" for no guide at all.
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

        /// A guide channel (its id lowercased), in the order of the file.
        /// True when one of the provider's channels may use it, so its
        /// programmes are worth keeping.
        mutating func saw(guideID: String, names: [String]) -> Bool {
            order += 1
            var found = false
            func add(_ streams: [Int]?, _ kind: Kind) {
                guard let streams else { return }
                found = true
                for stream in streams {
                    candidates[stream, default: []].append(Candidate(guideID: guideID, kind: kind, order: order))
                }
            }
            add(manual[guideID], .manual)
            add(byID[guideID], .id)
            for key in LiveTVEPGMatch.guideKeys(id: guideID, names: names) { add(byName[key], .name) }
            return found
        }

        /// Stream → guide id. Only guide channels with programmes count
        /// (`listed`); then manual over id over name, then the first one.
        func links(listed: Set<String>) -> [Int: String] {
            var result: [Int: String] = [:]
            for (stream, list) in candidates {
                let best = list.filter { listed.contains($0.guideID) }.max { lhs, rhs in
                    lhs.kind != rhs.kind ? lhs.kind < rhs.kind : lhs.order > rhs.order
                }
                if let best { result[stream] = best.guideID }
            }
            return result
        }
    }
}
