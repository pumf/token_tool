import SwiftUI
import AppKit
import UserNotifications

@main
struct TokenToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        configureNotificationCategories(center)
    }

    private func configureNotificationCategories(_ center: UNUserNotificationCenter) {
        let qoder = UNNotificationCategory(
            identifier: NotificationCategory.qoder,
            actions: [
                UNNotificationAction(identifier: "open.qoder", title: "打开 Qoder", options: [])
            ],
            intentIdentifiers: [],
            options: []
        )
        let workbuddy = UNNotificationCategory(
            identifier: NotificationCategory.workbuddy,
            actions: [
                UNNotificationAction(identifier: "open.workbuddy", title: "打开 WorkBuddy", options: [])
            ],
            intentIdentifiers: [],
            options: []
        )
        let codex = UNNotificationCategory(
            identifier: NotificationCategory.codex,
            actions: [
                UNNotificationAction(identifier: "open.codex", title: "打开 ChatGPT", options: [])
            ],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([qoder, workbuddy, codex])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let category = response.notification.request.content.categoryIdentifier
        DispatchQueue.main.async {
            switch category {
            case NotificationCategory.qoder:
                Apps.open(bundleID: "com.qodercn.app", fallback: "/Applications/Qoder CN.app")
            case NotificationCategory.workbuddy:
                Apps.open(bundleID: "com.tencent.workbuddy.mac", fallback: "/Applications/WorkBuddy.app")
            case NotificationCategory.codex:
                Apps.open(bundleID: "com.openai.codex", fallback: "/Applications/ChatGPT.app")
            default:
                break
            }
        }
        completionHandler()
    }
}
