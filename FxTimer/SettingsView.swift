import SwiftUI

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

    // お知らせ
    @AppStorage(IntervalManager.Keys.reminderAlarm) var reminderAlarmEnabled = true
    @AppStorage(IntervalManager.Keys.reminderSpeak) var reminderSpeakEnabled = true

    // Trading Economics
    @AppStorage(IntervalManager.Keys.teApiKey) var teApiKey: String = ""
    @AppStorage(IntervalManager.Keys.teAutoImport) var teAutoImportEnabled: Bool = false
    @AppStorage(IntervalManager.Keys.teCountries) var teCountries: String = "United States,Japan"
    @AppStorage(IntervalManager.Keys.teKeywordCsv) var teKeywordCsv: String = "NFP,CPI,Retail Sales,Core PCE,FOMC,Unemployment Rate,ISM"
    @AppStorage(IntervalManager.Keys.teImportanceFilter) private var teImportanceRaw: Int = 3

    @State private var reminders: [ReminderItem] = []
    @State private var editingItem: ReminderItem? = nil
    @State private var isAdding: Bool = false


    private let indicatorPresets: [(String, String)] = [
        ("雇用統計(NFP)", "NFP"),
        ("消費者物価指数(CPI)", "CPI"),
        ("小売売上高", "Retail Sales"),
        ("コアPCE", "Core PCE"),
        ("FOMC/政策金利", "FOMC"),
        ("失業率", "Unemployment Rate"),
        ("ISM", "ISM")
    ]

    private var importanceBinding: Binding<ImportanceFilter> {
        Binding(
            get: { ImportanceFilter(rawValue: teImportanceRaw) ?? .highOnly },
            set: { teImportanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("効果音・通知") {
                Toggle("チャイム音 (1013)", isOn: $enableBeep)
                Toggle("振動",            isOn: $enableVibration)
                Toggle("ローカル通知（足確定）",    isOn: $enableNotification)
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

            Section("お知らせ（ローカル通知）") {
                Toggle("通知音を鳴らす", isOn: $reminderAlarmEnabled)
                Toggle("通知内容を読み上げる（前面表示時）", isOn: $reminderSpeakEnabled)

                if reminders.isEmpty {
                    Text("まだ登録がありません。下の「追加」で登録してください。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    let sorted = reminders.sorted(by: sortKey)
                    ForEach(sorted) { item in
                        Button {
                            editingItem = item
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(item.timeText)  \(ruleLabel(item.rule))")
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

                Button { isAdding = true } label: {
                    Label("追加", systemImage: "plus")
                }

                Button {
                    mgr.rescheduleAllLocalNotifications()
                } label: {
                    Label("通知を再作成（120日分）", systemImage: "arrow.clockwise")
                }
                .font(.subheadline)
            }

            Section("指標発表（Trading Economics）") {
                TextField("Trading Economics APIキー（c=...）", text: $teApiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                TextField("国（例: United States,Japan）", text: $teCountries)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                Picker("重要度フィルタ", selection: importanceBinding) {
                    ForEach(ImportanceFilter.allCases) { f in
                        Text(f.title).tag(f)
                    }
                }

                

                DisclosureGroup("重要指標プリセット（キーワード）") {
                    ForEach(indicatorPresets, id: \.1) { (label, kw) in
                        Toggle(label, isOn: Binding(
                            get: {
                                let set = Set(teKeywordCsv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                                return set.contains(kw.lowercased())
                            },
                            set: { on in
                                var set = Set(teKeywordCsv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                                if on { set.insert(kw) } else { set.remove(kw) }
                                teKeywordCsv = set.sorted().joined(separator: ",")
                            }
                        ))
                    }

                    Button {
                        teKeywordCsv = indicatorPresets.map { $0.1 }.joined(separator: ",")
                    } label: {
                        Text("全部ON")
                    }
                    .font(.subheadline)

                    Button {
                        teKeywordCsv = ""
                    } label: {
                        Text("全部OFF（=全指標）")
                    }
                    .font(.subheadline)

                    Text("※ ここでONにしたキーワードを含む指標だけを登録します。\n　空にすると国の全指標が対象になります（多すぎる場合があります）。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("スタート時に自動で取り込む", isOn: $teAutoImportEnabled)

                Button {
                    Task { await mgr.importTE_USJP_30MinBefore() }
                } label: {
                    Label("取得して30分前の通知に登録", systemImage: "arrow.down.circle")
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
        .onAppear {
            reminders = mgr.getReminders()
            mgr.rescheduleAllLocalNotifications()
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
                onSave: { newItem in reminders.append(newItem) },
                onDelete: nil
            )
        }
    }

    private func sortKey(_ a: ReminderItem, _ b: ReminderItem) -> Bool {
        if a.hour != b.hour { return a.hour < b.hour }
        if a.minute != b.minute { return a.minute < b.minute }
        return a.text < b.text
    }

    private func delete(at offsets: IndexSet) {
        let sorted = reminders.sorted(by: sortKey)
        let idsToDelete = offsets.map { sorted[$0].id }
        reminders.removeAll { idsToDelete.contains($0.id) }
    }

    private func ruleLabel(_ r: ReminderRule) -> String {
        switch r {
        case .daily:
            return "毎日"
        case .weekly(let wds):
            return "毎週 " + wds.map(weekdayLabel).joined(separator: ",")
        case .biweekly(let wds, _):
            return "隔週 " + wds.map(weekdayLabel).joined(separator: ",")
        case .monthlyDay(let d):
            return "毎月 \(d)日"
        case .monthlyNthWeekday(let nth, let wd):
            let nthText = (nth == -1) ? "最終" : "第\(nth)"
            return "毎月 \(nthText)\(weekdayLabel(wd))"
        case .oneTime(let y, let m, let d):
            return "\(y)/\(m)/\(d)"
        }
    }

    private func weekdayLabel(_ w: Int) -> String {
        // 1=Sun ... 7=Sat
        switch w {
        case 1: return "日"
        case 2: return "月"
        case 3: return "火"
        case 4: return "水"
        case 5: return "木"
        case 6: return "金"
        case 7: return "土"
        default: return "?"
        }
    }
}
