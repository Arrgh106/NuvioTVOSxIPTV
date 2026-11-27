import SwiftUI

// Fork (Live TV step 17d): the parts of a game's page and the Sports
// page's game panel: the timeline (goals, cards, substitutions, scores per
// sport), the odds, form dots and the line-ups as a picture.

// MARK: Timeline

/// What happened, team by team: the left team's moments on the left, the
/// right team's on the right, the minute between them; a section per half,
/// period, quarter or inning, with the score at its end. Each line takes
/// focus, so the remote scrolls through a long game.
struct SportsTimeline: View {
    let moments: [SportsMoment]
    let event: SportsEvent
    let league: League

    var body: some View {
        let leftHome = league.sport.homeFirst
        let periods = Array(Set(moments.map(\.period))).sorted()
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 6) {
                HStack {
                    if let left = leftHome ? event.home : event.away { SportsTeamLogo(team: left.team, size: 40) }
                    Spacer()
                    if let right = leftHome ? event.away : event.home { SportsTeamLogo(team: right.team, size: 40) }
                }
                .padding(.horizontal, 24)
                ForEach(periods, id: \.self) { period in
                    let list = moments.filter { $0.period == period }
                    if periods.count > 1 || period > 0 {
                        SportsPeriodHeader(title: SportsTimeline.periodTitle(league.sport, period),
                                           score: list.last(where: { $0.score != nil })?.score.map { leftHome ? $0 : Self.flip($0) })
                    }
                    ForEach(Array(list.enumerated()), id: \.offset) { _, moment in
                        SportsMomentRow(moment: moment, leftHome: leftHome, color: color(moment.home))
                    }
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
        }
        .modifier(LiveTVGlass(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func color(_ home: Bool?) -> Color {
        let side = home == true ? event.home : (home == false ? event.away : nil)
        return side?.team.color.map { Color(sportsARGB: $0) } ?? .white.opacity(0.4)
    }

    /// "1–2" read the other way round ("2–1").
    static func flip(_ score: String) -> String {
        let parts = score.components(separatedBy: "–")
        return parts.count == 2 ? parts[1] + "–" + parts[0] : score
    }

    static func periodTitle(_ sport: Sport, _ period: Int) -> String {
        switch sport {
        case .football, .rugby:
            switch period {
            case 1: return L10n.string("livetv_sports_first_half", fallback: "1st Half")
            case 2: return L10n.string("livetv_sports_second_half", fallback: "2nd Half")
            case 3, 4: return L10n.string("livetv_sports_extra_time", fallback: "Extra Time")
            case 5: return L10n.string("livetv_sports_shootout", fallback: "Penalties")
            default: return L10n.string("livetv_sports_match", fallback: "Match")
            }
        case .hockey:
            return period > 3 ? L10n.string("livetv_sports_overtime", fallback: "Overtime")
                : L10n.format("livetv_sports_period_format", fallback: "Period %d", period)
        case .baseball:
            return L10n.format("livetv_sports_inning_format", fallback: "Inning %d", period)
        default:
            return period > 4 ? L10n.string("livetv_sports_overtime", fallback: "Overtime")
                : L10n.format("livetv_sports_quarter_format", fallback: "Quarter %d", period)
        }
    }
}

private struct SportsPeriodHeader: View {
    let title: String
    let score: String?

    var body: some View {
        HStack(spacing: 14) {
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
            Text(title.uppercased()).font(.system(size: 16, weight: .heavy)).foregroundColor(.white.opacity(0.6)).fixedSize()
            if let score {
                Text(score).font(.system(size: 16, weight: .heavy)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .fixedSize()
            }
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// One moment: on its team's side, its sign (ball, card, arrows, the
/// score's kind), who, the assist or who went off, the score after it.
private struct SportsMomentRow: View {
    let moment: SportsMoment
    let leftHome: Bool
    let color: Color
    @FocusState private var focused: Bool

    var body: some View {
        let onLeft = moment.home.map { $0 == leftHome } ?? true
        Button(action: {}) {
            HStack(spacing: 0) {
                Group { if onLeft { content(alignRight: true) } else { Spacer(minLength: 0) } }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(moment.clock)
                    .font(.system(size: 18, weight: .heavy))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 86, height: 34)
                    .background(Capsule().fill(color.opacity(0.85)))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                Group { if !onLeft { content(alignRight: false) } else { Spacer(minLength: 0) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(focused ? 0.16 : 0)))
        }
        .buttonStyle(LiveTVInvisibleButtonStyle())
        .focused($focused)
    }

    @ViewBuilder
    private func content(alignRight: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if alignRight {
                texts(alignRight: true)
                sign
            } else {
                sign
                texts(alignRight: false)
            }
        }
    }

    private var sign: some View {
        SportsMomentSign(kind: moment.kind, tag: moment.kind == .score ? moment.detail : nil)
    }

    @ViewBuilder
    private func texts(alignRight: Bool) -> some View {
        VStack(alignment: alignRight ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 8) {
                if alignRight, let score = moment.score { scoreBadge(score) }
                Text(title)
                    .font(.system(size: moment.kind == .score || moment.kind == .penalty ? 18 : 21, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(alignRight ? .trailing : .leading)
                if !alignRight, let score = moment.score { scoreBadge(score) }
            }
            if let line = secondLine {
                Text(line.text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(line.color)
                    .lineLimit(1)
            }
        }
    }

    private func scoreBadge(_ score: String) -> some View {
        Text(leftHome ? score : SportsTimeline.flip(score))
            .font(.system(size: 17, weight: .heavy))
            .monospacedDigit()
            .padding(.horizontal, 9).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.18)))
    }

    private var title: String {
        let name = moment.player ?? ""
        switch moment.kind {
        case .ownGoal: return name + " (" + L10n.string("livetv_sports_own_goal_short", fallback: "OG") + ")"
        case .penaltyGoal: return name + " (" + L10n.string("livetv_sports_penalty_short", fallback: "Pen") + ")"
        case .penaltyMiss: return name + " · " + L10n.string("livetv_sports_penalty_missed", fallback: "Penalty missed")
        default: return name
        }
    }

    private var secondLine: (text: String, color: Color)? {
        guard let detail = moment.detail, moment.kind != .score else { return nil }
        switch moment.kind {
        case .sub: return ("↓ " + detail, Color(red: 1, green: 0.45, blue: 0.45))
        case .goal, .penaltyGoal: return (L10n.format("livetv_sports_assist_format", fallback: "Assist: %@", detail), .white.opacity(0.65))
        default: return (detail, .white.opacity(0.65))
        }
    }
}

/// A moment's sign: a ball, a card, the substitution's arrows, the kind of
/// score ("TD", "Try").
struct SportsMomentSign: View {
    let kind: SportsMoment.Kind
    var tag: String? = nil
    var size: CGFloat = 30

    var body: some View {
        Group {
            switch kind {
            case .goal, .penaltyGoal:
                Image(systemName: "soccerball").font(.system(size: size * 0.8, weight: .semibold)).foregroundColor(.white)
            case .ownGoal:
                Image(systemName: "soccerball").font(.system(size: size * 0.8, weight: .semibold)).foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
            case .penaltyMiss:
                Image(systemName: "xmark.circle.fill").font(.system(size: size * 0.8)).foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
            case .yellow:
                card(.yellow)
            case .red:
                card(.red)
            case .yellowRed:
                ZStack { card(.yellow).offset(x: -4, y: -2); card(.red).offset(x: 4, y: 2) }
            case .sub:
                VStack(spacing: 0) {
                    Image(systemName: "arrow.up").foregroundColor(.green)
                    Image(systemName: "arrow.down").foregroundColor(Color(red: 1, green: 0.45, blue: 0.45))
                }
                .font(.system(size: size * 0.42, weight: .heavy))
            case .penalty:
                Image(systemName: "timer").font(.system(size: size * 0.75, weight: .semibold)).foregroundColor(.orange)
            case .score:
                Text((tag ?? "•").uppercased())
                    .font(.system(size: size * 0.42, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
                    .frame(minWidth: size, minHeight: size * 0.8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(LiveTVTheme.accent.opacity(0.85)))
                    .foregroundColor(LiveTVTheme.isWhiteAccent ? .black : .white)
            }
        }
        .frame(minWidth: size, minHeight: size)
    }

    private func card(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(color).frame(width: size * 0.5, height: size * 0.7)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.3), lineWidth: 1))
    }
}

/// The key moments in a few lines (the Sports page's game panel): goals
/// and red cards, or the scores; a team's logo by each.
struct SportsMomentsSummary: View {
    let moments: [SportsMoment]
    let event: SportsEvent
    var limit = 6

    var body: some View {
        let key = moments.filter { $0.isGoal || $0.kind == .red || $0.kind == .yellowRed || $0.kind == .penaltyMiss || $0.kind == .score }
        let shown = Array(key.suffix(limit))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, moment in
                HStack(spacing: 10) {
                    if let side = moment.home == true ? event.home : (moment.home == false ? event.away : nil) {
                        SportsTeamLogo(team: side.team, size: 28)
                    }
                    SportsMomentSign(kind: moment.kind, tag: moment.kind == .score ? moment.detail : nil, size: 24)
                    Text(moment.clock).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundColor(.white.opacity(0.7))
                    Text(moment.player ?? "").font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let score = moment.score {
                        Text(score).font(.system(size: 18, weight: .heavy)).monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: Odds and form

/// The odds side by side: the first team, the draw, the second team (each
/// team's logo), over/under, and whose odds they are.
struct SportsOddsView: View {
    let odds: SportsOdds
    let event: SportsEvent
    let league: League
    var compact = false

    var body: some View {
        let us = SportsSettings.shared.showsBroadcasts
        let values = self.values
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        if let side = item.0 {
                            SportsTeamLogo(team: side.team, size: compact ? 26 : 34)
                        } else {
                            Text("X").font(.system(size: compact ? 16 : 19, weight: .heavy)).foregroundColor(.white.opacity(0.6))
                                .frame(width: compact ? 26 : 34)
                        }
                        Text(SportsOdds.text(item.1, us: us))
                            .font(.system(size: compact ? 19 : 24, weight: .heavy))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, compact ? 5 : 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.1)))
                }
                if let total = odds.overUnder {
                    Text(L10n.format("livetv_sports_over_under_format", fallback: "O/U %@", SportsTeams.format(total)))
                        .font(.system(size: compact ? 17 : 20, weight: .bold))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            if let provider = odds.provider {
                Text(L10n.format("livetv_sports_odds_by_format", fallback: "Odds: %@", provider))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }
}

extension SportsOddsView {
    /// The first team, the draw, the second team, in the order they're said.
    fileprivate var values: [(SportsSide?, Double?)] {
        let sides = event.ordered(league.sport)
        guard sides.count == 2 else { return [] }
        var list: [(SportsSide?, Double?)] = [(sides[0], sides[0].home ? odds.home : odds.away)]
        if let draw = odds.draw { list.append((nil, draw)) }
        list.append((sides[1], sides[1].home ? odds.home : odds.away))
        return list
    }
}

/// The last results as dots: W green, D grey, L red.
struct SportsFormDots: View {
    let results: [String]
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: size * 0.25) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                Text(Self.letter(result))
                    .font(.system(size: size * 0.45, weight: .heavy))
                    .foregroundColor(result == "D" || result == "T" ? .black : .white)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Self.color(result)))
            }
        }
    }

