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

    @State private var reminders: [ReminderItem] = []
    @State private var editingItem: ReminderItem? = nil
    @State private var isAdding: Bool = false

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

            // ✅ ここが追加：プリセット（目安テンプレ）
            Section("目安テンプレ（プリセット）") {
                Button { mgr.addPresetTemplates(); reminders = mgr.getReminders() } label: {
                    Label("CPI / 小売売上高 / コアPCE / 雇用統計 を追加（OFFで登録）", systemImage: "tray.and.arrow.down")
                }

                Button(role: .destructive) { mgr.removePresetTemplates(); reminders = mgr.getReminders() } label: {
                    Label("目安テンプレを全削除", systemImage: "trash")
                }

                Text("※ 発表時刻は月ごとに変動するため、まずOFFで登録し、時刻を編集してONにして使ってください。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("お知らせ") {
                Toggle("ポップアップ時にアラーム音", isOn: $reminderAlarmEnabled)
                Toggle("お知らせ内容を読み上げる", isOn: $reminderSpeakEnabled)

                if reminders.isEmpty {
                    Text("まだ登録がありません。下の「追加」で登録してください。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    let sorted = reminders.sorted(by: { ($0.hour, $0.minute) < ($1.hour, $1.minute) })
                    ForEach(sorted) { item in
                        Button { editingItem = item } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.timeText).font(.headline)
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

                Button { isAdding = true } label: {
                    Label("追加", systemImage: "plus")
                }

                Text("※ メイン画面のスタートボタンの上に表示（自動消去、タップで消去）。")
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

                Toggle("スタート時に自動で取り込む", isOn: $teAutoImportEnabled)

                Button { Task { await mgr.importHighImportanceIndicators30MinBefore() } } label: {
                    Label("取得して30分前通知に登録（重要度フィルタ適用）", systemImage: "arrow.down.circle")
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
        let sorted = reminders.sorted(by: { ($0.hour, $0.minute) < ($1.hour, $1.minute) })
        let idsToDelete = offsets.map { sorted[$0].id }
        reminders.removeAll { idsToDelete.contains($0.id) }
    }
}
