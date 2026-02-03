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
    var hour: Int = 9
    var minute: Int = 0
    var text: String = "お知らせ"

    var timeText: String { String(format: "%02d:%02d", hour, minute) }
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

        // ★ お知らせ（複数）
        static let remindersJson = "remindersJson"
        static let reminderAlarm = "reminderAlarmEnabled"

        // ★ お知らせ読み上げ
        static let reminderSpeak = "reminderSpeakEnabled"
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

    // ★ お知らせ保存（JSON）
    @AppStorage(Keys.remindersJson) private var remindersJson: String = "[]"
    // ★ お知らせアラーム音
    @AppStorage(Keys.reminderAlarm) var reminderAlarmEnabled: Bool = true
    // ★ お知らせ読み上げ
    @AppStorage(Keys.reminderSpeak) var reminderSpeakEnabled: Bool = true

    //==== UI バインディング ---------------------------------------------------
    @Published var status    = "停止中"
    @Published var isRunning = false
    @Published var clockText = "--:--:--"        // デジタル時計
    /// <分数:Int, 経過率 0.0‥1.0:Double>
    @Published var progress: [Int: Double] = [:]

    // ★ お知らせ表示（バナー）
    @Published var reminderBannerText: String = ""
    @Published var isReminderVisible: Bool = false

    //==== 内部状態 ------------------------------------------------------------
    private var timer: DispatchSourceTimer?
    private let speech = AVSpeechSynthesizer()
    private var silentPlayer: AVAudioPlayer?
    private let chimeSoundID: SystemSoundID = 1060
    private var lastCountdownSec: Int?
    private var isEnglish: Bool { lang == "en" }

    // ★ お知らせ重複発火防止（同一分・同一ID）
    private var firedReminderKeys = Set<String>()

    // ★ お知らせアラーム音（SystemSound）
    private let reminderSoundID: SystemSoundID = 1005

    // MARK: - お知らせ（読み書き）
    func getReminders() -> [ReminderItem] {
        guard let data = remindersJson.data(using: .utf8) else { return [] }
        if let decoded = try? JSONDecoder().decode([ReminderItem].self, from: data) {
            return decoded
        }
        return []
    }

    func setReminders(_ items: [ReminderItem]) {
        if let data = try? JSONEncoder().encode(items),
           let str = String(data: data, encoding: .utf8) {
            remindersJson = str
        }
    }

    // MARK: - 制御 ------------------------------------------------------------
    func start() {
        stop()                                   // 二重起動防止
        prepareBackgroundAudio()
        status = "待機中"
        isRunning = true

        // 秒境界に合わせてタイマーを始動
        let now        = Date()
        let nanosecond = Calendar.current.component(.nanosecond, from: now)
        let delayNsec  = 1_000_000_000 - nanosecond
        let startTime  = DispatchTime.now() + .nanoseconds(delayNsec)

        timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer?.schedule(deadline: startTime,
                        repeating: .seconds(1),
                        leeway: .milliseconds(1))
        timer?.setEventHandler { [weak self] in self?.tick() }
        timer?.resume()
    }

    func stop() {
        timer?.cancel(); timer = nil
        silentPlayer?.stop(); silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
        status = "停止中"
        lastCountdownSec = nil
        // お知らせ表示は止めても残して良いので消さない
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - タイマーチック --------------------------------------------------
    private func tick() {
        let now = Date()
        updateClock(now)

        let cal  = Calendar.current
        let sec  = cal.component(.second, from: now)
        let min  = cal.component(.minute, from: now)
        let hour = cal.component(.hour,   from: now)

        updateProgressBars(hour: hour, minute: min, second: sec)

        // ★ お知らせチェック（複数）
        checkReminders(now: now, hour: hour, minute: min, second: sec)

        switch sec {
        case 30:
            if announce30Sec {
                speak(isEnglish ? "thirty seconds" : "30秒")
            }

        case 45: // 15 秒前（1分足は対象外）
            let upcomingMin  = (min + 1) % 60
            let upcomingHour = (upcomingMin == 0) ? (hour + 1) % 24 : hour
            if let interval = selectInterval(hour: upcomingHour,
                                             minute: upcomingMin,
                                             includeOne: false) {
                announceAhead(interval)
            }

        case 55...59: // 5 秒カウントダウン（1分足含む）
            guard lastCountdownSec != sec else { return }
            lastCountdownSec = sec
            if selectInterval(hour: hour, minute: min, includeOne: true) != nil {
                speakCountdown(60 - sec)
            }

        case 0: // 足確定（1分足含む）
            lastCountdownSec = nil
            if let interval = selectInterval(hour: hour, minute: min, includeOne: true) {
                playChime(interval)
            }

        default: break
        }
    }

    // ★ お知らせ（複数）判定：秒==0で、該当するものを全部発火
    private func checkReminders(now: Date, hour: Int, minute: Int, second: Int) {
        guard second == 0 else { return }

        let reminders = getReminders().filter { $0.enabled }
        guard !reminders.isEmpty else { return }

        // 今日の日付
        let cal = Calendar.current
        let y = cal.component(.year,  from: now)
        let mo = cal.component(.month, from: now)
        let d = cal.component(.day,   from: now)

        // この時刻に一致するお知らせを収集
        let matched = reminders.filter { $0.hour == hour && $0.minute == minute }
        guard !matched.isEmpty else { return }

        // 重複発火防止（同日・同時刻・同ID）
        var fireTexts: [String] = []
        for item in matched {
            let key = String(format: "%04d%02d%02d-%02d%02d-%@",
                             y, mo, d, hour, minute, item.id.uuidString)
            if firedReminderKeys.contains(key) { continue }
            firedReminderKeys.insert(key)

            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            fireTexts.append(t.isEmpty ? "お知らせ" : t)
        }
        guard !fireTexts.isEmpty else { return }

        // キーは増え続けるので、適度に掃除（上限200）
        if firedReminderKeys.count > 200 {
            firedReminderKeys = Set(firedReminderKeys.suffix(120))
        }

        // まとめて表示（複数件なら改行）
        fireReminderBanner(text: fireTexts.joined(separator: "\n"))
    }

    // ★ お知らせ表示 + アラーム音 + 読み上げ
    private func fireReminderBanner(text: String) {
        reminderBannerText = text

        if reminderAlarmEnabled {
            AudioServicesPlaySystemSound(reminderSoundID)
        }

        // ★ 読み上げ（複数件の改行は「。 」に変換）
        if reminderSpeakEnabled {
            let speakText = text
                .replacingOccurrences(of: "\n", with: "。 ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !speakText.isEmpty {
                speak(speakText)
            }
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            isReminderVisible = true
        }

        // 自動消去（30秒）
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isReminderVisible = false
            }
        }
    }

    func dismissReminder() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isReminderVisible = false
        }
    }

    /// 時計用文字列を HH:mm:ss で生成
    private func updateClock(_ date: Date) {
        let cal = Calendar.current
        let h = cal.component(.hour,   from: date)
        let m = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        clockText = String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// 各インターバルの経過率を更新
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

    /// 有効インターバル判定
    private func selectInterval(hour: Int,
                                minute: Int,
                                includeOne: Bool) -> Int? {
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

    // MARK: - 出力処理 --------------------------------------------------------
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
        vibrateIfNeeded(); notifyIfNeeded(text); speak(text)
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
        speak(isEnglish ? "\(value)" : "\(value)")
    }

    // MARK: - ユーティリティ --------------------------------------------------
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
        let r = UNNotificationRequest(identifier: UUID().uuidString,
                                      content: c, trigger: t)
        UNUserNotificationCenter.current().add(r)
    }

    /// 無音ループでバックグラウンド維持
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

