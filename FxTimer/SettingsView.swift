import SwiftUI

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

            Section("お知らせ（ローカル通知）") {
                Toggle("通知音（デフォルト）", isOn: $reminderAlarmEnabled)
                    .onChange(of: reminderAlarmEnabled) { _, _ in mgr.rescheduleAllLocalNotifications() }

                Toggle("前面表示時に読み上げる", isOn: $reminderSpeakEnabled)

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

                Button {
                    mgr.addPresets()
                    reminders = mgr.getReminders()
                } label: {
                    Label("プリセットを追加（NFP/週次失業保険など）", systemImage: "sparkles")
                }

                Button {
                    mgr.rescheduleAllLocalNotifications()
                } label: {
                    Label("通知を再スケジュール", systemImage: "arrow.clockwise")
                }

                Text("※ 隔週・数週ごとは先の数週間分を自動で積むため、時々「再スケジュール」すると安全です。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("指標発表（Trading Economics）") {
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
                .onChange(of: teMinImportance) { _, _ in
                    // 次回取り込みに反映
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

    private func wdText(_ w: Int) -> String {
        let map: [Int:String] = [1:"日",2:"月",3:"火",4:"水",5:"木",6:"金",7:"土"]
        return map[w] ?? "\(w)"
    }

    private func recurrenceLabel(_ item: ReminderItem) -> String {
        switch item.recurrence {
        case "once":
            return "1回だけ: \(item.dateTextForOnce ?? "未設定")"
        case "daily":
            return "毎日"
        case "weekly":
            return "毎週: \(wdText(item.weekday ?? 2))"
        case "weeklyN":
            let interval = item.weekInterval ?? 2
            let base = (interval == 2) ? "隔週" : "\(interval)週ごと"
            return "\(base): \(wdText(item.weekday ?? 6))"
        case "monthlyDay":
            return "毎月: \(item.dayOfMonth ?? 1)日"
        case "monthlyNthWeekday":
            let nth = item.nthWeek ?? 1
            let nthText: String = (nth == -1) ? "最終" : "第\(nth)"
            return "\(nthText)\(wdText(item.weekday ?? 6))"
        default:
            return "毎日"
        }
    }
}
