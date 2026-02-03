import SwiftUI

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

                    switch item.recurrence {
                    case "once":
                        DatePicker("日付", selection: onceDateBinding, displayedComponents: [.date])

                    case "weekly":
                        Picker("曜日", selection: Binding<Int>(
                            get: { item.weekday ?? 2 },
                            set: { item.weekday = $0 }
                        )) {
                            ForEach(weekdayLabels, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }

                    case "weeklyN":
                        Picker("間隔", selection: Binding<Int>(
                            get: { item.weekInterval ?? 2 },
                            set: { item.weekInterval = $0 }
                        )) {
                            ForEach(weekIntervalChoices, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }

                        Picker("曜日", selection: Binding<Int>(
                            get: { item.weekday ?? 6 },
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

                    case "monthlyDay":
                        Picker("日", selection: Binding<Int>(
                            get: { item.dayOfMonth ?? 1 },
                            set: { item.dayOfMonth = $0 }
                        )) {
                            ForEach(1...31, id: \.self) { d in
                                Text("\(d)日").tag(d)
                            }
                        }

                    case "monthlyNthWeekday":
                        Picker("第N", selection: Binding<Int>(
                            get: { item.nthWeek ?? 1 },
                            set: { item.nthWeek = $0 }
                        )) {
                            ForEach(nthChoices, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }

                        Picker("曜日", selection: Binding<Int>(
                            get: { item.weekday ?? 6 },
                            set: { item.weekday = $0 }
                        )) {
                            ForEach(weekdayLabels, id: \.0) { v in
                                Text(v.1).tag(v.0)
                            }
                        }

                    default:
                        EmptyView()
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
                        // 不整合を減らすため、recurrence に応じて不要フィールドを整理
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
