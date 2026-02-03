//
//  FxIntervalNotifier.swift
//  FX 時間足確定アラート
//
import SwiftUI
import AVFoundation
import UserNotifications
import AudioToolbox

// MARK: - お知らせモデル（複数）
struct ReminderItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true

    // 時刻
    var hour: Int = 9
    var minute: Int = 0

    // 内容
    var text: String = "お知らせ"

    // 繰り返し
    // "once" / "daily"
    // "weekly"（毎週）: weekday
    // "weeklyN"（N週ごと）: weekday + weekInterval + anchorYMD
    // "monthlyDay"（毎月◯日）: dayOfMonth
    // "monthlyNthWeekday"（第N◯曜/最終◯曜）: nthWeek + weekday
    var recurrence: String = "daily"

    // once 用（指定日）
    var year: Int? = nil
    var month: Int? = nil
    var day: Int? = nil

    // weekly / weeklyN / monthlyNthWeekday 用（Calendar.weekday: 1=日,2=月,...7=土）
    var weekday: Int? = nil

    // weeklyN 用（2=隔週）
    var weekInterval: Int? = nil
    // weeklyN の基準日（この日を含む週を「0週目」として隔週判定）
    var anchorYear: Int? = nil
    var anchorMonth: Int? = nil
    var anchorDay: Int? = nil

    // monthlyDay 用（1...31）
    var dayOfMonth: Int? = nil

    // monthlyNthWeekday 用（第1〜第5、最終は -1）
    var nthWeek: Int? = nil    // 1..5 or -1

    // 自動取り込み識別（TradingEconomics 等）
    var source: String? = nil          // "te"
    var externalId: String? = nil      // CalendarID 等（任意）

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var dateTextForOnce: String? {
        guard recurrence == "once",
              let y = year, let m = month, let d = day else { return nil }
        return String(format: "%04d/%02d/%02d", y, m, d)
    }
}

// MARK: - Trading Economics: 値のゆらぎを吸収するための汎用デコーダ
private enum JSONAny: Decodable {
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
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    var asDouble: Double? {
        switch self {
        case .number(let d): return d
        case .int(let i): return Double(i)
        case .string(let s):
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }
}

// MARK: - Trading Economics Calendar（ゆらぎ対応デコード）
private struct TECalendarEvent: Decodable {
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
private struct TEApiError: Codable {
    let error: String?
    let message: String?
}

// MARK: - アプリ本体
@main
struct FxIntervalNotifierApp: App {
    @StateObject private var manager = IntervalManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onAppear { manager.requestNotificationPermission() }
        }
    }
}

// MARK: - IntervalManager
@MainActor
final class IntervalManager: ObservableObject {

    //==== 設定キー ------------------------------------------------------------
    enum Keys {
        static let beep = "enableBeep"
        static let vib  = "enableVibration"
        static let noti = "enableNotification"
        static let bg   = "enableBackgroundAudio"
        static let m1   = "int1"
        static let m5   = "int5"
        static let m15  = "int15"
        static let m30  = "int30"
        static let h1   = "int60"
        static let h4   = "int240"
        static let h8   = "int480"
        static let s30  = "announce30sec"
        static let lang = "announceLang"

        // お知らせ（複数）
        static let remindersJson = "remindersJson"
        static let reminderAlarm = "reminderAlarmEnabled"
        static let reminderSpeak = "reminderSpeakEnabled"

        // 指標取得（Trading Economics）
        static let teApiKey = "teApiKey"
        static let teAutoImport = "teAutoImportEnabled"
        static let teCountries = "teCountries"           // "United States,Japan"
        static let teMinImportance = "teMinImportance"   // 1/2/3
    }

    //==== ユーザ設定 ----------------------------------------------------------
    @AppStorage(Keys.beep) var enableBeep = true
    @AppStorage(Keys.vib)  var enableVibration = false
    @AppStorage(Keys.noti) var enableNotification = false
    @AppStorage(Keys.bg)   var enableBG = false

    @AppStorage(Keys.m1)   var on1   = true
    @AppStorage(Keys.m5)   var on5   = true
    @AppStorage(Keys.m15)  var on15  = true
    @AppStorage(Keys.m30)  var on30  = true
    @AppStorage(Keys.h1)   var on60  = true
    @AppStorage(Keys.h4)   var on240 = true
    @AppStorage(Keys.h8)   var on480 = true

    @AppStorage(Keys.s30)  var announce30Sec = false
    @AppStorage(Keys.lang) var lang = "ja"

    // お知らせ保存（JSON）
    @AppStorage(Keys.remindersJson) private var remindersJson: String = "[]"
    @AppStorage(Keys.reminderAlarm) var reminderAlarmEnabled: Bool = true
    @AppStorage(Keys.reminderSpeak) var reminderSpeakEnabled: Bool = true

    // 指標APIキー（アプリ内保存）
    @AppStorage(Keys.teApiKey) var teApiKey: String = ""
    @AppStorage(Keys.teAutoImport) var teAutoImportEnabled: Bool = false

    // ✅ US/JP に戻す
    @AppStorage(Keys.teCountries) var teCountries: String = "United States,Japan"

    // ✅ 重要度フィルタ（デフォルト 3=高）
    @AppStorage(Keys.teMinImportance) var teMinImportance: Int = 3

    //==== UI バインディング ---------------------------------------------------
    @Published var status    = "停止中"
    @Published var isRunning = false
    @Published var clockText = "--:--:--"
    /// <分数:Int, 経過率 0.0‥1.0:Double>
    @Published var progress: [Int: Double] = [:]

