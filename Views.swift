import SwiftUI
import AppKit
import Combine
import Darwin

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

    private struct CacheFile: Codable {
        var codex: ProviderResult?
        var workbuddy: ProviderResult?
        var qoder: ProviderResult?
        var fastAt: Double?
        var qoderAt: Double?
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/cache.json")
    }

    private enum Provider { case codex, workbuddy, qoder }
    private var fastTimer: Timer?
    private var qoderTimer: Timer?

    init(refreshOnStart: Bool = true) {
        loadCache()
        guard refreshOnStart else { return }
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
        case .workbuddy:
            workbuddy = result
            workbuddyError = nil
        case .qoder:
            qoder = result
            qoderError = nil
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

struct ProviderCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let plan: String?
    let error: String?
    let footer: String
    let actionTitle: String?
    let action: (() -> Void)?
    let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        plan: String? = nil,
        error: String? = nil,
        footer: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.plan = plan
        self.error = error
        self.footer = footer
        self.actionTitle = actionTitle
        self.action = action
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

            HStack(spacing: 8) {
                Text(footer)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(color)
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

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Text("Q \(qoderText)   W \(workbuddyText)   C \(codexText)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .help(tooltip)
    }

    private var qoderText: String {
        guard let qoder = store.qoder, qoder.ok == true, let percent = qoder.remainingPercent, (qoder.total ?? 0) > 0 else {
            return "--"
        }
        return Format.percent(percent)
    }

    private var workbuddyText: String {
        guard let workbuddy = store.workbuddy, workbuddy.ok == true else { return "--" }
        return Format.compact(workbuddy.remaining)
    }

    private var codexText: String {
        guard let codex = store.codex, codex.ok == true, let window = codex.primaryWindow else { return "--" }
        return Format.percent(window.remainingPercent)
    }

    private var tooltip: String {
        var parts: [String] = []
        if let qoder = store.qoder, qoder.ok == true {
            parts.append("Qoder \(Format.percent(qoder.remainingPercent))（剩余 \(Format.credits(qoder.remaining)) / \(Format.credits(qoder.total))）")
        } else {
            parts.append("Qoder 不可用")
        }
        if let workbuddy = store.workbuddy, workbuddy.ok == true {
            parts.append("WorkBuddy 剩余 \(Format.credits(workbuddy.remaining)) / \(Format.credits(workbuddy.total)) credits")
        } else {
            parts.append("WorkBuddy 不可用")
        }
        if let codex = store.codex, codex.ok == true, let window = codex.primaryWindow {
            parts.append("Codex \(Format.window(window.windowMinutes))窗口剩余 \(Format.percent(window.remainingPercent))")
        } else {
            parts.append("Codex 不可用")
        }
        return parts.joined(separator: " · ")
    }
}

struct MenuContent: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            qoderCard
            workbuddyCard
            codexCard
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 382)
        .background(.regularMaterial)
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

    private var qoderCard: some View {
        ProviderCard(
            title: "Qoder",
            subtitle: "官方 CLI · 账号额度",
            icon: "curlybraces",
            color: Theme.qoder,
            plan: Format.plan(store.qoder?.plan),
            error: store.qoderError,
            footer: qoderFooter,
            actionTitle: qoderActionTitle,
            action: qoderAction
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
                    Text("已用 \(Format.percent(qoder.usedPercent))")
                    Spacer()
                    if let expires = qoder.planExpiresAt, expires != "N/A", !expires.isEmpty {
                        Text("到期 \(expires)")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
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
            actionTitle: store.workbuddyError == nil ? nil : "打开 WorkBuddy",
            action: store.workbuddyError == nil ? nil : {
                Apps.open(bundleID: "com.tencent.workbuddy.mac", fallback: "/Applications/WorkBuddy.app")
            }
        ) {
            if let workbuddy = store.workbuddy, let total = workbuddy.total, total > 0 {
                UsageBar(
                    label: "Credits",
                    detail: "剩余 \(Format.credits(workbuddy.remaining)) / \(Format.credits(total))",
                    fraction: (workbuddy.usedPercent ?? 0) / 100,
                    tint: Theme.workbuddy
                )
                HStack(spacing: 8) {
                    Text("已用 \(Format.percent(workbuddy.usedPercent))")
                    Spacer()
                    Text("\(workbuddy.packages ?? 0) 个资源包")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
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
            actionTitle: store.codexError == nil ? nil : "打开 ChatGPT",
            action: store.codexError == nil ? nil : {
                Apps.open(bundleID: "com.openai.chat", fallback: "/Applications/ChatGPT.app")
            }
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
            } else {
                emptyContent
            }
        }
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

    private var qoderActionTitle: String? {
        guard let error = store.qoderError else { return nil }
        if error.contains("未登录") { return "打开终端登录" }
        if error.contains("未安装") { return "安装说明" }
        return nil
    }

    private var qoderAction: (() -> Void)? {
        guard let error = store.qoderError else { return nil }
        if error.contains("未登录") {
            return { Apps.openTerminal("~/.local/bin/qoderclicn login") }
        }
        if error.contains("未安装") {
            return { Apps.openURL("https://docs.qoder.cn/cli/installation") }
        }
        return nil
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
