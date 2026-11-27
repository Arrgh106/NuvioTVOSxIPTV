import Foundation

/// Every league and sport the Sports page knows (the list itself is in
/// SportsLeagues.swift), and which ones a region shows, as Android's
/// SportsCatalog.
enum SportsCatalog {
    /// Fork: leagues from other feeds than ESPN (OpenLigaDB's 3. Liga).
    static let forkLeagues: [League] = [
        League(id: "openligadb/bl3", sport: .football, name: "3. Liga", short: "3. LIGA", guideWords: ["3. Liga"],
               regions: [], minutes: 115, color: 0xFF1F5E3A),
    ]

    /// Every league: Android's and the fork's.
    static let all: [League] = leagues.flatMap { $0.id == "soccer/ger.2" ? [$0] + forkLeagues : [$0] }

    private static let byId: [String: League] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    static func league(_ id: String) -> League? { byId[id] }

    /// The regions Android sorts the world into, with their names.
    static let regions: [(code: String, name: String)] = [
        ("US", "United States"),
        ("UK", "United Kingdom"),
        ("IE", "Ireland"),
        ("CA", "Canada"),
        ("AU", "Australia & New Zealand"),
    ] + countryRegions + [("OTHER", "Somewhere else")]

    /// Fork: countries of their own (Android's regions are only the
    /// English-speaking ones): what's on everywhere else, and that
    /// country's own football.
    static let countryRegions: [(code: String, name: String)] = [
        "DE", "AT", "CH", "FR", "ES", "IT", "NL", "BE", "PT", "DK", "SE", "NO", "FI", "PL", "CZ", "GR", "TR",
        "BR", "AR", "MX", "JP", "KR", "SA", "ZA", "IN",
    ].map { (code: $0, name: Locale.current.localizedString(forRegionCode: $0) ?? $0) }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

    static func isCountry(_ region: String) -> Bool { countryRegions.contains { $0.code == region } }

    static func regionName(_ code: String) -> String { regions.first { $0.code == code }?.name ?? code }

    /// A country as a Sports region.
    static func region(ofCountry country: String) -> String {
        if isCountry(country.uppercased()) { return country.uppercased() }
        switch country.uppercased() {
        case "US", "PR": return "US"
        case "GB", "UK": return "UK"
        case "IE": return "IE"
        case "CA": return "CA"
        case "AU", "NZ": return "AU"
        default: return "OTHER"
        }
    }

    /// Fork: the leagues of your own country, shown by default too (Android
    /// knows only the English-speaking regions; ESPN names a country's
    /// football leagues "ger.1", "ger.2", "ger.dfb_pokal"…).
    static let espnCountry: [String: String] = [
        "DE": "ger", "AT": "aut", "CH": "sui", "FR": "fra", "BE": "bel", "NL": "ned", "ES": "esp", "PT": "por",
        "IT": "ita", "DK": "den", "SE": "swe", "NO": "nor", "FI": "fin", "PL": "pol", "CZ": "cze", "GR": "gre",
        "TR": "tur", "BR": "bra", "AR": "arg", "MX": "mex", "JP": "jpn", "KR": "kor", "CN": "chn",
        "SA": "ksa", "ZA": "rsa", "IN": "ind", "RU": "rus", "UA": "ukr", "RO": "rou", "HR": "cro", "RS": "srb",
        "CL": "chi", "CO": "col", "US": "usa", "GB": "eng", "IE": "irl", "AU": "aus",
    ]

    /// Shown in All Events by default: the region's leagues and your own
    /// country's.
    static func inRegion(_ league: League, region: String, country: String) -> Bool {
        let country = isCountry(region) ? region : country
        if league.regions.contains(isCountry(region) ? "OTHER" : region) { return true }
        if league.onOpenLiga { return country.uppercased() == "DE" }
        guard let code = espnCountry[country.uppercased()], league.sport == .football,
              let path = league.espnPath, path.hasPrefix("soccer/") else { return false }
        let name = path.dropFirst("soccer/".count)
        return name.hasPrefix(code + ".") && !name.contains(".w.") && !league.women
    }

    /// In All Events: the region's leagues with your own choices on top:
    /// `changed` holds a plain id for one taken off that's normally shown,
    /// "+id" for one added from elsewhere.
    static func shown(_ league: League, region: String, country: String, changed: Set<String>) -> Bool {
        let normal = inRegion(league, region: region, country: country)
        if normal { return !changed.contains(league.id) }
        return changed.contains("+" + league.id)
    }

    /// Turns a league on or off (see `shown`).
    static func toggled(_ league: League, region: String, country: String, changed: Set<String>) -> Set<String> {
        var set = changed
        let normal = inRegion(league, region: region, country: country)
        if shown(league, region: region, country: country, changed: changed) {
            set.remove("+" + league.id)
            if normal { set.insert(league.id) }
        } else {
            set.remove(league.id)
            if !normal { set.insert("+" + league.id) }
        }
        return set
    }

    /// The sports in the order the region cares about them.
    static func sportsOrder(region: String) -> [Sport] {
        let first: [Sport]
        switch region {
        case "UK", "IE": first = [.football, .rugby, .cricket, .darts, .snooker, .racing, .fighting, .wrestling, .golf, .tennis]
        case "AU": first = [.aussieRules, .rugby, .cricket, .football, .basketball]
        case "CA": first = [.hockey, .americanFootball, .basketball, .baseball]
        case "US": first = [.americanFootball, .basketball, .baseball, .hockey, .football]
        default: first = [.football, .racing, .tennis, .basketball, .hockey, .americanFootball]
        }
        return first + Sport.allCases.filter { !first.contains($0) }
    }
}
