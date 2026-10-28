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
    private var updates: UpdateChecker?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        configureNotificationCategories(center)
        let store = UsageStore()
        let updates = UpdateChecker()
        self.store = store
        self.updates = updates
        self.menuBar = MenuBarController(store: store, updates: updates)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            updates.checkIfNeeded()
        }
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
    private let updates: UpdateChecker
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hostingView: NSHostingView<MenuPanel>
    private var cancellables = Set<AnyCancellable>()
    private var lastCloseAt = Date.distantPast
    private var appliedMaxHeight: CGFloat = 0
    private var blinkTimer: Timer?
    private var blinkDimmed = false

    init(store: UsageStore, updates: UpdateChecker) {
        self.store = store
        self.updates = updates
        self.hostingView = NSHostingView(
            rootView: MenuPanel(store: store, updates: updates, maxHeight: 700)
        )
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        hostingView.frame = NSRect(x: 0, y: 0, width: Token.panelWidth, height: 1)
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
                    self?.syncBlink()
                    self?.resizeIfNeeded()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.applyMaxHeightIfNeeded() {
                        self.updateContentSize()
                    }
                }
            }
            .store(in: &cancellables)

        applyMaxHeightIfNeeded()
        updateTitle()
        syncBlink()
        updateContentSize()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard Date().timeIntervalSince(lastCloseAt) > 0.2 else { return }
        guard let button = statusItem.button else { return }
        markAttentionSeen()
        applyMaxHeightIfNeeded()
        updateTitle()
        updateContentSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        store.refreshQoderIfStale()
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseAt = Date()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        var text = store.menuBarText
        var color = NSColor.labelColor
        let kind = store.attentionKind
        if store.menuBarHighlight, !store.isAttentionMuted, kind != .none {
            text = (kind == .warning ? "⚠ " : "＋ ") + text
            color = kind == .warning ? .systemRed : .systemOrange
            if blinkDimmed { color = color.withAlphaComponent(0.25) }
        }
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
        button.toolTip = store.menuBarTooltip
    }

    private func syncBlink() {
        if store.attentionBlinkActive(now: Date()) {
            guard blinkTimer == nil else { return }
            let timer = Timer(timeInterval: UsageAnalytics.attentionBlinkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.store.attentionBlinkActive(now: Date()) else {
                        self.stopBlink()
                        return
                    }
                    self.blinkDimmed.toggle()
                    self.updateTitle()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else {
            stopBlink()
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        if blinkDimmed {
            blinkDimmed = false
            updateTitle()
        }
    }

    private func markAttentionSeen() {
        store.markAttentionSeen()
        stopBlink()
    }

    private var maxPanelHeight: CGFloat {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return 700 }
        return max(240, visible.height - 36)
    }

    @discardableResult
    private func applyMaxHeightIfNeeded() -> Bool {
        let height = maxPanelHeight
        guard abs(height - appliedMaxHeight) > 0.5 else { return false }
        appliedMaxHeight = height
        hostingView.rootView = MenuPanel(store: store, updates: updates, maxHeight: height)
        return true
    }

    private func updateContentSize() {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let height = min(ceil(fitting.height), appliedMaxHeight)
        popover.contentSize = NSSize(
            width: max(Token.panelWidth, ceil(fitting.width)),
            height: max(1, height)
        )
    }

    private func resizeIfNeeded() {
        guard popover.isShown else { return }
        hostingView.layoutSubtreeIfNeeded()
        let height = max(1, min(ceil(hostingView.fittingSize.height), appliedMaxHeight))
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: popover.contentSize.width, height: height)
    }
}
