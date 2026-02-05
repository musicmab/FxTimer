import Foundation

// プリセット（目安テンプレ）機能は IntervalManager の拡張として追加する
extension IntervalManager {

    // MARK: - プリセット（目安テンプレ）追加
    func addPresetTemplates() {
        var items = getReminders()

        // 既に同名テンプレがある場合は追加しない（重複防止）
        func exists(_ text: String) -> Bool {
            items.contains(where: { $0.text == text && $0.source == "preset" })
        }

        // 目安テンプレ：時間は後で編集して使う前提（enabled=false）
        // ※ 発表時刻は月ごと/DSTでズレるためテンプレは雛形扱いが安全
        let templates: [(String, ReminderRule, Int, Int)] = [
            ("【US】雇用統計（NFP）※目安テンプレ", .monthlyNth(weekday: 6, nth: 1), 21, 30),  // 第1金曜（目安）
            ("【US】消費者物価指数（CPI）※目安テンプレ", .monthlyDay(days: [10]), 21, 30),     // 目安
            ("【US】小売売上高 ※目安テンプレ", .monthlyDay(days: [15]), 21, 30),              // 目安
            ("【US】コアPCE（PCE）※目安テンプレ", .monthlyDay(days: [29]), 21, 30)            // 目安
        ]

        for (text, rule, h, m) in templates {
            if exists(text) { continue }

            var r = ReminderItem()
            r.enabled = false     // ★ 追加直後はOFF（ユーザーが編集してONにする）
            r.hour = h
            r.minute = m
            r.text = text
            r.rule = rule
            r.source = "preset"
            r.externalId = nil
            items.append(r)
        }

        setReminders(items)
    }

    // MARK: - プリセット（目安テンプレ）削除
    func removePresetTemplates() {
        var items = getReminders()
        items.removeAll { $0.source == "preset" }
        setReminders(items)
    }
}
