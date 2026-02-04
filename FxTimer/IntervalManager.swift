import SwiftUI
import AVFoundation
import UserNotifications
import AudioToolbox

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
        static let teCountries = "teCountries" // デフォルト US/JP
        static let teImportanceFilter = "teImportanceFilter" // 0=all / 3=highOnly
        static let teKeywordCsv = "teKeywordCsv" // 例: "NFP,CPI,Core PCE"
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
    @AppStorage(Keys.teCountries) var teCountries: String = "United States,Japan"
    @AppStorage(Keys.teImportanceFilter) private var teImportanceRaw: Int = 3
    @AppStorage(Keys.teKeywordCsv) var teKeywordCsv: String = "NFP,CPI,Retail Sales,Core PCE,FOMC,Unemployment Rate,ISM"

    var teImportanceFilter: ImportanceFilter {
        get { ImportanceFilter(rawValue: teImportanceRaw) ?? .highOnly }
        set { teImportanceRaw = newValue.rawValue }
    }

    //==== UI バインディング ---------------------------------------------------
    @Published var status    = "停止中"
    @Published var isRunning = false
    @Published var clockText = "--:--:--"
    /// <分数:Int, 経過率 0.0‥1.0:Double>
    @Published var progress: [Int: Double] = [:]

    // 指標取得ステータス（設定画面に表示）
    @Published var indicatorStatus: String = ""

    //==== 内部状態 ------------------------------------------------------------
    private var timer: DispatchSourceTimer?
    private let speech = AVSpeechSynthesizer()
    private var silentPlayer: AVAudioPlayer?
    private let chimeSoundID: SystemSoundID = 1060
    private var lastCountdownSec: Int?
    private var isEnglish: Bool { lang == "en" }

    // 端末の通知センターに投げる（ローカル通知）
    private let notifyCenter = UNUserNotificationCenter.current()

    // JST固定のカレンダー（指標通知/お知らせの計算に使う）
    private var calTokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return c
    }

    // MARK: - Public: permission / start stop --------------------------------
    func requestNotificationPermission() {
        notifyCenter.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func start() {
        stop()
        prepareBackgroundAudio()
        status = "待機中"
        isRunning = true

        let now        = Date()
        let nanosecond = Calendar.current.component(.nanosecond, from: now)
        let delayNsec  = 1_000_000_000 - nanosecond
        let startTime  = DispatchTime.now() + .nanoseconds(delayNsec)

        timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer?.schedule(deadline: startTime, repeating: .seconds(1), leeway: .milliseconds(1))
        timer?.setEventHandler { [weak self] in self?.tick() }
        timer?.resume()

        // 任意：スタート時に自動で取り込み
        if teAutoImportEnabled {
            Task { await self.importTE_USJP_30MinBefore() }
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

    // MARK: - Reminders (storage) --------------------------------------------
    func getReminders() -> [ReminderItem] {
        guard let data = remindersJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ReminderItem].self, from: data)) ?? []
    }

    func setReminders(_ items: [ReminderItem]) {
        if let data = try? JSONEncoder().encode(items),
           let str = String(data: data, encoding: .utf8) {
            remindersJson = str
        }
        rescheduleAllLocalNotifications()
    }

    // MARK: - Local notifications --------------------------------------------
    /// アプリ起動時・設定変更時に「先の一定期間」をまとめて入れ直す方式
    func rescheduleAllLocalNotifications(lookAheadDays: Int = 120) {
        let items = getReminders().filter { $0.enabled }
        notifyCenter.removeAllPendingNotificationRequests()

        guard !items.isEmpty else { return }

        let now = Date()
        guard let end = calTokyo.date(byAdding: .day, value: lookAheadDays, to: now) else { return }

        var requests: [UNNotificationRequest] = []

        for item in items {
            let occ = upcomingOccurrences(for: item, from: now, to: end)
            for fireDate in occ {
                let req = makeNotificationRequest(item: item, fireDate: fireDate)
                if let req { requests.append(req) }
            }
        }

        // まとめて追加（順不同でもOK）
        for r in requests {
            notifyCenter.add(r)
        }
    }

    private func makeNotificationRequest(item: ReminderItem, fireDate: Date) -> UNNotificationRequest? {
        // idが同じでも、日付違いを識別できるようにする
        let y = calTokyo.component(.year, from: fireDate)
        let m = calTokyo.component(.month, from: fireDate)
        let d = calTokyo.component(.day, from: fireDate)
        let hh = calTokyo.component(.hour, from: fireDate)
        let mm = calTokyo.component(.minute, from: fireDate)

        let identifier = "reminder-\(item.id.uuidString)-\(y)\(String(format: "%02d", m))\(String(format: "%02d", d))-\(String(format: "%02d", hh))\(String(format: "%02d", mm))"

        var comp = DateComponents()
        comp.calendar = calTokyo
        comp.timeZone = calTokyo.timeZone
        comp.year = y
        comp.month = m
        comp.day = d
        comp.hour = hh
        comp.minute = mm

        let trigger = UNCalendarNotificationTrigger(dateMatching: comp, repeats: false)

        let body = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UNMutableNotificationContent()
        content.title = "お知らせ"
        content.body = body.isEmpty ? "お知らせ" : body

        // 「アラーム音」→ ここはOS標準音を鳴らす（カスタム音はファイル追加が必要）
        content.sound = reminderAlarmEnabled ? .default : nil

        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    private func upcomingOccurrences(for item: ReminderItem, from start: Date, to end: Date) -> [Date] {
        // 日次で走査（120日程度なら十分軽い）
        var dates: [Date] = []

        // anchor（隔週）の基準
        let anchor = anchorDateIfNeeded(rule: item.rule)

        // 走査開始（0:00へ）
        var dayCursor = calTokyo.startOfDay(for: start)

        while dayCursor <= end {
            if matches(rule: item.rule, date: dayCursor, anchor: anchor) {
                if let fire = calTokyo.date(bySettingHour: item.hour, minute: item.minute, second: 0, of: dayCursor) {
                    if fire > start, fire <= end {
                        dates.append(fire)
                    }
                }
            }
            guard let next = calTokyo.date(byAdding: .day, value: 1, to: dayCursor) else { break }
            dayCursor = next
        }

        return dates
    }

    private func anchorDateIfNeeded(rule: ReminderRule) -> Date? {
        switch rule {
        case .biweekly(_, let anchorISO):
            return parseAnchorISO(anchorISO)
        default:
            return nil
        }
    }

    private func parseAnchorISO(_ s: String) -> Date? {
        // "yyyy-MM-dd" を想定
        let df = DateFormatter()
        df.calendar = calTokyo
        df.timeZone = calTokyo.timeZone
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)
    }

    private func matches(rule: ReminderRule, date: Date, anchor: Date?) -> Bool {
        let weekday = calTokyo.component(.weekday, from: date) // 1=Sun ... 7=Sat
        let day = calTokyo.component(.day, from: date)

        switch rule {
        case .daily:
            return true

        case .weekly(let weekdays):
            return weekdays.contains(weekday)

        case .biweekly(let weekdays, _):
            guard weekdays.contains(weekday) else { return false }
            guard let anchor else { return true }
            // anchor週と同じパリティの週だけ通す
            let w1 = calTokyo.component(.weekOfYear, from: anchor)
            let w2 = calTokyo.component(.weekOfYear, from: date)
            let y1 = calTokyo.component(.yearForWeekOfYear, from: anchor)
            let y2 = calTokyo.component(.yearForWeekOfYear, from: date)
            let diffWeeks = (y2 - y1) * 53 + (w2 - w1) // ざっくり（年跨ぎ）
            return (diffWeeks % 2) == 0

        case .monthlyDay(let targetDay):
            return day == clamp(targetDay, 1, 31)

        case .monthlyNthWeekday(let nth, let targetWeekday):
            guard weekday == clamp(targetWeekday, 1, 7) else { return false }
            return isNthWeekday(ofMonthFor: date, nth: nth)

        case .oneTime(let y, let m, let d):
            let yy = calTokyo.component(.year, from: date)
            let mm = calTokyo.component(.month, from: date)
            let dd = calTokyo.component(.day, from: date)
            return (yy == y && mm == m && dd == d)
        }
    }

    private func isNthWeekday(ofMonthFor date: Date, nth: Int) -> Bool {
        // nth: 1..4 or -1(last)
        let targetWeekday = calTokyo.component(.weekday, from: date)
        let year = calTokyo.component(.year, from: date)
        let month = calTokyo.component(.month, from: date)

        // その月の同weekdayの日付一覧を作る
        guard let firstDay = calTokyo.date(from: DateComponents(calendar: calTokyo, timeZone: calTokyo.timeZone, year: year, month: month, day: 1)) else {
            return false
        }
        let range = calTokyo.range(of: .day, in: .month, for: firstDay) ?? 1..<32

        var candidates: [Int] = []
        for d in range {
            if let dt = calTokyo.date(from: DateComponents(calendar: calTokyo, timeZone: calTokyo.timeZone, year: year, month: month, day: d)),
               calTokyo.component(.weekday, from: dt) == targetWeekday {
                candidates.append(d)
            }
        }

        let day = calTokyo.component(.day, from: date)

        if nth == -1 {
            return day == candidates.last
        } else {
            let idx = nth - 1
            guard idx >= 0, idx < candidates.count else { return false }
            return day == candidates[idx]
        }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

    // MARK: - tick (interval logic) ------------------------------------------
    private func tick() {
        let now = Date()
        updateClock(now)

        let cal  = Calendar.current
        let sec  = cal.component(.second, from: now)
        let min  = cal.component(.minute, from: now)
        let hour = cal.component(.hour,   from: now)

        updateProgressBars(hour: hour, minute: min, second: sec)

        switch sec {
        case 30:
            if announce30Sec {
                speak(isEnglish ? "thirty seconds" : "30秒")
            }

        case 45: // 15 秒前
            let upcomingMin  = (min + 1) % 60
            let upcomingHour = (upcomingMin == 0) ? (hour + 1) % 24 : hour
            if let interval = selectInterval(hour: upcomingHour, minute: upcomingMin, includeOne: false) {
                announceAhead(interval)
            }

        case 55...59: // 5 秒カウントダウン
            guard lastCountdownSec != sec else { return }
            lastCountdownSec = sec
            if selectInterval(hour: hour, minute: min, includeOne: true) != nil {
                speakCountdown(60 - sec)
            }

        case 0: // 足確定
            lastCountdownSec = nil
            if let interval = selectInterval(hour: hour, minute: min, includeOne: true) {
                playChime(interval)
            }

        default: break
        }
    }

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

    // MARK: - output ----------------------------------------------------------
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

    // MARK: - speech / util ---------------------------------------------------
    func speakPublic(_ text: String) { speak(text) }

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
        // ここは「足確定アラート」のローカル通知（任意）
        guard enableNotification else { return }
        let c = UNMutableNotificationContent()
        c.title = text
        c.sound = .default
        let t = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let r = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: t)
        notifyCenter.add(r)
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
        } catch {
            print(error)
        }
    }

    func playFeedback(text: String) {
        AudioServicesPlaySystemSound(1104)
        speak(text)
    }
}

