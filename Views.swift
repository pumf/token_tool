import SwiftUI
import AppKit
import Combine
import Darwin
@preconcurrency import UserNotifications

struct CodexWindow: Codable, Sendable, Identifiable {
    let id: String
    let windowMinutes: Int
    let usedPercent: Double
    let remainingPercent: Double
    let resetsAt: Int?
}

struct CodexCredits: Codable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?
}

struct ProviderResult: Codable, Sendable {
    var ok: Bool?
    var error: String?
    var updatedAt: Int?
    var plan: String?
    var accountType: String?
    var windows: [CodexWindow]?
    var credits: CodexCredits?
    var resetCredits: Int?
    var total: Double?
    var remaining: Double?
    var used: Double?
    var usedPercent: Double?
    var remainingPercent: Double?
    var packages: Int?
    var unit: String?
    var planExpiresAt: String?
    var planUsed: Double?
    var planTotal: Double?
    var addonUsed: Double?
    var addonTotal: Double?
    var orgResourcePackage: String?
    var source: String?

    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(updatedAt))
    }

    var primaryWindow: CodexWindow? { windows?.first }
}

struct CollectorOutput: Decodable, Sendable {
    let version: Int?
    let updatedAt: Int?
    let providers: [String: ProviderResult]?
}

struct CollectorAction: Decodable, Sendable {
    let ok: Bool
    let status: String?
    let cli: String?
    let url: String?
    let message: String?
    let error: String?
}

enum NotificationCategory {
    static let qoder = "provider.qoder"
    static let workbuddy = "provider.workbuddy"
    static let codex = "provider.codex"

    static func forProvider(_ provider: UsageProvider) -> String {
        switch provider {
        case .qoder: return qoder
        case .workbuddy: return workbuddy
        case .codex: return codex
        }
    }
}

enum CollectorRunner {
    struct RunResult: Sendable {
        let output: CollectorOutput?
        let error: String?
    }

    struct ActionResult: Sendable {
        let action: CollectorAction?
        let error: String?
    }

    private struct ActionEnvelope: Decodable {
        let result: CollectorAction?
    }

    static func run(provider: String, timeout: TimeInterval = 80) -> RunResult {
        switch execute(["--provider", provider], timeout: timeout) {
        case .failure(let message):
            return RunResult(output: nil, error: message)
        case .success(let data):
            do {
                return RunResult(
                    output: try JSONDecoder().decode(CollectorOutput.self, from: data),
                    error: nil
                )
            } catch {
                return RunResult(output: nil, error: "采集器输出无法解析")
            }
        }
    }

    static func action(_ name: String, timeout: TimeInterval) -> ActionResult {
        switch execute(["--action", name], timeout: timeout) {
        case .failure(let message):
            return ActionResult(action: nil, error: message)
        case .success(let data):
            guard let envelope = try? JSONDecoder().decode(ActionEnvelope.self, from: data),
                  let result = envelope.result else {
                return ActionResult(action: nil, error: "采集器输出无法解析")
            }
            if !result.ok {
                return ActionResult(action: result, error: result.error ?? "操作失败")
            }
            return ActionResult(action: result, error: nil)
        }
    }

    private enum Capture {
        case success(Data)
        case failure(String)
    }

    // Output goes to temp files rather than pipes: install scripts can write more
    // than the 64KB pipe buffer and would otherwise block the child process.
    private static func execute(_ arguments: [String], timeout: TimeInterval) -> Capture {
        guard let script = Bundle.main.url(forResource: "collector", withExtension: "py") else {
            return .failure("采集器文件缺失")
        }
        let directory = FileManager.default.temporaryDirectory
        let outputURL = directory.appendingPathComponent("tokentool-\(UUID().uuidString).out")
        let errorURL = directory.appendingPathComponent("tokentool-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL),
              let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            return .failure("无法创建采集器输出文件")
        }
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        do {
            try process.run()
        } catch {
            return .failure("无法启动采集器")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            return .failure("采集超时")
        }
        outputHandle.closeFile()
        errorHandle.closeFile()
        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            return .failure("采集器没有返回数据")
        }
        return .success(data)
    }
}

enum LaunchAtLogin {
    static let label = "com.local.tokentool"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        let manager = FileManager.default
        if enabled {
            let appPath = Bundle.main.bundleURL.path
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            ) else { return }
            try? manager.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: plistURL, options: .atomic)
            _ = run(["/bin/launchctl", "enable", "gui/\(getuid())/\(label)"])
        } else {
            _ = run(["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"])
            try? manager.removeItem(at: plistURL)
        }
    }

    @discardableResult
    static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

enum AttentionKind: Int, Comparable, Sendable {
    case none = 0
    case claim = 1
    case warning = 2