    // お知らせ表示（バナー）
    @Published var reminderBannerText: String = ""
    @Published var isReminderVisible: Bool = false

    // 指標取得ステータス
    @Published var indicatorStatus: String = ""

    //==== 内部状態 ------------------------------------------------------------
    private var timer: DispatchSourceTimer?
    private let speech = AVSpeechSynthesizer()
    private var silentPlayer: AVAudioPlayer?
    private let chimeSoundID: SystemSoundID = 1060
    private var lastCountdownSec: Int?
    private var isEnglish: Bool { lang == "en" }

    // お知らせ重複発火防止（1分単位）
    private var firedReminderKeys = Set<String>()

    // お知らせアラーム音
    private let reminderSoundID: SystemSoundID = 1005

    // MARK: - お知らせ（読み書き）
    func getReminders() -> [ReminderItem] {
        guard let data = remindersJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ReminderItem].self, from: data)) ?? []
    }

    func setReminders(_ items: [ReminderItem]) {
        if let data = try? JSONEncoder().encode(items),
           let str = String(data: data, encoding: .utf8) {
            remindersJson = str
        }
    }

    // MARK: - 制御
    func start() {
        stop()
        prepareBackgroundAudio()
        status = "待機中"
        isRunning = true

        let now = Date()
        let nanosecond = Calendar.current.component(.nanosecond, from: now)
        let delayNsec  = 1_000_000_000 - nanosecond
        let startTime  = DispatchTime.now() + .nanoseconds(delayNsec)

        timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer?.schedule(deadline: startTime, repeating: .seconds(1), leeway: .milliseconds(1))
        timer?.setEventHandler { [weak self] in self?.tick() }
        timer?.resume()

        if teAutoImportEnabled {
            Task { await self.importIndicators30MinBefore() }
        }
    }

    func stop() {
        timer?.cancel(); timer = nil
        silentPlayer?.stop(); silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
        status = "停止中"
        lastCountdownSec = nil
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - tick
    private func tick() {
        let now = Date()
        updateClock(now)

        let cal  = Calendar.current
        let sec  = cal.component(.second, from: now)
        let min  = cal.component(.minute, from: now)
        let hour = cal.component(.hour,   from: now)

        updateProgressBars(hour: hour, minute: min, second: sec)

        // お知らせチェック
        checkReminders(now: now, hour: hour, minute: min, second: sec)

        switch sec {
        case 30:
            if announce30Sec { speak(isEnglish ? "thirty seconds" : "30秒") }

        case 45:
            let upcomingMin  = (min + 1) % 60
            let upcomingHour = (upcomingMin == 0) ? (hour + 1) % 24 : hour
            if let interval = selectInterval(hour: upcomingHour, minute: upcomingMin, includeOne: false) {
                announceAhead(interval)
            }

        case 55...59:
            guard lastCountdownSec != sec else { return }
            lastCountdownSec = sec
            if selectInterval(hour: hour, minute: min, includeOne: true) != nil {
                speakCountdown(60 - sec)
            }

        case 0:
            lastCountdownSec = nil
            if let interval = selectInterval(hour: hour, minute: min, includeOne: true) {
                playChime(interval)
            }

        default: break
        }
    }

    // MARK: - お知らせ（繰り返し判定ヘルパー）
    // 週の開始を月曜に固定（隔週判定が安定）
    private func startOfISOWeek(_ date: Date) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) ?? date
    }

    private func weeksBetweenISO(_ a: Date, _ b: Date) -> Int {
        let sa = startOfISOWeek(a)
        let sb = startOfISOWeek(b)
        let diff = Calendar(identifier: .iso8601).dateComponents([.weekOfYear], from: sa, to: sb)
        return diff.weekOfYear ?? 0
    }

    // その日が「第N◯曜」か（nth=1..5）、nth=-1 で「最終◯曜」
    private func isNthWeekdayOfMonth(_ date: Date, weekday: Int, nth: Int) -> Bool {
        let cal = Calendar.current
        let y = cal.component(.year, from: date)
        let m = cal.component(.month, from: date)
        let d = cal.component(.day, from: date)

        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = 1

        guard let firstDay = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: firstDay) else { return false }

        var days: [Int] = []
        for day in range {
            var c = DateComponents()
            c.year = y; c.month = m; c.day = day
            if let dt = cal.date(from: c) {
                let wd = cal.component(.weekday, from: dt)
                if wd == weekday { days.append(day) }
            }
        }
        guard !days.isEmpty else { return false }

        if nth == -1 {
            return d == days.last
        } else if nth >= 1 && nth <= days.count {
            return d == days[nth - 1]
        } else {
            return false
        }
    }

    private func matchesReminder(_ item: ReminderItem, y: Int, mo: Int, d: Int, weekday: Int, now: Date) -> Bool {
        switch item.recurrence {
        case "once":
            guard let iy = item.year, let im = item.month, let id = item.day else { return false }
            return (iy == y && im == mo && id == d)

        case "daily":
            return true

        case "weekly":
            guard let w = item.weekday else { return false }
            return w == weekday

        case "weeklyN":
            guard let w = item.weekday else { return false }
            guard w == weekday else { return false }

            let interval = max(item.weekInterval ?? 2, 1)

            let cal = Calendar.current
            let ay = item.anchorYear ?? y
            let am = item.anchorMonth ?? mo
            let ad = item.anchorDay ?? d
            var c = DateComponents()
            c.year = ay; c.month = am; c.day = ad
            let anchorDate = cal.date(from: c) ?? now

            let wdiff = weeksBetweenISO(anchorDate, now)
            return (wdiff % interval) == 0

        case "monthlyDay":
            guard let dom = item.dayOfMonth else { return false }
            return dom == d

        case "monthlyNthWeekday":
            guard let w = item.weekday, let nth = item.nthWeek else { return false }
            return isNthWeekdayOfMonth(now, weekday: w, nth: nth)

        default:
            return true
        }
    }

    private func checkReminders(now: Date, hour: Int, minute: Int, second: Int) {
        guard second == 0 else { return }

        var reminders = getReminders().filter { $0.enabled }
        guard !reminders.isEmpty else { return }

        let cal = Calendar.current
        let y  = cal.component(.year,  from: now)
        let mo = cal.component(.month, from: now)
        let d  = cal.component(.day,   from: now)
        let wd = cal.component(.weekday, from: now) // 1=日 ... 7=土

        let matched = reminders.filter {
            $0.hour == hour && $0.minute == minute && matchesReminder($0, y: y, mo: mo, d: d, weekday: wd, now: now)
        }
        guard !matched.isEmpty else { return }

        var fireTexts: [String] = []
        var changed = false

        for item in matched {
            let key = String(format: "%04d%02d%02d-%02d%02d-%@",
                             y, mo, d, hour, minute, item.id.uuidString)
            if firedReminderKeys.contains(key) { continue }
            firedReminderKeys.insert(key)

            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            fireTexts.append(t.isEmpty ? "お知らせ" : t)

            // once は発火したら無効化（翌日以降鳴らない）
            if item.recurrence == "once" {
                if let idx = reminders.firstIndex(where: { $0.id == item.id }) {
                    reminders[idx].enabled = false
                    changed = true
                }
            }
        }

        guard !fireTexts.isEmpty else { return }

        if firedReminderKeys.count > 300 {
            firedReminderKeys = Set(firedReminderKeys.suffix(180))
        }

        fireReminderBanner(text: fireTexts.joined(separator: "\n"))

        if changed {
            setReminders(reminders)
        }
    }

    private func fireReminderBanner(text: String) {
        reminderBannerText = text

        if reminderAlarmEnabled {
            AudioServicesPlaySystemSound(reminderSoundID)
        }

        if reminderSpeakEnabled {
            let speakText = text.replacingOccurrences(of: "\n", with: "。 ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speakText.isEmpty { speak(speakText) }
        }

        withAnimation(.easeInOut(duration: 0.2)) { isReminderVisible = true }

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.2)) { self.isReminderVisible = false }
        }
    }

    func dismissReminder() {
        withAnimation(.easeInOut(duration: 0.2)) { isReminderVisible = false }
    }

    // MARK: - プリセット：米雇用統計（NFP）想定：毎月第1金曜 8:30ET の「30分前」を今後Nか月分追加
    // ET 8:30 -> JST 21:30（米DST）/ 22:30（米標準）
    // ここでは「第1金曜」を機械的に作ります（祝日等によるズレは追従しません）。
    func addPresetUSDST_NFP_30MinBefore(monthsAhead: Int = 12) {
        let now = Date()

        guard let tzNY = TimeZone(identifier: "America/New_York"),
              let tzJST = TimeZone(identifier: "Asia/Tokyo") else { return }

        var calNY = Calendar(identifier: .gregorian)
        calNY.timeZone = tzNY
        var calJST = Calendar(identifier: .gregorian)
        calJST.timeZone = tzJST

        var reminders = getReminders()

        for i in 0..<max(monthsAhead, 1) {
            guard let target = calNY.date(byAdding: .month, value: i, to: now) else { continue }
            let y = calNY.component(.year, from: target)
            let m = calNY.component(.month, from: target)

            // 月初の「第1金曜」を NY 時間で探す
            var firstDayComp = DateComponents()
            firstDayComp.year = y
            firstDayComp.month = m
            firstDayComp.day = 1
            firstDayComp.hour = 0
            firstDayComp.minute = 0

            guard let firstDay = calNY.date(from: firstDayComp),
                  let range = calNY.range(of: .day, in: .month, for: firstDay) else { continue }

            var firstFriday: Date? = nil
            for day in range {
                var c = DateComponents()
                c.year = y; c.month = m; c.day = day
                c.hour = 0; c.minute = 0
                if let dt = calNY.date(from: c) {
                    let wd = calNY.component(.weekday, from: dt) // 6=金（NYでも同じ）
                    if wd == 6 {
                        firstFriday = dt
                        break
                    }
                }
            }
            guard let ff = firstFriday else { continue }

            // 発表：8:30 ET（NY）
            var releaseComp = calNY.dateComponents([.year,.month,.day], from: ff)
            releaseComp.hour = 8
            releaseComp.minute = 30
            guard let releaseNY = calNY.date(from: releaseComp) else { continue }

            // 30分前
            guard let alertNY = calNY.date(byAdding: .minute, value: -30, to: releaseNY) else { continue }

            // JSTへ
            let alertJST = alertNY // Date は絶対時刻なので、そのままJSTカレンダーで読み取る
            let jy = calJST.component(.year, from: alertJST)
            let jm = calJST.component(.month, from: alertJST)
            let jd = calJST.component(.day, from: alertJST)
            let jh = calJST.component(.hour, from: alertJST)
            let jmin = calJST.component(.minute, from: alertJST)

            // 未来分だけ入れる（過去ならスキップ）
            if alertJST < now { continue }

            var item = ReminderItem()
            item.enabled = true
            item.hour = jh
            item.minute = jmin
            item.text = "【US】雇用統計（NFP想定）（30分前）"
            item.recurrence = "once"
            item.year = jy
            item.month = jm
            item.day = jd
            item.source = "preset"
            item.externalId = "nfp-\(y)-\(m)"

            // 重複追加を避ける（同じ externalId があれば入れない）
            let exists = reminders.contains(where: { $0.source == "preset" && $0.externalId == item.externalId })
            if !exists {
                reminders.append(item)
            }
        }

        setReminders(reminders)
    }

    // MARK: - Trading Economics：Dateパース（多形式対応）
    private func parseDateFlexible(_ raw: JSONAny?) -> Date? {
        guard let raw else { return nil }

        // ① 数値（UNIX秒 / UNIXミリ秒）
        if let d = raw.asDouble {
            if d >= 1_000_000_000_000 { // ms
                return Date(timeIntervalSince1970: d / 1000.0)
            }
            if d >= 1_000_000_000 {     // sec
                return Date(timeIntervalSince1970: d)
            }
        }

        // ② 文字列
        guard let s0 = raw.asString?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !s0.isEmpty else {
            return nil
        }

        // ③ /Date(1700000000000)/ 形式
        if s0.hasPrefix("/Date("),
           let close = s0.firstIndex(of: ")") {
            let inside = String(s0[s0.index(s0.startIndex, offsetBy: 6)..<close])
            if let ms = Double(inside) {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
        }

        // ④ 数値文字列
        if let num = Double(s0) {
            if num >= 1_000_000_000_000 { return Date(timeIntervalSince1970: num / 1000.0) }
            if num >= 1_000_000_000 {     return Date(timeIntervalSince1970: num) }
        }

        // ⑤ ISO8601（小数秒あり）
        let isoA = ISO8601DateFormatter()
        isoA.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoA.date(from: s0) { return d }

        // ⑥ ISO8601（小数秒なし）
        let isoB = ISO8601DateFormatter()
        isoB.formatOptions = [.withInternetDateTime]
        if let d = isoB.date(from: s0) { return d }

        // ⑦ タイムゾーン無し → JSTとして解釈
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Tokyo")

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm"
        ]
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: s0) { return d }
        }

        return nil
    }

    // MARK: - 指標自動取得（Trading Economics）
    /// 指定国 / 重要度フィルタ（>= teMinImportance）/ 発表30分前の「1回だけ」Reminderを自動生成
    func importIndicators30MinBefore() async {
        let key = teApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            indicatorStatus = "APIキーが未設定です。設定で入力してください。"
            return
        }

        indicatorStatus = "取得中..."

        do {
            let countriesRaw = teCountries.trimmingCharacters(in: .whitespacesAndNewlines)
            let countries = countriesRaw.isEmpty ? "United States,Japan" : countriesRaw
            let encCountries = countries.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? countries

            guard let url = URL(string: "https://api.tradingeconomics.com/calendar/country/\(encCountries)?c=\(key)&f=json") else {
                indicatorStatus = "URL生成に失敗しました。"
                return
            }

            var req = URLRequest(url: url)
            req.timeoutInterval = 20

            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let statusCode = http?.statusCode ?? -1

            let bodyString = String(data: data, encoding: .utf8) ?? ""
            let head = String(bodyString.prefix(260))

            if !(200...299).contains(statusCode) {
                indicatorStatus = "HTTP \(statusCode)\n\(head)"
                return
            }

            if let events = try? JSONDecoder().decode([TECalendarEvent].self, from: data) {
                await applyTEEventsToReminders(events)
                return
            }

            if let apiErr = try? JSONDecoder().decode(TEApiError.self, from: data) {
                let msg = apiErr.error ?? apiErr.message ?? "不明なエラー"
                indicatorStatus = "APIエラー\n\(msg)"
                return
            }

            indicatorStatus = "形式不一致（JSON配列ではありません）\n\(head)"

        } catch {
            indicatorStatus = "取得に失敗しました：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func applyTEEventsToReminders(_ events: [TECalendarEvent]) async {
        let now = Date()

        // Tokyoで hour/minute + 日付を確定
        var calTokyo = Calendar.current
        calTokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current

        // デバッグ：先頭3件の Date/Importance
        let preview = events.prefix(3).map { e in
            let ds = e.dateString ?? "nil"
            let imp = e.importanceInt.map(String.init) ?? "nil"
            return "Date=\(ds), Importance=\(imp)"
        }.joined(separator: "\n")

        // TE自動取り込みは入れ替え
        var current = getReminders()
        current.removeAll { $0.source == "te" }

        let total = events.count
        var minImpCount = 0
        var dateParsedCount = 0
        var futureCount = 0
        var addedCount = 0

        for e in events {
            guard let releaseDate = parseDateFlexible(e.DateRaw) else { continue }
            dateParsedCount += 1
            if releaseDate >= now { futureCount += 1 }

            let imp = e.importanceInt ?? 0
            guard imp >= teMinImportance else { continue }
            minImpCount += 1

            // 未来だけ
            guard releaseDate >= now else { continue }

            // 発表30分前
            guard let alertDate = Calendar.current.date(byAdding: .minute, value: -30, to: releaseDate) else { continue }

            let hour = calTokyo.component(.hour, from: alertDate)
            let minute = calTokyo.component(.minute, from: alertDate)

            let y = calTokyo.component(.year, from: alertDate)
            let m = calTokyo.component(.month, from: alertDate)
            let d = calTokyo.component(.day, from: alertDate)

            let country = (e.Country ?? "")
            let title = (e.Event ?? e.Category ?? "指標")
            let text = "【\(country)】\(title)（30分前）"

            var item = ReminderItem()
            item.enabled = true
            item.hour = hour
            item.minute = minute
            item.text = text

            // ✅ TEは「1回だけ（指定日）」
            item.recurrence = "once"
            item.year = y
            item.month = m
            item.day = d

            item.source = "te"
            item.externalId = e.CalendarID

            current.append(item)
            addedCount += 1
        }

        setReminders(current)

        indicatorStatus =
        """
        取得完了：\(addedCount)件
        受信：\(total)件 / 重要度>=\(teMinImportance)：\(minImpCount)件
        日付パース成功：\(dateParsedCount)件 / 未来：\(futureCount)件

        ▼受信プレビュー（先頭3件）
        \(preview)
        """
    }

    // MARK: - 時計/進捗
    private func updateClock(_ date: Date) {
        let cal = Calendar.current
        let h = cal.component(.hour,   from: date)
        let m = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        clockText = String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func updateProgressBars(hour: Int, minute: Int, second: Int) {
        let currentSec = hour * 3600 + minute * 60 + second
        var dict: [Int: Double] = [:]

        let table: [(Int, Bool)] = [
            (1,   on1),
            (5,   on5),
            (15,  on15),
            (30,  on30),
            (60,  on60),
            (240, on240),
            (480, on480)
        ]

        for (intervalMin, isOn) in table where isOn {
            let intervalSec = intervalMin * 60
            let elapsed     = currentSec % intervalSec
            dict[intervalMin] = Double(elapsed) / Double(intervalSec)
        }
        progress = dict
    }

    private func selectInterval(hour: Int, minute: Int, includeOne: Bool) -> Int? {
        if minute == 0 {
            if hour % 8 == 0 && on480 { return 480 }
            if hour % 4 == 0 && on240 { return 240 }
            if                on60  { return 60 }
        }
        if minute % 30 == 0 && on30 { return 30 }
        if minute % 15 == 0 && on15 { return 15 }
        if minute % 5  == 0 && on5  { return 5  }
        if includeOne && on1 { return 1 }
        return nil
    }

    // MARK: - 出力
    private func intervalLabel(_ value: Int) -> String {
        switch value {
        case 480: return isEnglish ? "8-hour bar"  : "8時間足"
        case 240: return isEnglish ? "4-hour bar"  : "4時間足"
        case  60: return isEnglish ? "1-hour bar"  : "1時間足"
        default:  return isEnglish ? "\(value)-min bar" : "\(value)分足"
        }
    }

    private func announceAhead(_ interval: Int) {
        let text = isEnglish
            ? "In 15 seconds,\n\(intervalLabel(interval))\nwill close."
            : "まもなく\n\(intervalLabel(interval))\nが確定します。"
        status = text
        vibrateIfNeeded()
        notifyIfNeeded(text)
        speak(text)
    }

    private func playChime(_ interval: Int) {
        if enableBeep { AudioServicesPlaySystemSound(chimeSoundID) }
        vibrateIfNeeded()
        status = isEnglish
            ? "\(intervalLabel(interval))\nclosed."
            : "\(intervalLabel(interval))\nが確定しました。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.isRunning == true { self?.status = "" }
        }
    }

    private func speakCountdown(_ value: Int) {
        status = " \(value) "
        speak("\(value)")
    }

    // MARK: - ユーティリティ
    private func speak(_ text: String) {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: isEnglish ? "en-US" : "ja-JP")
        utt.rate  = 0.45
        speech.speak(utt)
    }

    private func vibrateIfNeeded() {
        if enableVibration { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
    }

    private func notifyIfNeeded(_ text: String) {
        guard enableNotification else { return }
        let c = UNMutableNotificationContent()
        c.title = text
        c.sound = .default
        let t = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let r = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: t)
        UNUserNotificationCenter.current().add(r)
    }

    private func prepareBackgroundAudio() {
        guard enableBG else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            if let url = Bundle.main.url(forResource: "Silent", withExtension: "mp3") {
                silentPlayer = try AVAudioPlayer(contentsOf: url)
                silentPlayer?.numberOfLoops = -1
                silentPlayer?.volume = 0
                silentPlayer?.play()
            }
        } catch { print(error) }
    }

    func playFeedback(text: String) {
        AudioServicesPlaySystemSound(1104)
        speak(text)
    }
}