// MARK: - Trading Economics import --------------------------------------------
extension IntervalManager {

    /// 指標: US/JP（設定で変更可）を取得 → Importanceフィルタ → 発表30分前の「1回通知」へ落とす
    func importTE_USJP_30MinBefore() async {
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

        let preview = events.prefix(3).map { e in
            let ds = e.dateString ?? "nil"
            let imp = e.importanceInt.map(String.init) ?? "nil"
            return "Date=\(ds), Importance=\(imp)"
        }.joined(separator: "\n")

        // 既存の「te」由来は入れ替え（完全同期）
        var current = getReminders()
        current.removeAll { $0.source == "te" }

        var total = events.count
        var passedImportance = 0
        var parsedCount = 0
        var futureCount = 0
        var addedCount = 0

        for e in events {
            guard let release = parseDateFlexible(e.DateRaw) else { continue }
            parsedCount += 1

            if release >= now { futureCount += 1 }

            // Importanceフィルタ
            // キーワードフィルタ（空なら全件）
            let keywords = teKeywordCsv
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !keywords.isEmpty {
                let hay = (e.Event ?? e.Category ?? "").lowercased()
                let hit = keywords.contains { kw in
                    hay.contains(kw.lowercased())
                }
                if !hit { continue }
            }


            if teImportanceFilter == .highOnly {
                guard e.importanceInt == 3 else { continue }
            }
            passedImportance += 1

            // 未来だけ
            guard release >= now else { continue }

            // 発表30分前に通知
            guard let alert = calTokyo.date(byAdding: .minute, value: -30, to: release) else { continue }

            let hour = calTokyo.component(.hour, from: alert)
            let minute = calTokyo.component(.minute, from: alert)

            let country = (e.Country ?? "")
            let title = (e.Event ?? e.Category ?? "指標")
            let text = "【\(country)】\(title)（30分前）"

            let y = calTokyo.component(.year, from: alert)
            let m = calTokyo.component(.month, from: alert)
            let d = calTokyo.component(.day, from: alert)

            var item = ReminderItem()
            item.enabled = true
            item.hour = hour
            item.minute = minute
            item.text = text
            item.rule = .oneTime(year: y, month: m, day: d)
            item.source = "te"
            item.externalId = e.CalendarID

            current.append(item)
            addedCount += 1
        }

        setReminders(current)

        indicatorStatus =
        """
        取得完了：\(addedCount)件
        受信：\(total)件 / フィルタ通過：\(passedImportance)件
        日付パース成功：\(parsedCount)件 / 未来：\(futureCount)件

        ▼受信プレビュー（先頭3件）
        \(preview)
        """
    }