    static func < (lhs: AttentionKind, rhs: AttentionKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AttentionItem: Identifiable, Sendable {
    let id: String
    let provider: UsageProvider
    let kind: AttentionKind
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String
    let canDismiss: Bool
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var codex: ProviderResult?
    @Published private(set) var workbuddy: ProviderResult?
    @Published private(set) var qoder: ProviderResult?
    @Published private(set) var codexError: String?
    @Published private(set) var workbuddyError: String?
    @Published private(set) var qoderError: String?
    @Published private(set) var fastRefreshing = false
    @Published private(set) var qoderRefreshing = false
    @Published private(set) var lastFastAt: Date?
    @Published private(set) var lastQoderAt: Date?
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var showQoderInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showQoderInMenuBar, forKey: "menuBar.qoder") }
    }
    @Published var showWorkBuddyInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showWorkBuddyInMenuBar, forKey: "menuBar.workbuddy") }
    }
    @Published var showCodexInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showCodexInMenuBar, forKey: "menuBar.codex") }
    }
    @Published var remindQoderClaim: Bool {
        didSet {
            UserDefaults.standard.set(remindQoderClaim, forKey: "reminder.qoder.claim")
            reminderSettingChanged()
        }
    }
    @Published var remindWorkBuddyClaim: Bool {
        didSet {
            UserDefaults.standard.set(remindWorkBuddyClaim, forKey: "reminder.workbuddy.claim")
            reminderSettingChanged()
        }
    }
    @Published var remindCodexReset: Bool {
        didSet {
            UserDefaults.standard.set(remindCodexReset, forKey: "reminder.codex.reset")
            reminderSettingChanged()
        }
    }
    @Published var alertLowBalance: Bool {
        didSet {
            UserDefaults.standard.set(alertLowBalance, forKey: "alert.low")
            prepareNotificationAuthorization()
            recomputeAttention(now: Date())
        }
    }
    @Published var alertExhaustion: Bool {
        didSet {
            UserDefaults.standard.set(alertExhaustion, forKey: "alert.exhaustion")
            prepareNotificationAuthorization()
            recomputeAttention(now: Date())
        }
    }
    @Published var alertAcceleration: Bool {
        didSet {
            UserDefaults.standard.set(alertAcceleration, forKey: "alert.acceleration")
            prepareNotificationAuthorization()
        }
    }
    @Published var lowBalanceThreshold: Int {
        didSet {
            UserDefaults.standard.set(lowBalanceThreshold, forKey: "alert.low.threshold")
            resetLowAlertState()
            recomputeAttention(now: Date())
        }
    }
    @Published var menuBarHighlight: Bool {
        didSet { UserDefaults.standard.set(menuBarHighlight, forKey: "attention.menuBar.highlight") }
    }
    @Published var menuBarBlink: Bool {
        didSet { UserDefaults.standard.set(menuBarBlink, forKey: "attention.menuBar.blink") }
    }
    @Published private(set) var attentionItems: [AttentionItem] = []
    @Published private(set) var attentionSince: Date?
    @Published private(set) var mutedUntil: Date?
    @Published private(set) var notificationsDenied = false
    @Published private var qoderHistory: [UsageSample] = []
    @Published private var workbuddyHistory: [UsageSample] = []
    @Published private var codexHistory: [UsageSample] = []

    private enum ReminderID {
        static let qoder = "reminder.qoder.claim"
        static let workbuddy = "reminder.workbuddy.claim"
        static let codex = "reminder.codex.reset"
    }

    private lazy var notificationCenter = UNUserNotificationCenter.current()

    private struct CacheFile: Codable {
        var codex: ProviderResult?
        var workbuddy: ProviderResult?
        var qoder: ProviderResult?
        var fastAt: Double?
        var qoderAt: Double?
    }

    private struct HistoryFile: Codable {
        var qoder: [UsageSample]?
        var workbuddy: [UsageSample]?
        var codex: [UsageSample]?
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/cache.json")
    }

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/history.json")
    }

    private enum Provider { case codex, workbuddy, qoder }
    private var fastTimer: Timer?
    private var qoderTimer: Timer?

    private static func storedFlag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private static func storedLowThreshold() -> Int {
        let value = UserDefaults.standard.integer(forKey: "alert.low.threshold")
        return [10, 20, 30].contains(value) ? value : 20
    }

    init(refreshOnStart: Bool = true) {
        showQoderInMenuBar = Self.storedFlag("menuBar.qoder")
        showWorkBuddyInMenuBar = Self.storedFlag("menuBar.workbuddy")
        showCodexInMenuBar = Self.storedFlag("menuBar.codex")
        remindQoderClaim = Self.storedFlag("reminder.qoder.claim")
        remindWorkBuddyClaim = Self.storedFlag("reminder.workbuddy.claim")
        remindCodexReset = Self.storedFlag("reminder.codex.reset")
        alertLowBalance = Self.storedFlag("alert.low")
        alertExhaustion = Self.storedFlag("alert.exhaustion")
        alertAcceleration = Self.storedFlag("alert.acceleration")
        lowBalanceThreshold = Self.storedLowThreshold()
        menuBarHighlight = Self.storedFlag("attention.menuBar.highlight")
        menuBarBlink = Self.storedFlag("attention.menuBar.blink")
        let muteEpoch = UserDefaults.standard.double(forKey: "attention.mute.until")
        mutedUntil = muteEpoch > 0 ? Date(timeIntervalSince1970: muteEpoch) : nil
        loadCache()
        loadHistory()
        seedHistoryFromCache()
        recomputeAttention(now: Date())
        guard refreshOnStart else { return }
        refreshReminders()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.prepareNotificationAuthorization()
        }
        refreshFast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refreshQoder()
        }
        scheduleTimers()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    var isRefreshing: Bool { fastRefreshing || qoderRefreshing }
    var lowThreshold: Double { Double(lowBalanceThreshold) }
    var lowRecovery: Double { lowThreshold + UsageAnalytics.lowRecoveryGap }

    var attentionKind: AttentionKind { attentionItems.map(\.kind).max() ?? .none }
    var isAttentionMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }
    var mutedDescription: String {
        guard let mutedUntil else { return "" }
        return "静音中，\(Format.time(mutedUntil)) 自动恢复提醒"
    }

    private(set) var attentionIdentity: String = ""

    /// 菜单栏是否需要闪动：新出现的提醒在 60 秒内、且用户还没打开过面板。
    func attentionBlinkActive(now: Date) -> Bool {
        guard menuBarHighlight, menuBarBlink, !isAttentionMuted, attentionKind != .none else {
            return false
        }
        guard let since = attentionSince, acknowledgedAt < since else { return false }
        return now.timeIntervalSince(since) <= UsageAnalytics.attentionBlinkDuration
    }

    func markAttentionSeen() {
        acknowledgedAt = Date()
    }

    private var acknowledgedAt = Date.distantPast

    func muteAttention(minutes: Int = 30) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        mutedUntil = until
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: "attention.mute.until")
        recomputeAttention(now: Date())
    }

    func unmuteAttention() {
        mutedUntil = nil
        UserDefaults.standard.removeObject(forKey: "attention.mute.until")
        recomputeAttention(now: Date())
    }

    func dismissClaimToday(_ provider: UsageProvider) {
        UserDefaults.standard.set(
            Self.dayKey(Date()),
            forKey: "attention.claim.dismiss.\(provider.rawValue)"
        )
        recomputeAttention(now: Date())
    }

    func openClient(_ provider: UsageProvider) {
        switch provider {
        case .qoder:
            Apps.open(bundleID: "com.qodercn.app", fallback: "/Applications/Qoder CN.app")
        case .workbuddy:
            Apps.open(bundleID: "com.tencent.workbuddy.mac", fallback: "/Applications/WorkBuddy.app")
        case .codex:
            Apps.open(bundleID: "com.openai.codex", fallback: "/Applications/ChatGPT.app")
        }
    }

    static func clientName(_ provider: UsageProvider) -> String {
        switch provider {
        case .qoder: return "Qoder"
        case .workbuddy: return "WorkBuddy"
        case .codex: return "ChatGPT"
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func recomputeAttention(now: Date) {
        if let mutedUntil, mutedUntil <= now {
            self.mutedUntil = nil
            UserDefaults.standard.removeObject(forKey: "attention.mute.until")
        }
        var items: [AttentionItem] = []
        if mutedUntil == nil {
            for provider in UsageProvider.allCases {
                guard let result = currentResult(for: provider), result.ok == true else { continue }
                let input = usageInput(result)
                if let item = warningItem(provider: provider, input: input) {
                    items.append(item)
                } else if let item = claimItem(provider: provider, input: input, now: now) {
                    items.append(item)
                }
            }
        }
        let ordered = items.filter { $0.kind == .warning } + items.filter { $0.kind == .claim }
        applyAttention(ordered)
    }

    private func applyAttention(_ items: [AttentionItem]) {
        attentionItems = items
        let identity = items.map { "\($0.id):\($0.kind.rawValue)" }.joined(separator: ",")
        guard identity != attentionIdentity else { return }
        attentionIdentity = identity
        attentionSince = identity.isEmpty ? nil : Date()
    }

    private func warningItem(provider: UsageProvider, input: UsageInput) -> AttentionItem? {
        let percent = UsageAnalytics.currentPercent(provider: provider, input: input)
        if alertLowBalance, let percent, percent <= lowThreshold {
            return AttentionItem(
                id: "low.\(provider.rawValue)",
                provider: provider,
                kind: .warning,
                icon: "exclamationmark.triangle.fill",
                title: "\(provider.displayName) 剩余 \(Int(percent.rounded()))%",
                detail: "已低于 \(Int(lowThreshold))% 阈值，请留意消耗或等待额度重置。",
                actionTitle: "打开 \(Self.clientName(provider))",
                canDismiss: false
            )
        }
        guard alertExhaustion,
              let forecast = forecast(for: provider),
              forecast.warning,
              forecast.text.hasSuffix("后耗尽") else { return nil }

        let detail: String
        if provider == .codex,
           let risk = forecast.windows.filter({ $0.exhaustsBeforeReset })
               .min(by: { $0.exhaustAt < $1.exhaustAt }),
           let reset = risk.resetsAt {
            detail = "预计 \(Format.reset(Int(risk.exhaustAt.timeIntervalSince1970))) 耗尽，早于重置时间 \(Format.reset(Int(reset.timeIntervalSince1970)))。"
        } else {
            detail = "按近期净消耗速度估算，剩余额度撑不到下一次领取或重置。"
        }
        return AttentionItem(
            id: "exhaust.\(provider.rawValue)",
            provider: provider,
            kind: .warning,
            icon: "hourglass",
            title: "\(provider.displayName) \(forecast.text)",
            detail: detail,
            actionTitle: "打开 \(Self.clientName(provider))",
            canDismiss: false
        )
    }

    private func claimItem(provider: UsageProvider, input: UsageInput, now: Date) -> AttentionItem? {
        switch provider {
        case .qoder:
            return dailyClaimItem(
                provider: .qoder,
                enabled: remindQoderClaim,
                claimHour: 10,
                grant: "100 Credits",
                input: input,
                now: now
            )
        case .workbuddy:
            return dailyClaimItem(
                provider: .workbuddy,
                enabled: remindWorkBuddyClaim,
                claimHour: 0,
                grant: "100 积分",
                input: input,
                now: now
            )
        case .codex:
            guard remindCodexReset else { return nil }
            let nowTs = now.timeIntervalSince1970
            let upcoming = input.windows.compactMap { item -> (UsageWindow, Int)? in
                guard let reset = item.resetsAt,
                      Double(reset) - nowTs > 0,
                      Double(reset) - nowTs <= 20 * 60 else {
                    return nil
                }
                return (item, reset)
            }
            guard let (window, reset) = upcoming.min(by: { $0.1 < $1.1 }) else { return nil }
            let key = "attention.claim.dismiss.codex"
            if UserDefaults.standard.string(forKey: key) == Self.dayKey(now) { return nil }
            return AttentionItem(
                id: "claim.codex",
                provider: .codex,
                kind: .claim,
                icon: "clock.arrow.circlepath",
                title: "Codex \(UsageAnalytics.windowText(window.minutes))窗口即将重置",
                detail: "\(Format.reset(reset)) 刷新额度，重置后可继续使用。",
                actionTitle: "打开 \(Self.clientName(.codex))",
                canDismiss: true
            )
        }
    }

    private func dailyClaimItem(
        provider: UsageProvider,
        enabled: Bool,
        claimHour: Int,
        grant: String,
        input: UsageInput,
        now: Date
    ) -> AttentionItem? {
        guard enabled else { return nil }
        guard let remaining = input.remaining,
              let total = input.total,
              total > 0,
              remaining < total - 0.5 else { return nil }
        guard let claimAt = Calendar.current.date(
            bySettingHour: claimHour, minute: 0, second: 0, of: now
        ), now >= claimAt else { return nil }
        let key = "attention.claim.dismiss.\(provider.rawValue)"
        if UserDefaults.standard.string(forKey: key) == Self.dayKey(now) { return nil }
        guard !receivedClaimSince(provider: provider, since: claimAt, now: now) else { return nil }
        return AttentionItem(
            id: "claim.\(provider.rawValue)",
            provider: provider,
            kind: .claim,
            icon: "gift.fill",
            title: "\(provider.displayName) 今日 \(grant) 待领取",
            detail: "领取成功后此提示会自动消失；今天不需要可先忽略。",
            actionTitle: "打开 \(Self.clientName(provider))",
            canDismiss: true
        )
    }

    private func receivedClaimSince(provider: UsageProvider, since: Date, now: Date) -> Bool {
        let sinceTs = Int(since.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)
        let samples = history(for: provider)
        let today = samples.filter { $0.at >= sinceTs && $0.at <= nowTs }
        if let baseline = samples.last(where: { $0.at < sinceTs })?.remaining,
           let latest = today.last?.remaining,
           latest > baseline + 0.5 {
            return true
        }
        guard today.count >= 2 else { return false }
        for index in 1..<today.count {
            if let previous = today[index - 1].remaining,
               let current = today[index].remaining,
               current > previous + 0.5 {
                return true
            }
        }
        return false
    }

    func refreshAll() {
        refreshFast()
        refreshQoder()
    }

    func refreshFast() {
        guard !fastRefreshing else { return }
        fastRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let run = CollectorRunner.run(provider: "fast")
            guard let self else { return }
            await MainActor.run {
                if let output = run.output {
                    if let result = output.providers?["codex"] {
                        self.apply(result, to: .codex)
                    } else {
                        self.codexError = "采集器未返回 Codex 数据"
                    }
                    if let result = output.providers?["workbuddy"] {
                        self.apply(result, to: .workbuddy)
                    } else {
                        self.workbuddyError = "采集器未返回 WorkBuddy 数据"
                    }
                } else {
                    let message = run.error ?? "采集器运行失败"
                    self.codexError = message
                    self.workbuddyError = message
                }
                self.lastFastAt = Date()
                self.fastRefreshing = false
                self.saveCache()
                self.recomputeAttention(now: Date())
            }
        }
    }

    func refreshQoder() {
        guard !qoderRefreshing else { return }
        qoderRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let run = CollectorRunner.run(provider: "qoder")
            guard let self else { return }
            await MainActor.run {
                if let output = run.output, let result = output.providers?["qoder"] {
                    self.apply(result, to: .qoder)
                } else {
                    self.qoderError = run.error ?? "采集器未返回 Qoder 数据"
                }
                self.lastQoderAt = Date()
                self.qoderRefreshing = false
                self.saveCache()
                self.recomputeAttention(now: Date())
            }
        }
    }

    enum QoderSetupPhase: Equatable {
        case idle
        case installing
        case preparing
        case waitingAuth(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .installing, .preparing, .waitingAuth:
                return true
            default:
                return false
            }
        }
    }

    @Published private(set) var qoderSetup: QoderSetupPhase = .idle
    private var loginPoll: Task<Void, Never>?

    func installQoderCLI() {
        guard !qoderSetup.isBusy else { return }
        guard Apps.confirm(
            title: "安装 Qoder CLI",
            info: "将从 Qoder 官方地址下载并执行安装脚本，完成后自动在浏览器发起登录授权。"
        ) else { return }
        qoderSetup = .installing
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CollectorRunner.action("qoder-install", timeout: 320)
            guard let self else { return }
            await MainActor.run {
                if let error = result.error {
                    self.qoderSetup = .failed(error)
                    self.qoderError = error
                    return
                }
                self.qoderSetup = .idle
                self.loginQoderCLI()
            }
        }
    }

    func loginQoderCLI() {
        guard !qoderSetup.isBusy else { return }
        qoderSetup = .preparing
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CollectorRunner.action("qoder-login", timeout: 45)
            guard let self else { return }
            await MainActor.run {
                if let error = result.error {
                    self.qoderSetup = .failed(error)
                    return
                }
                guard let string = result.action?.url, let url = URL(string: string) else {
                    self.qoderSetup = .failed("未获取到授权链接，请稍后重试")
                    return
                }
                NSWorkspace.shared.open(url)
                self.qoderSetup = .waitingAuth(url)
                self.pollQoderLogin()
            }
        }
    }

    func cancelQoderSetup() {
        loginPoll?.cancel()
        loginPoll = nil
        qoderSetup = .idle
    }

    private func pollQoderLogin() {
        loginPoll?.cancel()
        loginPoll = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.qoderSetup.isBusy else { return }
                let result = await Task.detached(priority: .utility) {
                    CollectorRunner.action("qoder-login-status", timeout: 20)
                }.value
                guard self.qoderSetup.isBusy, !Task.isCancelled else { return }
                switch result.action?.status {
                case "done":
                    self.qoderSetup = .idle
                    self.qoderError = nil
                    self.refreshQoder()
                    return
                case "failed":
                    self.qoderSetup = .failed(result.action?.message ?? "登录未完成")
                    return
                default:
                    continue
                }
            }
            self?.qoderSetup = .failed("登录等待超时，请重新发起")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func refreshNotificationStatus() {
        let center = notificationCenter
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let denied = settings.authorizationStatus == .denied
                let recovered = self.notificationsDenied && !denied
                self.notificationsDenied = denied
                if recovered {
                    self.refreshReminders()
                }
            }
        }
    }

    private func reminderSettingChanged() {
        refreshReminders()
        prepareNotificationAuthorization()
        recomputeAttention(now: Date())
    }

    private func prepareNotificationAuthorization() {
        guard remindQoderClaim || remindWorkBuddyClaim || remindCodexReset
                || alertLowBalance || alertExhaustion || alertAcceleration else { return }
        let center = notificationCenter
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.notificationsDenied = !granted
                        if granted {
                            self.refreshReminders()
                        }
                    }
                }
            case .denied:
                Task { @MainActor [weak self] in
                    self?.notificationsDenied = true
                }
            default:
                break
            }
        }
    }

    private func refreshReminders() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [
            ReminderID.qoder, ReminderID.workbuddy, ReminderID.codex,
        ])
        if remindQoderClaim {
            addDailyReminder(
                id: ReminderID.qoder,
                title: "Qoder 今日 100 Credits 可领取",
                body: "打开 Qoder 领取今日额度。",
                hour: 10,
                minute: 0,
                category: NotificationCategory.qoder
            )
        }
        if remindWorkBuddyClaim {
            addDailyReminder(
                id: ReminderID.workbuddy,
                title: "WorkBuddy 今日 100 积分可领取",
                body: "打开 WorkBuddy 领取今日积分。",
                hour: 0,
                minute: 0,
                category: NotificationCategory.workbuddy
            )
        }
        scheduleCodexReminder()
    }

    private func addDailyReminder(
        id: String,
        title: String,
        body: String,
        hour: Int,
        minute: Int,
        category: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        notificationCenter.add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger),
            withCompletionHandler: nil
        )
    }

    private func scheduleCodexReminder() {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [ReminderID.codex])
        guard remindCodexReset,
              let windows = codex?.windows,
              !windows.isEmpty,
              let window = windows.max(by: { $0.windowMinutes < $1.windowMinutes }),
              let reset = window.resetsAt else { return }
        let now = Int(Date().timeIntervalSince1970)
        guard reset > now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Codex \(Format.window(window.windowMinutes))额度已重置"
        content.body = "额度窗口已刷新，可以继续使用。"
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.codex
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(reset - now) + 30,
            repeats: false
        )
        notificationCenter.add(
            UNNotificationRequest(identifier: ReminderID.codex, content: content, trigger: trigger),
            withCompletionHandler: nil
        )
    }

    private func apply(_ result: ProviderResult, to provider: Provider) {
        guard result.ok == true else {
            let message = result.error ?? "未知错误"
            switch provider {
            case .codex: codexError = message
            case .workbuddy: workbuddyError = message
            case .qoder: qoderError = message
            }
            return
        }
        switch provider {
        case .codex:
            codex = result
            codexError = nil
            scheduleCodexReminder()
        case .workbuddy:
            workbuddy = result
            workbuddyError = nil
        case .qoder:
            qoder = result
            qoderError = nil
        }
        let usageProvider: UsageProvider
        switch provider {
        case .codex: usageProvider = .codex
        case .workbuddy: usageProvider = .workbuddy
        case .qoder: usageProvider = .qoder
        }
        recordHistory(provider: usageProvider, result: result)
        evaluateAlerts(provider: usageProvider, result: result)
    }

    func forecast(for provider: UsageProvider) -> UsageForecast? {
        guard let result = currentResult(for: provider), result.ok == true else { return nil }
        return UsageAnalytics.forecast(
            provider: provider,
            input: usageInput(result),
            samples: history(for: provider),
            lowThreshold: lowThreshold
        )
    }

    func insight(for provider: UsageProvider) -> UsageInsight? {
        guard let result = currentResult(for: provider), result.ok == true else { return nil }
        return UsageAnalytics.insight(
            provider: provider,
            input: usageInput(result),
            samples: history(for: provider)
        )
    }

    private func currentResult(for provider: UsageProvider) -> ProviderResult? {
        switch provider {
        case .qoder: return qoder
        case .workbuddy: return workbuddy
        case .codex: return codex
        }
    }

    private func usageInput(_ result: ProviderResult) -> UsageInput {
        UsageInput(
            remaining: result.remaining,
            total: result.total,
            remainingPercent: result.remainingPercent,
            windows: (result.windows ?? []).map {
                UsageWindow(
                    minutes: $0.windowMinutes,
                    remainingPercent: $0.remainingPercent,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
        )
    }

    private func history(for provider: UsageProvider) -> [UsageSample] {
        switch provider {
        case .qoder: return qoderHistory
        case .workbuddy: return workbuddyHistory
        case .codex: return codexHistory
        }
    }

    private func setHistory(_ samples: [UsageSample], for provider: UsageProvider) {
        switch provider {
        case .qoder: qoderHistory = samples
        case .workbuddy: workbuddyHistory = samples
        case .codex: codexHistory = samples
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: Self.historyURL),
              let file = try? JSONDecoder().decode(HistoryFile.self, from: data) else { return }
        let now = Date()
        qoderHistory = UsageAnalytics.prune(file.qoder ?? [], now: now)
        workbuddyHistory = UsageAnalytics.prune(file.workbuddy ?? [], now: now)
        codexHistory = UsageAnalytics.prune(file.codex ?? [], now: now)
    }

    private func seedHistoryFromCache() {
        let cached: [(UsageProvider, ProviderResult?)] = [
            (.qoder, qoder),
            (.workbuddy, workbuddy),
            (.codex, codex),
        ]
        for (provider, result) in cached {
            guard let result, result.ok == true, let date = result.updatedDate else { continue }
            recordHistory(provider: provider, result: result, at: date)
        }
    }

    private func recordHistory(provider: UsageProvider, result: ProviderResult, at date: Date? = nil) {
        let timestamp = date ?? result.updatedDate ?? Date()
        let input = usageInput(result)
        guard let sample = UsageAnalytics.sample(provider: provider, input: input, at: timestamp) else {
            return
        }
        var samples = history(for: provider)
        if let last = samples.last,
           sample.at - last.at < Int(UsageAnalytics.sampleInterval) {
            return
        }
        samples.append(sample)
        samples = UsageAnalytics.prune(samples)
        setHistory(samples, for: provider)
        saveHistory()
    }

    private func saveHistory() {
        let file = HistoryFile(
            qoder: qoderHistory,
            workbuddy: workbuddyHistory,
            codex: codexHistory
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        let directory = Self.historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.historyURL, options: .atomic)
    }

    func exportHistory() {
        UsageExport.save(qoder: qoderHistory, workbuddy: workbuddyHistory, codex: codexHistory)
    }

    private func evaluateAlerts(provider: UsageProvider, result: ProviderResult) {
        guard !notificationsDenied else { return }
        let input = usageInput(result)
        let now = Date()
        evaluateLowAlert(provider: provider, input: input, now: now)
        if provider == .codex {
            evaluateExhaustionAlert(input: input, now: now)
        }
        evaluateAccelerationAlert(provider: provider, input: input, now: now)
    }

    private func evaluateLowAlert(provider: UsageProvider, input: UsageInput, now: Date) {
        guard alertLowBalance else { return }
        guard let percent = UsageAnalytics.currentPercent(provider: provider, input: input) else {
            return
        }
        let key = "alert.low.\(provider.rawValue).last"
        let defaults = UserDefaults.standard
        if percent > lowRecovery {
            defaults.removeObject(forKey: key)
            return
        }
        guard percent <= lowThreshold else { return }
        let epoch = now.timeIntervalSince1970
        let last = defaults.double(forKey: key)
        guard last == 0 || epoch - last >= UsageAnalytics.lowCooldown else { return }

        let threshold = Int(lowThreshold)
        let rounded = Int(percent.rounded())
        let title: String
        let body: String
        if provider == .codex, let window = UsageAnalytics.lowestWindow(of: input) {
            title = "Codex \(UsageAnalytics.windowText(window.minutes))窗口低于 \(threshold)%"
            body = "当前剩余 \(rounded)%，请留意额度消耗或等待重置。"
        } else {
            title = "\(provider.displayName) 剩余低于 \(threshold)%"
            if let remaining = input.remaining {
                body = "当前剩余 \(Format.credits(remaining)) Credits（\(rounded)%），请及时领取或调整使用。"
            } else {
                body = "当前剩余 \(rounded)%，请及时领取或调整使用。"
            }
        }
        deliverAlert(
            id: "alert.low.\(provider.rawValue)",
            title: title,
            body: body,
            provider: provider
        ) {
            defaults.set(epoch, forKey: key)
        }
    }

    private func evaluateExhaustionAlert(input: UsageInput, now: Date) {
        guard alertExhaustion else { return }
        guard let forecast = UsageAnalytics.forecast(
            provider: .codex,
            input: input,
            samples: codexHistory,
            now: now,
            lowThreshold: lowThreshold
        ) else { return }
        guard let risk = forecast.windows
            .filter({ $0.exhaustsBeforeReset })
            .min(by: { $0.exhaustAt < $1.exhaustAt }) else { return }
        if alertLowBalance && risk.remainingPercent <= lowThreshold {
            return
        }
        guard let reset = risk.resetsAt else { return }

        let defaults = UserDefaults.standard
        let key = "alert.codex.exhaust.\(risk.minutes)"
        let resetEpoch = Int(reset.timeIntervalSince1970)
        guard defaults.integer(forKey: key) != resetEpoch else { return }

        let title = "Codex \(UsageAnalytics.windowText(risk.minutes))窗口可能在重置前耗尽"
        let body = "剩余 \(Int(risk.remainingPercent.rounded()))%，按近期速度预计 \(Format.reset(Int(risk.exhaustAt.timeIntervalSince1970))) 耗尽，早于重置时间 \(Format.reset(resetEpoch))。"
        deliverAlert(
            id: "alert.codex.exhaust.\(risk.minutes)",
            title: title,
            body: body,
            provider: .codex
        ) {
            defaults.set(resetEpoch, forKey: key)
        }
    }

    private func evaluateAccelerationAlert(provider: UsageProvider, input: UsageInput, now: Date) {
        guard alertAcceleration else { return }
        guard let percent = UsageAnalytics.currentPercent(provider: provider, input: input) else {
            return
        }
        if alertLowBalance && percent <= lowThreshold { return }

        let rates = UsageAnalytics.rampRates(
            provider: provider,
            input: input,
            samples: history(for: provider),
            now: now
        )
        guard let short = rates.short,
              let baseline = rates.baseline,
              baseline >= 0.2,
              short >= UsageAnalytics.rampMinimumRate,
              short >= baseline * UsageAnalytics.rampRatio else { return }

        let defaults = UserDefaults.standard
        let key = "alert.ramp.\(provider.rawValue).last"
        let epoch = now.timeIntervalSince1970
        let last = defaults.double(forKey: key)
        guard last == 0 || epoch - last >= UsageAnalytics.rampCooldown else { return }

        let ratio = short / baseline
        let body = "近 15 分钟消耗速度约为此前 1 小时的 \(String(format: "%.1f", ratio)) 倍，当前剩余 \(Int(percent.rounded()))%，请留意额度消耗。"
        deliverAlert(
            id: "alert.ramp.\(provider.rawValue)",
            title: "\(provider.displayName) 消耗速度明显加快",
            body: body,
            provider: provider
        ) {
            defaults.set(epoch, forKey: key)
        }
    }

    private func deliverAlert(
        id: String,
        title: String,
        body: String,
        provider: UsageProvider,
        onDelivered: (() -> Void)? = nil
    ) {
        let center = notificationCenter
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = NotificationCategory.forProvider(provider)
            content.threadIdentifier = "alerts.\(provider.rawValue)"
            let request = UNNotificationRequest(
                identifier: "\(id).\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if error == nil {
                    onDelivered?()
                }
            }
        }
    }

    private func resetLowAlertState() {
        for provider in UsageProvider.allCases {
            UserDefaults.standard.removeObject(forKey: "alert.low.\(provider.rawValue).last")
        }
    }

    private func scheduleTimers() {
        let fast = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFast() }
        }
        RunLoop.main.add(fast, forMode: .common)
        fastTimer = fast

        let qoder = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQoder() }
        }
        RunLoop.main.add(qoder, forMode: .common)
        qoderTimer = qoder
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        codex = cache.codex
        workbuddy = cache.workbuddy
        qoder = cache.qoder
        lastFastAt = cache.fastAt.map { Date(timeIntervalSince1970: $0) }
        lastQoderAt = cache.qoderAt.map { Date(timeIntervalSince1970: $0) }
    }

    private func saveCache() {
        let cache = CacheFile(
            codex: codex,
            workbuddy: workbuddy,
            qoder: qoder,
            fastAt: lastFastAt?.timeIntervalSince1970,
            qoderAt: lastQoderAt?.timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let directory = Self.cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}

enum Theme {
    static let qoder = Color(red: 0.20, green: 0.49, blue: 0.98)
    static let workbuddy = Color(red: 0.10, green: 0.68, blue: 0.42)
    static let codex = Color(red: 0.55, green: 0.36, blue: 0.95)
    static let warning = Color.orange
    static let danger = Color(nsColor: .systemRed)
    static let claim = Color(nsColor: .systemOrange)
}

enum Token {
    static let radiusCard: CGFloat = 12
    static let radiusControl: CGFloat = 8

    static let spaceTight: CGFloat = 6
    static let spaceRow: CGFloat = 8
    static let spaceCard: CGFloat = 12
    static let spaceSection: CGFloat = 12

    static let panelWidth: CGFloat = 382

    static let value = Font.system(size: 22, weight: .semibold)
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 11, weight: .medium)
    static let label = Font.system(size: 11, weight: .medium)
    static let meta = Font.system(size: 10)
    static let caption = Font.system(size: 10)

    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color(nsColor: .separatorColor)
    static let insetFill = Color.primary.opacity(0.04)
    static let hairline: CGFloat = 0.5
    static let detailMinHeight: CGFloat = 72
}

