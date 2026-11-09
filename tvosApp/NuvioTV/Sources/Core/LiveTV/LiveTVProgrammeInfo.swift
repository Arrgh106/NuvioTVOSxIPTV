import Foundation

/// The block the info panel shows (LIVE_TV_DESIGN.md, step 2): a programme
/// or a gap without listings, with the numbers the panel needs. Plain
/// Foundation, so the Linux tests cover it.
struct LiveTVProgrammeInfo: Equatable {
    let start: Date
    let end: Date
    /// nil for a gap ("No information").
    let title: String?
    let description: String?

    func isOn(at now: Date) -> Bool { start <= now && now < end }

    /// 0…1 through the programme.
    func progress(at now: Date) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(start) / length))
    }

    /// Minutes left, rounded up: ending in 30 s still shows 1 min.
    func minutesLeft(at now: Date) -> Int {
        max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// Calendar days from `now` to `date`: 0 today, 1 tomorrow.
    static func dayOffset(of date: Date, from now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
}
