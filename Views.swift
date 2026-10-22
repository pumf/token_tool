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

    static func run(provider: String, timeout: TimeInterval = 80) -> RunResult {
        guard let script = Bundle.main.url(forResource: "collector", withExtension: "py") else {
            return RunResult(output: nil, error: "采集器文件缺失")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--provider", provider]
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return RunResult(output: nil, error: "无法启动采集器")
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
            return RunResult(output: nil, error: "采集超时")
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return RunResult(output: nil, error: "采集器没有返回数据")
        }
        do {
            let output = try JSONDecoder().decode(CollectorOutput.self, from: data)
            return RunResult(output: output, error: nil)
        } catch {
            return RunResult(output: nil, error: "采集器输出无法解析")
        }
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
        }
    }
    @Published var alertExhaustion: Bool {
        didSet {
            UserDefaults.standard.set(alertExhaustion, forKey: "alert.exhaustion")
            prepareNotificationAuthorization()
        }
    }
    @Published var alertAcceleration: Bool {
        didSet {
            UserDefaults.standard.set(alertAcceleration, forKey: "alert.acceleration")
            prepareNotificationAuthorization()
        }
    }
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
        loadCache()
        loadHistory()
        seedHistoryFromCache()
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

    func refreshAll() {
        refreshFast()
        refreshQoder()
    }

    func refreshFast() {
        guard !fastRefreshing else { return }
        fastRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let run = CollectorRunner.run(provider: "fast")
            await MainActor.run {
                guard let self else { return }
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
            }
        }
    }

    func refreshQoder() {
        guard !qoderRefreshing else { return }
        qoderRefreshing = true
        Task.detached(priority: .utility) { [weak self] in
            let run = CollectorRunner.run(provider: "qoder")
            await MainActor.run {
                guard let self else { return }
                if let output = run.output, let result = output.providers?["qoder"] {
                    self.apply(result, to: .qoder)
                } else {
                    self.qoderError = run.error ?? "采集器未返回 Qoder 数据"
                }
                self.lastQoderAt = Date()
                self.qoderRefreshing = false
                self.saveCache()
            }
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
            samples: history(for: provider)
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
        if percent > UsageAnalytics.lowRecovery {
            defaults.removeObject(forKey: key)
            return
        }
        guard percent <= UsageAnalytics.lowThreshold else { return }
        let epoch = now.timeIntervalSince1970
        let last = defaults.double(forKey: key)
        guard last == 0 || epoch - last >= UsageAnalytics.lowCooldown else { return }

        let threshold = Int(UsageAnalytics.lowThreshold)
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
            now: now
        ) else { return }
        guard let risk = forecast.windows
            .filter({ $0.exhaustsBeforeReset })
            .min(by: { $0.exhaustAt < $1.exhaustAt }) else { return }
        if alertLowBalance && risk.remainingPercent <= UsageAnalytics.lowThreshold {
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
        if alertLowBalance && percent <= UsageAnalytics.lowThreshold { return }

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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.13))
                    Capsule().fill(tint).frame(width: max(3, geometry.size.width * normalized))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.25), value: normalized)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let points = self.points(in: geometry.size)
            if points.count >= 2, let last = points.last {
                ZStack {
                    areaPath(points: points, height: geometry.size.height)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.16), tint.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(points: points)
                        .stroke(
                            tint,
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                        )
                    Circle()
                        .fill(tint)
                        .frame(width: 3, height: 3)
                        .position(last)
                }
            } else {
                Capsule()
                    .fill(tint.opacity(0.12))
                    .frame(height: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .accessibilityLabel("近 7 天剩余比例趋势")
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 100
        let low = max(0, minimum - 4)
        let high = min(100, maximum + 4)
        let span = max(high - low, 4)
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
    let action: () -> Void
}

struct ProviderCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let plan: String?
    let error: String?
    let footer: String
    let links: [ProviderLink]
    let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        plan: String? = nil,
        error: String? = nil,
        footer: String,
        links: [ProviderLink] = [],
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.plan = plan
        self.error = error
        self.footer = footer
        self.links = links
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(color)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.13)))
                        .foregroundStyle(color)
                }
            }

            content

            if let error {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(error)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
                .foregroundStyle(Theme.warning)
            }

            HStack(spacing: 9) {
                Text(footer)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button {
                        link.action()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: link.icon)
                                .font(.system(size: 8, weight: .semibold))
                            Text(link.title)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(color)
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .help(link.help)
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
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
        if let qoder, qoder.ok == true {
            parts.append("Qoder 剩余 \(Format.credits(qoder.remaining)) / \(Format.credits(qoder.total)) Credits")
        } else {
            parts.append("Qoder 不可用")
        }
        if let workbuddy, workbuddy.ok == true {
            parts.append("WorkBuddy 剩余 \(Format.credits(workbuddy.remaining)) / \(Format.credits(workbuddy.total)) credits")
        } else {
            parts.append("WorkBuddy 不可用")
        }
        if let codex, codex.ok == true, let window = codex.primaryWindow {
            parts.append("Codex \(Format.window(window.windowMinutes))窗口剩余 \(Format.percent(window.remainingPercent))")
        } else {
            parts.append("Codex 不可用")
        }
        return parts.joined(separator: " · ")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            updateBanner
            qoderCard
            workbuddyCard
            codexCard
            menuBarSettings
            reminderSettings
            alertSettings
            Divider()
            aboutRow
            footer
        }
        .padding(14)
        .frame(width: 382)
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
                    .font(.system(size: 10))
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
        }
    }

    @ViewBuilder
    private var updateBanner: some View {
        if let release = updates.pendingRelease {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.qoder)
                VStack(alignment: .leading, spacing: 1) {
                    Text("新版本 \(release.version) 可用")
                        .font(.system(size: 10, weight: .semibold))
                    Text(updateSubtitle)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(updates.primaryActionTitle) {
                    updates.performPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 9, weight: .medium))
                .disabled(!updates.canPerformPrimaryAction)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.qoder.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Theme.qoder.opacity(0.20), lineWidth: 0.5)
            )
            .help(releaseHelp(release))
        }
    }

    private var updateSubtitle: String {
        switch updates.state {
        case .downloading:
            return "正在下载安装包…"
        case .ready:
            return "安装包已打开，拖入「应用程序」完成升级"
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
            error: store.qoderError,
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
                        detail: "剩余 \(Format.credits(addonTotal - addonUsed)) / \(Format.credits(addonTotal))",
                        fraction: addonUsed / addonTotal,
                        tint: Theme.qoder
                    )
                }
                if planTotal > 0 {
                    UsageBar(
                        label: "套餐额度",
                        detail: "剩余 \(Format.credits(planTotal - planUsed)) / \(Format.credits(planTotal))",
                        fraction: planUsed / planTotal,
                        tint: Theme.qoder
                    )
                }
                if addonTotal == 0 && planTotal == 0 {
                    Text("当前套餐未包含 Credits")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("已用 \(Format.credits(qoder.used)) Credits")
                    Spacer()
                    if let expires = qoder.planExpiresAt, expires != "N/A", !expires.isEmpty {
                        Text("到期 \(expires)")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                insightRow(.qoder)
                forecastRow(.qoder, tint: Theme.qoder)
            } else {
                emptyContent
            }
        }
    }

    private var workbuddyCard: some View {
        ProviderCard(
            title: "WorkBuddy",
            subtitle: "本机客户端 · 资源包",
            icon: "briefcase.fill",
            color: Theme.workbuddy,
            plan: Format.plan(store.workbuddy?.plan),
            error: store.workbuddyError,
            footer: workbuddyFooter,
            links: workbuddyLinks
        ) {
            if let workbuddy = store.workbuddy, let total = workbuddy.total, total > 0 {
                UsageBar(
                    label: "Credits",
                    detail: "剩余 \(Format.credits(workbuddy.remaining)) / \(Format.credits(total))",
                    fraction: (workbuddy.usedPercent ?? 0) / 100,
                    tint: Theme.workbuddy
                )
                HStack(spacing: 8) {
                    Text("已用 \(Format.credits(workbuddy.used)) Credits")
                    Spacer()
                    Text("\(workbuddy.packages ?? 0) 个资源包")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                insightRow(.workbuddy)
                forecastRow(.workbuddy, tint: Theme.workbuddy)
            } else if store.workbuddy != nil {
                Text("暂无可用的 Credits 资源包")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                emptyContent
            }
        }
    }

    private var codexCard: some View {
        ProviderCard(
            title: "Codex",
            subtitle: "ChatGPT 登录 · 限额窗口",
            icon: "terminal.fill",
            color: Theme.codex,
            plan: Format.plan(store.codex?.plan),
            error: store.codexError,
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
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("当前账号没有限额窗口")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("Credits")
                    Spacer()
                    if let credits = codex.credits, credits.hasCredits {
                        Text(credits.unlimited ? "无限" : "余额 \(Format.credits(credits.balance, digits: 2))")
                    } else {
                        Text("无额外 Credits")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                insightRow(.codex)
                forecastRow(.codex, tint: Theme.codex)
            } else {
                emptyContent
            }
        }
    }

    @ViewBuilder
    private func forecastRow(_ provider: UsageProvider, tint: Color) -> some View {
        if let forecast = store.forecast(for: provider) {
            HStack(spacing: 7) {
                Sparkline(values: forecast.values, tint: tint)
                    .frame(width: 58, height: 16)
                Text(forecast.text)
                    .font(.system(size: 9, weight: forecast.warning ? .semibold : .regular))
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
                    .font(.system(size: 8, weight: .semibold))
                Text(insightText(insight))
                    .font(.system(size: 9))
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
            .font(.system(size: 11))
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
        if let error = store.qoderError {
            if error.contains("未登录") {
                links.append(ProviderLink(
                    title: "终端登录",
                    icon: "terminal",
                    help: "在终端登录 Qoder CLI"
                ) {
                    Apps.openTerminal("~/.local/bin/qoderclicn login")
                })
            } else if error.contains("未安装") {
                links.append(ProviderLink(
                    title: "安装 CLI",
                    icon: "arrow.down.circle",
                    help: "查看 Qoder CLI 安装说明"
                ) {
                    Apps.openURL("https://docs.qoder.cn/cli/installation")
                })
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

    private var menuBarSettings: some View {
        HStack(spacing: 6) {
            Text("菜单栏显示")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            settingChip(
                "Qoder",
                color: Theme.qoder,
                isOn: $store.showQoderInMenuBar,
                iconOn: "eye.fill",
                iconOff: "eye.slash",
                help: "在菜单栏显示 Qoder"
            )
            settingChip(
                "WorkBuddy",
                color: Theme.workbuddy,
                isOn: $store.showWorkBuddyInMenuBar,
                iconOn: "eye.fill",
                iconOff: "eye.slash",
                help: "在菜单栏显示 WorkBuddy"
            )
            settingChip(
                "Codex",
                color: Theme.codex,
                isOn: $store.showCodexInMenuBar,
                iconOn: "eye.fill",
                iconOff: "eye.slash",
                help: "在菜单栏显示 Codex"
            )
        }
    }

    private var reminderSettings: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("提醒")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                settingChip(
                    "Qoder 10:00",
                    color: Theme.qoder,
                    isOn: $store.remindQoderClaim,
                    iconOn: "bell.fill",
                    iconOff: "bell.slash",
                    help: "每天 10:00 提醒领取 Qoder 100 Credits"
                )
                settingChip(
                    "WorkBuddy 00:00",
                    color: Theme.workbuddy,
                    isOn: $store.remindWorkBuddyClaim,
                    iconOn: "bell.fill",
                    iconOff: "bell.slash",
                    help: "每天 00:00 提醒领取 WorkBuddy 100 积分"
                )
                settingChip(
                    "Codex 重置",
                    color: Theme.codex,
                    isOn: $store.remindCodexReset,
                    iconOn: "bell.fill",
                    iconOff: "bell.slash",
                    help: "Codex 额度重置时提醒"
                )
            }
            if store.notificationsDenied {
                HStack(spacing: 4) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text("系统通知未授权，提醒与预警不会弹出")
                    Spacer(minLength: 4)
                    Button("去开启") {
                        Apps.openURL("x-apple.systempreferences:com.apple.preference.notifications")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.warning)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var alertSettings: some View {
        HStack(spacing: 6) {
            Text("智能预警")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            settingChip(
                "低额度",
                color: Theme.warning,
                isOn: $store.alertLowBalance,
                iconOn: "exclamationmark.triangle.fill",
                iconOff: "exclamationmark.triangle",
                help: "剩余低于 20% 时提醒"
            )
            settingChip(
                "重置前耗尽",
                color: Theme.warning,
                isOn: $store.alertExhaustion,
                iconOn: "clock.fill",
                iconOff: "clock",
                help: "Codex 预计在额度重置前耗尽时提醒"
            )
            settingChip(
                "消耗加速",
                color: Theme.warning,
                isOn: $store.alertAcceleration,
                iconOn: "bolt.fill",
                iconOff: "bolt",
                help: "近 15 分钟消耗速度明显高于此前 1 小时时提醒"
            )
        }
    }

    private func settingChip(
        _ title: String,
        color: Color,
        isOn: Binding<Bool>,
        iconOn: String,
        iconOff: String,
        help: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isOn.wrappedValue ? iconOn : iconOff)
                    .font(.system(size: 8, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(isOn.wrappedValue ? color : Color.secondary)
            .background(
                Capsule().fill(isOn.wrappedValue ? color.opacity(0.13) : Color.primary.opacity(0.04))
            )
            .overlay(
                Capsule().stroke(
                    isOn.wrappedValue ? color.opacity(0.25) : Color.primary.opacity(0.08),
                    lineWidth: 0.5
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
            Spacer(minLength: 4)
            updateControl
        }
        .font(.system(size: 9))
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
            Button("已是最新") {
                updates.check()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重新检查 GitHub Releases")
        case .failed(let message):
            Button("重试检查") {
                updates.check()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.warning)
            .help(message)
        case .idle, .available:
            Button("检查更新") {
                updates.check()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("从 GitHub Releases 检查新版本")
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