enum Format {
    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    static func credits(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "--" }
        decimal.maximumFractionDigits = digits
        decimal.minimumFractionDigits = 0
        return decimal.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    static func compact(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        if abs(value) >= 1000 {
            return String(format: "%.1fk", value / 1000)
        }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "从未" }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    static func window(_ minutes: Int) -> String {
        if minutes <= 0 { return "额度" }
        if minutes == 43200 { return "月度" }
        if minutes % 43200 == 0 { return "\(minutes / 43200) 月" }
        if minutes % 10080 == 0 { return "\(minutes / 10080) 周" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    static func reset(_ epoch: Int?) -> String {
        guard let epoch, epoch > 0 else { return "--" }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        formatter.dateFormat = sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func plan(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty, plan != "unknown" else { return nil }
        if plan == plan.lowercased() {
            return plan.capitalized
        }
        return plan
    }
}

struct UsageBar: View {
    let label: String
    let detail: String
    let fraction: Double
    let tint: Color

    private var normalized: Double {
        min(max(fraction.isFinite ? fraction : 0, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.spaceTight - 2) {
            HStack(spacing: 8) {
                Text(label)
                    .font(Token.label)
                Spacer(minLength: 8)
                Text(detail)
                    .font(Token.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.13))
                    Capsule().fill(tint).frame(width: max(3, geometry.size.width * normalized))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.25), value: normalized)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var days: Int = UsageAnalytics.chartDays

    var body: some View {
        GeometryReader { geometry in
            let points = self.points(in: geometry.size)
            ZStack(alignment: .topLeading) {
                baseline(in: geometry.size)
                if points.count >= 2, let last = points.last {
                    areaPath(points: points, height: geometry.size.height)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.18), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(points: points)
                        .stroke(
                            tint,
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                        )
                    todayMarker(in: geometry.size)
                    Circle()
                        .fill(tint)
                        .frame(width: 3, height: 3)
                        .position(last)
                } else {
                    Capsule()
                        .fill(tint.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .accessibilityLabel("近 \(days) 天剩余趋势，虚线为今日起点")
    }

    private func baseline(in size: CGSize) -> Path {
        var path = Path()
        guard size.width > 0, size.height > 0 else { return path }
        path.move(to: CGPoint(x: 0, y: size.height - Token.hairline))
        path.addLine(to: CGPoint(x: size.width, y: size.height - Token.hairline))
        return path
    }

    private func todayMarker(in size: CGSize) -> some View {
        Path { path in
            let x = size.width * todayFraction
            path.move(to: CGPoint(x: x, y: 1))
            path.addLine(to: CGPoint(x: x, y: size.height - 1))
        }
        .stroke(
            Color(nsColor: .secondaryLabelColor).opacity(0.6),
            style: StrokeStyle(lineWidth: Token.hairline, dash: [1.5, 1.5])
        )
    }

    private var todayFraction: CGFloat {
        let now = Date()
        let span = TimeInterval(max(1, days)) * 86400
        let chartStart = now.addingTimeInterval(-span)
        let startOfToday = Calendar.current.startOfDay(for: now)
        let raw = startOfToday.timeIntervalSince(chartStart) / max(span, 1)
        return min(max(CGFloat(raw), 0), 1)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 0
        let padding = max(1.0, (maximum - minimum) * 0.08)
        let low = max(0, minimum - padding)
        let high = maximum + padding
        let span = max(high - low, padding)
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = (value - low) / span
            let y = size.height - CGFloat(normalized) * max(1, size.height - 3) - 1.5
            return CGPoint(x: x, y: min(max(y, 1), size.height - 1))
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func areaPath(points: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: height))
        path.addLine(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.closeSubpath()
        return path
    }
}

struct ProviderLink {
    let title: String
    let icon: String
    let help: String
    let action: (() -> Void)?
}

struct ProviderCard<Detail: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let plan: String?
    let value: String
    let valueCaption: String
    let status: String?
    let footer: String
    let links: [ProviderLink]
    let detail: Detail

    init(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        plan: String? = nil,
        value: String,
        valueCaption: String,
        status: String? = nil,
        footer: String,
        links: [ProviderLink] = [],
        @ViewBuilder detail: () -> Detail
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.plan = plan
        self.value = value
        self.valueCaption = valueCaption
        self.status = status
        self.footer = footer
        self.links = links
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.spaceRow) {
            HStack(spacing: Token.spaceRow) {
                RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(color)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Token.title)
                    Text(subtitle)
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Token.spaceRow)
                if let plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Token.insetFill))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 24, height: 1)
                }
            }
            .frame(height: 28)

            HStack(alignment: .firstTextBaseline, spacing: Token.spaceTight) {
                Text(value)
                    .font(Token.value)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: Token.spaceTight)
                Text(valueCaption)
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 27)

