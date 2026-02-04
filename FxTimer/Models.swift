import Foundation

// MARK: - お知らせ（複数 + ルール）
enum ReminderRule: Codable, Equatable {
    case oneTime(year: Int, month: Int, day: Int)                 // 1回だけ
    case daily                                                    // 毎日
    case weekly(weekdays: [Int])                                  // 毎週（1=日 ... 7=土）
    case biweekly(weekdays: [Int], anchorISODate: String)         // 隔週（基準週を anchor で決める）
    case monthlyDay(day: Int)                                     // 毎月◯日
    case monthlyNthWeekday(nth: Int, weekday: Int)                // 毎月 第nth weekday（nth: 1..4, -1=最終）

    private enum CodingKeys: String, CodingKey { case type, a, b, c }
    private enum RuleType: String, Codable { case oneTime, daily, weekly, biweekly, monthlyDay, monthlyNthWeekday }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(RuleType.self, forKey: .type)
        switch t {
        case .oneTime:
            let a = try c.decode([Int].self, forKey: .a)
            self = .oneTime(year: a[safe: 0] ?? 2000, month: a[safe: 1] ?? 1, day: a[safe: 2] ?? 1)
        case .daily:
            self = .daily
        case .weekly:
            let a = try c.decode([Int].self, forKey: .a)
            self = .weekly(weekdays: a)
        case .biweekly:
            let a = try c.decode([Int].self, forKey: .a)
            let b = try c.decode(String.self, forKey: .b)
            self = .biweekly(weekdays: a, anchorISODate: b)
        case .monthlyDay:
            let a = try c.decode(Int.self, forKey: .a)
            self = .monthlyDay(day: a)
        case .monthlyNthWeekday:
            let a = try c.decode([Int].self, forKey: .a)
            self = .monthlyNthWeekday(nth: a[safe: 0] ?? 1, weekday: a[safe: 1] ?? 2)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .oneTime(let y, let m, let d):
            try c.encode(RuleType.oneTime, forKey: .type)
            try c.encode([y, m, d], forKey: .a)
        case .daily:
            try c.encode(RuleType.daily, forKey: .type)
        case .weekly(let wds):
            try c.encode(RuleType.weekly, forKey: .type)
            try c.encode(wds, forKey: .a)
        case .biweekly(let wds, let anchor):
            try c.encode(RuleType.biweekly, forKey: .type)
            try c.encode(wds, forKey: .a)
            try c.encode(anchor, forKey: .b)
        case .monthlyDay(let day):
            try c.encode(RuleType.monthlyDay, forKey: .type)
            try c.encode(day, forKey: .a)
        case .monthlyNthWeekday(let nth, let weekday):
            try c.encode(RuleType.monthlyNthWeekday, forKey: .type)
            try c.encode([nth, weekday], forKey: .a)
        }
    }
}

struct ReminderItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true

    // 時刻
    var hour: Int = 9
    var minute: Int = 0

    // 内容
    var text: String = "お知らせ"

    // ルール
    var rule: ReminderRule = .daily

    // 自動取り込み識別（TradingEconomics 等）
    var source: String? = nil          // "te"
    var externalId: String? = nil      // CalendarID 等（任意）

    var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

enum ImportanceFilter: Int, CaseIterable, Identifiable, Codable {
    case all = 0
    case highOnly = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: return "すべて"
        case .highOnly: return "高（3）だけ"
        }
    }
}

private extension Array {
    subscript(safe idx: Int) -> Element? {
        guard idx >= 0, idx < count else { return nil }
        return self[idx]
    }
}