    static func color(_ result: String) -> Color {
        switch result {
        case "W": return Color(red: 0.2, green: 0.75, blue: 0.35)
        case "L": return Color(red: 0.9, green: 0.25, blue: 0.3)
        default: return Color(white: 0.82)
        }
    }

    static func letter(_ result: String) -> String {
        switch result {
        case "W": return L10n.string("livetv_sports_win_short", fallback: "W")
        case "L": return L10n.string("livetv_sports_loss_short", fallback: "L")
        default: return L10n.string("livetv_sports_draw_short", fallback: "D")
        }
    }

    /// "WDLWW" as ["W", "D", "L", "W", "W"].
    static func split(_ form: String?) -> [String] {
        (form ?? "").map { String($0) }.filter { ["W", "D", "L", "T"].contains($0) }
    }
}

// MARK: Line-ups

/// The line-ups as a picture: football on a pitch (each team from its
/// goalkeeper to its forwards, as its formation and the players' positions
/// say), basketball and hockey by position; goals, cards and substitutions
/// on each player; the bench beside. When the positions don't make a
/// picture, the lists.
struct SportsLineupView: View {
    let lineups: [SportsLineup]
    let event: SportsEvent
    let league: League

    var body: some View {
        let ordered = orderedLineups
        let layouts = ordered.map { self.layout(for: $0) }
        if ordered.count == 2, layouts.allSatisfy({ $0 != nil }) {
            HStack(alignment: .top, spacing: 24) {
                bench(ordered[0], alignRight: false)
                SportsField(left: layouts[0] ?? [], right: layouts[1] ?? [],
                            leftColor: color(ordered[0]), rightColor: color(ordered[1]),
                            leftTitle: title(ordered[0]), rightTitle: title(ordered[1]), sport: league.sport)
                    .frame(width: 1060, height: 420)
                bench(ordered[1], alignRight: true)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 80) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, lineup in
                    VStack(alignment: .leading, spacing: 6) {
                        Text([lineup.team, lineup.formation].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 24, weight: .bold))
                            .padding(.bottom, 6)
                        ForEach(Array(lineup.players.prefix(11).enumerated()), id: \.offset) { _, player in
                            Text(player).font(.system(size: 20))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The left team first (the home team in football).
    private var orderedLineups: [SportsLineup] {
        let leftID = (league.sport.homeFirst ? event.home : event.away)?.team.id
        return lineups.filter { $0.teamId == leftID } + lineups.filter { $0.teamId != leftID }
    }

    private func layout(for lineup: SportsLineup) -> [[SportsLineupPlayer]]? {
        if league.sport == .football { return SportsMoments.pitchRows(lineup.starters, formation: lineup.formation) }
        let rows = SportsMoments.groupRows(lineup.starters, sport: league.sport)
        return rows.count > 1 ? rows : nil
    }

    private func side(_ lineup: SportsLineup) -> SportsSide? {
        event.sides.first { $0.team.id == lineup.teamId }
    }

    private func color(_ lineup: SportsLineup) -> Color {
        Color(sportsARGB: side(lineup)?.team.color ?? 0xFF555A66)
    }

    private func title(_ lineup: SportsLineup) -> String {
        [side(lineup)?.team.name ?? lineup.team, lineup.formation].compactMap { $0 }.joined(separator: " · ")
    }

    /// The substitutes: the ones who came on first (minute, green arrow).
    private func bench(_ lineup: SportsLineup, alignRight: Bool) -> some View {
        let came = lineup.bench.filter { $0.subbedOn != nil }
        let rest = lineup.bench.filter { $0.subbedOn == nil }
        return VStack(alignment: alignRight ? .trailing : .leading, spacing: 5) {
            if let team = side(lineup)?.team { SportsTeamLogo(team: team, size: 36).padding(.bottom, 4) }
            Text(L10n.string("livetv_sports_bench", fallback: "Bench").uppercased())
                .font(.system(size: 14, weight: .heavy)).foregroundColor(.white.opacity(0.5))
            ForEach(Array((came + rest).prefix(12).enumerated()), id: \.offset) { _, player in
                HStack(spacing: 6) {
                    if let minute = player.subbedOn {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .heavy)).foregroundColor(.green)
                        Text(minute).font(.system(size: 14, weight: .bold)).foregroundColor(.green).monospacedDigit()
                    }
                    Text([player.jersey, player.shortName].compactMap { $0 }.joined(separator: " "))
                        .font(.system(size: 16, weight: player.subbedOn != nil ? .bold : .regular))
                        .foregroundColor(.white.opacity(player.subbedOn != nil ? 1 : 0.6))
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 230, alignment: alignRight ? .trailing : .leading)
    }
}

/// A pitch (or court, or rink) with both teams' starters: the left team
/// from its goal to the middle, the right team mirrored.
private struct SportsField: View {
    let left: [[SportsLineupPlayer]]
    let right: [[SportsLineupPlayer]]
    let leftColor: Color
    let rightColor: Color
    let leftTitle: String
    let rightTitle: String
    let sport: Sport

    var body: some View {
        GeometryReader { box in
            let w = box.size.width, h = box.size.height
            ZStack {
                surface(w, h)
                ForEach(Array(left.enumerated()), id: \.offset) { r, row in
                    ForEach(Array(row.enumerated()), id: \.offset) { i, player in
                        SportsFieldPlayer(player: player, color: leftColor)
                            .position(x: x(r, of: left.count, w: w, mirrored: false), y: y(i, of: row.count, h: h, mirrored: false))
                    }
                }
                ForEach(Array(right.enumerated()), id: \.offset) { r, row in
                    ForEach(Array(row.enumerated()), id: \.offset) { i, player in
                        SportsFieldPlayer(player: player, color: rightColor)
                            .position(x: x(r, of: right.count, w: w, mirrored: true), y: y(i, of: row.count, h: h, mirrored: true))
                    }
                }
                VStack {
                    HStack {
                        Text(leftTitle)
                        Spacer()
                        Text(rightTitle)
                    }
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// A row's place from the goal (6 %) to near the middle (44 %).
    private func x(_ row: Int, of count: Int, w: CGFloat, mirrored: Bool) -> CGFloat {
        let share = count > 1 ? 0.06 + 0.38 * CGFloat(row) / CGFloat(count - 1) : 0.25
        return mirrored ? w * (1 - share) : w * share
    }

    /// Spread across; a team playing right to left has its left at the
    /// bottom.
    private func y(_ index: Int, of count: Int, h: CGFloat, mirrored: Bool) -> CGFloat {
        let slot = mirrored ? count - 1 - index : index
        return h * 0.1 + h * 0.82 * CGFloat(slot + 1) / CGFloat(count + 1)
    }

    @ViewBuilder
    private func surface(_ w: CGFloat, _ h: CGFloat) -> some View {
        let line = Color.white.opacity(0.35)
        switch sport {
        case .football, .rugby:
            ZStack {
                LinearGradient(colors: [Color(red: 0.13, green: 0.42, blue: 0.2), Color(red: 0.1, green: 0.34, blue: 0.16)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().strokeBorder(line, lineWidth: 2).padding(10)
                Rectangle().fill(line).frame(width: 2).padding(.vertical, 10)
                Circle().strokeBorder(line, lineWidth: 2).frame(width: h * 0.28, height: h * 0.28)
                HStack {
                    Rectangle().strokeBorder(line, lineWidth: 2).frame(width: w * 0.13, height: h * 0.52)
                    Spacer()
                    Rectangle().strokeBorder(line, lineWidth: 2).frame(width: w * 0.13, height: h * 0.52)
                }
                .padding(.horizontal, 10)
            }
        case .basketball:
            ZStack {
                Color(red: 0.55, green: 0.36, blue: 0.2)
                Rectangle().strokeBorder(line, lineWidth: 2).padding(10)
                Rectangle().fill(line).frame(width: 2).padding(.vertical, 10)
                Circle().strokeBorder(line, lineWidth: 2).frame(width: h * 0.3, height: h * 0.3)
            }
        case .hockey:
            ZStack {
                Color(red: 0.86, green: 0.9, blue: 0.95).opacity(0.25)
                RoundedRectangle(cornerRadius: 60).strokeBorder(line, lineWidth: 2).padding(10)
                Rectangle().fill(Color.red.opacity(0.6)).frame(width: 3).padding(.vertical, 10)
                HStack {
                    Rectangle().fill(Color.blue.opacity(0.6)).frame(width: 3)
                    Spacer()
                    Rectangle().fill(Color.blue.opacity(0.6)).frame(width: 3)
                }
                .padding(.horizontal, w * 0.33)
                .padding(.vertical, 10)
            }
        default:
            Color.white.opacity(0.08)
        }
    }
}

/// A player on the field: his number on his team's colour, his name, and
/// what he did (goals, a card, the minute he went off).
private struct SportsFieldPlayer: View {
    let player: SportsLineupPlayer
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(color)
                Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                Text(player.jersey ?? "").font(.system(size: 17, weight: .heavy)).foregroundColor(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1)
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) {
                if player.goals > 0 {
                    HStack(spacing: 1) {
                        Image(systemName: "soccerball").font(.system(size: 13, weight: .bold))
                        if player.goals > 1 { Text("\(player.goals)").font(.system(size: 12, weight: .heavy)) }
                    }
                    .padding(3)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .offset(x: 12, y: -8)
                }
            }
            .overlay(alignment: .topLeading) {
                if player.red || player.yellow {
                    RoundedRectangle(cornerRadius: 2).fill(player.red ? Color.red : Color.yellow)
                        .frame(width: 11, height: 15)
                        .offset(x: -6, y: -6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let minute = player.subbedOff {
                    HStack(spacing: 1) {
                        Image(systemName: "arrow.down").font(.system(size: 10, weight: .heavy))
                        Text(minute).font(.system(size: 11, weight: .heavy))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color(red: 0.85, green: 0.25, blue: 0.3)))
                    .offset(x: 18, y: 6)
                }
            }
            Text(Self.lastName(player.shortName))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 110)
                .shadow(color: .black.opacity(0.8), radius: 2)
        }
    }

    /// "N. Füllkrug" as "Füllkrug"; one name as it is.
    static func lastName(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, parts[0].hasSuffix(".") else { return name }
        return parts.dropFirst().joined(separator: " ")
    }
}