            VStack(alignment: .leading, spacing: Token.spaceTight) {
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: status == nil ? Token.detailMinHeight : 0, alignment: .top)

            if let status {
                HStack(alignment: .top, spacing: Token.spaceTight - 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(status)
                        .font(Token.meta)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, Token.spaceTight)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                        .fill(Theme.warning.opacity(0.10))
                )
                .help(status)
            }

            Divider()
                .overlay(Color(nsColor: .separatorColor).opacity(0.5))

            HStack(spacing: Token.spaceRow) {
                Text(footer)
                    .font(Token.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: Token.spaceTight)
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button {
                        link.action?()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: link.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(link.title)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                                .fill(Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(link.action == nil)
                    .help(link.help)
                }
            }
            .frame(height: 20)
        }
        .padding(Token.spaceCard)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .fill(Token.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .stroke(Token.cardStroke.opacity(0.6), lineWidth: Token.hairline)
        )
    }
}

extension UsageStore {
    var menuBarText: String {
        var parts: [String] = []
        if showQoderInMenuBar { parts.append("Q \(qoderText)") }
        if showWorkBuddyInMenuBar { parts.append("W \(workbuddyText)") }
        if showCodexInMenuBar { parts.append("C \(codexText)") }
        return parts.isEmpty ? "AI" : parts.joined(separator: "   ")
    }

