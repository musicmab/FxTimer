import SwiftUI
import AVFoundation
import UserNotifications
import AudioToolbox

@MainActor
final class IntervalManager: ObservableObject {

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

        static let remindersJson = "remindersJson"
        static let reminderAlarm = "reminderAlarmEnabled"
        static let reminderSpeak = "reminderSpeakEnabled"

        static let teApiKey = "teApiKey"
        static let teAutoImport = "teAutoImportEnabled"
        static let teCountries = "teCountries"
        static let teMinImportance = "teMinImportance"
    }

    //== settings
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

    @AppStorage(Keys.remindersJson) private var remindersJson: String = "[]"
    @AppStorage(Keys.reminderAlarm) var reminderAlarmEnabled: Bool = true
    @AppStorage(Keys.reminderSpeak) var reminderSpeakEnabled: Bool = true

    @AppStorage(Keys.teApiKey) var teApiKey: String = ""
    @AppStorage(Keys.teAutoImport) var teAutoImportEnabled: Bool = false
    @AppStorage(Keys.teCountries) var teCountries: String = "United States,Japan" // ★戻す
    @AppStorage(Keys.teMinImportance) var teMinImportance: Int = 3

    //== UI
    @Published var status    = "停止中"
    @Published var isRunning = false
    @Published var clockText = "--:--:--"
    @Published var progress: [Int: Double] = [:]
    @Published var indicatorStatus: String = ""

    //== internal
    private var timer: DispatchSourceTimer?
    private let speech = AVSpeechSynthesizer()
    private var silentPlayer: AVAudioPlayer?
    private let chimeSoundID: SystemSoundID = 1060
    private var lastCountdownSec: Int?
    private var isEnglish: Bool { lang == "en" }

    // ローカル通知識別子プレフィックス
    private let notifPrefix = "rem_"
    private let notifBiweeklyPrefix = "remB_"
    private let notifNthPrefix = "remN_"

    // MARK: - Reminders JSON
    func getReminders() -> [ReminderItem] {
        guard let data = remindersJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ReminderItem].self, from: data)) ?? []
    }

    func setReminders(_ items: [ReminderItem]) {
        if let data = try? JSONEncoder().encode(items),
           let str = String(data: data, encoding: .utf8) {
            remindersJson = str
        }
        // 保存のたびに通知を張り替える
        rescheduleAllLocalNotifications()
    }

    // MARK: - Start/Stop (バーや時報用)
    func start() {
        stop()
        prepareBackgroundAudio()
        status = "待機中"
        isRunning = true

        let now = Date()
        let ns = Calendar.current.component(.nanosecond, from: now)
        let delayNsec = 1_000_000_000 - ns
        let startTime = DispatchTime.now() + .nanoseconds(delayNsec)

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
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Tick
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

        default:
            break
        }
    }

    // MARK: - ローカル通知：全再スケジュール
    func rescheduleAllLocalNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }
            let ids = pending.map { $0.identifier }
            let remove = ids.filter { $0.hasPrefix(self.notifPrefix) || $0.hasPrefix(self.notifBiweeklyPrefix) || $0.hasPrefix(self.notifNthPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: remove)

            // 追加
            let items = self.getReminders().filter { $0.enabled }
            self.scheduleItems(items)
        }
    }

    private func scheduleItems(_ items: [ReminderItem]) {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let cal = Calendar.current

        for item in items {
            let body = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = body.isEmpty ? "お知らせ" : body

            switch item.recurrence {
            case "daily":
                var c = DateComponents()
                c.hour = item.hour
                c.minute = item.minute
                let id = notifPrefix + item.id.uuidString
                center.add(makeRequest(id: id, title: "お知らせ", body: text,
                                       trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: true)))

            case "weekly":
                var c = DateComponents()
                c.weekday = item.weekday ?? 2
                c.hour = item.hour
                c.minute = item.minute
                let id = notifPrefix + item.id.uuidString
                center.add(makeRequest(id: id, title: "お知らせ", body: text,
                                       trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: true)))

            case "monthlyDay":
                var c = DateComponents()
                c.day = min(max(item.dayOfMonth ?? 1, 1), 31)
                c.hour = item.hour
                c.minute = item.minute
                let id = notifPrefix + item.id.uuidString
                center.add(makeRequest(id: id, title: "お知らせ", body: text,
                                       trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: true)))

            case "monthlyNthWeekday":
                // UNCalendar は weekdayOrdinal が使える
                var c = DateComponents()
                c.weekday = item.weekday ?? 6
                c.weekdayOrdinal = item.nthWeek ?? 1   // -1 最終も可
                c.hour = item.hour
                c.minute = item.minute
                let id = notifNthPrefix + item.id.uuidString
                center.add(makeRequest(id: id, title: "お知らせ", body: text,
                                       trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: true)))

            case "once":
                guard let y = item.year, let m = item.month, let d = item.day else { continue }
                var c = DateComponents()
                c.year = y; c.month = m; c.day = d
                c.hour = item.hour; c.minute = item.minute
                let date = cal.date(from: c) ?? now
                if date <= now { continue }
                let id = notifPrefix + item.id.uuidString
                center.add(makeRequest(id: id, title: "お知らせ", body: text,
                                       trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: false)))

            case "weeklyN":
                // ★隔週/数週ごと：repeatsで表現できないので、先の N週間分を one-shot で積む
                scheduleBiweeklyLike(item: item, body: text, weeksAhead: 16)

            default:
                // 互換：未定義はdaily
                var c = DateComponents()
                c.hour = item.hour
                c.minute = item.minute
                let id = notifPrefix + item.id.uuidString
                center.add(makeRequest(id: id, title: "お知らせ", body: text,
                                       trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: true)))
            }
        }
    }

    private func scheduleBiweeklyLike(item: ReminderItem, body: String, weeksAhead: Int) {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let interval = max(item.weekInterval ?? 2, 1)
        let weekday = item.weekday ?? 6

        // 基準日（未設定なら今日）
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current

        let ay = item.anchorYear
        let am = item.anchorMonth
        let ad = item.anchorDay

        let anchorDate: Date = {
            guard let ay, let am, let ad else { return now }
            var c = DateComponents()
            c.year = ay; c.month = am; c.day = ad
            return Calendar.current.date(from: c) ?? now
        }()

        // 未来の対象曜日日付を列挙し、「基準週からの差分が interval の倍数」だけ採用
        for w in 0...weeksAhead {
            guard let baseWeek = cal.date(byAdding: .weekOfYear, value: w, to: now) else { continue }

            // その週の target weekday を作る
            let weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: baseWeek)) ?? baseWeek
            var target = weekStart
            let currentW = cal.component(.weekday, from: weekStart)
            let diff = (weekday - currentW + 7) % 7
            target = cal.date(byAdding: .day, value: diff, to: weekStart) ?? target

            // その日の時刻を付与
            var comp = Calendar.current.dateComponents([.year,.month,.day], from: target)
            comp.hour = item.hour
            comp.minute = item.minute
            guard let fireDate = Calendar.current.date(from: comp), fireDate > now else { continue }

            // iso週差
            let aWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: anchorDate)) ?? anchorDate
            let tWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: fireDate)) ?? fireDate
            let diffWeeks = cal.dateComponents([.weekOfYear], from: aWeek, to: tWeek).weekOfYear ?? 0
            if diffWeeks % interval != 0 { continue }

            let id = notifBiweeklyPrefix + item.id.uuidString + "_" + String(fireDate.timeIntervalSince1970)
            let trig = UNCalendarNotificationTrigger(dateMatching: comp, repeats: false)
            center.add(makeRequest(id: id, title: "お知らせ", body: body, trigger: trig))
        }
    }

    private func makeRequest(id: String, title: String, body: String, trigger: UNNotificationTrigger) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = reminderAlarmEnabled ? .default : nil
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    // MARK: - Presets（雇用統計以外も追加）
    // 「規則で固定できるもの」＋「目安（あとで編集前提）」を両方入れます
    func addPresets() {
        var items = getReminders()

        func appendIfNotExists(_ item: ReminderItem) {
            let exists = items.contains(where: { $0.source == item.source && $0.externalId == item.externalId })
            if !exists { items.append(item) }
        }

        // 1) 雇用統計（NFP想定）：第1金曜（実際は変動あり得るがルールは明確）
        // → ここでは「毎月 第1金曜」通知（30分前）として追加（ユーザーが後で調整可）
        do {
            var r = ReminderItem()
            r.enabled = true
            r.recurrence = "monthlyNthWeekday"
            r.nthWeek = 1
            r.weekday = 6 // 金
            r.hour = 21   // JST 目安（※DSTでズレ得る。必要なら変更）
            r.minute = 0
            r.text = "【US】雇用統計（NFP想定）（30分前・目安）"
            r.source = "preset"
            r.externalId = "preset_nfp_monthly_1st_fri"
            appendIfNotExists(r)
        }

        // 2) 米・週次新規失業保険申請件数（毎週 木曜）※時刻は季節で変わることがあります
        do {
            var r = ReminderItem()
            r.enabled = true
            r.recurrence = "weekly"
            r.weekday = 5 // 木
            r.hour = 22   // JST目安
            r.minute = 0
            r.text = "【US】週次 失業保険申請（目安）"
            r.source = "preset"
            r.externalId = "preset_us_jobless_claims_weekly"
            appendIfNotExists(r)
        }

        // 3) 米・FOMC（目安）：毎月 第3水曜 03:00（JST）などは実際は日程変動
        // → ルール固定できないので「目安」テンプレ。編集前提。
        do {
            var r = ReminderItem()
            r.enabled = false
            r.recurrence = "monthlyNthWeekday"
            r.nthWeek = 3
            r.weekday = 4 // 水
            r.hour = 2
            r.minute = 30
            r.text = "【US】FOMC（目安：編集して使う）"
            r.source = "preset"
            r.externalId = "preset_fomc_placeholder"
            appendIfNotExists(r)
        }

        // 4) 日銀イベント（目安テンプレ）
        do {
            var r = ReminderItem()
            r.enabled = false
            r.recurrence = "monthlyDay"
            r.dayOfMonth = 20
            r.hour = 11
            r.minute = 0
            r.text = "【JP】日銀関連（目安：編集して使う）"
            r.source = "preset"
            r.externalId = "preset_boj_placeholder"
            appendIfNotExists(r)
        }

        setReminders(items) // ←これが reschedule も呼ぶ
    }

    // MARK: - Trading Economics import（取り込んだら「指定日1回通知」を積む）
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
            let enc = countries.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? countries

            guard let url = URL(string: "https://api.tradingeconomics.com/calendar/country/\(enc)?c=\(key)&f=json") else {
                indicatorStatus = "URL生成に失敗しました。"
                return
            }

            var req = URLRequest(url: url)
            req.timeoutInterval = 20

            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            let body = String(data: data, encoding: .utf8) ?? ""
            let head = String(body.prefix(260))

            guard (200...299).contains(code) else {
                indicatorStatus = "HTTP \(code)\n\(head)"
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

    private func parseDateFlexible(_ raw: JSONAny?) -> Date? {
        guard let raw else { return nil }

        if let d = raw.asDouble {
            if d >= 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000.0) }
            if d >= 1_000_000_000 { return Date(timeIntervalSince1970: d) }
        }

        guard let s0 = raw.asString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s0.isEmpty else { return nil }

        if s0.hasPrefix("/Date("),
           let close = s0.firstIndex(of: ")") {
            let inside = String(s0[s0.index(s0.startIndex, offsetBy: 6)..<close])
            if let ms = Double(inside) { return Date(timeIntervalSince1970: ms / 1000.0) }
        }

        if let num = Double(s0) {
            if num >= 1_000_000_000_000 { return Date(timeIntervalSince1970: num / 1000.0) }
            if num >= 1_000_000_000 { return Date(timeIntervalSince1970: num) }
        }

        let isoA = ISO8601DateFormatter()
        isoA.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoA.date(from: s0) { return d }

        let isoB = ISO8601DateFormatter()
        isoB.formatOptions = [.withInternetDateTime]
        if let d = isoB.date(from: s0) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Tokyo")

        for f in ["yyyy-MM-dd'T'HH:mm:ss","yyyy-MM-dd HH:mm:ss","yyyy-MM-dd'T'HH:mm","yyyy-MM-dd HH:mm"] {
            df.dateFormat = f
            if let d = df.date(from: s0) { return d }
        }
        return nil
    }

    @MainActor
    private func applyTEEventsToReminders(_ events: [TECalendarEvent]) async {
        let now = Date()

        var calTokyo = Calendar.current
        calTokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current

        let preview = events.prefix(3).map { e in
            let ds = e.dateString ?? "nil"
            let imp = e.importanceInt.map(String.init) ?? "nil"
            return "Date=\(ds), Importance=\(imp)"
        }.joined(separator: "\n")

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

            guard releaseDate >= now else { continue }
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
            item.hour = hour; item.minute = minute
            item.text = text
            item.recurrence = "once"
            item.year = y; item.month = m; item.day = d
            item.source = "te"
            item.externalId = e.CalendarID

            current.append(item)
            addedCount += 1
        }

        setReminders(current) // ←保存＋再スケジュール

        indicatorStatus =
        """
        取得完了：\(addedCount)件
        受信：\(total)件 / 重要度>=\(teMinImportance)：\(minImpCount)件
        日付パース成功：\(dateParsedCount)件 / 未来：\(futureCount)件

        ▼受信プレビュー（先頭3件）
        \(preview)
        """
    }

    // MARK: - Clock/Progress
    private func updateClock(_ date: Date) {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        clockText = String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func updateProgressBars(hour: Int, minute: Int, second: Int) {
        let currentSec = hour * 3600 + minute * 60 + second
        var dict: [Int: Double] = [:]
        let table: [(Int, Bool)] = [(1,on1),(5,on5),(15,on15),(30,on30),(60,on60),(240,on240),(480,on480)]
        for (intervalMin, isOn) in table where isOn {
            let intervalSec = intervalMin * 60
            let elapsed = currentSec % intervalSec
            dict[intervalMin] = Double(elapsed) / Double(intervalSec)
        }
        progress = dict
    }

    private func selectInterval(hour: Int, minute: Int, includeOne: Bool) -> Int? {
        if minute == 0 {
            if hour % 8 == 0 && on480 { return 480 }
            if hour % 4 == 0 && on240 { return 240 }
            if on60 { return 60 }
        }
        if minute % 30 == 0 && on30 { return 30 }
        if minute % 15 == 0 && on15 { return 15 }
        if minute % 5  == 0 && on5  { return 5  }
        if includeOne && on1 { return 1 }
        return nil
    }

    // MARK: - Output
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

    // フォアグラウンド通知で呼ぶために public ラッパ
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
