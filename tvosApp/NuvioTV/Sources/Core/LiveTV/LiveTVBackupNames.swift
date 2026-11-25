import Foundation

// Fork: backup copies of a channel (step 15b), as Android's "Backup channel":
// another channel with the same name once a country or provider prefix,
// bracketed notes and quality or backup words are left out ("US: ESPN HD"
// and "ESPN (Backup)" are both "espn"). Other sources come first; another
// local station ("FOX (WNYW)" vs "FOX (KTTV)") is never one. Pure, so the
// logic tests run it on Linux.
enum LiveTVBackupNames {
    /// A channel as the backup lookup sees it.
    struct Copy: Equatable, Sendable {
        let id: Int
        let name: String
        /// The source it comes from (`LiveTVSourceIDs.slot(ofChannel:)`).
        let slot: Int
    }

    private static func pattern(_ text: String) -> NSRegularExpression {
        // Fixed patterns: a typo is a programming error.
        try! NSRegularExpression(pattern: text)
    }

    // Made once: this runs for every channel in the list.
    private static let prefix = pattern(#"^\s*[a-z]{2,4}\s*[:|]\s*"#)
    private static let prefixDash = pattern(#"^\s*[a-z]{2,3}\s+-\s+"#)
    private static let brackets = pattern(#"[\[(][^\])]*[\])]"#)
    /// Sound layout in the name ("5.1", "2.0"): left in, it reads as part of it.
    private static let audio = pattern(#"(?<![\d.])[257]\.[01](?![\d.])"#)
    private static let noise = pattern(
        #"\b(hd|fhd|uhd|sd|4k|8k|hevc|h\.?26[45]|1080[pi]?|720p?|2160p?|\d{2}\s?fps|backup|bkp|bk|alt|alternate|raw|ᴴᴰ)\b"#)
    private static let note = pattern(#"[\[(]([^\])]*)[\])]"#)

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// The name copies of a channel share.
    static func key(_ name: String) -> String {
        var text = name.lowercased()
        text = replacing(prefix, in: text, with: "")
        text = replacing(prefixDash, in: text, with: "")
        text = replacing(brackets, in: text, with: " ")
        text = replacing(audio, in: text, with: " ")
        text = replacing(noise, in: text, with: " ")
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }))
        return kept.split(separator: " ").joined(separator: " ")
    }

    /// The call sign or region in brackets ("FOX (WNYW)" → "wnyw"), not a
    /// quality note like "(HD)".
    static func stationNote(_ name: String) -> String? {
        let text = name.lowercased()
        for match in note.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let inner = text[range].trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, !key(inner).isEmpty { return inner }
        }
        return nil
    }

    /// Channels by `key` (names too short to tell apart left out).
    static func index(_ copies: [Copy]) -> [String: [Copy]] {
        var result: [String: [Copy]] = [:]
        for copy in copies {
            let name = key(copy.name)
            if name.count >= 2 { result[name, default: []].append(copy) }
        }
        return result
    }

    /// The copy to switch to from `failed`, skipping `tried`: other
    /// sources first, never another local station. nil when none is left.
    static func backup(for failed: Copy, in index: [String: [Copy]], tried: Set<Int>) -> Copy? {
        let name = key(failed.name)
        guard name.count >= 2 else { return nil }
        let station = stationNote(failed.name)
        let left = (index[name] ?? []).filter { copy in
            guard copy.id != failed.id, !tried.contains(copy.id) else { return false }
            let other = stationNote(copy.name)
            return station == nil || other == nil || station == other
        }
        return left.first { $0.slot != failed.slot } ?? left.first
    }
}