    var menuBarTooltip: String {
        var parts: [String] = []
        if !isAttentionMuted, let item = attentionItems.first {
            parts.append(item.kind == .warning ? "需要关注：\(item.title)" : "待处理：\(item.title)")
        }
        if let qoder, qoder.ok == true {
            var line = "Qoder 剩余 \(Format.credits(qoder.remaining)) / \(Format.credits(qoder.total)) Credits"
            if let suffix = forecastSuffix(for: .qoder) { line += " · \(suffix)" }
            parts.append(line)
        } else {
            parts.append("Qoder 不可用")
        }
        if let workbuddy, workbuddy.ok == true {
            var line = "WorkBuddy 剩余 \(Format.credits(workbuddy.remaining)) / \(Format.credits(workbuddy.total)) credits"
            if let suffix = forecastSuffix(for: .workbuddy) { line += " · \(suffix)" }
            parts.append(line)
        } else {
            parts.append("WorkBuddy 不可用")
        }
        if let codex, codex.ok == true, let window = codex.primaryWindow {
            var line = "Codex \(Format.window(window.windowMinutes))窗口剩余 \(Format.percent(window.remainingPercent))"
            if let suffix = forecastSuffix(for: .codex) { line += " · \(suffix)" }
            parts.append(line)
        } else {
            parts.append("Codex 不可用")
        }
        return parts.joined(separator: " · ")
    }

