import Foundation

// Fork: channel and group names you change (step 10a), as Android's
// "Rename channel" and "Channel Name Cleanup". Pure, so the logic tests run
// it on Linux.

/// The names a profile changed, and the words cleaned off the others.
struct LiveTVNameEdits: Sendable, Equatable {
    /// Stream id → name, from "Rename Channel".
    var channelNames: [Int: String] = [:]
    /// Group id → name, from "Rename Group".
    var groupNames: [String: String] = [:]
    /// "USA, HD, 24/7": taken off the start or end of channel names.
    var removals = ""
    /// The words come off group names too.
    var cleanGroups = false

    static let none = LiveTVNameEdits()

    var isEmpty: Bool {
        channelNames.isEmpty && groupNames.isEmpty && LiveTVNameCleaner.terms(removals).isEmpty
    }

    /// Names for a list: a rename first, then the cleaned name. Nil where
    /// the name stays as the provider sent it.
    func channelDisplayNames(_ channels: [(id: Int, name: String)]) -> [Int: String] {
        let cleaner = LiveTVNameCleaner.Cleaner(terms: LiveTVNameCleaner.terms(removals), names: channels.map(\.name))
        var result: [Int: String] = [:]
        for channel in channels {
            let shown = channelNames[channel.id] ?? cleaner.clean(channel.name)
            if shown != channel.name { result[channel.id] = shown }
        }
        return result
    }

    /// What a rename to `name` keeps: nil where the name would come out
    /// the same without it (empty, or the provider's name while Name
    /// Cleanup can't change it), so nothing is left to reset.
    func channelRename(_ name: String, providerName: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if clean == providerName, !LiveTVNameCleaner.mayChange(providerName, terms: LiveTVNameCleaner.terms(removals)) {
            return nil
        }
        return clean
    }

    func groupRename(_ name: String, providerName: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let terms = LiveTVNameCleaner.terms(removals)
        let automatic = cleanGroups && !terms.isEmpty
            ? LiveTVNameCleaner.Cleaner(terms: terms).clean(providerName) : providerName
        return clean == automatic ? nil : clean
    }

    func groupDisplayName(id: String, name: String, cleaner: LiveTVNameCleaner.Cleaner?) -> String {
        if let renamed = groupNames[id] { return renamed }
        guard cleanGroups, let cleaner else { return name }
        return cleaner.clean(name)
    }
}

/// Android's `ChannelNameEditor`: words off the start or end of a name
/// ("USA: ESPN HD" → "ESPN"), never in the middle, never leaving it empty.
enum LiveTVNameCleaner {
    /// "Add Common Prefixes & Suffixes".
    static let common = "USA, US, UK, CA, AU, 24/7, FHD, HD, SD, UHD, 4K, HEVC, RAW, VIP, ᴴᴰ, ᵁᴴᴰ, ᶠᴴᴰ"