// MARK: - UI ------------------------------------------------------------------
struct ContentView: View {
    @EnvironmentObject var mgr: IntervalManager

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    //── ❶ 時計 ＋ プログレスバー（常に最上部） ──
                    VStack(alignment: .center, spacing: 8) {
                        Text(mgr.clockText)
                            .font(.system(size: 60,
                                          weight: .bold,
                                          design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.top, 20)
                            .frame(maxWidth: .infinity,
                                   alignment: .center)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(mgr.progress.keys.sorted(), id: \.self) { key in
                                if let p = mgr.progress[key] {
                                    IntervalProgressBar(minutes: key,
                                                        progress: p)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    Spacer()

                    //── ❸ お知らせ（スタートボタンの上） ─────
                    VStack(spacing: 16) {

                        if mgr.isReminderVisible {
                            Button {
                                mgr.dismissReminder()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "bell.fill")
                                        .font(.title3)
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

                        //── ボタン ＋ 設定リンク（常に最下部） ─────
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

                //──────────────── カウントダウン（中央オーバーレイ） ───────────────
                Group {
                    if mgr.status.starts(with: " ") {
                        Text(mgr.status.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 200,
                                          weight: .bold,
                                          design: .monospaced))
                        + Text(" ")
                            .font(.system(size: 200,
                                          weight: .bold,
                                          design: .monospaced))
                    } else {
                        Text(mgr.status)
                            .font(.system(size: 50,
                                          weight: .medium,
                                          design: .monospaced))
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

// MARK: - お知らせ編集画面
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

    var body: some View {
        NavigationStack {
            Form {
                Section("お知らせ内容") {
                    Toggle("有効", isOn: $item.enabled)
                    DatePicker("時刻", selection: timeBinding, displayedComponents: [.hourAndMinute])
                    TextField("内容", text: $item.text, axis: .vertical)
                        .lineLimit(1...4)
                }

                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Text("削除")
                        }
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
                        onSave(item)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var mgr: IntervalManager

    // 効果音・通知
    @AppStorage(IntervalManager.Keys.beep) var enableBeep = true
    @AppStorage(IntervalManager.Keys.vib)  var enableVibration = false
    @AppStorage(IntervalManager.Keys.noti) var enableNotification = false
    @AppStorage(IntervalManager.Keys.bg)   var enableBG = false

    // 時間足
    @AppStorage(IntervalManager.Keys.m1)   var on1   = true
    @AppStorage(IntervalManager.Keys.m5)   var on5   = true
    @AppStorage(IntervalManager.Keys.m15)  var on15  = true
    @AppStorage(IntervalManager.Keys.m30)  var on30  = true
    @AppStorage(IntervalManager.Keys.h1)   var on60  = true
    @AppStorage(IntervalManager.Keys.h4)   var on240 = true
    @AppStorage(IntervalManager.Keys.h8)   var on480 = true

    @AppStorage(IntervalManager.Keys.s30)  var announce30Sec = false
    @AppStorage(IntervalManager.Keys.lang) var lang = "ja"

    // ★ お知らせアラーム
    @AppStorage(IntervalManager.Keys.reminderAlarm) var reminderAlarmEnabled = true
    // ★ お知らせ読み上げ
    @AppStorage(IntervalManager.Keys.reminderSpeak) var reminderSpeakEnabled = true

    // ★ 複数お知らせ（画面用）
    @State private var reminders: [ReminderItem] = []
    @State private var editingItem: ReminderItem? = nil
    @State private var isAdding: Bool = false

    var body: some View {
        Form {

            Section("効果音・通知") {
                Toggle("チャイム音 (1013)", isOn: $enableBeep)
                Toggle("振動",            isOn: $enableVibration)
                Toggle("ローカル通知",    isOn: $enableNotification)
                Toggle("バックグラウンド動作", isOn: $enableBG)
                Toggle("30秒ごとに『30秒』と読み上げる", isOn: $announce30Sec)
            }

            Section("有効な時間足") {
                Toggle("1 分足",   isOn: $on1)
                Toggle("5 分足",   isOn: $on5)
                Toggle("15 分足",  isOn: $on15)
                Toggle("30 分足",  isOn: $on30)
                Toggle("1 時間足", isOn: $on60)
                Toggle("4 時間足", isOn: $on240)
                Toggle("8 時間足", isOn: $on480)
            }

            // ★ お知らせ（複数）
            Section("お知らせ") {
                Toggle("ポップアップ時にアラーム音", isOn: $reminderAlarmEnabled)
                Toggle("お知らせ内容を読み上げる", isOn: $reminderSpeakEnabled)

                if reminders.isEmpty {
                    Text("まだ登録がありません。下の「追加」で登録してください。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(reminders.sorted(by: { ($0.hour, $0.minute) < ($1.hour, $1.minute) })) { item in
                        Button {
                            editingItem = item
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.timeText)
                                        .font(.headline)
                                    Text(item.text.isEmpty ? "お知らせ" : item.text)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
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

                Button {
                    isAdding = true
                } label: {
                    Label("追加", systemImage: "plus")
                }

                Text("※ メイン画面のスタートボタンの上に表示されます（30秒で自動消去、タップで消去）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        .onAppear {
            reminders = mgr.getReminders()
        }
        .onChange(of: reminders) { _, newValue in
            mgr.setReminders(newValue)
        }
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
                onSave: { newItem in
                    reminders.append(newItem)
                },
                onDelete: nil
            )
        }
    }

    private func delete(at offsets: IndexSet) {
        // 表示順が sort されているので、削除も同じ並びで確定させる
        let sorted = reminders.sorted(by: { ($0.hour, $0.minute) < ($1.hour, $1.minute) })
        let idsToDelete = offsets.map { sorted[$0].id }
        reminders.removeAll { idsToDelete.contains($0.id) }
    }
}

// MARK: - Progress Bar View -----------------------------------------------
struct IntervalProgressBar: View {
    let minutes: Int
    let progress: Double        // 0.0‥1.0

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
            Text(label)
                .font(.caption)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(barColor)
        }
    }
}