    private func forecastSuffix(for provider: UsageProvider) -> String? {
        guard let forecast = forecast(for: provider), forecast.text != "样本积累中" else {
            return nil
        }
        return forecast.text
    }

    private var qoderText: String {
        guard let qoder, qoder.ok == true, let remaining = qoder.remaining, (qoder.total ?? 0) > 0 else {
            return "--"
        }
        return Format.credits(remaining)
    }

    private var workbuddyText: String {
        guard let workbuddy, workbuddy.ok == true, let remaining = workbuddy.remaining else {
            return "--"
        }
        return Format.credits(remaining)
    }

    private var codexText: String {
        guard let codex, codex.ok == true, let window = codex.primaryWindow else { return "--" }
        return Format.percent(window.remainingPercent)
    }
}

struct MenuContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateChecker
    @State private var settingsExpanded: Bool

    init(store: UsageStore, updates: UpdateChecker, settingsExpanded: Bool = false) {
        self.store = store
        self.updates = updates
        self._settingsExpanded = State(initialValue: settingsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.spaceSection) {
            header
            attentionStrip
            updateBanner
            qoderCard
            workbuddyCard
            codexCard
            quickBar
            if settingsExpanded {
                settingsPanel
            }
            Divider()
            aboutRow
            footer
        }
        .padding(Token.spaceSection + 2)
        .frame(width: Token.panelWidth)
        .onAppear {
            store.refreshNotificationStatus()
            updates.checkIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 用量")
                    .font(.system(size: 16, weight: .bold))
                Text("Qoder · WorkBuddy · Codex")
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    store.refreshAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                settingsExpanded.toggle()
            } label: {
                Image(systemName: settingsExpanded ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(settingsExpanded ? "收起设置" : "展开菜单栏显示、提醒与智能预警设置")
            .accessibilityLabel("设置")
        }
    }

    private var quickBar: some View {
        HStack(spacing: Token.spaceTight) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
            Text("刷新 \(Format.time(store.lastFastAt))")
            Text("·").foregroundStyle(.quaternary)
            Text("Qoder \(Format.time(store.lastQoderAt))")
            Spacer(minLength: Token.spaceTight)
            settingChip(
                "预警 \(store.lowBalanceThreshold)%",
                isOn: $store.alertLowBalance,
                iconOn: "exclamationmark.triangle.fill",
                iconOff: "exclamationmark.triangle",
                help: "任一平台剩余低于 \(store.lowBalanceThreshold)% 时提醒"
            )
            Button {
                settingsExpanded.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text("更多设置")
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: settingsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(settingsExpanded ? "收起设置" : "展开更多设置")
        }
        .font(Token.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Token.spaceTight + 2)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                .fill(Token.insetFill)
        )
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: Token.spaceRow) {
            menuBarSettings
            reminderSettings
            alertSettings
            if store.notificationsDenied {
                HStack(spacing: 4) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("系统通知未授权，提醒与预警不会弹出")
                    Spacer(minLength: 4)
                    Button("去开启") {
                        Apps.openURL("x-apple.systempreferences:com.apple.preference.notifications")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.warning)
                }
                .font(Token.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Token.spaceTight + 2)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .fill(Token.insetFill)
        )
        .transition(.opacity)
    }

    @ViewBuilder
    private var attentionStrip: some View {
        if store.isAttentionMuted {
            HStack(spacing: 4) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 10, weight: .semibold))
                Text(store.mutedDescription)
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("取消静音") {
                    store.unmuteAttention()
                }
                .buttonStyle(.plain)
                .font(Token.caption)
                .foregroundStyle(Theme.claim)
            }
            .padding(.horizontal, Token.spaceTight + 2)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                    .fill(Token.insetFill)
            )
        } else if !store.attentionItems.isEmpty {
            VStack(alignment: .leading, spacing: Token.spaceTight) {
                ForEach(store.attentionItems) { item in
                    attentionRow(item)
                }
                HStack(spacing: 6) {
                    Text("\(store.attentionItems.count) 项需要留意")
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("静音 30 分钟") {
                        store.muteAttention()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(attentionTint.opacity(0.9))
                    .help("30 分钟内不再高亮菜单栏、也不再显示这条提示")
                }
            }
            .padding(Token.spaceRow)
            .background(
                RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                    .fill(attentionTint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                    .stroke(attentionTint.opacity(0.32), lineWidth: Token.hairline)
            )
        }
    }

    private var attentionTint: Color {
        store.attentionKind == .warning ? Theme.danger : Theme.claim
    }

    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(alignment: .top, spacing: Token.spaceTight) {
            Image(systemName: item.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.kind == .warning ? Theme.danger : Theme.claim)
                .frame(width: 14, alignment: .top)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Token.title)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail)
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Token.spaceTight)
            VStack(alignment: .trailing, spacing: 3) {
                Button(item.actionTitle) {
                    store.openClient(item.provider)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                if item.canDismiss {
                    Button("今天不再提醒") {
                        store.dismissClaimToday(item.provider)
                    }
                    .buttonStyle(.plain)
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var updateBanner: some View {
        if let release = updates.pendingRelease {
            HStack(spacing: Token.spaceRow) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.qoder)
                VStack(alignment: .leading, spacing: 1) {
                    Text("新版本 \(release.version) 可用")
                        .font(.system(size: 11, weight: .semibold))
                    Text(updateSubtitle)
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
                Spacer(minLength: Token.spaceTight)
                Button(updates.primaryActionTitle) {
                    updates.performPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 10, weight: .medium))
                .disabled(!updates.canPerformPrimaryAction)
            }
            .padding(Token.spaceRow)
            .background(
                RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                    .fill(Theme.qoder.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                    .stroke(Theme.qoder.opacity(0.20), lineWidth: Token.hairline)
            )
            .help(releaseHelp(release))
        } else if updates.showsResult {
            resultBanner
        }
    }

    private var resultBanner: some View {
        let failure = updates.lastError
        return HStack(spacing: Token.spaceRow) {
            Image(systemName: failure == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(failure == nil ? Theme.workbuddy : Theme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(failure == nil ? "已是最新版本 v\(updates.currentVersion)" : "检查更新失败")
                    .font(.system(size: 11, weight: .semibold))
                Text(
                    failure == nil
                        ? "上次检查 \(Format.time(updates.lastCheckAt)) · 每 24 小时自动检查一次"
                        : failure!
                )
                .font(Token.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: Token.spaceTight)
            Button("知道了") {
                updates.dismissResult()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 10, weight: .medium))
        }
        .padding(Token.spaceRow)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .fill((failure == nil ? Theme.workbuddy : Theme.warning).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .stroke((failure == nil ? Theme.workbuddy : Theme.warning).opacity(0.20), lineWidth: Token.hairline)
        )
    }

    private var updateSubtitle: String {
        switch updates.state {
        case .downloading:
            return "正在下载安装包…"
        case .ready(_, _, let verified):
            return verified
                ? "SHA-256 已校验 · 拖入「应用程序」完成升级"
                : "未找到校验值，SHA-256 未校验 · 拖入「应用程序」完成升级"
        default:
            return "当前 v\(updates.currentVersion)，可下载对应芯片安装包"
        }
    }

    private func releaseHelp(_ release: UpdateRelease) -> String {
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return "当前 v\(updates.currentVersion)" }
        return String(notes.prefix(500))
    }

    private var qoderCard: some View {
        ProviderCard(
            title: "Qoder",
            subtitle: "官方 CLI · 账号额度",
            icon: "curlybraces",
            color: Theme.qoder,
            plan: Format.plan(store.qoder?.plan),
            value: store.qoder?.ok == true ? Format.credits(store.qoder?.remaining) : "--",
            valueCaption: qoderCaption,
            status: store.qoderError,
            footer: qoderFooter,
            links: qoderLinks
        ) {
            if let qoder = store.qoder {
                let addonTotal = qoder.addonTotal ?? 0
                let addonUsed = qoder.addonUsed ?? 0
                let planTotal = qoder.planTotal ?? 0
                let planUsed = qoder.planUsed ?? 0
                if addonTotal > 0 {
                    UsageBar(
                        label: "附加额度",
                        detail: "已用 \(Format.credits(addonUsed)) / \(Format.credits(addonTotal))",
                        fraction: addonUsed / addonTotal,
                        tint: Theme.qoder
                    )
                }
                if planTotal > 0 {
                    UsageBar(
                        label: "套餐额度",
                        detail: "已用 \(Format.credits(planUsed)) / \(Format.credits(planTotal))",
                        fraction: planUsed / planTotal,
                        tint: Theme.qoder
                    )
                }
                if addonTotal == 0 && planTotal == 0 {
                    Text("当前套餐未包含 Credits")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
                if let expires = qoder.planExpiresAt, expires != "N/A", !expires.isEmpty {
                    Text("套餐到期 \(expires)")
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                }
                insightRow(.qoder)
                forecastRow(.qoder, tint: Theme.qoder)
            } else {
                emptyContent
            }
        }
    }

    private var qoderCaption: String {
        guard store.qoder?.ok == true, let total = store.qoder?.total, total > 0 else {
            return "等待采集"
        }
        return "剩余 / 共 \(Format.credits(total)) Credits"
    }

    private var workbuddyCard: some View {
        ProviderCard(
            title: "WorkBuddy",
            subtitle: "本机客户端 · 资源包",
            icon: "briefcase.fill",
            color: Theme.workbuddy,
            plan: Format.plan(store.workbuddy?.plan),
            value: store.workbuddy?.ok == true ? Format.credits(store.workbuddy?.remaining) : "--",
            valueCaption: workbuddyCaption,
            status: store.workbuddyError,
            footer: workbuddyFooter,
            links: workbuddyLinks
        ) {
            if let workbuddy = store.workbuddy, let total = workbuddy.total, total > 0 {
                UsageBar(
                    label: "Credits",
                    detail: "已用 \(Format.credits(workbuddy.used)) / \(Format.credits(total))",
                    fraction: (workbuddy.usedPercent ?? 0) / 100,
                    tint: Theme.workbuddy
                )
                if let packages = workbuddy.packages, packages > 0 {
                    Text("\(packages) 个资源包")
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                }
                insightRow(.workbuddy)
                forecastRow(.workbuddy, tint: Theme.workbuddy)
            } else if store.workbuddy != nil {
                Text("暂无可用的 Credits 资源包")
                    .font(Token.meta)
                    .foregroundStyle(.secondary)
            } else {
                emptyContent
            }
        }
    }

    private var workbuddyCaption: String {
        guard store.workbuddy?.ok == true, let total = store.workbuddy?.total, total > 0 else {
            return "等待采集"
        }
        return "剩余 / 共 \(Format.credits(total)) credits"
    }

    private var codexCard: some View {
        ProviderCard(
            title: "Codex",
            subtitle: "ChatGPT 登录 · 限额窗口",
            icon: "terminal.fill",
            color: Theme.codex,
            plan: Format.plan(store.codex?.plan),
            value: codexValue,
            valueCaption: codexCaption,
            status: store.codexError,
            footer: codexFooter,
            links: codexLinks
        ) {
            if let codex = store.codex {
                if let windows = codex.windows, !windows.isEmpty {
                    ForEach(windows) { window in
                        UsageBar(
                            label: "\(Format.window(window.windowMinutes))窗口",
                            detail: "已用 \(Format.percent(window.usedPercent)) · 剩余 \(Format.percent(window.remainingPercent))",
                            fraction: window.usedPercent / 100,
                            tint: Theme.codex
                        )
                    }
                    if let reset = windows.first?.resetsAt {
                        Text("重置于 \(Format.reset(reset))")
                            .font(Token.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("当前账号没有限额窗口")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("额外 Credits")
                    Spacer()
                    if let credits = codex.credits, credits.hasCredits {
                        Text(credits.unlimited ? "无限" : "余额 \(Format.credits(credits.balance, digits: 2))")
                    } else {
                        Text("无")
                    }
                }
                .font(Token.caption)
                .foregroundStyle(.secondary)
                insightRow(.codex)
                forecastRow(.codex, tint: Theme.codex)
            } else {
                emptyContent
            }
        }
    }

    private var codexValue: String {
        guard store.codex?.ok == true, let window = store.codex?.primaryWindow else { return "--" }
        return Format.percent(window.remainingPercent)
    }

    private var codexCaption: String {
        guard store.codex?.ok == true, let window = store.codex?.primaryWindow else {
            return "等待采集"
        }
        return "\(Format.window(window.windowMinutes))窗口剩余"
    }

    @ViewBuilder
    private func forecastRow(_ provider: UsageProvider, tint: Color) -> some View {
        if let forecast = store.forecast(for: provider) {
            HStack(spacing: 7) {
                Sparkline(values: forecast.values, tint: tint)
                    .frame(width: 62, height: 18)
                Text(forecast.text)
                    .font(.system(size: 10, weight: forecast.warning ? .semibold : .regular))
                    .foregroundStyle(forecast.warning ? Theme.warning : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(forecast.help)
        }
    }

    @ViewBuilder
    private func insightRow(_ provider: UsageProvider) -> some View {
        if let insight = store.insight(for: provider) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 10, weight: .semibold))
                Text(insightText(insight))
                    .font(Token.meta)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .help("按本机历史采样估算，领取或重置带来的增加不计入消耗；日均需至少 6 小时样本，已观察 \(insight.observedDays) 天。")
        }
    }

    private func insightText(_ insight: UsageInsight) -> String {
        let today = insight.todayConsumed.map {
            "今日消耗 \(insightValue($0, percent: insight.isPercent))"
        } ?? "今日消耗 --"
        let average = insight.dailyAverage.map {
            "近7日日均 \(insightValue($0, percent: insight.isPercent))/天"
        } ?? "近7日日均 --"
        return "\(today) · \(average)"
    }

    private func insightValue(_ value: Double, percent: Bool) -> String {
        if percent {
            return value > 0 && value < 10
                ? String(format: "%.1f%%", value)
                : Format.percent(value)
        }
        return "\(Format.credits(value)) Credits"
    }

    private var emptyContent: some View {
        Text("暂无数据")
            .font(Token.meta)
            .foregroundStyle(.secondary)
    }

    private var qoderFooter: String {
        if store.qoderError != nil, store.qoder != nil {
            return "上次成功 \(Format.time(store.qoder?.updatedDate))"
        }
        return "更新于 \(Format.time(store.qoder?.updatedDate ?? store.lastQoderAt))"
    }

    private var workbuddyFooter: String {
        if store.workbuddyError != nil, store.workbuddy != nil {
            return "上次成功 \(Format.time(store.workbuddy?.updatedDate))"
        }
        return "更新于 \(Format.time(store.workbuddy?.updatedDate ?? store.lastFastAt))"
    }

    private var codexFooter: String {
        if store.codexError != nil, store.codex != nil {
            return "上次成功 \(Format.time(store.codex?.updatedDate))"
        }
        return "更新于 \(Format.time(store.codex?.updatedDate ?? store.lastFastAt))"
    }

    private var qoderLinks: [ProviderLink] {
        var links = [
            ProviderLink(
                title: "打开",
                icon: "arrow.up.forward.app",
                help: "打开 Qoder CN"
            ) {
                Apps.open(bundleID: "com.qodercn.app", fallback: "/Applications/Qoder CN.app")
            },
            ProviderLink(
                title: "官网",
                icon: "globe",
                help: "打开 Qoder 官网"
            ) {
                Apps.openURL("https://qoder.com.cn")
            },
        ]
        switch store.qoderSetup {
        case .installing:
            links.append(ProviderLink(
                title: "安装中",
                icon: "arrow.down.circle",
                help: "正在下载并执行官方安装脚本，约需 1-2 分钟"
            ) {})
        case .preparing:
            links.append(ProviderLink(
                title: "准备授权",
                icon: "link",
                help: "正在获取登录授权链接"
            ) {})
        case .waitingAuth(let url):
            links.append(ProviderLink(
                title: "等待授权",
                icon: "link",
                help: "在浏览器完成登录后会自动刷新；点击可重新打开授权页"
            ) {
                NSWorkspace.shared.open(url)
            })
            links.append(ProviderLink(
                title: "取消",
                icon: "xmark",
                help: "取消本次登录"
            ) {
                store.cancelQoderSetup()
            })
        case .failed(let message):
            links.append(ProviderLink(
                title: "重试登录",
                icon: "arrow.clockwise",
                help: message
            ) {
                store.loginQoderCLI()
            })
            links.append(ProviderLink(
                title: "终端处理",
                icon: "terminal",
                help: "授权页无法完成时，在终端手动执行登录：" + message
            ) {
                Apps.openTerminal("~/.local/bin/qoderclicn login")
            })
        case .idle:
            if let error = store.qoderError {
                if error.contains("未登录") {
                    links.append(ProviderLink(
                        title: "登录",
                        icon: "person.crop.circle.badge.questionmark",
                        help: "在浏览器完成 Qoder CLI 登录"
                    ) {
                        store.loginQoderCLI()
                    })
                } else if error.contains("未安装") {
                    links.append(ProviderLink(
                        title: "安装 CLI",
                        icon: "arrow.down.circle",
                        help: "下载并安装官方 Qoder CLI，完成后自动登录"
                    ) {
                        store.installQoderCLI()
                    })
                }
            }
        }
        return links
    }

    private var workbuddyLinks: [ProviderLink] {
        [
            ProviderLink(
                title: "打开",
                icon: "arrow.up.forward.app",
                help: "打开 WorkBuddy"
            ) {
                Apps.open(bundleID: "com.tencent.workbuddy.mac", fallback: "/Applications/WorkBuddy.app")
            },
            ProviderLink(
                title: "官网",
                icon: "globe",
                help: "打开 WorkBuddy 官网"
            ) {
                Apps.openURL("https://www.workbuddy.cn")
            },
        ]
    }

    private var codexLinks: [ProviderLink] {
        [
            ProviderLink(
                title: "打开",
                icon: "arrow.up.forward.app",
                help: "打开 ChatGPT"
            ) {
                Apps.open(bundleID: "com.openai.codex", fallback: "/Applications/ChatGPT.app")
            },
            ProviderLink(
                title: "官网",
                icon: "globe",
                help: "打开 Codex 官网"
            ) {
                Apps.openURL("https://openai.com/codex/")
            },
        ]
    }

    private func settingRow<Chips: View>(
        _ label: String,
        @ViewBuilder chips: () -> Chips
    ) -> some View {
        HStack(spacing: Token.spaceTight) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            chips()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var menuBarSettings: some View {
        settingRow("菜单栏") {
            settingChip(
                "Qoder",
                isOn: $store.showQoderInMenuBar,
                iconOn: "eye.fill",
                iconOff: "eye.slash",
                help: "在菜单栏显示 Qoder"
            )
            settingChip(
                "WorkBuddy",
                isOn: $store.showWorkBuddyInMenuBar,
                iconOn: "eye.fill",
                iconOff: "eye.slash",
                help: "在菜单栏显示 WorkBuddy"
            )
            settingChip(
                "Codex",
                isOn: $store.showCodexInMenuBar,
                iconOn: "eye.fill",
                iconOff: "eye.slash",
                help: "在菜单栏显示 Codex"
            )
        }
        settingRow("注意力") {
            settingChip(
                "高亮",
                isOn: $store.menuBarHighlight,
                iconOn: "paintbrush.pointed.fill",
                iconOff: "paintbrush.pointed",
                help: "有告警时菜单栏文字变红并加 ⚠，待领取时变橙色"
            )
            settingChip(
                "闪动",
                isOn: $store.menuBarBlink,
                iconOn: "lightbulb.fill",
                iconOff: "lightbulb",
                help: "新提醒出现后菜单栏闪动 60 秒，打开面板即停止"
            )
        }
    }

    private var reminderSettings: some View {
        settingRow("提醒") {
            settingChip(
                "Qoder",
                isOn: $store.remindQoderClaim,
                iconOn: "bell.fill",
                iconOff: "bell.slash",
                help: "每天 10:00 提醒领取 Qoder 100 Credits"
            )
            settingChip(
                "WorkBuddy",
                isOn: $store.remindWorkBuddyClaim,
                iconOn: "bell.fill",
                iconOff: "bell.slash",
                help: "每天 00:00 提醒领取 WorkBuddy 100 积分"
            )
            settingChip(
                "Codex",
                isOn: $store.remindCodexReset,
                iconOn: "bell.fill",
                iconOff: "bell.slash",
                help: "Codex 额度重置时提醒"
            )
        }
    }

    private var alertSettings: some View {
        VStack(alignment: .leading, spacing: Token.spaceTight - 1) {
            settingRow("智能预警") {
                settingChip(
                    "低额度",
                    isOn: $store.alertLowBalance,
                    iconOn: "exclamationmark.triangle.fill",
                    iconOff: "exclamationmark.triangle",
                    help: "剩余低于 \(store.lowBalanceThreshold)% 时提醒"
                )
                settingChip(
                    "重置前耗尽",
                    isOn: $store.alertExhaustion,
                    iconOn: "clock.fill",
                    iconOff: "clock",
                    help: "Codex 预计在额度重置前耗尽时提醒"
                )
                settingChip(
                    "消耗加速",
                    isOn: $store.alertAcceleration,
                    iconOn: "bolt.fill",
                    iconOff: "bolt",
                    help: "近 15 分钟消耗速度明显高于此前 1 小时时提醒"
                )
            }
            if store.alertLowBalance {
                settingRow("低额度阈值") {
                    ForEach([10, 20, 30], id: \.self) { value in
                        thresholdChip(value)
                    }
                }
            }
        }
    }

    private func thresholdChip(_ value: Int) -> some View {
        let selected = store.lowBalanceThreshold == value
        return Button("\(value)%") {
            store.lowBalanceThreshold = value
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: selected ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(selected ? Theme.warning : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(selected ? Theme.warning.opacity(0.14) : Token.insetFill)
        )
        .overlay(
            Capsule().stroke(
                selected ? Theme.warning.opacity(0.28) : Token.cardStroke.opacity(0.5),
                lineWidth: Token.hairline
            )
        )
        .help("低于 \(value)% 时提醒，恢复至 \(value + Int(UsageAnalytics.lowRecoveryGap))% 以上后重新布防")
    }

    private func settingChip(
        _ title: String,
        isOn: Binding<Bool>,
        iconOn: String,
        iconOff: String,
        help: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? iconOn : iconOff)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .fixedSize()
            .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.primary.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                    .stroke(
                        Token.cardStroke.opacity(isOn.wrappedValue ? 0.8 : 0.4),
                        lineWidth: Token.hairline
                    )
            )
        }
        .buttonStyle(.plain)
        .help("\(help)（\(isOn.wrappedValue ? "已开启" : "已关闭")）")
    }

    private var aboutRow: some View {
        HStack(spacing: 5) {
            Text("v\(updates.currentVersion)")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.quaternary)
            Button("GitHub") {
                Apps.openURL("https://github.com/pumf/token_tool")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开项目源码")
            Text("·")
                .foregroundStyle(.quaternary)
            Button("MIT") {
                if let license = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
                    NSWorkspace.shared.open(license)
                } else {
                    Apps.openURL("https://opensource.org/license/mit")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("查看随应用附带的 MIT 许可证")
            if let lastCheckAt = updates.lastCheckAt {
                Text("·")
                    .foregroundStyle(.quaternary)
                Text("检查于 \(Format.ago(lastCheckAt))")
                    .foregroundStyle(.tertiary)
                    .help("GitHub Releases 检查节奏为每 24 小时一次，也可点击右侧按钮立即检查")
            }
            Spacer(minLength: 4)
            updateControl
        }
        .font(Token.meta)
    }

    @ViewBuilder
    private var updateControl: some View {
        switch updates.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("检查中")
            }
            .foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("下载中")
            }
            .foregroundStyle(.secondary)
        case .ready:
            Text("安装包已就绪")
                .foregroundStyle(.secondary)
        case .upToDate:
            Button("已是最新 · \(Format.time(updates.lastCheckAt))") {
                updates.checkFromUser()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("上次检查 \(Format.ago(updates.lastCheckAt))；每 24 小时自动检查一次，点击立即重新检查")
        case .failed(let message):
            Button("重试检查") {
                updates.checkFromUser()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.warning)
            .help(message)
        case .idle, .available:
            Button("检查更新") {
                updates.checkFromUser()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("从 GitHub Releases 检查新版本（当前 v\(updates.currentVersion)）")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                )
            ) {
                Text("开机启动")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Spacer()
            Button("导出") {
                store.exportHistory()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help("导出近 14 天用量历史为 CSV")
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateChecker
    let maxHeight: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            MenuContent(store: store, updates: updates)
        }
        .frame(width: 382)
        .frame(maxHeight: maxHeight)
        .background(.regularMaterial)
    }
}

enum Apps {
    static func open(bundleID: String, fallback: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: fallback),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    static func confirm(title: String, info: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }
}
