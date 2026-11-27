import Foundation

/// Every league and sport the Sports page knows (the list itself is in
/// SportsLeagues.swift), and which ones a region shows, as Android's
/// SportsCatalog.
enum SportsCatalog {
    /// Fork: leagues from other feeds than ESPN (OpenLigaDB's 3. Liga).
    static let forkLeagues: [League] = [
        League(id: "openligadb/bl3", sport: .football, name: "3. Liga", short: "3. LIGA", guideWords: ["3. Liga"],
               regions: [], minutes: 115, color: 0xFF1F5E3A,
               // Logos: football-logos.cc (credited in Settings → About → Licenses & Attributions).
               logo: "https://assets.football-logos.cc/logos/germany/256x256/3-liga.d8504584.png"),
    ]

    /// Every league: Android's and the fork's.
    static let all: [League] = leagues.flatMap { $0.id == "soccer/ger.2" ? [$0] + forkLeagues : [$0] }
        .map { league in
            var league = league
            if league.logo == nil { league.logo = wikiLogos[league.id] }
            return league
        }

    /// Logos for the leagues ESPN has none for, from Wikipedia / Wikimedia
    /// Commons (its 250 px thumbnails; credited in Licenses &
    /// Attributions).
    static let wikiLogos: [String: String] = [
        "baseball/caribbean-series": "https://thumb.wikimedia.org/wikipedia/en/thumb/0/04/CaribbeanSeries.PNG/250px-CaribbeanSeries.PNG",
        "baseball/college-baseball": "https://upload.wikimedia.org/wikipedia/en/c/c2/Cws_logo_new_ncaa2016.png",
        "baseball/dominican-winter-league": "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/50/Dominican_Republic_Professional_Baseball_League_Logo.png/250px-Dominican_Republic_Professional_Baseball_League_Logo.png",
        "baseball/llb": "https://thumb.wikimedia.org/wikipedia/en/thumb/8/8c/Little_League_logo.svg/250px-Little_League_logo.svg.png",
        "baseball/puerto-rican-winter-league": "https://thumb.wikimedia.org/wikipedia/en/thumb/d/d4/Liga_de_B%C3%A9isbol_Profesional_Roberto_Clemente_logo.png/250px-Liga_de_B%C3%A9isbol_Profesional_Roberto_Clemente_logo.png",
        "baseball/venezuelan-winter-league": "https://thumb.wikimedia.org/wikipedia/en/thumb/0/0c/Venezuelan_Professional_Baseball_League_logo.png/250px-Venezuelan_Professional_Baseball_League_logo.png",
        "baseball/world-baseball-classic": "https://thumb.wikimedia.org/wikipedia/commons/thumb/0/08/World_Baseball_Classic_symbol.svg/250px-World_Baseball_Classic_symbol.svg.png",
        "field-hockey/womens-college-field-hockey": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/dd/NCAA_logo.svg/250px-NCAA_logo.svg.png",
        "football/cfl": "https://thumb.wikimedia.org/wikipedia/en/thumb/1/1e/CFL_2016_logo.svg/250px-CFL_2016_logo.svg.png",
        "golf/ntw": "https://thumb.wikimedia.org/wikipedia/en/thumb/a/ad/Korn_Ferry_Tour_logo.svg/250px-Korn_Ferry_Tour_logo.svg.png",
        "hockey/mens-college-hockey": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/dd/NCAA_logo.svg/250px-NCAA_logo.svg.png",
        "hockey/olympics-mens-ice-hockey": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/eb/Ice_hockey_pictogram.svg/250px-Ice_hockey_pictogram.svg.png",
        "hockey/olympics-womens-ice-hockey": "https://thumb.wikimedia.org/wikipedia/commons/thumb/e/eb/Ice_hockey_pictogram.svg/250px-Ice_hockey_pictogram.svg.png",
        "hockey/womens-college-hockey": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/dd/NCAA_logo.svg/250px-NCAA_logo.svg.png",
        "lacrosse/mens-college-lacrosse": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/dd/NCAA_logo.svg/250px-NCAA_logo.svg.png",
        "lacrosse/womens-college-lacrosse": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/dd/NCAA_logo.svg/250px-NCAA_logo.svg.png",
        "racing/nascar-premier": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/cb/NASCAR_Cup_Series_logo.svg/250px-NASCAR_Cup_Series_logo.svg.png",
        "racing/nascar-secondary": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4f/NASCAR_OAP_SERIES_Logo.svg/250px-NASCAR_OAP_SERIES_Logo.svg.png",
        "racing/nascar-truck": "https://thumb.wikimedia.org/wikipedia/en/thumb/3/35/NASCAR_FedEx_Freight_Truck_Series_logo.png/250px-NASCAR_FedEx_Freight_Truck_Series_logo.png",
        "rugby/164205": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/66/Rugby_World_Cup_footer_logo_%28post-2023%29.svg/250px-Rugby_World_Cup_footer_logo_%28post-2023%29.svg.png",
        "rugby/17567": "https://thumb.wikimedia.org/wikipedia/commons/thumb/d/df/2026_Nations_Championship_pictogram.svg/250px-2026_Nations_Championship_pictogram.svg.png",
        "rugby/242041": "https://upload.wikimedia.org/wikipedia/en/2/25/Super_Rugby_Pacific_logo.png",
        "rugby/244293": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/69/The_Rugby_Championship_logo_%28white_background%29.png/250px-The_Rugby_Championship_logo_%28white_background%29.png",
        "rugby/270555": "https://thumb.wikimedia.org/wikipedia/en/thumb/b/bd/Currie_Cup_logo.svg/250px-Currie_Cup_logo.svg.png",
        "rugby/270557": "https://thumb.wikimedia.org/wikipedia/en/thumb/0/07/United_Rugby_Championship_logo.svg/250px-United_Rugby_Championship_logo.svg.png",
        "rugby/270559": "https://thumb.wikimedia.org/wikipedia/en/thumb/d/dd/Logo_Top14_2012.png/250px-Logo_Top14_2012.png",
        "rugby/270563": "https://thumb.wikimedia.org/wikipedia/en/thumb/d/d6/Bunnings-npc-logo.png/250px-Bunnings-npc-logo.png",
        "rugby/271937": "https://thumb.wikimedia.org/wikipedia/en/thumb/6/65/InvestecChampionsCupLogo.svg/250px-InvestecChampionsCupLogo.svg.png",
        "rugby/272073": "https://thumb.wikimedia.org/wikipedia/en/thumb/0/03/EPCRchallengecuplogo.svg/250px-EPCRchallengecuplogo.svg.png",
        "rugby/289234": "https://thumb.wikimedia.org/wikipedia/en/thumb/9/97/World_Rugby_logo.svg/250px-World_Rugby_logo.svg.png",
        "rugby/289237": "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/66/Rugby_World_Cup_footer_logo_%28post-2023%29.svg/250px-Rugby_World_Cup_footer_logo_%28post-2023%29.svg.png",
        "rugby/289262": "https://thumb.wikimedia.org/wikipedia/en/thumb/7/7a/Major_League_Rugby_logo.svg/250px-Major_League_Rugby_logo.svg.png",
        "soccer/concacaf.central.american.cup": "https://thumb.wikimedia.org/wikipedia/commons/thumb/1/10/Logo_CONCACAF_Central_American_Cup.svg/250px-Logo_CONCACAF_Central_American_Cup.svg.png",
        "soccer/eng.fa_qual": "https://thumb.wikimedia.org/wikipedia/en/thumb/d/d5/FA_Cup_logo_%282020%29.svg/250px-FA_Cup_logo_%282020%29.svg.png",
        "soccer/eng.w.fa": "https://upload.wikimedia.org/wikipedia/en/3/32/Women%27s_FA_Cup.png",
        "soccer/eng.w.league_cup": "https://thumb.wikimedia.org/wikipedia/en/thumb/2/23/FA_Women%27s_League_Cup_logo.png/250px-FA_Women%27s_League_Cup_logo.png",
        "soccer/esp.copa_de_la_reina": "https://thumb.wikimedia.org/wikipedia/en/thumb/4/46/Copa-De-La-Reina-RFEF.svg/250px-Copa-De-La-Reina-RFEF.svg.png",
        "soccer/esp.w.1": "https://thumb.wikimedia.org/wikipedia/en/thumb/b/b3/Ligafwomen.svg/250px-Ligafwomen.svg.png",
        "soccer/fifa.wworld.u17": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/aa/FIFA_logo_without_slogan.svg/250px-FIFA_logo_without_slogan.svg.png",
        "soccer/fifa.wworldq.uefa": "https://thumb.wikimedia.org/wikipedia/commons/thumb/a/aa/FIFA_logo_without_slogan.svg/250px-FIFA_logo_without_slogan.svg.png",
        "soccer/fra.w.1": "https://upload.wikimedia.org/wikipedia/en/7/74/Premi%C3%A8re_Ligue.png",
        "soccer/ksa.kings.cup": "https://thumb.wikimedia.org/wikipedia/en/thumb/d/d0/King_Cup.png/250px-King_Cup.png",
        "soccer/mex.w.1": "https://thumb.wikimedia.org/wikipedia/en/thumb/a/a2/Liga_Femenil_2026_Logo.jpeg/250px-Liga_Femenil_2026_Logo.jpeg",
        "soccer/par.1.supercopa": "https://thumb.wikimedia.org/wikipedia/commons/thumb/7/71/Supercopa_paraguay.jpg/250px-Supercopa_paraguay.jpg",
        "soccer/por.taca.portugal": "https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4d/Ta%C3%A7a_de_Portugal_Trophy.svg/250px-Ta%C3%A7a_de_Portugal_Trophy.svg.png",
        "soccer/uefa.euro_u21_qual": "https://thumb.wikimedia.org/wikipedia/en/thumb/9/92/UEFA_European_Under-21_Championship_logo.svg/250px-UEFA_European_Under-21_Championship_logo.svg.png",
        "soccer/uefa.w.europa": "https://thumb.wikimedia.org/wikipedia/en/thumb/4/46/UEFA_Women%27s_Europa_Cup.svg/250px-UEFA_Women%27s_Europa_Cup.svg.png",
        "soccer/uefa.w.nations": "https://thumb.wikimedia.org/wikipedia/en/thumb/8/8a/UEFA_Women%27s_Nations_League_logo.svg/250px-UEFA_Women%27s_Nations_League_logo.svg.png",
        "soccer/usa.w.usl.1": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3d/USL_Super_League_abbr_light_logo.svg/250px-USL_Super_League_abbr_light_logo.svg.png",
        "tennis/atp": "https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3f/ATP_Tour_logo.svg/250px-ATP_Tour_logo.svg.png",
        "tennis/wta": "https://thumb.wikimedia.org/wikipedia/en/thumb/0/0e/WTA_Tour_logo.png/250px-WTA_Tour_logo.png",
    ]

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

