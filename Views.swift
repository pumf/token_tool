import SwiftUI
import AppKit
import Combine
import Darwin
@preconcurrency import UserNotifications

/// 采集器字段全部按可选解码：上游改字段名或删字段时，这一家降级成「部分未知」，
/// 不会让整份 JSON 解码失败、把另外两家一起打回「无法解析」。
struct CodexWindow: Codable, Sendable, Identifiable {
    let id: String
    let windowMinutes: Int?
    let usedPercent: Double?
    let remainingPercent: Double?
    let resetsAt: Int?

    private enum CodingKeys: String, CodingKey {
        case id, windowMinutes, usedPercent, remainingPercent, resetsAt
    }

    init(
        id: String,
        windowMinutes: Int?,
        usedPercent: Double?,
        remainingPercent: Double?,
        resetsAt: Int?
    ) {
        self.id = id
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minutes = (try? container.decode(Int.self, forKey: .windowMinutes)) ?? nil
        let percent = (try? container.decode(Double.self, forKey: .usedPercent)) ?? nil
        id = (try? container.decode(String.self, forKey: .id)) ?? "window-\(minutes ?? 0)"
        windowMinutes = minutes
        usedPercent = percent
        remainingPercent = (try? container.decode(Double.self, forKey: .remainingPercent)) ?? nil
        resetsAt = (try? container.decode(Int.self, forKey: .resetsAt)) ?? nil
    }
}

struct CodexCredits: Codable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
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

    private enum CodingKeys: String, CodingKey {
        case ok, error, updatedAt, plan, accountType, windows, credits, resetCredits
        case total, remaining, used, usedPercent, remainingPercent, packages, unit
        case planExpiresAt, planUsed, planTotal, addonUsed, addonTotal
        case orgResourcePackage, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.loose(Bool.self, .ok)
        error = container.loose(String.self, .error)
        updatedAt = container.loose(Int.self, .updatedAt)
        plan = container.loose(String.self, .plan)
        accountType = container.loose(String.self, .accountType)
        windows = container.loose([CodexWindow].self, .windows)
        credits = container.loose(CodexCredits.self, .credits)
        resetCredits = container.loose(Int.self, .resetCredits)
        total = container.loose(Double.self, .total)
        remaining = container.loose(Double.self, .remaining)
        used = container.loose(Double.self, .used)
        usedPercent = container.loose(Double.self, .usedPercent)
        remainingPercent = container.loose(Double.self, .remainingPercent)
        packages = container.loose(Int.self, .packages)
        unit = container.loose(String.self, .unit)
        planExpiresAt = container.loose(String.self, .planExpiresAt)
        planUsed = container.loose(Double.self, .planUsed)
        planTotal = container.loose(Double.self, .planTotal)
        addonUsed = container.loose(Double.self, .addonUsed)
        addonTotal = container.loose(Double.self, .addonTotal)
        orgResourcePackage = container.loose(String.self, .orgResourcePackage)
        source = container.loose(String.self, .source)
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer {
    /// 字段级宽容解码：类型不符就当没有，而不是让整个对象解码失败。
    func loose<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

struct CollectorOutput: Decodable, Sendable {
    let version: Int?
    let updatedAt: Int?
    let providers: [String: ProviderResult]?
    /// 解码失败或版本不符的 provider，键为采集器里的名字，值为可直接展示的中文原因。
    let providerErrors: [String: String]

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, providers
    }

    static let supportedVersion = 1

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.loose(Int.self, .version)
        updatedAt = container.loose(Int.self, .updatedAt)
        var parsed: [String: ProviderResult] = [:]
        var failures: [String: String] = [:]
        if version != nil, version != Self.supportedVersion {
            failures["all"] = "采集器输出版本 \(version!) 与当前应用不匹配"
        }
        if let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .providers) {
            for key in nested.allKeys {
                if let result = try? nested.decode(ProviderResult.self, forKey: key) {
                    parsed[key.stringValue] = result
                } else {
                    failures[key.stringValue] = "该平台的返回结构已变化，请升级应用"
                }
            }
        } else if container.contains(.providers) {
            failures["all"] = "采集器返回的 providers 不是对象"
        }
        providers = parsed.isEmpty ? nil : parsed
        providerErrors = failures
    }
}

struct CollectorAction: Decodable, Sendable {
    let ok: Bool
    let status: String?
    let cli: String?
    let url: String?
    let message: String?
    let error: String?
}

/// 通知分类与「打开客户端」按钮的标识符。旧版本按供应商手写，这里改成从枚举原值派生，
/// 保持既有字符串不变（provider.qoder / open.qoder ...），已发出的通知仍可正常响应。
enum NotificationCategory {
    static func forProvider(_ provider: UsageProvider) -> String {
        "provider.\(provider.rawValue)"
    }

    static func openAction(for provider: UsageProvider) -> String {
        "open.\(provider.rawValue)"
    }

