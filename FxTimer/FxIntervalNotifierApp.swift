import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    // manager を注入するための受け皿
    static weak var sharedManager: IntervalManager?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // フォアグラウンド中もバナー＆音を鳴らす
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {

        // フォアグラウンド時だけ読み上げ
        if let mgr = AppDelegate.sharedManager,
           mgr.reminderSpeakEnabled {
            let body = notification.request.content.body
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { mgr.speakPublic(text) }
        }

        return [.banner, .sound]
    }
}

@main
struct FxIntervalNotifierApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = IntervalManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onAppear {
                    AppDelegate.sharedManager = manager
                    manager.requestNotificationPermission()
                    // 起動時に通知スケジュールを復元
                    manager.rescheduleAllLocalNotifications()
                }
        }
    }
}
