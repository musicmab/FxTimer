import Foundation

public struct ReminderItem: Identifiable, Codable, Equatable {
    public var id: UUID = UUID()
    public var enabled: Bool = true

    // 時刻
    public var hour: Int = 9
    public var minute: Int = 0

    // 内容（通知本文）
    public var text: String = "お知らせ"

    // 繰り返し
    // once / daily / weekly / weeklyN / monthlyDay / monthlyNthWeekday
    public var recurrence: String = "daily"

    // once 用（yyyy/mm/dd）
    public var year: Int? = nil
    public var month: Int? = nil
    public var day: Int? = nil

    // weekly / weeklyN / monthlyNthWeekday 用（Calendar.weekday: 1=日..7=土）
    public var weekday: Int? = nil

    // weeklyN（隔週/数週ごと）
    public var weekInterval: Int? = nil
    public var anchorYear: Int? = nil
    public var anchorMonth: Int? = nil
    public var anchorDay: Int? = nil

    // monthlyDay（毎月◯日）
    public var dayOfMonth: Int? = nil

    // monthlyNthWeekday（第N/最終）
    public var nthWeek: Int? = nil // 1..5 or -1

    // 自動取り込み識別
    public var source: String? = nil          // "te" / "preset"
    public var externalId: String? = nil

    public init() {}

    public var timeText: String { String(format: "%02d:%02d", hour, minute) }

    public var dateTextForOnce: String? {
        guard recurrence == "once",
              let y = year, let m = month, let d = day else { return nil }
        return String(format: "%04d/%02d/%02d", y, m, d)
    }
}

// MARK: - Trading Economics decoder helper
enum JSONAny: Decodable {
    case string(String), number(Double), int(Int), bool(Bool), null
    case object([String: JSONAny]), array([JSONAny])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONAny].self) { self = .object(v); return }
        if let v = try? c.decode([JSONAny].self) { self = .array(v); return }
        self = .null
    }

    var asString: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .number(let d):
            if d.rounded() == d { return String(Int(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var asInt: Int? {
        switch self {
        case .int(let i): return i
        case .number(let d): return d.rounded() == d ? Int(d) : nil
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }
    var asDouble: Double? {
        switch self {
        case .number(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }
}

struct TECalendarEvent: Decodable {
    let CalendarID: String?
    let DateRaw: JSONAny?
    let Country: String?
    let Event: String?
    let Category: String?
    let ImportanceRaw: JSONAny?

    enum CodingKeys: String, CodingKey { case CalendarID, Date, Country, Event, Category, Importance }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        CalendarID = try? c.decodeIfPresent(String.self, forKey: .CalendarID)
        DateRaw = try? c.decodeIfPresent(JSONAny.self, forKey: .Date)
        Country = try? c.decodeIfPresent(String.self, forKey: .Country)
        Event = try? c.decodeIfPresent(String.self, forKey: .Event)
        Category = try? c.decodeIfPresent(String.self, forKey: .Category)
        ImportanceRaw = try? c.decodeIfPresent(JSONAny.self, forKey: .Importance)
    }

    var dateString: String? { DateRaw?.asString }
    var importanceInt: Int? { ImportanceRaw?.asInt }
}

struct TEApiError: Codable {
    let error: String?
    let message: String?
}
