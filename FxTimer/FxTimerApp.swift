import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var sharedManager: IntervalManager?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // Foreground: show banner & sound, and optionally speak.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if let mgr = AppDelegate.sharedManager, mgr.reminderSpeakEnabled {
            let body = notification.request.content.body
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { mgr.speakPublic(text) }
        }
        return [.banner, .sound]
    }
}

@main
struct FxTimerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = IntervalManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onAppear {
                    AppDelegate.sharedManager = manager
                    manager.requestNotificationPermission()
                    manager.rescheduleAllLocalNotifications()
                }
        }
    }
}