    static var all: [String] {
        Providers.ordered.map { forProvider($0.id) }
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
        let tag = UUID().uuidString
        let outputURL = directory.appendingPathComponent("tokentool-\(tag).out")
        let errorURL = directory.appendingPathComponent("tokentool-\(tag).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let process = Process()
        var didLaunch = false
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL),
              let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            return .failure("无法创建采集器输出文件")
        }
        defer {
            // 无论走哪条返回路径都要关句柄、回收子进程、删临时文件；
            // 旧实现在超时分支直接 return，每次超时都留下一个僵尸进程和两个未关闭的 fd。
            try? outputHandle.close()
            try? errorHandle.close()
            if didLaunch { reap(process) }
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        do {
            try process.run()
            didLaunch = true
        } catch {
            return .failure("无法启动采集器：\(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let timedOut = process.isRunning
        if didLaunch { reap(process) }
        let stderr = readTail(of: errorURL, bytes: 600)
        if timedOut {
            return .failure(classify(timeout: timeout, stderr: stderr))
        }
        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            return .failure(classify(status: process.terminationStatus, stderr: stderr))
        }
        if process.terminationStatus != 0, !stderr.isEmpty {
            Diagnostics.record("collector", "退出码 \(process.terminationStatus)：\(stderr)")
        }
        return .success(data)
    }

    /// 先 TERM、再 KILL，最后 waitUntilExit 收尸；重复调用安全。
    private static func reap(_ process: Process) {
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }

    private static func readTail(of url: URL, bytes: Int) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let tail = data.suffix(bytes)
        return String(decoding: tail, as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(3)
            .joined(separator: " / ")
    }

    /// 把「python3 不存在」「需要命令行工具」这类环境问题说清楚，而不是统一报采集超时。
    private static func classify(timeout: TimeInterval, stderr: String) -> String {
        let reason = stderr.isEmpty ? "" : "（\(stderr)）"
        return "采集超时 \(Int(timeout)) 秒\(reason)"
    }

    private static func classify(status: Int32, stderr: String) -> String {
        if stderr.contains("python3") && stderr.contains("No such file") {
            return "本机没有 python3，请安装 Xcode 命令行工具（xcode-select --install）后重试"
        }
        if stderr.contains("xcode-select") {
            return "需要先安装 Xcode 命令行工具才能采集（xcode-select --install）"
        }
        if status == 127 {
            return "找不到 python3，请安装 Xcode 命令行工具后重试"
        }
        let reason = stderr.isEmpty ? "" : "：\(stderr)"
        return "采集器没有输出任何数据（退出码 \(status)\(reason)）"
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
    /// 一家供应商的运行态。名称、口径、采集节奏、客户端等静态属性都在 Providers 注册表里，
    /// 这里只按供应商索引保存会随采集变化的数据。
    struct ProviderState {
        var result: ProviderResult?
        var error: String?
        var history: [UsageSample] = []
        var lastCollectedAt: Date?
        var isRefreshing = false
    }

    @Published private var states: [UsageProvider: ProviderState] = [:]
    /// 菜单栏显示与领取提醒的开关；落盘键名由注册表登记，保持与旧版本一致。
    @Published private var menuBarVisibility: [UsageProvider: Bool] = [:]
    @Published private var reminderVisibility: [UsageProvider: Bool] = [:]
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
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
    @Published var simpleMode: Bool {
        didSet { UserDefaults.standard.set(simpleMode, forKey: "ui.simpleMode") }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBar.style") }
    }
    @Published private(set) var attentionItems: [AttentionItem] = []
    @Published private(set) var attentionSince: Date?
    @Published private(set) var mutedUntil: Date?
    @Published private(set) var notificationsDenied = false

    private lazy var notificationCenter = UNUserNotificationCenter.current()

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/cache.json")
    }

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/history.json")
    }

