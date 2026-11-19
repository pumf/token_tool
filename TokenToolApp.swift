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
        updates.startAutoChecks()
    }

    private func configureNotificationCategories(_ center: UNUserNotificationCenter) {
        center.setNotificationCategories(Set(Providers.ordered.map { descriptor in
            UNNotificationCategory(
                identifier: NotificationCategory.forProvider(descriptor.id),
                actions: [
                    UNNotificationAction(
                        identifier: NotificationCategory.openAction(for: descriptor.id),
                        title: "打开 \(descriptor.clientName)",
                        options: []
                    ),
                ],
                intentIdentifiers: [],
                options: []
            )
        }))
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
            if let descriptor = Providers.ordered.first(where: {
                NotificationCategory.forProvider($0.id) == category
            }) {
                Apps.open(bundleID: descriptor.clientBundleID, fallback: descriptor.clientAppPath)
            }
        }
        completionHandler()
    }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let updates: UpdateChecker
    private let motion: PanelMotion
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let hostingView: NSHostingView<MenuPanel>
    private var cancellables = Set<AnyCancellable>()
    private var lastCloseAt = Date.distantPast
    private var appliedMaxHeight: CGFloat = 0
    private var measuredPanelHeight: CGFloat = 0
    private var blinkTimer: Timer?
    private var blinkDimmed = false
    private var rollTimer: Timer?
    private var hotKey: GlobalHotKey?

    init(store: UsageStore, updates: UpdateChecker) {
        let motion = PanelMotion()
        self.store = store
        self.updates = updates
        self.motion = motion
        self.hostingView = NSHostingView(
            rootView: MenuPanel(store: store, updates: updates, motion: motion, maxHeight: 700)
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
                    self?.syncRoll()
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

        hotKey = GlobalHotKey { [weak self] in self?.togglePopoverFromHotKey() }
        store.$hotKeyEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncHotKey() }
            }
            .store(in: &cancellables)

        applyMaxHeightIfNeeded()
        updateTitle()
        syncBlink()
        syncRoll()
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
        motion.isVisible = true
        installOutsideClickMonitors()
        // 应用是 accessory 身份，不激活的话弹窗永远拿不到 key 窗口：
        // 1）面板接不住键盘（预算输入框等）；
        // 2）transient 的「点外面关闭」靠「失焦」触发，窗口没成为 key 就永远等不到。
        // 激活并抢 key 的时机放在 popoverDidShow 里：show() 刚返回时弹窗窗口
        // 可能仍在展示动画中，此刻 makeKey 偶发失败，之后点哪里都不会失焦。
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.resizeIfNeeded()
        }
        store.refreshStaleForPanel()
    }

    /// 兜底关闭：transient 失焦链路偶发失效（key 竞态），用鼠标事件监听保证
    /// 「点击弹窗之外一定关闭」。全局监听收其他应用的点击，本地监听收自家
    /// 应用内落在弹窗与状态栏图标之外的点击。展示期间安装，关闭即拆。
    private var outsideClickMonitors: [Any] = []

    private func installOutsideClickMonitors() {
        guard outsideClickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.closePopoverIfShown()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.closePopoverIfClickOutside(event)
            return event
        }
        if let global { outsideClickMonitors.append(global) }
        if let local { outsideClickMonitors.append(local) }
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach { NSEvent.removeMonitor($0) }
        outsideClickMonitors.removeAll()
    }

    private func closePopoverIfShown() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func closePopoverIfClickOutside(_ event: NSEvent) {
        guard popover.isShown else { return }
        // 弹窗内容与状态栏图标各有正常处理路径；点自家其余区域视为外部点击。
        if let popoverWindow = popover.contentViewController?.view.window,
           event.window === popoverWindow {
            return
        }
        if let buttonWindow = statusItem.button?.window,
           event.window === buttonWindow {
            return
        }
        closePopoverIfShown()
    }

    /// 热键展开时应用可能不在前台；激活逻辑已统一进 togglePopover，这里只做转发。
    private func togglePopoverFromHotKey() {
        togglePopover(nil)
    }

    private func syncHotKey() {
        if store.hotKeyEnabled {
            hotKey?.register()
        } else {
            hotKey?.unregister()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        // 窗口真正挂出来之后再抢 key，避开 show() 期间的展示竞态。
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseAt = Date()
        motion.isVisible = false
        removeOutsideClickMonitors()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let title = NSMutableAttributedString(attributedString: store.menuBarText(for: store.menuBarStyle, font: font))
        var color = NSColor.labelColor
        let kind = store.attentionKind
        if store.menuBarHighlight, !store.isAttentionMuted, kind != .none {
            title.insert(NSAttributedString(string: kind == .warning ? "⚠ " : "＋ ", attributes: [.font: font]), at: 0)
            color = kind == .warning ? .systemRed : .systemOrange
            if blinkDimmed { color = color.withAlphaComponent(0.25) }
        }
        if store.menuBarStyle == .bars, !store.menuBarMetrics.isEmpty {
            button.image = MenuBarGlyph.bars(store.menuBarMetrics, dimmed: blinkDimmed)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
        } else {
            button.image = nil
            button.imagePosition = .noImage
        }
        title.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: title.length))
        button.attributedTitle = title
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

    /// 菜单栏在剩余量与今日消耗之间滚动；今日数据或样式不满足条件时回到只显示剩余。
    private func syncRoll() {
        if store.menuBarRollAvailable {
            guard rollTimer == nil else { return }
            let timer = Timer(timeInterval: UsageAnalytics.menuBarRollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.store.menuBarRollAvailable else {
                        self.stopRoll()
                        return
                    }
                    self.store.setMenuBarShowsToday(!self.store.menuBarShowsToday)
                    self.updateTitle()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            rollTimer = timer
        } else {
            stopRoll()
        }
    }

    private func stopRoll() {
        rollTimer?.invalidate()
        rollTimer = nil
        if store.menuBarShowsToday {
            store.setMenuBarShowsToday(false)
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
        hostingView.rootView = makePanel(maxHeight: height)
        return true
    }

    private func makePanel(maxHeight: CGFloat) -> MenuPanel {
        MenuPanel(store: store, updates: updates, motion: motion, maxHeight: maxHeight) { [weak self] height in
            guard let self else { return }
            self.measuredPanelHeight = height
            // 回调发生在 SwiftUI 布局中，等这一轮布局结束再改弹窗尺寸。
            DispatchQueue.main.async { [weak self] in
                self?.resizeIfNeeded()
            }
        }
    }

    /// 面板高度跟随内容：内容变矮就收，不留下方空白；超过上限才滚动。
    private func applyPanelHeight() {
        guard measuredPanelHeight > 0 else { return }
        let height = max(1, min(measuredPanelHeight, appliedMaxHeight))
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: Token.panelWidth, height: height)
    }

    private func updateContentSize() {
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let natural = measuredPanelHeight > 0 ? measuredPanelHeight : ceil(fitting.height)
        popover.contentSize = NSSize(
            width: max(Token.panelWidth, ceil(fitting.width)),
            height: max(1, min(ceil(natural), appliedMaxHeight))
        )
    }

    private func resizeIfNeeded() {
        guard popover.isShown else { return }
        hostingView.layoutSubtreeIfNeeded()
        if measuredPanelHeight > 0 {
            applyPanelHeight()
            return
        }
        let height = max(1, min(ceil(hostingView.fittingSize.height), appliedMaxHeight))
        guard abs(popover.contentSize.height - height) > 0.5 else { return }
        popover.contentSize = NSSize(width: popover.contentSize.width, height: height)
    }
}
