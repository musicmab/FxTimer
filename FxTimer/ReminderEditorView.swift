import SwiftUI

// MARK: - お知らせ編集画面
struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State var item: ReminderItem
    let onSave: (ReminderItem) -> Void
    let onDelete: (() -> Void)?

    // ルール編集用UI状態
    private enum RuleKind: String, CaseIterable, Identifiable {
        case daily
        case weekly
        case monthlyDay
        case monthlyNth
        case monthlyLast
        case once

        var id: String { rawValue }

        var title: String {
            switch self {
            case .daily:      return "毎日"
            case .weekly:     return "毎週 / 隔週"
            case .monthlyDay: return "毎月（○日）"
            case .monthlyNth: return "毎月（第n曜日）"
            case .monthlyLast:return "毎月（最終○曜）"
            case .once:       return "1回のみ（日時）"
            }
        }
    }

    @State private var kind: RuleKind = .daily

    // weekly
    @State private var weeklyIntervalWeeks: Int = 1 // 1=毎週,2=隔週
    @State private var weeklyWeekdays: Set<Int> = [2,3,4,5,6] // デフォルト平日（月〜金）

    // monthlyDay
    @State private var monthlyDaysText: String = "1" // "1,15,30" 形式

    // monthlyNth / monthlyLast
    @State private var nthWeekday: Int = 6 // 金
    @State private var nth: Int = 1        // 第1
    @State private var lastWeekday: Int = 6

    // once
    @State private var onceDate: Date = Date()

    // 時刻編集（hour/minute）
    private var timeBinding: Binding<Date> {
        Binding<Date>(
            get: {
                var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comp.hour = item.hour
                comp.minute = item.minute
                comp.second = 0
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

                    if item.source == "te" {
                        Text("※ Trading Economics から自動生成された項目です。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("繰り返し") {
                    Picker("種類", selection: $kind) {
                        ForEach(RuleKind.allCases) { k in
                            Text(k.title).tag(k)
                        }
                    }

                    ruleDetailEditor
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
                        applyUIToRule()
                        onSave(item)
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadRuleToUI()
            }
        }
    }

    // MARK: - ルール詳細UI
    @ViewBuilder
    private var ruleDetailEditor: some View {
        switch kind {
        case .daily:
            Text("毎日、指定した時刻に通知します。")
                .font(.caption)
                .foregroundColor(.secondary)

        case .weekly:
            Stepper(value: $weeklyIntervalWeeks, in: 1...4, step: 1) {
                Text(weeklyIntervalWeeks == 1 ? "毎週" : "隔週（\(weeklyIntervalWeeks)週ごと）")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("曜日").font(.caption).foregroundColor(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                    ForEach(1...7, id: \.self) { wd in
                        let selected = weeklyWeekdays.contains(wd)
                        Button {
                            if selected { weeklyWeekdays.remove(wd) } else { weeklyWeekdays.insert(wd) }
                        } label: {
                            Text(weekdayShort(wd))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(selected ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("※ 曜日が未選択の場合は保存時に「月〜金」を自動設定します。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)

        case .monthlyDay:
            TextField("日付（例: 1,15,30）", text: $monthlyDaysText)
                .keyboardType(.numbersAndPunctuation)
            Text("※ 1〜31 をカンマ区切りで指定できます。存在しない日（2/30など）は自動でスキップされます。")
                .font(.caption)
                .foregroundColor(.secondary)

        case .monthlyNth:
            Picker("曜日", selection: $nthWeekday) {
                ForEach(1...7, id: \.self) { wd in
                    Text(weekdayLong(wd)).tag(wd)
                }
            }
            Picker("第n", selection: $nth) {
                ForEach(1...4, id: \.self) { n in
                    Text("第\(n)").tag(n)
                }
            }
            Text("例：第1金曜、第3水曜など。")
                .font(.caption)
                .foregroundColor(.secondary)

        case .monthlyLast:
            Picker("曜日", selection: $lastWeekday) {
                ForEach(1...7, id: \.self) { wd in
                    Text(weekdayLong(wd)).tag(wd)
                }
            }
            Text("例：最終金曜など。")
                .font(.caption)
                .foregroundColor(.secondary)

        case .once:
            DatePicker("日時", selection: $onceDate, displayedComponents: [.date, .hourAndMinute])
            Text("※ 1回のみの通知用です（自動取り込みで使います）。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - UI <-> Rule 変換
    private func loadRuleToUI() {
        switch item.rule {
        case .daily:
            kind = .daily

        case .weekly(let weekdays, let intervalWeeks):
            kind = .weekly
            weeklyIntervalWeeks = max(1, intervalWeeks)
            weeklyWeekdays = Set(weekdays.filter { 1...7 ~= $0 })
            if weeklyWeekdays.isEmpty { weeklyWeekdays = [2,3,4,5,6] }

        case .monthlyDay(let days):
            kind = .monthlyDay
            let clean = days.filter { 1...31 ~= $0 }.sorted()
            monthlyDaysText = clean.isEmpty ? "1" : clean.map(String.init).joined(separator: ",")

        case .monthlyNth(let weekday, let nth):
            kind = .monthlyNth
            nthWeekday = (1...7 ~= weekday) ? weekday : 6
            self.nth = min(max(nth, 1), 4)

        case .monthlyLast(let weekday):
            kind = .monthlyLast
            lastWeekday = (1...7 ~= weekday) ? weekday : 6

        case .once(let iso):
            kind = .once
            onceDate = parseISO(iso) ?? Date()
        }
    }

    private func applyUIToRule() {
        switch kind {
        case .daily:
            item.rule = .daily

        case .weekly:
            var wds = Array(weeklyWeekdays).sorted()
            if wds.isEmpty { wds = [2,3,4,5,6] }
            item.rule = .weekly(weekdays: wds, intervalWeeks: max(1, weeklyIntervalWeeks))

        case .monthlyDay:
            let days = parseDays(monthlyDaysText)
            item.rule = .monthlyDay(days: days.isEmpty ? [1] : days)

        case .monthlyNth:
            item.rule = .monthlyNth(weekday: nthWeekday, nth: nth)

        case .monthlyLast:
            item.rule = .monthlyLast(weekday: lastWeekday)

        case .once:
            item.rule = .once(dateISO: isoString(onceDate))
        }
    }

    // MARK: - helpers
    private func parseDays(_ text: String) -> [Int] {
        let parts = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
        let nums = parts.compactMap { Int($0) }.filter { 1...31 ~= $0 }
        return Array(Set(nums)).sorted()
    }

    private func weekdayShort(_ w: Int) -> String {
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

    private func weekdayLong(_ w: Int) -> String {
        "（" + weekdayShort(w) + "）"
    }

    private func isoString(_ d: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return iso.string(from: d)
    }

    private func parseISO(_ s: String) -> Date? {
        let isoA = ISO8601DateFormatter()
        isoA.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoA.date(from: s) { return d }

        let isoB = ISO8601DateFormatter()
        isoB.formatOptions = [.withInternetDateTime]
        if let d = isoB.date(from: s) { return d }

        // TZなしISO→JST扱い
        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "Asia/Tokyo")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df.date(from: s)
    }
}
