import SwiftUI

struct ReminderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State var item: ReminderItem
    let onSave: (ReminderItem) -> Void
    let onDelete: (() -> Void)?

    @State private var selectedRuleType: RuleType = .daily
    @State private var oneTimeDate: Date = Date()
    @State private var weeklyDays: Set<Int> = [2,3,4,5,6]
    @State private var monthlyDay: Int = 1
    @State private var nth: Int = 1
    @State private var nthWeekday: Int = 6
    @State private var biweeklyAnchor: Date = Date()

    enum RuleType: String, CaseIterable, Identifiable {
        case oneTime = "1回"
        case daily = "毎日"
        case weekly = "毎週(曜日)"
        case biweekly = "隔週(曜日)"
        case monthlyDay = "毎月(日付)"
        case monthlyNthWeekday = "毎月(第n曜日)"
        var id: String { rawValue }
    }

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
                Section("基本") {
                    Toggle("有効", isOn: $item.enabled)
                    DatePicker("時刻", selection: timeBinding, displayedComponents: [.hourAndMinute])
                    TextField("内容", text: $item.text, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("繰り返しルール") {
                    Picker("種別", selection: $selectedRuleType) {
                        ForEach(RuleType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }

                    ruleEditor()
                }

                if item.source == "te" {
                    Section {
                        Text("※ Trading Economics から自動生成された項目です。")
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
                        item.rule = buildRuleFromUI()
                        onSave(item)
                        dismiss()
                    }
                }
            }
            .onAppear { bootstrapUIFromItem() }
        }
    }

    @ViewBuilder
    private func ruleEditor() -> some View {
        switch selectedRuleType {
        case .oneTime:
            DatePicker("日付", selection: $oneTimeDate, displayedComponents: [.date])

        case .daily:
            EmptyView()

        case .weekly:
            weekdayPicker(title: "曜日", selection: $weeklyDays)

        case .biweekly:
            weekdayPicker(title: "曜日", selection: $weeklyDays)
            DatePicker("基準日（この週を基準）", selection: $biweeklyAnchor, displayedComponents: [.date])
                .font(.subheadline)

        case .monthlyDay:
            Stepper(value: $monthlyDay, in: 1...31) {
                Text("日付: \(monthlyDay)日")
            }

        case .monthlyNthWeekday:
            Picker("第n", selection: $nth) {
                Text("第1").tag(1)
                Text("第2").tag(2)
                Text("第3").tag(3)
                Text("第4").tag(4)
                Text("最終").tag(-1)
            }
            Picker("曜日", selection: $nthWeekday) {
                Text("日").tag(1)
                Text("月").tag(2)
                Text("火").tag(3)
                Text("水").tag(4)
                Text("木").tag(5)
                Text("金").tag(6)
                Text("土").tag(7)
            }
        }
    }

    @ViewBuilder
    private func weekdayPicker(title: String, selection: Binding<Set<Int>>) -> some View {
        let days: [(Int, String)] = [
            (1, "日"), (2, "月"), (3, "火"), (4, "水"), (5, "木"), (6, "金"), (7, "土")
        ]
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline)
            HStack {
                ForEach(days, id: \.0) { d in
                    let isOn = selection.wrappedValue.contains(d.0)
                    Button {
                        if isOn {
                            selection.wrappedValue.remove(d.0)
                        } else {
                            selection.wrappedValue.insert(d.0)
                        }
                    } label: {
                        Text(d.1)
                            .frame(width: 36, height: 30)
                            .background(isOn ? Color.green.opacity(0.25) : Color.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func bootstrapUIFromItem() {
        switch item.rule {
        case .oneTime(let y, let m, let d):
            selectedRuleType = .oneTime
            var comp = DateComponents()
            comp.year = y; comp.month = m; comp.day = d
            oneTimeDate = Calendar.current.date(from: comp) ?? Date()
        case .daily:
            selectedRuleType = .daily
        case .weekly(let wds):
            selectedRuleType = .weekly
            weeklyDays = Set(wds)
        case .biweekly(let wds, let anchorISO):
            selectedRuleType = .biweekly
            weeklyDays = Set(wds)
            biweeklyAnchor = parseYYYYMMDD(anchorISO) ?? Date()
        case .monthlyDay(let d):
            selectedRuleType = .monthlyDay
            monthlyDay = d
        case .monthlyNthWeekday(let n, let wd):
            selectedRuleType = .monthlyNthWeekday
            nth = n
            nthWeekday = wd
        }
    }

    private func buildRuleFromUI() -> ReminderRule {
        switch selectedRuleType {
        case .oneTime:
            let cal = Calendar.current
            let y = cal.component(.year, from: oneTimeDate)
            let m = cal.component(.month, from: oneTimeDate)
            let d = cal.component(.day, from: oneTimeDate)
            return .oneTime(year: y, month: m, day: d)

        case .daily:
            return .daily

        case .weekly:
            return .weekly(weekdays: weeklyDays.sorted())

        case .biweekly:
            let anchor = formatYYYYMMDD(biweeklyAnchor)
            return .biweekly(weekdays: weeklyDays.sorted(), anchorISODate: anchor)

        case .monthlyDay:
            return .monthlyDay(day: monthlyDay)

        case .monthlyNthWeekday:
            return .monthlyNthWeekday(nth: nth, weekday: nthWeekday)
        }
    }

    private func formatYYYYMMDD(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }

    private func parseYYYYMMDD(_ s: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.date(from: s)
    }
}
