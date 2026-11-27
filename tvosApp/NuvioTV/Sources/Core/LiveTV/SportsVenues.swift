import Foundation

/// Where to look for a game's stadium picture: the venue the feed names
/// (and its city), else the home team's home ground.
struct SportsVenueQuery: Hashable, Sendable {
    var venue: String?
    var city: String?
    var team: String?

    /// The cache key: the venue when known, else the team.
    var key: String? {
        if let venue = venue?.nilIfBlank { return "v:" + SportsVenues.normalized(venue) + "|" + SportsVenues.normalized(city ?? "") }
        if let team = team?.nilIfBlank { return "t:" + SportsVenues.normalized(team) }
        return nil
    }
}

/// A Wikipedia article as the lookup needs it.
struct SportsWikiPage: Sendable {
    let title: String
    let item: String?
    let intro: String
    let image: String?
    let disambiguation: Bool
}

/// Fork (Live TV step 17d): a stadium's picture for the Sports pages'
/// backdrop, from Wikipedia and Wikidata (free, no key), the same way for
/// every sport and country. Robust before anything: a picture is only taken
/// when everything agrees, else none (the teams' colours stay):
/// - the venue's English Wikipedia article (its redirects followed, so a
///   sponsor's name finds the ground), not a disambiguation page;
/// - its intro names the city the feed gives;
/// - Wikidata knows it as a venue (a capacity, or a venue's kind) and not as
///   demolished;
/// - no venue (OpenLigaDB names none): the home team's article, its current
///   home ground on Wikidata (no end date), that ground's picture.
enum SportsVenues {
    private typealias JSON = [String: Any]

    // MARK: Requests

    private static let wikipedia = "https://en.wikipedia.org/w/api.php"
    private static let wikidata = "https://www.wikidata.org/w/api.php"

    /// An article (redirects followed): its Wikidata item, intro and picture.
    static func pageURL(_ title: String) -> URL? {
        var parts = URLComponents(string: wikipedia)
        parts?.queryItems = [
            .init(name: "action", value: "query"), .init(name: "titles", value: title), .init(name: "redirects", value: "1"),
            .init(name: "prop", value: "pageprops|pageimages|extracts"), .init(name: "exintro", value: "1"),
            .init(name: "explaintext", value: "1"), .init(name: "exchars", value: "600"),
            .init(name: "piprop", value: "thumbnail"), .init(name: "pithumbsize", value: "1920"),
            .init(name: "pilicense", value: "any"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
        ]
        return parts?.url
    }

    /// A Wikidata item's statements.
    static func itemURL(_ id: String) -> URL? {
        var parts = URLComponents(string: wikidata)
        parts?.queryItems = [
            .init(name: "action", value: "wbgetentities"), .init(name: "ids", value: id),
            .init(name: "props", value: "claims"), .init(name: "format", value: "json"),
        ]
        return parts?.url
    }

    /// A Commons file at backdrop size.
    static func fileURL(_ file: String) -> String? {
        let name = file.replacingOccurrences(of: " ", with: "_")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "https://commons.wikimedia.org/wiki/Special:FilePath/\(encoded)?width=1920"
    }

    // MARK: Reading

    static func parsePage(_ data: Data) -> SportsWikiPage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              let page = ((root["query"] as? JSON)?["pages"] as? [JSON])?.first,
              page["missing"] == nil, page["invalid"] == nil,
              let title = page["title"] as? String else { return nil }
        let props = page["pageprops"] as? JSON ?? [:]
        return SportsWikiPage(
            title: title,
            item: props["wikibase_item"] as? String,
            intro: page["extract"] as? String ?? "",
            image: (page["thumbnail"] as? JSON)?["source"] as? String,
            disambiguation: props["disambiguation"] != nil)
    }

    private static func claims(_ data: Data, id: String) -> JSON? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { return nil }
        return ((root["entities"] as? JSON)?[id] as? JSON)?["claims"] as? JSON
    }

    private static func values(_ claims: JSON, _ property: String) -> [JSON] {
        (claims[property] as? [JSON] ?? []).filter { (($0["mainsnak"] as? JSON)?["datavalue"]) != nil }
    }

    private static func itemIDs(_ claims: JSON, _ property: String) -> [String] {
        values(claims, property).compactMap {
            ((($0["mainsnak"] as? JSON)?["datavalue"] as? JSON)?["value"] as? JSON)?["id"] as? String
        }
    }

    /// Kinds of venue (Wikidata items) for grounds without a capacity:
    /// stadiums, arenas, halls, race tracks.
    static let venueKinds: Set<String> = [
        "Q483110", "Q1154710", "Q1076486", "Q641226", "Q1763828", "Q2338524", "Q1049757", "Q3498109", "Q8719053",
    ]

    /// The article is the venue: in the city given, a venue, still there.
    static func isVenue(_ page: SportsWikiPage, item data: Data, city: String?) -> Bool {
        guard !page.disambiguation, let id = page.item, let claims = claims(data, id: id) else { return false }
        if let city = city?.nilIfBlank, !normalized(page.intro).contains(normalized(city)) { return false }
        // Demolished or closed.
        if !values(claims, "P576").isEmpty { return false }
        return !values(claims, "P1083").isEmpty || !Set(itemIDs(claims, "P31")).isDisjoint(with: venueKinds)
    }

    /// A team's current home ground (no end date), the last one listed.
    static func homeGround(team data: Data, item id: String) -> String? {
        guard let claims = claims(data, id: id) else { return nil }
        let current = values(claims, "P115").filter { (($0["qualifiers"] as? JSON)?["P582"]) == nil }
        return current.compactMap {
            ((($0["mainsnak"] as? JSON)?["datavalue"] as? JSON)?["value"] as? JSON)?["id"] as? String
        }.last
    }

    /// A ground's picture (its Commons file), unless it's demolished.
    static func groundImage(_ data: Data, item id: String) -> String? {
        guard let claims = claims(data, id: id), values(claims, "P576").isEmpty,
              let file = (values(claims, "P18").first?["mainsnak"] as? JSON).flatMap({ ($0["datavalue"] as? JSON)?["value"] as? String })
        else { return nil }
        return fileURL(file)
    }

    /// Lower case, no accents, "ß" as "ss", only letters and digits.
    static func normalized(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
