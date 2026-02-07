import Foundation

struct QuietTimeWarningRule: Identifiable, Codable, Equatable {
    let id: UUID
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int
    var label: String
    var enabled: Bool

    init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int, label: String, enabled: Bool = true) {
        self.id = UUID()
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.label = label
        self.enabled = enabled
    }

    func contains(date: Date) -> Bool {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let now = h * 60 + m
        let start = startHour * 60 + startMinute
        let end = endHour * 60 + endMinute

        if start < end {
            return now >= start && now < end
        } else {
            return now >= start || now < end
        }
    }
}
