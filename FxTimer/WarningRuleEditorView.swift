import SwiftUI

struct WarningRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State var rule: QuietTimeWarningRule
    let onSave: (QuietTimeWarningRule) -> Void
    let onDelete: (() -> Void)?

    private var startTimeBinding: Binding<Date> {
        Binding<Date>(
            get: {
                var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comp.hour = rule.startHour
                comp.minute = rule.startMinute
                comp.second = 0
                return Calendar.current.date(from: comp) ?? Date()
            },
            set: { newDate in
                let cal = Calendar.current
                rule.startHour = cal.component(.hour, from: newDate)
                rule.startMinute = cal.component(.minute, from: newDate)
            }
        )
    }

    private var endTimeBinding: Binding<Date> {
        Binding<Date>(
            get: {
                var comp = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                comp.hour = rule.endHour
                comp.minute = rule.endMinute
                comp.second = 0
                return Calendar.current.date(from: comp) ?? Date()
            },
            set: { newDate in
                let cal = Calendar.current
                rule.endHour = cal.component(.hour, from: newDate)
                rule.endMinute = cal.component(.minute, from: newDate)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("時間帯") {
                    Toggle("有効", isOn: $rule.enabled)
                    DatePicker("開始", selection: startTimeBinding, displayedComponents: [.hourAndMinute])
                    DatePicker("終了", selection: endTimeBinding, displayedComponents: [.hourAndMinute])
                    Text("※ 終了時刻は含まれません（例：02:00〜05:00 なら 04:59 まで）。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("※ 22:00〜05:00 のような日跨ぎにも対応しています。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("ラベル") {
                    TextField("警告文", text: $rule.label, axis: .vertical)
                        .lineLimit(1...3)
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
            .navigationTitle("警告時間帯")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(rule)
                        dismiss()
                    }
                }
            }
        }
    }
}