    /// Comma separated, trimmed, without doubles, longest first (so "FHD"
    /// goes before "HD").
    static func terms(_ raw: String) -> [String] {
        var seen = Set<String>()
        let list = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return list.enumerated().sorted { lhs, rhs in
            lhs.element.count != rhs.element.count ? lhs.element.count > rhs.element.count : lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func isLetterOrDigit(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// Whether cleanup could change this name: by its patterns, or as a
    /// space prefix ("USA CNN"), which depends on the whole list.
    static func mayChange(_ name: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        if Cleaner(terms: terms).clean(name) != name { return true }
        let lower = String(name.drop(while: { !isLetterOrDigit($0) })).lowercased()
        return terms.contains { term in term.allSatisfy(\.isLetter) && lower.hasPrefix(term.lowercased() + " ") }
    }

    /// Words a list uses as a prefix with only a space after it ("USA ESPN",
    /// "USA CNN"): five or more of its channels start that way. Otherwise a
    /// lone "USA Network" keeps its name.
    static func spacePrefixes(names: [String], terms: [String]) -> Set<String> {
        let words = terms.filter { $0.allSatisfy(\.isLetter) }.map { $0.lowercased() }
        guard !words.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for name in names {
            let lower = String(name.drop(while: { !isLetterOrDigit($0) })).lowercased()
            for word in words where lower.hasPrefix(word + " ") && lower.count > word.count + 1 {
                counts[word, default: 0] += 1
            }
        }
        return Set(counts.filter { $0.value >= 5 }.keys)
    }

    /// The patterns for a list of words, built once per list.
    final class Cleaner: @unchecked Sendable {
        private struct Compiled {
            let prefix: NSRegularExpression
            let suffix: NSRegularExpression
            let suffixCheck: NSRegularExpression
        }

        private let lowerTerms: [String]
        private let compiled: [Compiled]
        private let spacePrefixes: Set<String>

        init(terms: [String], names: [String] = []) {
            lowerTerms = terms.map { $0.lowercased() }
            spacePrefixes = LiveTVNameCleaner.spacePrefixes(names: names, terms: terms)
            compiled = terms.compactMap { term in
                let q = NSRegularExpression.escapedPattern(for: term)
                // A plain ASCII word or number stands alone ("HD" isn't the end
                // of "XHD", "4K" not the start of "4KIDS"); tags in special
                // letters (ᴴᴰ) can be stuck on.
                let ascii = term.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
                let before = ascii ? #"(?<![\p{L}\p{N}])"# : ""
                let after = ascii ? #"(?![\p{L}\p{N}])"# : ""
                // Prefix: "USA: ESPN", "[USA] ESPN", "|US| ESPN", "US ➤ ESPN". A
                // word needs a symbol after it, so "USA" never eats "USA Network".
                let prefix = term.allSatisfy(\.isLetter)
                    ? #"^[^\p{L}\p{N}]*"# + q + #"\s*[^\p{L}\p{N}\s(\[{<][^\p{L}\p{N}(\[{<]*"#
                    : #"^[^\p{L}\p{N}]*"# + q + after + #"[^\p{L}\p{N}(\[{<]*"#
                // Suffix: "ESPN HD", "ESPN (US)", "ESPN | FHD", "ESPN 24/7".
                let suffix = #"[^\p{L}\p{N}+&)\]}]*"# + before + q + #"[^\p{L}\p{N}]*$"#
                let check = before + q + #"[^\p{L}\p{N}]*$"#
                guard let p = try? NSRegularExpression(pattern: prefix, options: .caseInsensitive),
                      let s = try? NSRegularExpression(pattern: suffix, options: .caseInsensitive),
                      let c = try? NSRegularExpression(pattern: check, options: .caseInsensitive) else { return nil }
                return Compiled(prefix: p, suffix: s, suffixCheck: c)
            }
        }

        var isEmpty: Bool { compiled.isEmpty }

        func clean(_ name: String) -> String {
            guard !compiled.isEmpty else { return name }
            var start = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // A list-wide "USA " prefix: off once ("USA USA Network" keeps "USA Network").
            if !spacePrefixes.isEmpty {
                let body = String(start.drop(while: { !LiveTVNameCleaner.isLetterOrDigit($0) }))
                let lower = body.lowercased()
                if let word = spacePrefixes.first(where: { lower.hasPrefix($0 + " ") }) {
                    let rest = String(body.dropFirst(word.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rest.isEmpty { start = rest }
                }
            }
            // Most names have none of the words at either end: no patterns.
            guard atEdge(start.lowercased()) else { return start }
            var out = start
            var changed = true
            var round = 0
            while changed && round < 6 {
                round += 1
                if round > 1 && !atEdge(out.lowercased()) { break }
                changed = false
                for c in compiled {
                    let p = Self.remove(c.prefix, from: out)
                    if p != out && !p.isEmpty { out = p; changed = true }
                    if Self.matches(c.suffixCheck, out) {
                        let s = Self.remove(c.suffix, from: out)
                        if s != out && !s.isEmpty { out = s; changed = true }
                    }
                }
            }
            return out
        }

        /// A word at the very start or end, past any symbols around the name.
        private func atEdge(_ lower: String) -> Bool {
            let start = String(lower.drop(while: { !LiveTVNameCleaner.isLetterOrDigit($0) }))
            var end = lower
            while let last = end.last, !LiveTVNameCleaner.isLetterOrDigit(last) { end.removeLast() }
            let rawStart = String(lower.drop(while: \.isWhitespace))
            var rawEnd = lower
            while let last = rawEnd.last, last.isWhitespace { rawEnd.removeLast() }
            return lowerTerms.contains { t in
                start.hasPrefix(t) || end.hasSuffix(t) || rawStart.hasPrefix(t) || rawEnd.hasSuffix(t)
            }
        }

        private static func remove(_ regex: NSRegularExpression, from text: String) -> String {
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}
