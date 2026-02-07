//
//  IntervalManager.swift
//  FxTimer
//

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
        static let warningRulesJson = "warningRulesJson"
        static let warningSpeakEnabled = "warningSpeakEnabled"

        // Trading Economics
        static let teApiKey = "teApiKey"
        static let teAutoImport = "teAutoImportEnabled"
        static let teCountries = "teCountries" // 例: "United States,Japan"
    }

    //==== ユーザ設定 ----------------------------------------------------------
    @AppStorage(Keys.beep) var enableBeep = true
    @AppStorage(Keys.vib)  var enableVibration = false
    @AppStorage(Keys.noti) var enableNotification = true // ローカル通知方式を使う
    @AppStorage(Keys.bg)   var enableBG = false

    @AppStorage(Keys.m1)  var on1  = true
    @AppStorage(Keys.m5)  var on5  = true
    @AppStorage(Keys.m15) var on15 = true
    @AppStorage(Keys.m30) var on30 = true
    @AppStorage(Keys.h1)  var on60 = true
    @AppStorage(Keys.h4)  var on240 = true
    @AppStorage(Keys.h8)  var on480 = true

    @AppStorage(Keys.s30)  var announce30Sec = false
    @AppStorage(Keys.lang) var lang = "ja"

    // お知らせ保存（JSON）
    @AppStorage(Keys.remindersJson) private var remindersJson: String = "[]"
    @AppStorage(Keys.reminderAlarm) var reminderAlarmEnabled: Bool = true
    @AppStorage(Keys.reminderSpeak) var reminderSpeakEnabled: Bool = true
    @AppStorage(Keys.warningRulesJson) private var warningRulesJson: String = "[]"
    @AppStorage(Keys.warningSpeakEnabled) var warningSpeakEnabled: Bool = true

    // Trading Economics（アプリ内保存）
    @AppStorage(Keys.teApiKey) var teApiKey: String = ""
    @AppStorage(Keys.teAutoImport) var teAutoImportEnabled: Bool = false
    @AppStorage(Keys.teCountries) var teCountries: String = "United States,Japan"

    //==== UI バインディング ---------------------------------------------------
    @Published var status    = "停止中"
    @Published var isRunning = false
    @Published var clockText = "--:--:--"
    /// <分数:Int, 経過率 0.0‥1.0:Double>
    @Published var progress: [Int: Double] = [:]
    @Published var warningText: String = ""

    // Trading Economics 取得状況（SettingsView で表示）
    @Published var indicatorStatus: String = ""

    //==== 内部状態 ------------------------------------------------------------
    private var timer: DispatchSourceTimer?
    private var warningTimer: DispatchSourceTimer?
    private let speech = AVSpeechSynthesizer()
    private var silentPlayer: AVAudioPlayer?
    private let chimeSoundID: SystemSoundID = 1060
    private var lastCountdownSec: Int?
    private var isEnglish: Bool { lang == "en" }
    private var activeWarningRuleIDs: Set<UUID> = []

    init() {
        startWarningMonitor()
        updateWarningState(now: Date())
    }

    // MARK: - 制御 ------------------------------------------------------------
    func start() {
        stop()
        prepareBackgroundAudio()
        status = "待機中"
        isRunning = true

        // 秒境界に合わせてタイマーを始動
        let now        = Date()
        let nanosecond = Calendar.current.component(.nanosecond, from: now)
        let delayNsec  = 1_000_000_000 - nanosecond
        let startTime  = DispatchTime.now() + .nanoseconds(delayNsec)

        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: startTime, repeating: .seconds(1), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        // 起動中だけでも「前面通知＋読み上げ」を成功させたいので、先に通知を再作成
        rebuildLocalNotificationsNext120Days()

        if teAutoImportEnabled { Task { await importHighImportanceIndicators30MinBefore() } }
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - お知らせ（読み書き） -------------------------------------------
    func getReminders() -> [ReminderItem] {
        guard let data = remindersJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ReminderItem].self, from: data)) ?? []
    }

    func setReminders(_ items: [ReminderItem]) {
        if let data = try? JSONEncoder().encode(items), let str = String(data: data, encoding: .utf8) { remindersJson = str }
    }

    // MARK: - 警告時間帯（読み書き） ---------------------------------------
    func getWarningRules() -> [QuietTimeWarningRule] {
        guard let data = warningRulesJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([QuietTimeWarningRule].self, from: data)) ?? []
    }

    func setWarningRules(_ items: [QuietTimeWarningRule]) {
        if let data = try? JSONEncoder().encode(items), let str = String(data: data, encoding: .utf8) {
            warningRulesJson = str
        }
        updateWarningState(now: Date())
    }

    // MARK: - tick ------------------------------------------------------------
    private func tick() {
        let now = Date()
        updateClock(now)

        let cal  = Calendar.current
        let sec  = cal.component(.second, from: now)
        let min  = cal.component(.minute, from: now)
        let hour = cal.component(.hour,   from: now)

        updateProgressBars(hour: hour, minute: min, second: sec)
        let didSpeakWarning = updateWarningState(now: now)

        switch sec {
        case 30:
            if announce30Sec, !didSpeakWarning { speakPublic(isEnglish ? "thirty seconds" : "30秒") }

        case 45: // 15 秒前（1分足は除外）
            let upcomingMin  = (min + 1) % 60
            let upcomingHour = (upcomingMin == 0) ? (hour + 1) % 24 : hour
            if !didSpeakWarning,
               let interval = selectInterval(hour: upcomingHour, minute: upcomingMin, includeOne: false) {
                announceAhead(interval)
            }

        case 55...59: // 5 秒カウントダウン
            guard lastCountdownSec != sec else { return }
            lastCountdownSec = sec
            if !didSpeakWarning,
               selectInterval(hour: hour, minute: min, includeOne: true) != nil {
                speakCountdown(60 - sec)
            }

        case 0: // 足確定
            lastCountdownSec = nil
            if let interval = selectInterval(hour: hour, minute: min, includeOne: true) { playChime(interval) }

        default:
            break
        }
    }

    // MARK: - 警告時間帯 ----------------------------------------------------
    private func startWarningMonitor() {
        guard warningTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        t.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self, !self.isRunning else { return }
            self.updateWarningState(now: Date())
        }
        t.resume()
        warningTimer = t
    }

    @discardableResult
    private func updateWarningState(now: Date, allowSpeak: Bool = true) -> Bool {
        let activeItems = getWarningRules()
            .filter { $0.enabled }
            .filter { $0.contains(date: now) }

        let activeIDs = Set(activeItems.map { $0.id })
        let entering = activeItems.filter { !activeWarningRuleIDs.contains($0.id) }
        activeWarningRuleIDs = activeIDs

        warningText = activeItems.map { warningLabel(for: $0) }.joined(separator: "\n")

        guard allowSpeak, warningSpeakEnabled, !entering.isEmpty else { return false }
        let speakText = entering.map { warningLabel(for: $0) }.joined(separator: "、")
        if !speakText.isEmpty {
            speakPublic(speakText)
        }
        return !speakText.isEmpty
    }

    private func warningLabel(for item: QuietTimeWarningRule) -> String {
        let trimmed = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "警告" : trimmed
    }

    // MARK: - 時計/進捗 ------------------------------------------------------
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

    // MARK: - 出力 -----------------------------------------------------------
    private func intervalLabel(_ value: Int) -> String {
        switch value {
        case 480: return isEnglish ? "8-hour bar"  : "8時間足"
        case 240: return isEnglish ? "4-hour bar"  : "4時間足"
        case  60: return isEnglish ? "1-hour bar"  : "1時間足"
        default:  return isEnglish ? "\(value)-min bar" : "\(value)分足"
        }
    }

    private func announceAhead(_ interval: Int) {
        let text = isEnglish ? "In 15 seconds,\n\(intervalLabel(interval))\nwill close." : "まもなく\n\(intervalLabel(interval))\nが確定します。"
        status = text
        vibrateIfNeeded()
        notifyIfNeeded(text)
        speakPublic(text)
    }

    private func playChime(_ interval: Int) {
        if enableBeep { AudioServicesPlaySystemSound(chimeSoundID) }
        vibrateIfNeeded()
        status = isEnglish ? "\(intervalLabel(interval))\nclosed." : "\(intervalLabel(interval))\nが確定しました。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in if self?.isRunning == true { self?.status = "" } }
    }

    private func speakCountdown(_ value: Int) {
        status = " \(value) "
        speakPublic("\(value)")
    }

    // 外部（App / Settings / 通知処理）から呼べる読み上げ
    func speakPublic(_ text: String) {
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: isEnglish ? "en-US" : "ja-JP")
        utt.rate  = 0.45
        speech.speak(utt)
    }

    func playFeedback(text: String) {
        AudioServicesPlaySystemSound(1104)
        speakPublic(text)
    }

    private func vibrateIfNeeded() {
        if enableVibration { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
    }

    private func notifyIfNeeded(_ text: String) {
        guard enableNotification else { return }
        // ここは「足確定」の即時通知用途（1秒後）
        let c = UNMutableNotificationContent(); c.title = text; c.sound = .default
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

    // MARK: - ローカル通知（お知らせ） --------------------------------------
    func rebuildLocalNotificationsNext120Days() { rebuildLocalNotifications(days: 120) }

    func rebuildLocalNotifications(days: Int) {
        guard enableNotification else { indicatorStatus = "通知がOFFのため作成しませんでした。"; return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: pendingReminderIdentifiers())

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: now) ?? now
        let reminders = getReminders().filter { $0.enabled }
        if reminders.isEmpty { indicatorStatus = "通知作成：0件（お知らせが有効になっていません）"; return }

        let fireDates = buildOccurrences(reminders: reminders, start: now, end: end)
        var requests: [UNNotificationRequest] = []

        for (item, date) in fireDates {
            let id = reminderRequestId(itemId: item.id, date: date)
            let c = UNMutableNotificationContent()
            c.title = item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "お知らせ" : item.text
            c.body = ""
            c.sound = reminderAlarmEnabled ? .default : nil
            let comps = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            requests.append(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
        }

        // まとめて登録
        for r in requests { center.add(r) }
        indicatorStatus = "通知を作成しました：\(requests.count)件（\(days)日分）"
    }

    private func pendingReminderIdentifiers() -> [String] {
        // まとめて削除したいので prefix を使う（iOS API は prefix delete が無い → ここでは固定リストは作れない）
        // 代替：全件 removePending を使うと他通知も消えるので避ける。
        // ここでは「識別子が分からない」問題を回避するため、基本は rebuild で add だけ。削除は Settings 側で removeAllPending を使う設計にするのが安全。
        // 今回は「FxTimer.reminder." で始まるID」を自前で再生成できないため、空で返す。
        return []
    }

    private func reminderRequestId(itemId: UUID, date: Date) -> String {
        // date を "yyyyMMddHHmm" にして一意化（同一itemでも複数回）
        let df = DateFormatter(); df.dateFormat = "yyyyMMddHHmm"; df.timeZone = .current
        return "FxTimer.reminder.\(itemId.uuidString).\(df.string(from: date))"
    }

    private func buildOccurrences(reminders: [ReminderItem], start: Date, end: Date) -> [(ReminderItem, Date)] {
        var cal = Calendar.current
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current

        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var day = startDay
        var out: [(ReminderItem, Date)] = []

        // weekly の週番号アンカー
        let baseWeek = cal.component(.weekOfYear, from: startDay)
        let baseWeekYear = cal.component(.yearForWeekOfYear, from: startDay)

        while day <= endDay {
            for item in reminders {
                if let fire = match(rule: item.rule, item: item, day: day, calendar: cal, baseWeek: baseWeek, baseWeekYear: baseWeekYear, start: start, end: end) { out.append((item, fire)) }
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        }

        // start以降のみに絞る
        return out.filter { $0.1 >= start && $0.1 <= end }.sorted { $0.1 < $1.1 }
    }

    private func match(rule: ReminderRule, item: ReminderItem, day: Date, calendar cal: Calendar, baseWeek: Int, baseWeekYear: Int, start: Date, end: Date) -> Date? {
        // day は startOfDay
        func atTime(_ d: Date) -> Date? {
            var comp = cal.dateComponents([.year,.month,.day], from: d)
            comp.hour = item.hour
            comp.minute = item.minute
            comp.second = 0
            return cal.date(from: comp)
        }

        switch rule {
        case .daily:
            return atTime(day)

        case .weekly(let weekdays, let intervalWeeks):
            let wd = cal.component(.weekday, from: day) // 1..7
            guard weekdays.contains(wd) else { return nil }
            let wk = cal.component(.weekOfYear, from: day)
            let wkYear = cal.component(.yearForWeekOfYear, from: day)
            let delta = weekIndex(week: wk, year: wkYear) - weekIndex(week: baseWeek, year: baseWeekYear)
            guard intervalWeeks <= 1 || (delta % intervalWeeks == 0) else { return nil }
            return atTime(day)

        case .monthlyDay(let days):
            let dd = cal.component(.day, from: day)
            guard days.contains(dd) else { return nil }
            return atTime(day)

        case .monthlyNth(let weekday, let nth):
            guard nth >= 1 && nth <= 4 else { return nil }
            let ym = cal.dateComponents([.year,.month], from: day)
            guard let first = cal.date(from: DateComponents(year: ym.year, month: ym.month, day: 1)) else { return nil }
            guard let targetDay = nthWeekdayDate(of: first, weekday: weekday, nth: nth, calendar: cal) else { return nil }
            return cal.isDate(day, inSameDayAs: targetDay) ? atTime(day) : nil

        case .monthlyLast(let weekday):
            let ym = cal.dateComponents([.year,.month], from: day)
            guard let first = cal.date(from: DateComponents(year: ym.year, month: ym.month, day: 1)) else { return nil }
            guard let last = lastWeekdayDate(of: first, weekday: weekday, calendar: cal) else { return nil }
            return cal.isDate(day, inSameDayAs: last) ? atTime(day) : nil

        case .once(let dateISO):
            guard let d = parseISO(dateISO) else { return nil }
            // d の日付部分で一致させる
            return cal.isDate(day, inSameDayAs: d) ? d : nil
        }
    }

    private func weekIndex(week: Int, year: Int) -> Int { year * 100 + week }

    private func nthWeekdayDate(of firstDayOfMonth: Date, weekday: Int, nth: Int, calendar cal: Calendar) -> Date? {
        // firstDayOfMonth は月初
        var first = firstDayOfMonth
        let firstW = cal.component(.weekday, from: first)
        let diff = (weekday - firstW + 7) % 7
        first = cal.date(byAdding: .day, value: diff, to: first) ?? first
        return cal.date(byAdding: .day, value: 7 * (nth - 1), to: first)
    }

    private func lastWeekdayDate(of firstDayOfMonth: Date, weekday: Int, calendar cal: Calendar) -> Date? {
        var comp = cal.dateComponents([.year,.month], from: firstDayOfMonth)
        comp.month = (comp.month ?? 1) + 1
        comp.day = 1
        guard let firstOfNext = cal.date(from: comp) else { return nil }
        guard let lastDay = cal.date(byAdding: .day, value: -1, to: firstOfNext) else { return nil }
        var d = lastDay
        while cal.component(.weekday, from: d) != weekday {
            guard let prev = cal.date(byAdding: .day, value: -1, to: d) else { break }
            d = prev
        }
        return d
    }

    private func parseISO(_ iso: String) -> Date? {
        let s = iso.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let isoA = ISO8601DateFormatter(); isoA.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoA.date(from: s) { return d }
        let isoB = ISO8601DateFormatter(); isoB.formatOptions = [.withInternetDateTime]
        return isoB.date(from: s)
    }

    // MARK: - Trading Economics（自動取得→once通知に落とす） -----------------
    func importHighImportanceIndicators30MinBefore() async {
        let key = teApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { indicatorStatus = "APIキーが未設定です。"; return }
        indicatorStatus = "取得中..."
        do {
            let countriesRaw = teCountries.trimmingCharacters(in: .whitespacesAndNewlines)
            let countries = countriesRaw.isEmpty ? "United States,Japan" : countriesRaw
            let encCountries = countries.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? countries
            guard let url = URL(string: "https://api.tradingeconomics.com/calendar/country/\(encCountries)?c=\(key)&f=json") else { indicatorStatus = "URL生成に失敗"; return }
            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if !(200...299).contains(code) {
                let head = String((String(data: data, encoding: .utf8) ?? "").prefix(240))
                indicatorStatus = "HTTP \(code)\n\(head)"
                return
            }
            if let events = try? JSONDecoder().decode([TECalendarEvent].self, from: data) { await applyTEEventsToReminders(events); return }
            if let apiErr = try? JSONDecoder().decode(TEApiError.self, from: data) { indicatorStatus = "APIエラー\n\(apiErr.error ?? apiErr.message ?? "不明")"; return }
            let head = String((String(data: data, encoding: .utf8) ?? "").prefix(240))
            indicatorStatus = "形式不一致\n\(head)"
        } catch {
            indicatorStatus = "取得に失敗：\(error.localizedDescription)"
        }
    }

    private func applyTEEventsToReminders(_ events: [TECalendarEvent]) async {
        // ここでは free 制限などで 403 が起きることが多いので、成功時だけ once を作成
        let now = Date()
        var calTokyo = Calendar.current
        calTokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current

        // 自動取り込みは入れ替え
        var current = getReminders()
        current.removeAll { $0.source == "te" }

        var added = 0
        for e in events {
            guard e.importanceInt == 3 else { continue }
            guard let release = parseDateFlexible(e.DateRaw) else { continue }
            if release < now { continue }
            guard let alert = calTokyo.date(byAdding: .minute, value: -30, to: release) else { continue }
            var item = ReminderItem()
            item.enabled = true
            item.hour = calTokyo.component(.hour, from: alert)
            item.minute = calTokyo.component(.minute, from: alert)
            let country = (e.Country ?? "")
            let title = (e.Event ?? e.Category ?? "指標")
            item.text = "【\(country)】\(title)（30分前）"
            item.rule = .once(dateISO: isoString(release))
            item.source = "te"
            item.externalId = e.CalendarID
            current.append(item)
            added += 1
        }

        setReminders(current)
        rebuildLocalNotificationsNext120Days()
        indicatorStatus = "TE取り込み：\(added)件（重要度=3のみ）"
    }

    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private func parseDateFlexible(_ raw: JSONAny?) -> Date? {
        guard let raw else { return nil }
        if let d = raw.asDouble {
            if d >= 1_000_000_000_000 { return Date(timeIntervalSince1970: d / 1000.0) }
            if d >= 1_000_000_000 { return Date(timeIntervalSince1970: d) }
        }
        guard let s0 = raw.asString?.trimmingCharacters(in: .whitespacesAndNewlines), !s0.isEmpty else { return nil }
        if s0.hasPrefix("/Date("), let close = s0.firstIndex(of: ")") {
            let inside = String(s0[s0.index(s0.startIndex, offsetBy: 6)..<close])
            if let ms = Double(inside) { return Date(timeIntervalSince1970: ms / 1000.0) }
        }
        if let num = Double(s0) {
            if num >= 1_000_000_000_000 { return Date(timeIntervalSince1970: num / 1000.0) }
            if num >= 1_000_000_000 { return Date(timeIntervalSince1970: num) }
        }
        let isoA = ISO8601DateFormatter(); isoA.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoA.date(from: s0) { return d }
        let isoB = ISO8601DateFormatter(); isoB.formatOptions = [.withInternetDateTime]
        if let d = isoB.date(from: s0) { return d }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "Asia/Tokyo")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let d = df.date(from: s0) { return d }
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: s0)
    }
}
