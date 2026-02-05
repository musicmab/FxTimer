//
//  FxIntervalNotifierApp.swift
//  FxTimer
//

import SwiftUI

@main
struct FxIntervalNotifierApp: App {
    @StateObject private var manager = IntervalManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onAppear {
                    manager.requestNotificationPermission()

                    // ✅ 起動時に毎回、120日分を作り直したい場合だけONにしてください
                    // manager.rebuildLocalNotificationsNext120Days()
                }
        }
    }
}