    /// 每次写入前轮换出来的上一份历史，主文件损坏时用它回退。
    private static var historyBackupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/history.json.bak")
    }

    private var refreshTimers: [Timer] = []

    private static func storedFlag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private static func storedLowThreshold() -> Int {
        let value = UserDefaults.standard.integer(forKey: "alert.low.threshold")
        return [10, 20, 30].contains(value) ? value : 20
    }

    /// 注册表里的刷新节奏分组，间隔小的排在前面。
    private static let groups = Providers.groups

    init(refreshOnStart: Bool = true) {
        alertLowBalance = Self.storedFlag("alert.low")
        alertExhaustion = Self.storedFlag("alert.exhaustion")
        alertAcceleration = Self.storedFlag("alert.acceleration")
        lowBalanceThreshold = Self.storedLowThreshold()
        menuBarHighlight = Self.storedFlag("attention.menuBar.highlight")
        menuBarBlink = Self.storedFlag("attention.menuBar.blink")
        simpleMode = UserDefaults.standard.object(forKey: "ui.simpleMode") as? Bool ?? false
        menuBarStyle = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBar.style") ?? "") ?? .classic
        let muteEpoch = UserDefaults.standard.double(forKey: "attention.mute.until")
        mutedUntil = muteEpoch > 0 ? Date(timeIntervalSince1970: muteEpoch) : nil
        for descriptor in Providers.all {
            states[descriptor.id] = ProviderState()
            menuBarVisibility[descriptor.id] = Self.storedFlag(descriptor.menuBarDefaultsKey)
            reminderVisibility[descriptor.id] = Self.storedFlag(descriptor.reminderDefaultsKey)
        }
        loadCache()
        loadHistory()
        seedHistoryFromCache()
        recomputeAttention(now: Date())
        guard refreshOnStart else { return }
        refreshReminders()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.prepareNotificationAuthorization()
        }
        // 采集器都是子进程，启动时按分组错峰开跑，避免几家的 python3 同时抢 CPU。
        for (index, group) in Self.groups.enumerated() {
            let delay = Double(index) * 1.2
            if delay == 0 {
                refresh(group.providers)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refresh(group.providers)
                }
            }
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

    // MARK: 按供应商索引的运行态

    func result(for provider: UsageProvider) -> ProviderResult? { states[provider]?.result }
    func error(for provider: UsageProvider) -> String? { states[provider]?.error }
    func history(for provider: UsageProvider) -> [UsageSample] { states[provider]?.history ?? [] }
    func lastCollectedAt(for provider: UsageProvider) -> Date? { states[provider]?.lastCollectedAt }
    func isRefreshing(_ provider: UsageProvider) -> Bool { states[provider]?.isRefreshing ?? false }
    func isShownInMenuBar(_ provider: UsageProvider) -> Bool { menuBarVisibility[provider] ?? true }
    func isReminderEnabled(_ provider: UsageProvider) -> Bool { reminderVisibility[provider] ?? true }

    func menuBarBinding(for provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { self.isShownInMenuBar(provider) },
            set: { value in
                self.menuBarVisibility[provider] = value
                UserDefaults.standard.set(value, forKey: provider.descriptor.menuBarDefaultsKey)
            }
        )
    }

    func reminderBinding(for provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { self.isReminderEnabled(provider) },
            set: { value in
                self.reminderVisibility[provider] = value
                UserDefaults.standard.set(value, forKey: provider.descriptor.reminderDefaultsKey)
                self.reminderSettingChanged()
            }
        )
    }

    /// 页脚的采集时间戳：节奏最快的一组沿用的是「刷新」这个叫法，其余按组内供应商名。
    var refreshSummaries: [(label: String, at: Date?)] {
        Self.groups.enumerated().map { index, group in
            let label = index == 0
                ? "刷新"
                : group.providers.map(\.displayName).joined(separator: "/")
            let at = group.providers.compactMap { states[$0]?.lastCollectedAt }.max()
            return (label, at)
        }
    }

    var isRefreshing: Bool { Providers.all.contains { self.isRefreshing($0.id) } }
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
        let descriptor = provider.descriptor
        Apps.open(bundleID: descriptor.clientBundleID, fallback: descriptor.clientAppPath)
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
                guard let result = availableResult(for: provider) else { continue }
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
                actionTitle: "打开 \(provider.descriptor.clientName)",
                canDismiss: false
            )
        }
        guard alertExhaustion,
              let forecast = forecast(for: provider),
              forecast.warning,
              forecast.text.hasSuffix("后耗尽") else { return nil }

        let detail: String
        if provider.isPercent,
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
            actionTitle: "打开 \(provider.descriptor.clientName)",
            canDismiss: false
        )
    }

    private func claimItem(provider: UsageProvider, input: UsageInput, now: Date) -> AttentionItem? {
        guard isReminderEnabled(provider) else { return nil }
        switch provider.descriptor.claimReminder {
        case let .daily(hour, grant, _):
            return dailyClaimItem(
                provider: provider,
                claimHour: hour,
                grant: grant,
                input: input,
                now: now
            )
        case .windowReset:
            return windowResetClaimItem(provider: provider, input: input, now: now)
        }
    }

    /// 窗口制没有「领取」动作，改在最近一个限额窗口即将重置时提醒。
    private func windowResetClaimItem(provider: UsageProvider, input: UsageInput, now: Date) -> AttentionItem? {
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
        let key = "attention.claim.dismiss.\(provider.rawValue)"
        if UserDefaults.standard.string(forKey: key) == Self.dayKey(now) { return nil }
        return AttentionItem(
            id: "claim.\(provider.rawValue)",
            provider: provider,
            kind: .claim,
            icon: "clock.arrow.circlepath",
            title: "\(provider.displayName) \(UsageAnalytics.windowText(window.minutes))窗口即将重置",
            detail: "\(Format.reset(reset)) 刷新额度，重置后可继续使用。",
            actionTitle: "打开 \(provider.descriptor.clientName)",
            canDismiss: true
        )
    }

    private func dailyClaimItem(
        provider: UsageProvider,
        claimHour: Int,
        grant: String,
        input: UsageInput,
        now: Date
    ) -> AttentionItem? {
        guard input.remaining != nil, let total = input.total, total > 0 else { return nil }
        guard let claimAt = Calendar.current.date(
            bySettingHour: claimHour, minute: 0, second: 0, of: now
        ), now >= claimAt else { return nil }
        let key = "attention.claim.dismiss.\(provider.rawValue)"
        if UserDefaults.standard.string(forKey: key) == Self.dayKey(now) { return nil }
        guard !receivedClaimToday(provider: provider, input: input, now: now) else { return nil }
        return AttentionItem(
            id: "claim.\(provider.rawValue)",
            provider: provider,
            kind: .claim,
            icon: "gift.fill",
            title: "\(provider.displayName) 今日 \(grant) 待领取",
            detail: "领取成功后此提示会自动消失；今天不需要可先忽略。",
            actionTitle: "打开 \(provider.descriptor.clientName)",
            canDismiss: true
        )
    }

    /// 今天是否已经领到过量：领取会把剩余与总量同时抬高，消耗只让剩余下降，
    /// 资源包过期则让总量下降，因此「任一相邻样本出现增加」就是已领取的可靠信号。
    /// 判定从当天 00:00 起算而不是从领取时点起算，提前或延后领取都不会误报。
    /// 历史是 5 分钟一个采样点，所以还要把最新一次采集值当作相邻点再比一次。
    private func receivedClaimToday(
        provider: UsageProvider,
        input: UsageInput,
        now: Date
    ) -> Bool {
        let dayStart = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let samples = history(for: provider).sorted { $0.at < $1.at }
        guard var baseline = samples.last(where: { $0.at < dayStart }) ?? samples.first else { return false }
        for sample in samples where sample.at >= dayStart {
            if Self.grew(from: baseline, to: sample) { return true }
            baseline = sample
        }
        return Self.grew(
            from: baseline,
            to: UsageSample(
                at: 0,
                remaining: input.remaining,
                total: input.total,
                remainingPercent: nil,
                windows: nil
            )
        )
    }

    private static func grew(from previous: UsageSample, to current: UsageSample) -> Bool {
        if let value = previous.remaining, let next = current.remaining, next > value + 0.5 { return true }
        if let value = previous.total, let next = current.total, next > value + 0.5 { return true }
        return false
    }

    /// 一次采集的目标：名称、超时预算与退避基准全部来自注册表。
    /// Codex 需要等本机 app-server 应答，WorkBuddy 走本机 socket，分开给预算，
    /// 一家挂死不会把另一家已经采好的数据一起超时掉。
    private struct CollectionTarget: Sendable {
        let provider: UsageProvider

        var name: String { provider.descriptor.collectorKey }
        var title: String { provider.displayName }
        var timeout: TimeInterval { provider.descriptor.collectorTimeout }
        var baseInterval: TimeInterval { provider.descriptor.refreshInterval }
    }

    /// 环境类失败（超时、python3 缺失、输出不可解析）按指数退避，避免每个周期反复重开子进程。
    private var collectorFailures: [UsageProvider: Int] = [:]
    private var collectorRetryAt: [UsageProvider: Date] = [:]

    private func canCollect(_ provider: UsageProvider) -> Bool {
        guard let at = collectorRetryAt[provider] else { return true }
        return Date() >= at
    }

    private func registerFailure(_ target: CollectionTarget, message: String) {
        let failures = (collectorFailures[target.provider] ?? 0) + 1
        collectorFailures[target.provider] = failures
        let interval = min(target.baseInterval * pow(2, Double(min(failures - 1, 4))), 900)
        collectorRetryAt[target.provider] = Date().addingTimeInterval(interval)
        Diagnostics.record(
            "collector",
            "\(target.name) 连续 \(failures) 次采集失败，\(Int(interval)) 秒后重试：\(message)"
        )
    }

    private func resetFailures(_ target: CollectionTarget) {
        guard collectorFailures[target.provider] != nil else { return }
        Diagnostics.record("collector", "\(target.name) 采集恢复")
        collectorFailures[target.provider] = nil
        collectorRetryAt[target.provider] = nil
    }

    private func setError(_ message: String?, for provider: UsageProvider) {
        states[provider]?.error = message
    }

    private func consume(_ run: CollectorRunner.RunResult, from target: CollectionTarget) {
        guard let output = run.output else {
            let message = run.error ?? "采集器运行失败"
            registerFailure(target, message: message)
            setError(message, for: target.provider)
            return
        }
        resetFailures(target)
        if let fatal = output.providerErrors["all"] {
            setError(fatal, for: target.provider)
            Diagnostics.record("collector", "\(target.name)：\(fatal)")
            return
        }
        guard let result = output.providers?[target.name] else {
            let message = output.providerErrors[target.name] ?? "采集器未返回 \(target.title) 数据"
            setError(message, for: target.provider)
            Diagnostics.record("collector", "\(target.name)：\(message)")
            return
        }
        apply(result, to: target.provider)
    }

    /// 手动刷新与唤醒都强制采集一次，忽略退避窗口。
    func refreshAll() {
        for group in Self.groups {
            refresh(group.providers, force: true)
        }
    }

    /// 一批采集目标：跳过在途与仍在退避窗口里的供应商。
    private func targets(_ providers: [UsageProvider], force: Bool) -> [CollectionTarget] {
        providers
            .filter { !self.isRefreshing($0) && (force || self.canCollect($0)) }
            .map { CollectionTarget(provider: $0) }
    }

    func refresh(_ providers: [UsageProvider], force: Bool = false) {
        let batch = targets(providers, force: force)
        guard !batch.isEmpty else { return }
        for target in batch { states[target.provider]?.isRefreshing = true }
        Task.detached(priority: .utility) { [weak self] in
            guard let store = self else { return }
            // 逐个采集、采完立刻回主线程更新：慢的一家（最多等满自己的超时）不会压着
            // 已经采好的一家让面板等到最后才刷新。
            for target in batch {
                let run = CollectorRunner.run(provider: target.name, timeout: target.timeout)
                await MainActor.run { store.consume(run, from: target) }
            }
            await MainActor.run {
                let finished = Date()
                for target in batch {
                    store.states[target.provider]?.isRefreshing = false
                    store.states[target.provider]?.lastCollectedAt = finished
                }
                store.saveCache()
                store.recomputeAttention(now: finished)
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
                    self.setError(error, for: .qoder)
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
                    self.setError(nil, for: .qoder)
                    self.refresh([.qoder])
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
        guard Providers.all.contains(where: { self.isReminderEnabled($0.id) })
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

    /// 到点通知的标识沿用注册表里登记的提醒键名，与旧版本写死的三个 id 一致。
    private func refreshReminders() {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: Providers.all.map(\.reminderDefaultsKey)
        )
        for descriptor in Providers.all where isReminderEnabled(descriptor.id) {
            switch descriptor.claimReminder {
            case let .daily(hour, grant, body):
                addDailyReminder(
                    id: descriptor.reminderDefaultsKey,
                    title: "\(descriptor.displayName) 今日 \(grant) 可领取",
                    body: body,
                    hour: hour,
                    minute: 0,
                    category: NotificationCategory.forProvider(descriptor.id)
                )
            case .windowReset:
                scheduleWindowResetReminder(for: descriptor.id)
            }
        }
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

    /// 窗口制没有每日领取，改成在最长窗口的重置点之后立刻通知一次。
    private func scheduleWindowResetReminder(for provider: UsageProvider) {
        let id = provider.descriptor.reminderDefaultsKey
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
        guard isReminderEnabled(provider),
              let windows = result(for: provider)?.windows,
              let window = windows.max(by: { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }),
              let minutes = window.windowMinutes,
              let reset = window.resetsAt else { return }
        let now = Int(Date().timeIntervalSince1970)
        guard reset > now else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) \(Format.window(minutes))额度已重置"
        content.body = "额度窗口已刷新，可以继续使用。"
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.forProvider(provider)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(reset - now) + 30,
            repeats: false
        )
        notificationCenter.add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger),
            withCompletionHandler: nil
        )
    }

    private func apply(_ result: ProviderResult, to provider: UsageProvider) {
        guard result.ok == true else {
            let message = result.error
                ?? (result.ok == nil ? "采集结果缺少状态字段，请升级应用" : "未知错误")
            // 只在状态变化时记一行，否则「未登录」这类稳定状态会被每个周期刷满日志。
            if error(for: provider) != message {
                Diagnostics.record("collector", "\(provider.displayName) 数据不可用：\(message)")
            }
            setError(message, for: provider)
            return
        }
        if error(for: provider) != nil {
            Diagnostics.record("collector", "\(provider.displayName) 数据恢复")
        }
        states[provider]?.result = result
        states[provider]?.error = nil
        if case .windowReset = provider.descriptor.claimReminder {
            scheduleWindowResetReminder(for: provider)
        }
        recordHistory(provider: provider, result: result)
        evaluateAlerts(provider: provider, result: result)
    }

    func forecast(for provider: UsageProvider) -> UsageForecast? {
        guard let result = result(for: provider), result.ok == true else { return nil }
        return UsageAnalytics.forecast(
            provider: provider,
            input: usageInput(result),
            samples: history(for: provider),
            lowThreshold: lowThreshold
        )
    }

    func insight(for provider: UsageProvider) -> UsageInsight? {
        guard let result = result(for: provider), result.ok == true else { return nil }
        return UsageAnalytics.insight(
            provider: provider,
            input: usageInput(result),
            samples: history(for: provider)
        )
    }

    /// 采集成功且可用的供应商。
    func availableResult(for provider: UsageProvider) -> ProviderResult? {
        guard let result = result(for: provider), result.ok == true else { return nil }
        return result
    }

    private func usageInput(_ result: ProviderResult) -> UsageInput {
        UsageInput(
            remaining: result.remaining,
            total: result.total,
            remainingPercent: result.remainingPercent,
            windows: (result.windows ?? []).compactMap { window in
                guard let minutes = window.windowMinutes,
                      let remaining = window.remainingPercent else { return nil }
                return UsageWindow(
                    minutes: minutes,
                    remainingPercent: remaining,
                    usedPercent: window.usedPercent ?? (100 - remaining),
                    resetsAt: window.resetsAt
                )
            }
        )
    }

    private func setHistory(_ samples: [UsageSample], for provider: UsageProvider) {
        states[provider]?.history = samples
    }

    private func loadHistory() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: Self.historyURL.path) else { return }
        if let file = Self.decodeHistory(at: Self.historyURL) {
            applyHistory(file)
            return
        }
        // 主文件读不出：先确认备份能不能救，再把坏文件改名留证。
        let fallback = Self.decodeHistory(at: Self.historyBackupURL)
        moveMainHistoryAside()
        if let file = fallback {
            Diagnostics.record("history", "history.json 无法解析，已回退到上一份备份")
            applyHistory(file)
            return
        }
        // 备份也读不出：坏文件已经改名保留，重新开始积累不会覆盖唯一证据。
        try? manager.removeItem(at: Self.historyBackupURL)
        Diagnostics.record("history", "历史文件与备份均无法解析，已改名保留后重新开始积累")
    }

    private func applyHistory(_ snapshot: HistorySnapshot) {
        let now = Date()
        for provider in UsageProvider.allCases {
            states[provider]?.history = UsageAnalytics.prune(snapshot.samples[provider] ?? [], now: now)
        }
    }

    private static func decodeHistory(at url: URL) -> HistorySnapshot? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return LocalData.decodeHistory(data)
    }

    /// 把读不出的主文件改名留证；备份是否删除由调用方决定。
    private func moveMainHistoryAside() {
        let manager = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let kept = Self.historyURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp)")
            .appendingPathExtension("json")
        try? manager.removeItem(at: kept)
        try? manager.moveItem(at: Self.historyURL, to: kept)
        // 只留最近两份取证文件，避免长期故障把目录塞满。
        let directory = Self.historyURL.deletingLastPathComponent()
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let corrupt = names.filter { $0.hasPrefix("history.corrupt-") }.sorted()
        for name in corrupt.dropLast(2) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func saveHistory() {
        let snapshot = HistorySnapshot(
            samples: Providers.all.reduce(into: [:]) { partial, descriptor in
                partial[descriptor.id] = history(for: descriptor.id)
            }
        )
        guard let data = LocalData.encodeHistory(snapshot) else {
            Diagnostics.record("history", "历史编码失败，本轮未写入")
            return
        }
        let manager = FileManager.default
        let directory = Self.historyURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // 每次覆盖前先轮换一份备份：写入被中断时最多退回上一份，不会两个文件一起坏。
            if manager.fileExists(atPath: Self.historyURL.path) {
                try? manager.removeItem(at: Self.historyBackupURL)
                try manager.copyItem(at: Self.historyURL, to: Self.historyBackupURL)
            }
            try data.write(to: Self.historyURL, options: .atomic)
        } catch {
            Diagnostics.record("history", "历史写入失败：\(error.localizedDescription)")
        }
    }

    private func seedHistoryFromCache() {
        for provider in Providers.all {
            guard let result = result(for: provider.id), result.ok == true,
                  let date = result.updatedDate else { continue }
            recordHistory(provider: provider.id, result: result, at: date)
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

    func exportHistory() {
        UsageExport.save(Providers.all.reduce(into: [:]) { partial, descriptor in
            partial[descriptor.id] = history(for: descriptor.id)
        })
    }

    private func evaluateAlerts(provider: UsageProvider, result: ProviderResult) {
        guard !notificationsDenied else { return }
        let input = usageInput(result)
        let now = Date()
        evaluateLowAlert(provider: provider, input: input, now: now)
        if provider.isPercent {
            evaluateExhaustionAlert(provider: provider, input: input, now: now)
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
        if provider.isPercent, let window = UsageAnalytics.lowestWindow(of: input) {
            title = "\(provider.displayName) \(UsageAnalytics.windowText(window.minutes))窗口低于 \(threshold)%"
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

    /// 窗口制的耗尽风险：按窗口「可能在重置前耗尽」逐一判定，去重键沿用既有的
    /// `alert.<provider>.exhaust.<minutes>`，写入的是该窗口的重置时间。
    private func evaluateExhaustionAlert(provider: UsageProvider, input: UsageInput, now: Date) {
        guard alertExhaustion else { return }
        guard let forecast = UsageAnalytics.forecast(
            provider: provider,
            input: input,
            samples: history(for: provider),
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
        let key = "alert.\(provider.rawValue).exhaust.\(risk.minutes)"
        let resetEpoch = Int(reset.timeIntervalSince1970)
        guard defaults.integer(forKey: key) != resetEpoch else { return }

        let title = "\(provider.displayName) \(UsageAnalytics.windowText(risk.minutes))窗口可能在重置前耗尽"
        let body = "剩余 \(Int(risk.remainingPercent.rounded()))%，按近期速度预计 \(Format.reset(Int(risk.exhaustAt.timeIntervalSince1970))) 耗尽，早于重置时间 \(Format.reset(resetEpoch))。"
        deliverAlert(
            id: key,
            title: title,
            body: body,
            provider: provider
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
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Diagnostics.record(
                "alert",
                allowed
                    ? "\(provider.displayName) \(title)｜\(body)"
                    : "\(provider.displayName) \(title)｜通知未授权，只保留面板提示"
            )
            guard allowed else { return }
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
                if let error {
                    Diagnostics.record("notify", "通知投递失败：\(error.localizedDescription)")
                } else {
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

    /// 一个刷新节奏一组一个定时器：快组照常 60 秒，走 CLI 的 Qoder 单独按自己的间隔跑。
    private func scheduleTimers() {
        for group in Self.groups {
            let timer = Timer(timeInterval: group.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh(group.providers) }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimers.append(timer)
        }
    }

    /// 面板展开时补采注册表里标记的供应商：领取、消耗都要等下一个定时周期才反映太慢。
    /// 采集耗时约 5 秒且异步进行，面板先显示缓存值，回来后自动就地更新。
    func refreshStaleForPanel() {
        let now = Date()
        for provider in Providers.panelRefreshProviders {
            guard let at = lastCollectedAt(for: provider),
                  now.timeIntervalSince(at) >= provider.descriptor.refreshInterval else { continue }
            refresh([provider])
        }
    }

    private func loadCache() {
        guard FileManager.default.fileExists(atPath: Self.cacheURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let snapshot = LocalData.decodeCache(data) else {
            Diagnostics.record("cache", "cache.json 无法解析，本次启动从空白状态开始")
            return
        }
        for descriptor in Providers.all {
            states[descriptor.id]?.result = snapshot.results[descriptor.id]
            states[descriptor.id]?.lastCollectedAt = snapshot.collectedAt[descriptor.id]
        }
    }

    private func saveCache() {
        var snapshot = CacheSnapshot()
        for descriptor in Providers.all {
            snapshot.results[descriptor.id] = states[descriptor.id]?.result
            if let at = states[descriptor.id]?.lastCollectedAt {
                snapshot.collectedAt[descriptor.id] = at
            }
        }
        guard let data = LocalData.encodeCache(snapshot) else {
            Diagnostics.record("cache", "缓存编码失败")
            return
        }
        do {
            let directory = Self.cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            Diagnostics.record("cache", "缓存写入失败：\(error.localizedDescription)")
        }
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

    static func window(_ minutes: Int?) -> String {
        window(minutes ?? 0)
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
    let compact: Bool
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
        compact: Bool = false,
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
        self.compact = compact
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Token.spaceTight + 2 : Token.spaceRow) {
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
                    if !compact {
                        Text(subtitle)
                            .font(Token.caption)
                            .foregroundStyle(.secondary)
                    }
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
            .frame(minHeight: compact || status != nil ? 0 : Token.detailMinHeight, alignment: .top)

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

            if compact {
                if !links.isEmpty {
                    linksRow
                }
            } else {
                Divider()
                    .overlay(Color(nsColor: .separatorColor).opacity(0.5))
                HStack(spacing: Token.spaceRow) {
                    Text(footer)
                        .font(Token.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: Token.spaceTight)
                    linksRow
                }
                .frame(height: 20)
            }
        }
        .padding(compact ? Token.spaceTight + 4 : Token.spaceCard)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .fill(Token.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .stroke(Token.cardStroke.opacity(0.6), lineWidth: Token.hairline)
        )
    }

    private var linksRow: some View {
        HStack(spacing: Token.spaceRow) {
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
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case classic
    case compact
    case bars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "数字"
        case .compact: return "紧凑"
        case .bars: return "条形"
        }
    }

    var sample: String {
        switch self {
        case .classic: return "Q 1,870   W 1,208   C 58%"
        case .compact: return "Q1.9k W1.2k C58%"
        case .bars: return "条形 + 72% 40% 58%"
        }
    }
}

/// 菜单栏上单个平台的展示数据：三种样式共用同一份，隐藏开关也在这里生效。
struct MenuBarMetric {
    let letter: String
    let value: String
    let compact: String
    let percent: String
    let fraction: Double?
    let tint: Color
}

/// 条形样式左侧的小图：每个平台一列竖条，按品牌色从底部填充剩余比例。
/// 显式给 1x/2x 两种位图，避免菜单栏在 Retina 上放大糊掉。
enum MenuBarGlyph {
    static let size = NSSize(width: 15, height: 12)

    static func bars(_ metrics: [MenuBarMetric], dimmed: Bool) -> NSImage {
        let image = NSImage(size: size)
        for scale in [CGFloat(2), 1] {
            guard let rep = bitmap(metrics, dimmed: dimmed, scale: scale) else { continue }
            image.addRepresentation(rep)
        }
        return image
    }

    private static func bitmap(_ metrics: [MenuBarMetric], dimmed: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        rep.size = size
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        draw(metrics, dimmed: dimmed)
        context.flushGraphics()
        NSGraphicsContext.current = previous
        return rep
    }

    private static func draw(_ metrics: [MenuBarMetric], dimmed: Bool) {
        let count = metrics.count
        guard count > 0 else { return }
        let rect = NSRect(origin: .zero, size: size)
        let gap: CGFloat = 2.25
        let columnWidth = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let radius = min(columnWidth / 2, 1.4)
        let trackColor = NSColor.labelColor.withAlphaComponent(dimmed ? 0.10 : 0.20)
        for (index, metric) in metrics.enumerated() {
            let x = CGFloat(index) * (columnWidth + gap)
            trackColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: 0, width: columnWidth, height: rect.height),
                xRadius: radius,
                yRadius: radius
            ).fill()
            guard let fraction = metric.fraction, fraction > 0 else { continue }
            NSColor(metric.tint)
                .withAlphaComponent(dimmed ? 0.25 : 1)
                .setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: 0, width: columnWidth, height: max(2.5, rect.height * fraction)),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
    }
}

extension UsageStore {
    var menuBarMetrics: [MenuBarMetric] {
        Providers.ordered.compactMap { menuBarMetric(for: $0) }
    }

    private func menuBarMetric(for descriptor: ProviderDescriptor) -> MenuBarMetric? {
        guard isShownInMenuBar(descriptor.id) else { return nil }
        let result = result(for: descriptor.id)
        let ok = result?.ok == true
        let value: String
        let compact: String
        let percent: Double?
        if descriptor.isPercent {
            percent = ok ? result?.primaryWindow?.remainingPercent : nil
            value = Format.percent(percent)
            compact = value
        } else {
            let remaining: Double? = ok ? result?.remaining : nil
            percent = percentOf(remaining, over: ok ? (result?.total ?? 0) : 0)
            value = Format.credits(remaining)
            compact = Format.compact(remaining)
        }
        return MenuBarMetric(
            letter: descriptor.menuBarLetter,
            value: value,
            compact: compact,
            percent: Format.percent(percent),
            fraction: fractionOf(percent),
            tint: descriptor.color
        )
    }

    func menuBarText(for style: MenuBarStyle) -> String {
        let metrics = menuBarMetrics
        guard !metrics.isEmpty else { return "AI" }
        switch style {
        case .classic:
            return metrics.map { "\($0.letter) \($0.value)" }.joined(separator: "   ")
        case .compact:
            return metrics.map { "\($0.letter)\($0.compact)" }.joined(separator: " ")
        case .bars:
            return metrics.map(\.percent).joined(separator: " ")
        }
    }

    var menuBarText: String { menuBarText(for: menuBarStyle) }

    private func percentOf(_ remaining: Double?, over total: Double) -> Double? {
        guard let remaining, total > 0 else { return nil }
        return remaining / total * 100
    }

    private func fractionOf(_ percent: Double?) -> Double? {
        percent.map { min(max($0 / 100, 0), 1) }
    }

    var menuBarTooltip: String {
        var parts: [String] = []
        if !isAttentionMuted, let item = attentionItems.first {
            parts.append(item.kind == .warning ? "需要关注：\(item.title)" : "待处理：\(item.title)")
        }
        parts.append(contentsOf: Providers.ordered.map { tooltipLine(for: $0) })
        return parts.joined(separator: " · ")
    }

    private func tooltipLine(for descriptor: ProviderDescriptor) -> String {
        let result = result(for: descriptor.id)
        if descriptor.isPercent {
            guard result?.ok == true, let window = result?.primaryWindow else {
                return "\(descriptor.displayName) 不可用"
            }
            var line = "\(descriptor.displayName) \(Format.window(window.windowMinutes))窗口剩余 \(Format.percent(window.remainingPercent))"
            if let suffix = forecastSuffix(for: descriptor.id) { line += " · \(suffix)" }
            return line
        }
        guard let result, result.ok == true else { return "\(descriptor.displayName) 不可用" }
        var line = "\(descriptor.displayName) 剩余 \(Format.credits(result.remaining)) / \(Format.credits(result.total)) \(descriptor.creditUnit)"
        if let suffix = forecastSuffix(for: descriptor.id) { line += " · \(suffix)" }
        return line
    }

    private func forecastSuffix(for provider: UsageProvider) -> String? {
        guard let forecast = forecast(for: provider), forecast.text != "样本积累中" else {
            return nil
        }
        return forecast.text
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
            providerCards
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
                Text(Providers.ordered.map(\.displayName).joined(separator: " · "))
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
            ForEach(Array(store.refreshSummaries.enumerated()), id: \.offset) { index, summary in
                if index > 0 {
                    Text("·").foregroundStyle(.quaternary)
                }
                Text("\(summary.label) \(Format.time(summary.at))")
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Token.spaceTight)
            settingChip(
                "预警 \(store.lowBalanceThreshold)%",
                isOn: $store.alertLowBalance,
                iconOn: "exclamationmark.triangle.fill",
                iconOff: "exclamationmark.triangle",
                help: "任一平台剩余低于 \(store.lowBalanceThreshold)% 时提醒"
            )
            settingChip(
                "简单",
                isOn: $store.simpleMode,
                iconOn: "rectangle.compress.vertical",
                iconOff: "rectangle.expand.vertical",
                help: "简单模式：三个平台只显示主要用量与今日消耗，隐藏预测与更新时间"
            )
            Button {
                settingsExpanded.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text("设置")
                        .lineLimit(1)
                        .fixedSize()
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
            interfaceSettings
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

    /// 三家共用一套卡片外壳，内容按额度口径与额度布局分派，新增供应商不需要再加卡片。
    @ViewBuilder
    private var providerCards: some View {
        ForEach(Providers.ordered, id: \.id) { descriptor in
            providerCard(descriptor.id)
        }
    }

    private func providerCard(_ provider: UsageProvider) -> some View {
        let descriptor = provider.descriptor
        return ProviderCard(
            title: descriptor.displayName,
            subtitle: descriptor.subtitle,
            icon: descriptor.icon,
            color: descriptor.color,
            plan: Format.plan(store.result(for: provider)?.plan),
            value: cardValue(provider),
            valueCaption: cardCaption(provider),
            status: store.error(for: provider),
            footer: cardFooter(provider),
            links: cardLinks(provider),
            compact: store.simpleMode
        ) {
            providerContent(provider)
        }
    }

    private func cardValue(_ provider: UsageProvider) -> String {
        guard let result = store.result(for: provider), result.ok == true else { return "--" }
        switch provider.quotaKind {
        case .credits:
            return Format.credits(result.remaining)
        case .percentWindow:
            guard let window = result.primaryWindow else { return "--" }
            return Format.percent(window.remainingPercent)
        }
    }

    private func cardCaption(_ provider: UsageProvider) -> String {
        guard let result = store.result(for: provider), result.ok == true else { return "等待采集" }
        switch provider.quotaKind {
        case .credits:
            guard let total = result.total, total > 0 else { return "等待采集" }
            return "剩余 / 共 \(Format.credits(total)) \(provider.descriptor.creditUnit)"
        case .percentWindow:
            guard let window = result.primaryWindow else { return "等待采集" }
            return "\(Format.window(window.windowMinutes))窗口剩余"
        }
    }

    private func cardFooter(_ provider: UsageProvider) -> String {
        let result = store.result(for: provider)
        if store.error(for: provider) != nil, result != nil {
            return "上次成功 \(Format.time(result?.updatedDate))"
        }
        return "更新于 \(Format.time(result?.updatedDate ?? store.lastCollectedAt(for: provider)))"
    }

    private func cardLinks(_ provider: UsageProvider) -> [ProviderLink] {
        let descriptor = provider.descriptor
        var links = [
            ProviderLink(
                title: "打开",
                icon: "arrow.up.forward.app",
                help: descriptor.clientHelp
            ) {
                Apps.open(bundleID: descriptor.clientBundleID, fallback: descriptor.clientAppPath)
            },
            ProviderLink(
                title: "官网",
                icon: "globe",
                help: descriptor.websiteHelp
            ) {
                Apps.openURL(descriptor.websiteURL)
            },
        ]
        if descriptor.setup == .qoderCLI {
            links.append(contentsOf: qoderSetupLinks())
        }
        return links
    }

    /// Qoder 走 CLI 采集，未安装/未登录时把安装与授权动作放进卡片链接里。
    @ViewBuilder
    private func providerContent(_ provider: UsageProvider) -> some View {
        switch provider.quotaKind {
        case .credits:
            creditsContent(provider)
        case .percentWindow:
            windowContent(provider)
        }
    }

    @ViewBuilder
    private func creditsContent(_ provider: UsageProvider) -> some View {
        let descriptor = provider.descriptor
        if store.simpleMode {
            simpleCreditsBar(provider)
            simpleTodayRow(provider)
        } else if let result = store.result(for: provider) {
            switch descriptor.creditLayout ?? .resourcePackage {
            case .planBreakdown:
                let addonTotal = result.addonTotal ?? 0
                let addonUsed = result.addonUsed ?? 0
                let planTotal = result.planTotal ?? 0
                let planUsed = result.planUsed ?? 0
                if addonTotal > 0 {
                    UsageBar(
                        label: "附加额度",
                        detail: "已用 \(Format.credits(addonUsed)) / \(Format.credits(addonTotal))",
                        fraction: addonUsed / addonTotal,
                        tint: descriptor.color
                    )
                }
                if planTotal > 0 {
                    UsageBar(
                        label: "套餐额度",
                        detail: "已用 \(Format.credits(planUsed)) / \(Format.credits(planTotal))",
                        fraction: planUsed / planTotal,
                        tint: descriptor.color
                    )
                }
                if addonTotal == 0 && planTotal == 0 {
                    Text("当前套餐未包含 Credits")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
                if let expires = result.planExpiresAt, expires != "N/A", !expires.isEmpty {
                    Text("套餐到期 \(expires)")
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                }
                insightRow(provider)
                forecastRow(provider, tint: descriptor.color)
            case .resourcePackage:
                if let total = result.total, total > 0 {
                    UsageBar(
                        label: "Credits",
                        detail: "已用 \(Format.credits(result.used)) / \(Format.credits(total))",
                        fraction: (result.usedPercent ?? 0) / 100,
                        tint: descriptor.color
                    )
                    if let packages = result.packages, packages > 0 {
                        Text("\(packages) 个资源包")
                            .font(Token.caption)
                            .foregroundStyle(.secondary)
                    }
                    insightRow(provider)
                    forecastRow(provider, tint: descriptor.color)
                } else {
                    Text("暂无可用的 Credits 资源包")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            emptyContent
        }
    }

    /// 简单模式只保留最能代表当前余额的一条进度条。
    @ViewBuilder
    private func simpleCreditsBar(_ provider: UsageProvider) -> some View {
        let descriptor = provider.descriptor
        if let result = store.result(for: provider) {
            switch descriptor.creditLayout ?? .resourcePackage {
            case .planBreakdown:
                let planTotal = result.planTotal ?? 0
                let planUsed = result.planUsed ?? 0
                let addonTotal = result.addonTotal ?? 0
                let addonUsed = result.addonUsed ?? 0
                if planTotal > 0 {
                    UsageBar(
                        label: "套餐额度",
                        detail: "已用 \(Format.credits(planUsed)) / \(Format.credits(planTotal))",
                        fraction: planUsed / planTotal,
                        tint: descriptor.color
                    )
                } else if addonTotal > 0 {
                    UsageBar(
                        label: "附加额度",
                        detail: "已用 \(Format.credits(addonUsed)) / \(Format.credits(addonTotal))",
                        fraction: addonUsed / addonTotal,
                        tint: descriptor.color
                    )
                } else {
                    Text("当前套餐未包含 Credits")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
            case .resourcePackage:
                if let total = result.total, total > 0 {
                    UsageBar(
                        label: "Credits",
                        detail: "已用 \(Format.credits(result.used)) / \(Format.credits(total))",
                        fraction: (result.usedPercent ?? 0) / 100,
                        tint: descriptor.color
                    )
                } else {
                    Text("暂无可用的 Credits 资源包")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            emptyContent
        }
    }

    @ViewBuilder
    private func windowContent(_ provider: UsageProvider) -> some View {
        let descriptor = provider.descriptor
        if store.simpleMode {
            simpleWindowBar(provider)
            simpleTodayRow(provider)
        } else if let result = store.result(for: provider) {
            if let windows = result.windows, !windows.isEmpty {
                ForEach(windows) { window in
                    UsageBar(
                        label: "\(Format.window(window.windowMinutes))窗口",
                        detail: "已用 \(Format.percent(window.usedPercent)) · 剩余 \(Format.percent(window.remainingPercent))",
                        fraction: (window.usedPercent ?? 0) / 100,
                        tint: descriptor.color
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
                if let credits = result.credits, credits.hasCredits == true {
                    Text(credits.unlimited == true ? "无限" : "余额 \(Format.credits(credits.balance, digits: 2))")
                } else {
                    Text("无")
                }
            }
            .font(Token.caption)
            .foregroundStyle(.secondary)
            insightRow(provider)
            forecastRow(provider, tint: descriptor.color)
        } else {
            emptyContent
        }
    }

    @ViewBuilder
    private func simpleWindowBar(_ provider: UsageProvider) -> some View {
        if let result = store.result(for: provider) {
            if let window = result.primaryWindow {
                UsageBar(
                    label: "\(Format.window(window.windowMinutes))窗口",
                    detail: "已用 \(Format.percent(window.usedPercent)) · 剩余 \(Format.percent(window.remainingPercent))",
                    fraction: (window.usedPercent ?? 0) / 100,
                    tint: provider.descriptor.color
                )
            } else {
                Text("当前账号没有限额窗口")
                    .font(Token.meta)
                    .foregroundStyle(.secondary)
            }
        } else {
            emptyContent
        }
    }

    private func qoderSetupLinks() -> [ProviderLink] {
        var links: [ProviderLink] = []
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
            if let error = store.error(for: .qoder) {
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

    @ViewBuilder
    private func simpleTodayRow(_ provider: UsageProvider) -> some View {
        if let insight = store.insight(for: provider), let today = insight.todayConsumed {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 10, weight: .semibold))
                Text("今日消耗 \(insightValue(today, percent: insight.isPercent))")
                    .font(Token.meta)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .help("按本机历史采样估算，领取或重置带来的增加不计入消耗。")
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
    private var interfaceSettings: some View {
        settingRow("界面") {
            settingChip(
                "简单模式",
                isOn: $store.simpleMode,
                iconOn: "rectangle.compress.vertical",
                iconOff: "rectangle.expand.vertical",
                help: "三个平台只显示主要用量与今日消耗，隐藏预测与更新时间"
            )
        }
    }

    @ViewBuilder
    private var menuBarSettings: some View {
        settingRow("样式") {
            ForEach(MenuBarStyle.allCases) { style in
                styleChip(style)
            }
        }
        settingRow("菜单栏") {
            ForEach(Providers.ordered, id: \.id) { descriptor in
                settingChip(
                    descriptor.displayName,
                    isOn: store.menuBarBinding(for: descriptor.id),
                    iconOn: "eye.fill",
                    iconOff: "eye.slash",
                    help: "在菜单栏显示 \(descriptor.displayName)"
                )
            }
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
            ForEach(Providers.ordered, id: \.id) { descriptor in
                settingChip(
                    descriptor.displayName,
                    isOn: store.reminderBinding(for: descriptor.id),
                    iconOn: "bell.fill",
                    iconOff: "bell.slash",
                    help: reminderHelp(descriptor)
                )
            }
        }
    }

    /// 提醒开关的说明文字直接由注册表里的提醒形态拼出来，避免两处文案各写一份。
    private func reminderHelp(_ descriptor: ProviderDescriptor) -> String {
        switch descriptor.claimReminder {
        case .daily(let hour, let grant, _):
            return "每天 \(String(format: "%02d", hour)):00 提醒领取 \(descriptor.displayName) \(grant)"
        case .windowReset:
            return "\(descriptor.displayName) 额度重置时提醒"
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

    private func styleChip(_ style: MenuBarStyle) -> some View {
        let selected = store.menuBarStyle == style
        return Button {
            store.menuBarStyle = style
        } label: {
            Text(style.title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .fixedSize()
                .foregroundStyle(selected ? Theme.qoder : Color.secondary)
                .background(
                    Capsule().fill(selected ? Theme.qoder.opacity(0.14) : Token.insetFill)
                )
                .overlay(
                    Capsule().stroke(
                        selected ? Theme.qoder.opacity(0.28) : Token.cardStroke.opacity(0.5),
                        lineWidth: Token.hairline
                    )
                )
        }
        .buttonStyle(.plain)
        .help("菜单栏显示 \(style.sample)")
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
            Button("诊断") {
                Apps.revealDiagnostics()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help("在 Finder 中显示本地诊断日志（已脱敏，不含凭据与账号信息）")
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
    var onHeightChange: ((CGFloat) -> Void)? = nil

    /// 内容自然高度（未裁剪）；为 0 表示还没量过，先按 maxHeight 撑开。
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight + 0.5) {
            MenuContent(store: store, updates: updates)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(width: Token.panelWidth, height: panelHeight)
        .background(.regularMaterial)
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            let rounded = ceil(height)
            guard rounded > 0, abs(rounded - contentHeight) > 0.5 else { return }
            contentHeight = rounded
            onHeightChange?(rounded)
        }
    }

    private var panelHeight: CGFloat {
        guard contentHeight > 0 else { return maxHeight }
        return min(contentHeight, maxHeight)
    }
}

private struct PanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

    static func revealDiagnostics() {
        let log = Diagnostics.logURL
        let manager = FileManager.default
        try? manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(log.deletingLastPathComponent())
        }
    }

    static func openTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }
}
