import SwiftUI
import AppKit
import Combine
@preconcurrency import UserNotifications

@main
struct TokenToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        configureNotificationCategories(center)
        let store = UsageStore()
        self.store = store
        self.menuBar = MenuBarController(store: store)
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
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
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

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hostingView: NSHostingView<MenuContent>
    private var cancellables = Set<AnyCancellable>()
    private var lastCloseAt = Date.distantPast

    init(store: UsageStore) {
        self.store = store
        self.hostingView = NSHostingView(rootView: MenuContent(store: store))
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        hostingView.frame = NSRect(x: 0, y: 0, width: 382, height: 1)
        let controller = NSViewController()
        controller.view = hostingView
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateTitle()
                    self?.resizeIfNeeded()
                }
            }
            .store(in: &cancellables)

        updateTitle()
        updateContentSize()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard Date().timeIntervalSince(lastCloseAt) > 0.2 else { return }
        guard let button = statusItem.button else { return }
        updateTitle()
        updateContentSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseAt = Date()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.attributedTitle = NSAttributedString(
            string: store.menuBarText,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        button.toolTip = store.menuBarTooltip
    }

    private func updateContentSize() {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        popover.contentSize = NSSize(
            width: max(382, ceil(fitting.width)),
            height: max(1, ceil(fitting.height))
        )
    }

    private func resizeIfNeeded() {
        guard popover.isShown else { return }
        hostingView.layoutSubtreeIfNeeded()
        let height = max(1, ceil(hostingView.fittingSize.height))
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: popover.contentSize.width, height: height)
    }
}