    /// Your order of the sports (Settings → Sports): the ones you moved
    /// first, as you left them, then the rest in the region's order.
    static func sportsOrder(custom: [String], region: String) -> [Sport] {
        let mine = custom.compactMap(Sport.init(rawValue:))
        var seen: Set<Sport> = []
        return (mine + sportsOrder(region: region)).filter { seen.insert($0).inserted }
    }

    /// The order with `sport` moved `offset` places among `shown` (the
    /// sports listed), saved as the whole list.
    static func moving(_ sport: Sport, by offset: Int, among shown: [Sport], order: [Sport]) -> [String] {
        guard let from = shown.firstIndex(of: sport) else { return order.map(\.rawValue) }
        let to = min(max(from + offset, 0), shown.count - 1)
        var list = shown
        list.remove(at: from)
        list.insert(sport, at: to)
        return (list + order.filter { !list.contains($0) }).map(\.rawValue)
    }

    /// Competitions ESPN keeps no table for (cups, friendlies, some
    /// college and winter leagues), checked November 2026: left out of
    /// Tables and the team picker from the start (a table found later
    /// still counts).
    static let withoutTable: Set<String> = [
        "soccer/eng.fa", "soccer/eng.league_cup", "soccer/fifa.friendly", "rugby/289234", "rugby/244293", "rugby/270563",
        "rugby/270555", "cricket/8048", "soccer/eng.w.fa", "soccer/sco.tennents", "soccer/esp.copa_del_rey",
        "soccer/ger.dfb_pokal", "soccer/ita.coppa_italia", "soccer/fra.coupe_de_france", "soccer/ned.cup",
        "soccer/por.taca.portugal", "soccer/uefa.super_cup", "soccer/eng.charity", "soccer/usa.open",
        "soccer/concacaf.champions", "soccer/fifa.friendly.w", "soccer/bra.camp.gaucho", "soccer/fifa.worldq.ofc",
        "soccer/club.friendly", "soccer/eng.fa_qual", "soccer/esp.copa_de_la_reina", "soccer/uefa.w.europa",
        "soccer/bra.copa_do_brazil", "soccer/arg.copa", "soccer/par.1.supercopa", "soccer/ksa.kings.cup",
        "soccer/usa.ncaa.m.1", "soccer/usa.ncaa.w.1", "football/cfl", "lacrosse/mens-college-lacrosse",
        "lacrosse/womens-college-lacrosse", "baseball/dominican-winter-league", "baseball/puerto-rican-winter-league",
        "baseball/venezuelan-winter-league", "baseball/mexican-winter-league", "field-hockey/womens-college-field-hockey",
        "baseball/llb",
    ]

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