    // MARK: - Trading Economics：Dateパース（多形式対応）
    private func parseDateFlexible(_ raw: JSONAny?) -> Date? {
        guard let raw else { return nil }

        // ① 数値（UNIX秒 / UNIXミリ秒）
        if let d = raw.asDouble {
            if d >= 1_000_000_000_000 {
                return Date(timeIntervalSince1970: d / 1000.0)
            }
            if d >= 1_000_000_000 {
                return Date(timeIntervalSince1970: d)
            }
        }

        // ② 文字列として取得
        guard let s0 = raw.asString?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !s0.isEmpty else { return nil }

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
            if num >= 1_000_000_000_000 {
                return Date(timeIntervalSince1970: num / 1000.0)
            }
            if num >= 1_000_000_000 {
                return Date(timeIntervalSince1970: num)
            }
        }

        // ⑤ ISO8601（Zあり / 小数秒あり）
        let isoA = ISO8601DateFormatter()
        isoA.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoA.date(from: s0) { return d }

        // ⑥ ISO8601（Zあり）
        let isoB = ISO8601DateFormatter()
        isoB.formatOptions = [.withInternetDateTime]
        if let d = isoB.date(from: s0) { return d }

        // ⑦ ZなしISO（例: 2026-02-04T08:30:00）→ JST とみなす
        let df1 = DateFormatter()
        df1.calendar = Calendar(identifier: .gregorian)
        df1.timeZone = TimeZone(secondsFromGMT: 0)
        df1.locale = Locale(identifier: "en_US_POSIX")
        df1.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = df1.date(from: s0) { return d }

        // ⑧ スペース区切り
        let df2 = DateFormatter()
        df2.calendar = Calendar(identifier: .gregorian)
        df2.timeZone = TimeZone(secondsFromGMT: 0)
        df2.locale = Locale(identifier: "en_US_POSIX")
        df2.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = df2.date(from: s0) { return d }

        return nil
    }
}
