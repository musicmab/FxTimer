import Foundation
import AVFoundation

final class QuietTimeWarningManager: ObservableObject {
    @Published var rules: [QuietTimeWarningRule] = []
    @Published var activeLabel: String? = nil

    private var lastTriggeredRuleID: UUID?
    private let synthesizer = AVSpeechSynthesizer()

    func check(date: Date = Date(), speak: Bool) {
        for rule in rules where rule.enabled {
            if rule.contains(date: date) {
                activeLabel = rule.label
                if lastTriggeredRuleID != rule.id {
                    lastTriggeredRuleID = rule.id
                    if speak {
                        speakOnce(rule.label)
                    }
                }
                return
            }
        }
        activeLabel = nil
        lastTriggeredRuleID = nil
    }

    private func speakOnce(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        synthesizer.speak(u)
    }
}