// MARK: - UI
struct ContentView: View {
    @EnvironmentObject var mgr: IntervalManager

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    VStack(alignment: .center, spacing: 8) {
                        Text(mgr.clockText)
                            .font(.system(size: 60, weight: .bold, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.top, 20)
                            .frame(maxWidth: .infinity, alignment: .center)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(mgr.progress.keys.sorted(), id: \.self) { key in
                                if let p = mgr.progress[key] {
                                    IntervalProgressBar(minutes: key, progress: p)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    Spacer()

                    // お知らせ（スタートボタンの上）
                    VStack(spacing: 16) {
                        if mgr.isReminderVisible {
                            Button {
                                mgr.dismissReminder()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bell.fill").font(.title3)
                                    Text(mgr.reminderBannerText)
                                        .font(.headline)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .opacity(0.7)
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity)
                                .background(Color.yellow.opacity(0.25))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.yellow.opacity(0.6), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        VStack(spacing: 16) {
                            Button(mgr.isRunning ? "ストップ" : "スタート") {
                                if mgr.isRunning {
                                    mgr.stop()
                                } else {
                                    mgr.start()
                                    mgr.playFeedback(text: "スタート")
                                }
                            }
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity)
                            .background(mgr.isRunning ? Color.red : Color.blue)
                            .foregroundColor(.white)
                            .font(.title2)
                            .clipShape(Capsule())

                            NavigationLink("設定", destination: SettingsView())
                                .font(.headline)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 40)
                }

                // カウントダウン（中央）
                Group {
                    if mgr.status.starts(with: " ") {
                        Text(mgr.status.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 200, weight: .bold, design: .monospaced))
                        + Text(" ")
                            .font(.system(size: 200, weight: .bold, design: .monospaced))
                    } else {
                        Text(mgr.status)
                            .font(.system(size: 50, weight: .medium, design: .monospaced))
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.top, 60)
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("FX Interval")
        }
    }
}

// MARK: - お知らせ編集画面（繰り返し拡張）
struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State var item: ReminderItem
    let onSave: (ReminderItem) -> Void
    let onDelete: (() -> Void)?

    private var timeBinding: Binding<Date> {
        Binding<Date>(
            get: {
                var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comp.hour = item.hour
                comp.minute = item.minute
                return Calendar.current.date(from: comp) ?? Date()
            },
            set: { newDate in
                let cal = Calendar.current
                item.hour = cal.component(.hour, from: newDate)
                item.minute = cal.component(.minute, from: newDate)
            }
        )
    }

    private var onceDateBinding: Binding<Date> {
        Binding<Date>(
            get: {
                var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comp.year = item.year ?? comp.year
                comp.month = item.month ?? comp.month
                comp.day = item.day ?? comp.day
                return Calendar.current.date(from: comp) ?? Date()
            },
            set: { newDate in
                let cal = Calendar.current
                item.year = cal.component(.year, from: newDate)
                item.month = cal.component(.month, from: newDate)
                item.day = cal.component(.day, from: newDate)
            }
        )
    }

    private let weekdayLabels: [(Int, String)] = [
        (1,"日"), (2,"月"), (3,"火"), (4,"水"), (5,"木"), (6,"金"), (7,"土")
    ]

    private let weekIntervalChoices: [(Int, String)] = [
        (1, "毎週"),
        (2, "隔週（2週ごと）"),
        (3, "3週ごと"),
        (4, "4週ごと")
    ]

    private let nthChoices: [(Int, String)] = [
        (1, "第1"),
        (2, "第2"),
        (3, "第3"),
        (4, "第4"),
        (5, "第5"),
        (-1, "最終")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("お知らせ内容") {
                    Toggle("有効", isOn: $item.enabled)
                    DatePicker("時刻", selection: timeBinding, displayedComponents: [.hourAndMinute])
                    TextField("内容", text: $item.text, axis: .vertical).lineLimit(1...4)
                }

                Section("繰り返し") {
                    Picker("種類", selection: $item.recurrence) {
                        Text("1回だけ（指定日）").tag("once")
                        Text("毎日").tag("daily")
                        Text("毎週（曜日）").tag("weekly")
                        Text("隔週/数週ごと（曜日）").tag("weeklyN")
                        Text("毎月（◯日）").tag("monthlyDay")
                        Text("第N◯曜 / 最終◯曜").tag("monthlyNthWeekday")
                    }

                    if item.recurrence == "once" {
                        DatePicker("日付", selection: onceDateBinding, displayedComponents: [.date])

                    } else if item.recurrence == "weekly" {
                        Picker("曜日", selection: Binding<Int>(
                            get: { item.weekday ?? 2 },
                            set: { item.weekday = $0 }
                        )) {
                            ForEach(weekdayLabels, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }

                    } else if item.recurrence == "weeklyN" {
                        Picker("間隔", selection: Binding<Int>(
                            get: { item.weekInterval ?? 2 },
                            set: { item.weekInterval = $0 }
                        )) {
                            ForEach(weekIntervalChoices, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }

                        Picker("曜日", selection: Binding<Int>(
                            get: { item.weekday ?? 6 },   // デフォ金曜
                            set: { item.weekday = $0 }
                        )) {
                            ForEach(weekdayLabels, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }

                        DatePicker("基準日（隔週判定）", selection: Binding<Date>(
                            get: {
                                let cal = Calendar.current
                                var c = DateComponents()
                                c.year = item.anchorYear ?? cal.component(.year, from: Date())
                                c.month = item.anchorMonth ?? cal.component(.month, from: Date())
                                c.day = item.anchorDay ?? cal.component(.day, from: Date())
                                return cal.date(from: c) ?? Date()
                            },
                            set: { newDate in
                                let cal = Calendar.current
                                item.anchorYear = cal.component(.year, from: newDate)
                                item.anchorMonth = cal.component(.month, from: newDate)
                                item.anchorDay = cal.component(.day, from: newDate)
                            }
                        ), displayedComponents: [.date])

                    } else if item.recurrence == "monthlyDay" {
                        Picker("日", selection: Binding<Int>(
                            get: { item.dayOfMonth ?? 1 },
                            set: { item.dayOfMonth = $0 }
                        )) {
                            ForEach(1...31, id: \.self) { d in
                                Text("\(d)日").tag(d)
                            }
                        }

                    } else if item.recurrence == "monthlyNthWeekday" {
                        Picker("第N", selection: Binding<Int>(
                            get: { item.nthWeek ?? 1 },
                            set: { item.nthWeek = $0 }
                        )) {
                            ForEach(nthChoices, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }

                        Picker("曜日", selection: Binding<Int>(
                            get: { item.weekday ?? 6 }, // デフォ金曜
                            set: { item.weekday = $0 }
                        )) {
                            ForEach(weekdayLabels, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }
                    }
                }

                if item.source == "te" {
                    Section {
                        Text("※ Trading Economics から自動生成された項目です（指定日1回のみ）。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: { Text("削除") }
                    }
                }
            }
            .navigationTitle("お知らせ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // 種別に応じて値を整理 & デフォルト補完
                        let cal = Calendar.current
                        let today = Date()
                        let y = cal.component(.year, from: today)
                        let m = cal.component(.month, from: today)
                        let d = cal.component(.day, from: today)

                        switch item.recurrence {
                        case "once":
                            item.weekday = nil
                            item.weekInterval = nil
                            item.anchorYear = nil; item.anchorMonth = nil; item.anchorDay = nil
                            item.dayOfMonth = nil
                            item.nthWeek = nil
                            if item.year == nil || item.month == nil || item.day == nil {
                                item.year = y; item.month = m; item.day = d
                            }

                        case "weekly":
                            item.year = nil; item.month = nil; item.day = nil
                            item.weekInterval = nil
                            item.anchorYear = nil; item.anchorMonth = nil; item.anchorDay = nil
                            item.dayOfMonth = nil
                            item.nthWeek = nil
                            if item.weekday == nil { item.weekday = 2 }

                        case "weeklyN":
                            item.year = nil; item.month = nil; item.day = nil
                            item.dayOfMonth = nil
                            item.nthWeek = nil
                            if item.weekday == nil { item.weekday = 6 }
                            item.weekInterval = max(item.weekInterval ?? 2, 1)
                            if item.anchorYear == nil || item.anchorMonth == nil || item.anchorDay == nil {
                                item.anchorYear = y; item.anchorMonth = m; item.anchorDay = d
                            }

                        case "monthlyDay":
                            item.year = nil; item.month = nil; item.day = nil
                            item.weekday = nil
                            item.weekInterval = nil
                            item.anchorYear = nil; item.anchorMonth = nil; item.anchorDay = nil
                            item.nthWeek = nil
                            if item.dayOfMonth == nil { item.dayOfMonth = 1 }

                        case "monthlyNthWeekday":
                            item.year = nil; item.month = nil; item.day = nil
                            item.dayOfMonth = nil
                            item.weekInterval = nil
                            item.anchorYear = nil; item.anchorMonth = nil; item.anchorDay = nil
                            if item.weekday == nil { item.weekday = 6 }
                            if item.nthWeek == nil { item.nthWeek = 1 }

                        default: // daily
                            item.year = nil; item.month = nil; item.day = nil
                            item.weekday = nil
                            item.weekInterval = nil
                            item.anchorYear = nil; item.anchorMonth = nil; item.anchorDay = nil
                            item.dayOfMonth = nil
                            item.nthWeek = nil
                        }

                        onSave(item)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @EnvironmentObject var mgr: IntervalManager

    @AppStorage(IntervalManager.Keys.beep) var enableBeep = true
    @AppStorage(IntervalManager.Keys.vib)  var enableVibration = false
    @AppStorage(IntervalManager.Keys.noti) var enableNotification = false
    @AppStorage(IntervalManager.Keys.bg)   var enableBG = false

    @AppStorage(IntervalManager.Keys.m1)   var on1   = true
    @AppStorage(IntervalManager.Keys.m5)   var on5   = true
    @AppStorage(IntervalManager.Keys.m15)  var on15  = true
    @AppStorage(IntervalManager.Keys.m30)  var on30  = true
    @AppStorage(IntervalManager.Keys.h1)   var on60  = true
    @AppStorage(IntervalManager.Keys.h4)   var on240 = true
    @AppStorage(IntervalManager.Keys.h8)   var on480 = true

    @AppStorage(IntervalManager.Keys.s30)  var announce30Sec = false
    @AppStorage(IntervalManager.Keys.lang) var lang = "ja"

    @AppStorage(IntervalManager.Keys.reminderAlarm) var reminderAlarmEnabled = true
    @AppStorage(IntervalManager.Keys.reminderSpeak) var reminderSpeakEnabled = true

    @AppStorage(IntervalManager.Keys.teApiKey) var teApiKey: String = ""
    @AppStorage(IntervalManager.Keys.teAutoImport) var teAutoImportEnabled: Bool = false
    @AppStorage(IntervalManager.Keys.teCountries) var teCountries: String = "United States,Japan"
    @AppStorage(IntervalManager.Keys.teMinImportance) var teMinImportance: Int = 3

    @State private var reminders: [ReminderItem] = []
    @State private var editingItem: ReminderItem? = nil
    @State private var isAdding: Bool = false

    private let importanceChoices: [(Int, String)] = [
        (1, "1（低以上）"),
        (2, "2（中以上）"),
        (3, "3（高のみ）")
    ]

    var body: some View {
        Form {
            Section("効果音・通知") {
                Toggle("チャイム音 (1013)", isOn: $enableBeep)
                Toggle("振動", isOn: $enableVibration)
                Toggle("ローカル通知", isOn: $enableNotification)
                Toggle("バックグラウンド動作", isOn: $enableBG)
                Toggle("30秒ごとに『30秒』と読み上げる", isOn: $announce30Sec)
            }

            Section("有効な時間足") {
                Toggle("1 分足", isOn: $on1)
                Toggle("5 分足", isOn: $on5)
                Toggle("15 分足", isOn: $on15)
                Toggle("30 分足", isOn: $on30)
                Toggle("1 時間足", isOn: $on60)
                Toggle("4 時間足", isOn: $on240)
                Toggle("8 時間足", isOn: $on480)
            }

            Section("お知らせ") {
                Toggle("ポップアップ時にアラーム音", isOn: $reminderAlarmEnabled)
                Toggle("お知らせ内容を読み上げる", isOn: $reminderSpeakEnabled)

                if reminders.isEmpty {
                    Text("まだ登録がありません。下の「追加」で登録してください。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    let sorted = reminders.sorted { a, b in
                        (a.hour, a.minute, a.text) < (b.hour, b.minute, b.text)
                    }

                    ForEach(sorted) { item in
                        Button {
                            editingItem = item
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.timeText).font(.headline)
                                    Text(item.text.isEmpty ? "お知らせ" : item.text)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)

                                    Text(recurrenceLabel(item))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: item.enabled ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(item.enabled ? .green : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                }

                Button { isAdding = true } label: {
                    Label("追加", systemImage: "plus")
                }

                Text("※ メイン画面のスタートボタンの上に表示（30秒で自動消去、タップで消去）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ✅ プリセット追加
            Section("プリセット（簡易）") {
                Button {
                    mgr.addPresetUSDST_NFP_30MinBefore(monthsAhead: 12)
                    reminders = mgr.getReminders()
                } label: {
                    Label("雇用統計（NFP想定）: 第1金曜（30分前）を今後12か月追加", systemImage: "calendar.badge.plus")
                }

                Text("※ 祝日等で発表日がずれる場合は反映されません（簡易プリセット）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("指標発表（自動取得）") {
                TextField("Trading Economics APIキー（c=...）", text: $teApiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                TextField("国（例: United States,Japan）", text: $teCountries)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                Picker("重要度フィルタ", selection: $teMinImportance) {
                    ForEach(importanceChoices, id: \.0) { v in
                        Text(v.1).tag(v.0)
                    }
                }

                Toggle("スタート時に自動で取り込む", isOn: $teAutoImportEnabled)

                Button {
                    Task { await mgr.importIndicators30MinBefore() }
                } label: {
                    Label("取得して30分前通知に登録", systemImage: "arrow.down.circle")
                }

                if !mgr.indicatorStatus.isEmpty {
                    Text(mgr.indicatorStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("読み上げ言語") {
                Picker("読み上げ言語", selection: $lang) {
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("設定")
        .onAppear { reminders = mgr.getReminders() }
        .onChange(of: reminders) { _, newValue in mgr.setReminders(newValue) }
        .sheet(item: $editingItem) { item in
            ReminderEditorView(
                item: item,
                onSave: { updated in
                    if let idx = reminders.firstIndex(where: { $0.id == updated.id }) {
                        reminders[idx] = updated
                    }
                },
                onDelete: {
                    if let idx = reminders.firstIndex(where: { $0.id == item.id }) {
                        reminders.remove(at: idx)
                    }
                }
            )
        }
        .sheet(isPresented: $isAdding) {
            ReminderEditorView(
                item: ReminderItem(),
                onSave: { newItem in reminders.append(newItem) },
                onDelete: nil
            )
        }
    }

    private func delete(at offsets: IndexSet) {
        let sorted = reminders.sorted { a, b in
            (a.hour, a.minute, a.text) < (b.hour, b.minute, b.text)
        }
        let idsToDelete = offsets.map { sorted[$0].id }
        reminders.removeAll { idsToDelete.contains($0.id) }
    }

    private func recurrenceLabel(_ item: ReminderItem) -> String {
        func wdText(_ w: Int) -> String {
            let map: [Int:String] = [1:"日",2:"月",3:"火",4:"水",5:"木",6:"金",7:"土"]
            return map[w] ?? "\(w)"
        }

        switch item.recurrence {
        case "once":
            return "1回だけ: \(item.dateTextForOnce ?? "未設定")"

        case "daily":
            return "毎日"

        case "weekly":
            let wd = item.weekday ?? 2
            return "毎週: \(wdText(wd))"

        case "weeklyN":
            let wd = item.weekday ?? 6
            let interval = item.weekInterval ?? 2
            let base = (interval == 2) ? "隔週" : "\(interval)週ごと"
            let anchor: String
            if let ay = item.anchorYear, let am = item.anchorMonth, let ad = item.anchorDay {
                anchor = String(format: "基準:%04d/%02d/%02d", ay, am, ad)
            } else {
                anchor = "基準:未設定"
            }
            return "\(base): \(wdText(wd))（\(anchor)）"

        case "monthlyDay":
            return "毎月: \(item.dayOfMonth ?? 1)日"

        case "monthlyNthWeekday":
            let nth = item.nthWeek ?? 1
            let wd = item.weekday ?? 6
            let nthText: String = (nth == -1) ? "最終" : "第\(nth)"
            return "\(nthText)\(wdText(wd))"

        default:
            return "毎日"
        }
    }
}

// MARK: - Progress Bar View
struct IntervalProgressBar: View {
    let minutes: Int
    let progress: Double

    private var label: String {
        switch minutes {
        case 60:  return "1時間足"
        case 240: return "4時間足"
        case 480: return "8時間足"
        default:  return "\(minutes)分足"
        }
    }

    private var remainingSec: Int {
        Int((1.0 - progress) * Double(minutes) * 60.0)
    }

    private var barColor: Color {
        remainingSec <= 10 ? .red : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(barColor)
        }
    }
}
