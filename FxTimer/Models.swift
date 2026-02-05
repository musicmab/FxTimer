import Foundation

// MARK: - 繰り返しルール
enum ReminderRule: Codable, Equatable {
    case daily
    case weekly(weekdays: [Int], intervalWeeks: Int)   // weekdays: 1...7 (Sun=1), intervalWeeks: 1=毎週,2=隔週
    case monthlyDay(days: [Int])                       // 1...31（存在しない日はスキップ）
    case monthlyNth(weekday: Int, nth: Int)            // 第n weekday（1..4）
    case monthlyLast(weekday: Int)                     // 最終 weekday
    case once(dateISO: String)                         // ISO8601（発表30分前の“1回”用）
}

// MARK: - お知らせモデル（複数）
struct ReminderItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var hour: Int = 9
    var minute: Int = 0
    var text: String = "お知らせ"

    var rule: ReminderRule = .daily

    // 自動取り込み識別（TradingEconomics 等）
    var source: String? = nil
    var externalId: String? = nil

    var timeText: String { String(format: "%02d:%02d", hour, minute) }
}

// MARK: - Trading Economics: 値のゆらぎを吸収するための汎用デコーダ
enum JSONAny: Decodable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case null
    case object([String: JSONAny])
    case array([JSONAny])

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
        case .number(let d):
            if d.rounded() == d { return Int(d) }
            return nil
        case .string(let s):
            return Int(s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
        default: return nil
        }
    }

    var asDouble: Double? {
        switch self {
        case .number(let d): return d
        case .int(let i): return Double(i)
        case .string(let s):
            return Double(s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
        default: return nil
        }
    }
}

// MARK: - Trading Economics Calendar（ゆらぎ対応デコード）
struct TECalendarEvent: Decodable {
    let CalendarID: String?
    let DateRaw: JSONAny?
    let Country: String?
    let Event: String?
    let Category: String?
    let ImportanceRaw: JSONAny?

    enum CodingKeys: String, CodingKey {
        case CalendarID
        case Date
        case Country
        case Event
        case Category
        case Importance
    }

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

// MARK: - Trading Economics エラー（よくある形式）
struct TEApiError: Codable {
    let error: String?
    let message: String?
}
